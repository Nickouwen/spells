import Foundation

/// Swift twin of `scripts/verify.py` for a proof bundle directory: seq contiguity, prev links,
/// content digests recomputed from every shown field (priv_hash too at L2), row hashes, anchor heads + token imprints,
/// and the per-file SHA-256s in summary.json. TSA signatures are left to openssl (verify.py).
public enum ExportBundleVerifier {
    public struct Report: Sendable, Equatable {
        public var rows = 0
        public var anchors = 0
        public var firstBadSeq: Int64?
        /// nil = pass.
        public var failure: String?
        public var notes: [String] = []
        public var ok: Bool { failure == nil }
    }

    public static func verify(_ dir: URL) throws -> Report {
        var rep = Report()
        func fail(_ seq: Int64?, _ why: String) -> Report { rep.firstBadSeq = seq; rep.failure = why; return rep }
        func read(_ name: String) throws -> Data { try Data(contentsOf: dir.appending(path: name)) }
        func n(_ s: String?) -> String? { s == ExportBundle.null ? nil : s }

        guard let summary = try JSONSerialization.jsonObject(with: try read("summary.json")) as? [String: Any],
              summary["format"] as? String == ExportBundle.format else {
            return fail(nil, "summary.json missing or not \(ExportBundle.format)")
        }

        var rows: [(seq: Int64, file: String, r: [String: String])] = []
        for f in ["raw_spans.csv", "edits.csv"] {
            for r in ExportCSV.parse(try read(f)) {
                guard let seq = Int64(r["seq"] ?? "") else { return fail(nil, "\(f): bad seq '\(r["seq"] ?? "")'") }
                rows.append((seq, f, r))
            }
        }
        rows.sort { $0.seq < $1.seq }

        var hashes: [Int64: Data] = [:]
        var prev: Data?
        for (i, row) in rows.enumerated() {
            let (seq, file, r) = row
            let at = "seq \(seq) (\(file))"
            if i > 0, seq != rows[i - 1].seq + 1 {
                return fail(seq, "\(at): seq gap or duplicate after \(rows[i - 1].seq)")
            }
            guard let rowPrev = exportUnhex(r["prev_hash"] ?? ""), rowPrev.count == 32,
                  var content = exportUnhex(r["content_digest"] ?? ""), content.count == 32,
                  let rowHash = exportUnhex(r["row_hash"] ?? ""), rowHash.count == 32 else {
                return fail(seq, "\(at): malformed hash field")
            }
            if let prev, rowPrev != prev { return fail(seq, "\(at): prev_hash mismatch") }
            // "fields": public fields + priv_hash → recompute content. "none": also recompute priv_hash.
            // "row": digest only, taken as given (its link is still checked).
            if r["redacted"] == "fields" || r["redacted"] == "none" {
                let full = r["redacted"] == "none"
                // A withheld row must not show private values: they'd be unbound (priv_hash is taken as given).
                let privCols = file == "raw_spans.csv" ? ["title", "url", "blind"] : ["payload", "blind"]
                if !full, privCols.contains(where: { r[$0] != ExportBundle.withheld }) {
                    return fail(seq, "\(at): withheld row carries private values")
                }
                var blind = Data()
                if full {
                    guard let b = exportUnhex(r["blind"] ?? ""), b.count == 16 else { return fail(seq, "\(at): malformed blind") }
                    blind = b
                }
                let i64 = { (k: String) in Int64(r[k] ?? "") }
                guard var priv = exportUnhex(r["priv_hash"] ?? ""), priv.count == 32 else {
                    return fail(seq, "\(at): malformed priv_hash")
                }
                let pub: Data, tag: UInt8
                if file == "raw_spans.csv" {
                    guard let s = i64("start_ms"), let e = i64("end_ms"), let off = i64("tz_offset_s") else {
                        return fail(seq, "\(at): bad span fields")
                    }
                    pub = ChainCodec.spanPublic(startMs: s, endMs: e, tzId: r["tz_id"] ?? "", tzOffsetS: off,
                                                kind: r["kind"] ?? "", bundleId: n(r["bundle_id"]), appName: r["app_name"] ?? "")
                    tag = ChainCodec.spanTag
                    if full {
                        let p = ChainCodec.spanPrivate(pub: pub, blind: blind, title: n(r["title"]), url: n(r["url"]))
                        if p != priv { return fail(seq, "\(at): priv_hash mismatch") }
                        priv = p
                    }
                } else {
                    guard let c = i64("created_ms"), let lo = i64("lo_ms"), let hi = i64("hi_ms"), let g = i64("grp") else {
                        return fail(seq, "\(at): bad edit fields")
                    }
                    pub = ChainCodec.editPublic(createdMs: c, tzId: r["tz_id"] ?? "", op: r["op"] ?? "", loMs: lo, hiMs: hi,
                                                target: n(r["target"]).flatMap { Int64($0) }, grp: g)
                    tag = ChainCodec.editTag
                    if full, ChainCodec.editPrivate(pub: pub, blind: blind, payload: r["payload"] ?? "") != priv {
                        return fail(seq, "\(at): priv_hash mismatch")
                    }
                }
                let recomputed = ChainCodec.content(tag: tag, pub: pub, priv: priv)
                if recomputed != content { return fail(seq, "\(at): content_digest mismatch") }
                content = recomputed
            } else if r["redacted"] == "row" {
                // Digest only: any shown field would be unbound, so a digest-only row must show none.
                let hashCols: Set = ["seq", "redacted", "content_digest", "prev_hash", "row_hash"]
                if r.contains(where: { !hashCols.contains($0.key) && !$0.value.isEmpty }) {
                    return fail(seq, "\(at): digest-only row carries field values")
                }
            } else {
                return fail(seq, "\(at): unknown redacted value '\(r["redacted"] ?? "")'")
            }
            let h = ChainCodec.rowHash(seq: seq, prev: rowPrev, content: content)
            if h != rowHash { return fail(seq, "\(at): row_hash mismatch") }
            hashes[seq] = h
            prev = h
            rep.rows += 1
        }

        let chain = summary["chain"] as? [String: Any] ?? [:]
        if let last = rows.last, (chain["end_seq"] as? Int64 ?? (chain["end_seq"] as? NSNumber)?.int64Value) != last.seq
            || chain["end_hash"] as? String != exportHex(hashes[last.seq]!) {
            return fail(last.seq, "summary.json chain end ≠ last row")
        }

        for a in ExportCSV.parse(try read("anchors.csv")) {
            let id = a["anchor_id"] ?? "?"
            guard let seq = Int64(a["head_seq"] ?? ""), let head = exportUnhex(a["head_hash"] ?? "") else {
                return fail(nil, "anchor \(id): malformed")
            }
            guard let h = hashes[seq] else { return fail(seq, "anchor \(id): head #\(seq) outside the bundle's rows") }
            if h != head { return fail(seq, "anchor \(id): head_hash contradicts the chain at seq \(seq)") }
            if let file = a["token_file"], !file.isEmpty {
                do {
                    let info = try RFC3161.parseToken(try read(file))
                    if info.imprint != head { return fail(seq, "anchor \(id): token imprint ≠ head_hash") }
                    if exportUTC(info.genTimeMs) != a["gen_time_utc"] { return fail(seq, "anchor \(id): genTime ≠ token") }
                } catch {
                    return fail(seq, "anchor \(id): \(error)")
                }
            }
            rep.anchors += 1
        }

        for (name, want) in (summary["files"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let bytes = try? read(name) else { return fail(nil, "file \(name): missing") }
            if exportSHA256Hex(bytes) != want { return fail(nil, "file \(name): sha256 ≠ summary.json") }
        }
        if rep.anchors == 0 { rep.notes.append("no anchor covers these rows (run `spellsctl anchor`, then re-export)") }
        rep.notes.append("TSA signatures not checked here — run verify.py with --cafile (OpenSSL 3)")
        return rep
    }
}
