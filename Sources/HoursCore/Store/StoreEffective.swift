import Foundation

/// raw ⊕ edits → effective timeline. Pure; ms throughout; output sorted and non-overlapping.
///
/// 1. Liveness, descending seq: an edit is dead if its group was reverted by a live `undo`
///    (an undo's own group can be reverted too: undo-of-undo = redo).
/// 2. Live `delete`/`assign`/`add` apply in ascending seq (array order is irrelevant). `note` never changes time.
///    - delete: cut [lo,hi) out of every segment.
///    - assign: split at lo/hi; inside pieces take the payload's non-nil category/project.
///    - add: cut [lo,hi) (manual beats tracked), then insert a manual active segment.
///    Pieces an edit shaped carry its seq in `editSeqs` (provenance for "edited" + audit).
/// 3. Coalesce contiguous pieces of the same origin with identical overrides and provenance.
///
/// Manual segments: `appName` "", `bundleId`/`title`/`url` nil, `label` = the add's label, tz = the edit's tz.
public func effectiveSpans(raw: [RawSpan], edits: [Edit]) -> [EffectiveSpan] {
    var undone = Set<Int64>()
    var live: [Edit] = []
    for e in edits.sorted(by: { $0.seq > $1.seq }) where !undone.contains(e.grp) {
        switch e.op {
        case .undo: if let t = e.target { undone.insert(t) }
        case .note: break
        default: live.append(e)
        }
    }

    var segs = raw.filter { $0.endMs > $0.startMs }.sorted { $0.startMs < $1.startMs }.map {
        EffectiveSpan(startMs: $0.startMs, endMs: $0.endMs, tzId: $0.tzId, kind: $0.kind, bundleId: $0.bundleId,
                      appName: $0.appName, title: $0.title, url: $0.url, rawSeq: $0.seq)
    }
    for e in live.reversed() {
        switch e.payload {
        case .delete:
            segs = storeCut(segs, e.loMs, e.hiMs, e.seq)
        case let .assign(cat, proj):
            var out: [EffectiveSpan] = []
            out.reserveCapacity(segs.count + 2)
            for s in segs {
                guard s.startMs < e.hiMs, s.endMs > e.loMs else { out.append(s); continue }
                if s.startMs < e.loMs { var l = s; l.endMs = e.loMs; out.append(l) }
                var m = s
                m.startMs = max(s.startMs, e.loMs); m.endMs = min(s.endMs, e.hiMs)
                if let cat { m.categoryOverride = cat }
                if let proj { m.projectOverride = proj }
                m.editSeqs.append(e.seq)
                out.append(m)
                if s.endMs > e.hiMs { var r = s; r.startMs = e.hiMs; out.append(r) }
            }
            segs = out
        case let .add(label, cat, proj):
            segs = storeCut(segs, e.loMs, e.hiMs, e.seq)
            let manual = EffectiveSpan(startMs: e.loMs, endMs: e.hiMs, tzId: e.tzId, kind: .active, bundleId: nil,
                                       appName: "", title: nil, url: nil, categoryOverride: cat,
                                       projectOverride: proj, source: .manual, rawSeq: nil, label: label,
                                       editSeqs: [e.seq])
            let i = segs.firstIndex { $0.startMs >= e.hiMs } ?? segs.endIndex
            segs.insert(manual, at: i)
        case .undo, .note:
            break
        }
    }

    var out: [EffectiveSpan] = []
    out.reserveCapacity(segs.count)
    for s in segs {
        if let p = out.last, p.endMs == s.startMs, p.rawSeq == s.rawSeq, p.source == s.source,
           p.categoryOverride == s.categoryOverride, p.projectOverride == s.projectOverride,
           p.label == s.label, Set(p.editSeqs) == Set(s.editSeqs) {
            out[out.count - 1].endMs = s.endMs
        } else {
            out.append(s)
        }
    }
    return out
}

/// Clips spans to [lo, hi), dropping empties.
func storeClip(_ spans: [EffectiveSpan], _ lo: Int64, _ hi: Int64) -> [EffectiveSpan] {
    spans.compactMap { s in
        var c = s
        c.startMs = max(s.startMs, lo); c.endMs = min(s.endMs, hi)
        return c.endMs > c.startMs ? c : nil
    }
}

private func storeCut(_ segs: [EffectiveSpan], _ lo: Int64, _ hi: Int64, _ seq: Int64) -> [EffectiveSpan] {
    var out: [EffectiveSpan] = []
    out.reserveCapacity(segs.count + 1)
    for s in segs {
        guard s.startMs < hi, s.endMs > lo else { out.append(s); continue }
        if s.startMs < lo { var l = s; l.endMs = lo; l.editSeqs.append(seq); out.append(l) }
        if s.endMs > hi { var r = s; r.startMs = hi; r.editSeqs.append(seq); out.append(r) }
    }
    return out
}
