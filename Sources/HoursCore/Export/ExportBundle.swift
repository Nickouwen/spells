import Foundation
import GRDB

/// What a bundle reveals about in-scope rows. Every level shows all public fields (times, tz, kind, app;
/// edit op/range/target/group) plus `priv_hash`, so each shown field is bound to the chain.
/// Out-of-scope rows (non-work, outside the period) are reduced to `seq, content_digest, prev_hash, row_hash`.
public enum Disclosure: String, Sendable, CaseIterable {
    /// Public fields only; titles, URLs and edit payloads withheld (`priv_hash` shown).
    case L0
    /// L0 + URL host (a derived claim: it can only be checked at L2).
    case L1
    /// Private fields too (titles, URLs as stored — query/fragment stripped at capture — and edit payloads).
    case L2
}

public enum ExportMode: String, Sendable { case plain, audit }

/// Writes `timesheet.csv` (plain) or the full proof bundle (audit) into a directory.
public enum ExportBundle {
    public static let format = "hours-proof/v2"
    /// CSV markers: SQL NULL, and a field withheld by the disclosure level.
    public static let null = "\\N"
    public static let withheld = "[redacted]"

    public struct Result: Sendable {
        public var data: ExportPeriodData
        public var files: [String]
        /// Chain segment [first, end] in the bundle; nil for plain or when the period has no rows.
        public var segment: ClosedRange<Int64>?
        public var endHash: Data?
        /// Anchors whose head lies in the segment.
        public var anchors: [ChainAnchor]
        /// Rows in the segment after its last anchor (0 = fully anchored).
        public var unanchoredRows: Int64
    }

    public static func write(db: HoursDB, period: ExportPeriod, mode: ExportMode, disclosure: Disclosure = .L0,
                             to dir: URL, tz: TimeZone = .current, generatedMs: Int64? = nil) throws -> Result {
        let data = try ExportPeriodData.load(db, period: period)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String: Data] = ["timesheet.csv": data.timesheetCSV]
        var result = Result(data: data, files: [], segment: nil, endHash: nil, anchors: [], unanchoredRows: 0)

        if mode == .audit {
            let cats = Dictionary(uniqueKeysWithValues: data.config.categories.map { ($0.id, $0) })
            let projects = Dictionary(uniqueKeysWithValues: data.config.projects.map { ($0.id, $0.name) })
            let catNames = cats.mapValues(\.name)
            let work = data.days.keys.sorted().flatMap { d in
                (data.days[d] ?? []).filter { exportIsWork($0, cats) }.map { (d, $0) }
            }
            // ponytail: edits are scoped by the period's bounds in the exporter's current tz, not per-span tz.
            let lo = period.from.dayInterval(in: tz).lowerBound, hi = period.through.dayInterval(in: tz).upperBound
            let edits = try Store(db).edits(overlapping: lo, hi)
            let disclosed = Set(work.compactMap { $0.1.span.rawSeq }.filter { $0 > 0 } + edits.map(\.seq))
            let anchors = try AnchorStore(db).list()
            let head = try db.head()

            var spanRows: [[String]] = [], editRows: [[String]] = []
            if let first = disclosed.min(), let maxSeq = disclosed.max() {
                let end = anchors.map(\.headSeq).filter { $0 >= maxSeq }.min() ?? head.seq
                result.segment = first...end
                (spanRows, editRows, result.endHash) = try chainRows(db, first...end, disclosed: disclosed,
                                                                     disclosure: disclosure, periodEndMs: hi)
                result.anchors = anchors.filter { (first...end).contains($0.headSeq) }
                result.unanchoredRows = end - (result.anchors.map(\.headSeq).max() ?? first - 1)
            }

            files["raw_spans.csv"] = ExportCSV.render(header: spanHeader, rows: spanRows)
            files["edits.csv"] = ExportCSV.render(header: editHeader, rows: editRows)
            files["effective_spans.csv"] = ExportCSV.render(header: effectiveHeader, rows: work.map { d, c in
                let s = c.span
                let detail = switch disclosure {
                case .L0: ""
                case .L1: metricsHost(s.url) ?? ""
                case .L2: s.title ?? ""
                }
                return [d.description, String(s.startMs), String(s.endMs), exportLocal(s.startMs, s.tzId),
                        exportLocal(s.endMs, s.tzId), String(s.durationMs / 1000), s.source.rawValue,
                        s.rawSeq.map(String.init) ?? null, s.editSeqs.map(String.init).joined(separator: ";"),
                        // A manual label comes from the edit payload (private): real text only at L2.
                        s.source == .manual ? (disclosure == .L2 ? s.label ?? "" : ExportPeriodData.manualLabel) : s.appName,
                        detail,
                        c.categoryId.flatMap { catNames[$0] } ?? "", c.projectId.flatMap { projects[$0] } ?? "",
                        c.projectId == nil ? "0" : "1"]
            })
            var anchorRows: [[String]] = []
            for a in result.anchors {
                let file = a.token.map { _ in "anchors/\(a.id)-\(a.tsa ?? "tsa").tst" } ?? ""
                if let token = a.token { files[file] = token }
                anchorRows.append([String(a.id), String(a.headSeq), exportHex(a.headHash), a.method, a.tsa ?? "",
                                   exportUTC(a.requestedMs), a.genTimeMs.map(exportUTC) ?? "", file])
            }
            files["anchors.csv"] = ExportCSV.render(header: anchorHeader, rows: anchorRows)
            files["rules.json"] = data.config.snapshotJSON
            files["README.txt"] = Data(readme(period: period, disclosure: disclosure).utf8)
            files["verify.py"] = Data(ExportVerifyScript.source.utf8)

            let manualMs = work.filter { $0.1.span.source == .manual }.reduce(0) { $0 + $1.1.span.durationMs }
            // The open span (raw_seq 0) counts, so totals match Range, but nothing in the chain backs it yet.
            let unchainedMs = work.filter { $0.1.span.rawSeq == 0 }.reduce(0) { $0 + $1.1.span.durationMs }
            let fileHashes = files.keys.sorted().reduce(into: [String: String]()) { $0[$1] = exportSHA256Hex(files[$1]!) }
            let summary: [String: Any] = [
                "format": format,
                "generator": "spellsctl",
                "generated_utc": exportUTC(generatedMs ?? storeNowMs()),
                "period": ["from": period.from.description, "through": period.through.description,
                           "day_start_hour": Hours.defaultDayStartHour, "tz": tz.identifier],
                "disclosure": disclosure.rawValue,
                "definition": ExportPeriodData.definitionVersion,
                "totals": ["billable_hours": ExportPeriodData.hours(data.totalHundredths),
                           "billable_ms": data.metrics.billableMs, "work_ms": data.metrics.workMs,
                           "tracked_ms": data.metrics.trackedMs, "unassigned_work_ms": data.metrics.unassignedWorkMs,
                           "manual_work_ms": manualMs, "unchained_work_ms": unchainedMs],
                "edits": ["in_period": edits.count, "after_period_end": edits.filter { $0.createdMs >= hi }.count],
                "chain": ["first_seq": result.segment?.lowerBound ?? 0, "end_seq": result.segment?.upperBound ?? 0,
                          "end_hash": result.endHash.map(exportHex) ?? String(), "anchors": result.anchors.count,
                          "unanchored_rows": result.unanchoredRows],
                "rules_sha256": fileHashes["rules.json"]!,
                "files": fileHashes,
            ]
            files["summary.json"] = try JSONSerialization.data(withJSONObject: summary,
                                                               options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        }

        for (name, bytes) in files {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        result.files = files.keys.sorted()
        return result
    }

    static let spanHeader = ["seq", "start_ms", "end_ms", "start_utc", "end_utc", "tz_id", "tz_offset_s", "kind",
                             "bundle_id", "app_name", "title", "url", "blind", "url_host_unverified", "redacted",
                             "priv_hash", "content_digest", "prev_hash", "row_hash"]
    static let editHeader = ["seq", "grp", "created_ms", "created_utc", "tz_id", "op", "lo_ms", "hi_ms", "target",
                             "payload", "blind", "after_period_end", "redacted", "priv_hash", "content_digest",
                             "prev_hash", "row_hash"]
    static let effectiveHeader = ["date", "start_ms", "end_ms", "start_local", "end_local", "duration_s", "source",
                                  "raw_seq", "edit_seqs", "app", "detail", "category", "project", "billable"]
    static let anchorHeader = ["anchor_id", "head_seq", "head_hash", "method", "tsa", "requested_utc",
                               "gen_time_utc", "token_file"]

    /// Every span and edit row with seq in `range`, rendered per disclosure. Returns the hash at range.upperBound.
    static func chainRows(_ db: HoursDB, _ range: ClosedRange<Int64>, disclosed: Set<Int64>, disclosure: Disclosure,
                          periodEndMs: Int64) throws -> ([[String]], [[String]], Data?) {
        try db.writer.read { db in
            let args: StatementArguments = [range.lowerBound, range.upperBound]
            var endHash: Data?
            let full = disclosure == .L2
            func priv(_ v: String?) -> String { full ? v ?? null : withheld }
            let spans = try Row.fetchAll(db, sql: "SELECT * FROM span WHERE seq BETWEEN ? AND ? ORDER BY seq", arguments: args)
                .map { r -> [String] in
                    let seq: Int64 = r["seq"]
                    let tail = [exportHex(r["content_hash"]), exportHex(r["prev_hash"]), exportHex(r["hash"])]
                    if seq == range.upperBound { endHash = r["hash"] }
                    guard disclosed.contains(seq) else { return [String(seq)] + Array(repeating: "", count: 13) + ["row", ""] + tail }
                    let title: String? = r["title"], url: String? = r["url"], blind: Data = r["blind"]
                    let start: Int64 = r["start_ms"], end: Int64 = r["end_ms"], off: Int64 = r["tz_offset_s"]
                    let pub = ChainCodec.spanPublic(startMs: start, endMs: end, tzId: r["tz_id"], tzOffsetS: off,
                                                    kind: r["kind"], bundleId: r["bundle_id"], appName: r["app_name"])
                    return [String(seq), String(start), String(end), exportUTC(start), exportUTC(end), r["tz_id"],
                            String(off), r["kind"], (r["bundle_id"] as String?) ?? null, r["app_name"],
                            priv(title), priv(url), full ? exportHex(blind) : withheld,
                            disclosure == .L0 ? "" : metricsHost(url) ?? "", full ? "none" : "fields",
                            exportHex(ChainCodec.spanPrivate(pub: pub, blind: blind, title: title, url: url))] + tail
                }
            let edits = try Row.fetchAll(db, sql: "SELECT * FROM edit WHERE seq BETWEEN ? AND ? ORDER BY seq", arguments: args)
                .map { r -> [String] in
                    let seq: Int64 = r["seq"]
                    let tail = [exportHex(r["content_hash"]), exportHex(r["prev_hash"]), exportHex(r["hash"])]
                    if seq == range.upperBound { endHash = r["hash"] }
                    guard disclosed.contains(seq) else { return [String(seq)] + Array(repeating: "", count: 11) + ["row", ""] + tail }
                    let created: Int64 = r["created_ms"], grp: Int64 = r["grp"], lo: Int64 = r["lo_ms"], hi: Int64 = r["hi_ms"]
                    let target: Int64? = r["target"], payload: String = r["payload"], blind: Data = r["blind"]
                    let pub = ChainCodec.editPublic(createdMs: created, tzId: r["tz_id"], op: r["op"], loMs: lo, hiMs: hi,
                                                    target: target, grp: grp)
                    return [String(seq), String(grp), String(created), exportUTC(created), r["tz_id"], r["op"],
                            String(lo), String(hi), target.map(String.init) ?? null, priv(payload),
                            full ? exportHex(blind) : withheld, created >= periodEndMs ? "1" : "0", full ? "none" : "fields",
                            exportHex(ChainCodec.editPrivate(pub: pub, blind: blind, payload: payload))] + tail
                }
            return (spans, edits, endHash)
        }
    }

    static func readme(period: ExportPeriod, disclosure: Disclosure) -> String {
        """
        hours proof bundle — \(period) (disclosure \(disclosure.rawValue))

        WHAT THIS PROVES
          Every row in raw_spans.csv / edits.csv is linked into one SHA-256 hash chain. The anchors
          (RFC 3161 timestamp tokens from public TSAs) sign the chain head, so the rows existed, unaltered,
          no later than each token's genTime. It does NOT prove the work happened: the tracker records
          which app was frontmost while the user was not idle.

        CHECK IT (no app needed)
          python3 verify.py .            # chain links, digests, anchors, file hashes; exit 0 = pass, 1 = tamper
          python3 verify.py . --cafile ROOTS.pem   # also checks TSA signatures (needs OpenSSL 3, not LibreSSL)

          By hand, per anchor (head_hash from anchors.csv):
          openssl ts -verify -token_in -in anchors/<id>-<tsa>.tst -digest <head_hash> -sha256 -CAfile ROOTS.pem
          ROOTS.pem: the TSA's root certificate, fetched from the vendor —
            DigiCert: https://www.digicert.com/kb/digicert-root-certificates.htm (DigiCert Assured ID / Trusted Root G4)
            FreeTSA:  https://freetsa.org/files/cacert.pem
          macOS ships LibreSSL as /usr/bin/openssl, which can't do this; use OpenSSL 3 (brew install openssl@3).

        REDACTION
          redacted=row    : out of scope (non-work time, or outside the period) — only digests are shown.
          redacted=fields : titles/URLs/edit payloads and the row's blinding nonce withheld ("[redacted]"),
                            replaced by priv_hash. Every other field shown is recomputed into content_digest,
                            so it is bound. Without the nonce, priv_hash can't be checked against guessed titles.
          redacted=none   : private fields and blind shown too; verify.py also recomputes priv_hash from them.
          url_host_unverified (L1) is derived from the withheld URL: an UNVERIFIED CLAIM, checkable only
          at L2. Manual entries are labelled "Manual entry" below L2 (the label is private edit payload).
          effective_spans.csv and timesheet.csv are derived views, covered by the file hashes in
          summary.json but not by the chain. "\\N" means the stored value was NULL.
          raw_seq 0 in effective_spans.csv is the span still open at export time: it counts toward the
          totals but is not in the chain yet, so it is UNPROVEN (totals.unchained_work_ms in summary.json).
          Re-export after it closes to cover it.

        HASH SPEC (v2)
          pub_hash       = SHA256("hours/pub/v2" || tag || public fields)
          priv_hash      = SHA256("hours/priv/v2" || pub_hash || blind[16] || private fields)
          content_digest = SHA256("hours/content/v2" || tag || pub_hash || priv_hash)
          row_hash       = SHA256("hours/chain/v2" || I(seq) || prev_hash || content_digest)
          I(x) = 8-byte big-endian signed; T(s) = u32be(len) || utf8; N(v) = 0x00 | 0x01 || v
          span 'S' public:  I(start_ms) I(end_ms) T(tz_id) I(tz_offset_s) T(kind) N(T(bundle_id)) T(app_name)
          span 'S' private: N(T(title)) N(T(url))
          edit 'E' public:  I(created_ms) T(tz_id) T(op) I(lo_ms) I(hi_ms) N(I(target)) I(grp)
          edit 'E' private: T(payload)
          The first row's prev_hash is asserted; every later link is checked.

        """
    }
}
