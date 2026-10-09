import Foundation
import Testing
@testable import HoursCore

@Suite struct ExportBundleTests {
    func bundle(_ disclosure: Disclosure = .L0, db: HoursDB? = nil) throws -> (URL, ExportBundle.Result) {
        let dir = exportTempDir()
        let r = try ExportBundle.write(db: db ?? exportFixtureDB(), period: exportFixturePeriod, mode: .audit,
                                       disclosure: disclosure, to: dir, tz: exportUTCZone, generatedMs: 0)
        return (dir, r)
    }

    func text(_ dir: URL, _ name: String) throws -> String { try String(contentsOf: dir.appending(path: name), encoding: .utf8) }

    @Test func auditBundleContentsAndSegment() throws {
        let (dir, r) = try bundle()
        #expect(r.files == ["README.txt", "anchors.csv", "edits.csv", "effective_spans.csv", "raw_spans.csv",
                            "rules.json", "summary.json", "timesheet.csv", "verify.py"])
        #expect(r.segment == 2...10)   // first in-period row … head (no anchors yet)
        #expect(r.unanchoredRows == 9)
        let spans = ExportCSV.parse(try Data(contentsOf: dir.appending(path: "raw_spans.csv")))
        #expect(spans.map { $0["seq"]! } == ["2", "3", "4", "5", "6", "7", "8"])
        // YouTube (not work) and the 10-01 span's row … seq 8 is disclosed: part of it is billable on 09-30.
        #expect(spans.map { $0["redacted"]! } == ["fields", "fields", "row", "fields", "fields", "fields", "fields"])
        #expect(spans[2]["start_ms"] == "" && spans[2]["app_name"] == "")
        let edits = ExportCSV.parse(try Data(contentsOf: dir.appending(path: "edits.csv")))
        #expect(edits.map { $0["after_period_end"]! } == ["1", "0"])
        #expect(edits.map { $0["payload"]! } == [ExportBundle.withheld, ExportBundle.withheld])   // private at L0
        #expect(edits.map { $0["redacted"]! } == ["fields", "fields"] && edits.allSatisfy { $0["priv_hash"]!.count == 64 })
        #expect(spans[2]["priv_hash"] == "")   // digest-only row carries no priv_hash
        #expect(spans.filter { $0["redacted"] == "fields" }.allSatisfy { $0["blind"] == ExportBundle.withheld })
        #expect(edits.allSatisfy { $0["blind"] == ExportBundle.withheld })
        #expect(try text(dir, "timesheet.csv") == ExportTimesheetTests.golden)
        #expect(try text(dir, "verify.py") == (try text(exportRepoRoot, "scripts/verify.py")))

        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "summary.json"))) as! [String: Any]
        #expect((summary["totals"] as! [String: Any])["billable_hours"] as? String == "4.16")
        #expect((summary["totals"] as! [String: Any])["manual_work_ms"] as? Int == 1_200_000)
        #expect(summary["rules_sha256"] as? String == exportSHA256Hex(try Data(contentsOf: dir.appending(path: "rules.json"))))
    }

    @Test func l0HidesTitlesAndURLsAndStillVerifies() throws {
        let (dir, _) = try bundle(.L0)
        for f in try exportAllFiles(dir) where f != "verify.py" {
            let s = try text(dir, f)
            #expect(!s.contains("CANARY"), "\(f) leaks a title/URL/manual label")
            if f.hasSuffix(".csv") { #expect(!s.contains("youtube"), "\(f) leaks the redacted row") }   // rules.json names the rule host
        }
        #expect(try ExportBundleVerifier.verify(dir).ok)
        let py = try exportVerifyPy(dir)
        #expect(py.status == 0, "\(py.out)")
    }

    @Test func l1AddsHostsOnly() throws {
        let (dir, _) = try bundle(.L1)
        let s = try text(dir, "raw_spans.csv")
        #expect(s.contains(",github.com,"))
        #expect(s.components(separatedBy: "\n")[0].contains("url_host_unverified"))
        for f in try exportAllFiles(dir) where f != "verify.py" {
            #expect(!(try text(dir, f)).contains("CANARY"), "\(f) leaks a title/URL/manual label")
        }
        let eff = ExportCSV.parse(try Data(contentsOf: dir.appending(path: "effective_spans.csv")))
        #expect(eff.first { $0["source"] == "manual" }?["app"] == ExportPeriodData.manualLabel)
        #expect(try ExportBundleVerifier.verify(dir).ok)
    }

    @Test func l2RecomputesEveryDisclosedRow() throws {
        let (dir, _) = try bundle(.L2)
        let spans = ExportCSV.parse(try Data(contentsOf: dir.appending(path: "raw_spans.csv")))
        #expect(spans.map { $0["redacted"]! } == ["none", "none", "row", "none", "none", "none", "none"])
        #expect(spans[0]["title"] == "CANARYT Store.swift — spells" && spans[1]["url"] == ExportBundle.null)
        let edits = ExportCSV.parse(try Data(contentsOf: dir.appending(path: "edits.csv")))
        #expect(edits[0]["payload"] == #"{"category_id":6,"label":"CANARYL Client call, \"Alex\"","project_id":6}"#)
        #expect(edits.allSatisfy { $0["blind"]!.count == 32 } && spans[0]["blind"]!.count == 32)
        let eff = ExportCSV.parse(try Data(contentsOf: dir.appending(path: "effective_spans.csv")))
        #expect(eff.first { $0["source"] == "manual" }?["app"] == "CANARYL Client call, \"Alex\"")
        #expect(edits.map { $0["redacted"]! } == ["none", "none"])
        let rep = try ExportBundleVerifier.verify(dir)
        #expect(rep.ok && rep.rows == 9)
        #expect(try exportVerifyPy(dir).status == 0)
    }

    /// Cross-implementation: both verifiers name the same first bad row for each kind of tamper.
    @Test(arguments: [
        // (disclosure, file, seq, column, expected seq, reason fragment)
        (Disclosure.L0, "raw_spans.csv", Int64(5), "row_hash", Int64(5), "row_hash mismatch"),
        (.L0, "raw_spans.csv", 4, "content_digest", 4, "row_hash mismatch"),        // digest-only row
        (.L0, "raw_spans.csv", 6, "prev_hash", 6, "prev_hash mismatch"),
        (.L0, "edits.csv", 10, "lo_ms", 10, "content_digest mismatch"),
        // v2: public fields of a title-hidden L0 row are bound (the v1 gap).
        (.L0, "raw_spans.csv", 3, "start_ms", 3, "content_digest mismatch"),
        (.L0, "raw_spans.csv", 5, "app_name", 5, "content_digest mismatch"),
        (.L0, "raw_spans.csv", 2, "priv_hash", 2, "content_digest mismatch"),
        (.L1, "raw_spans.csv", 6, "end_ms", 6, "content_digest mismatch"),
        (.L0, "edits.csv", 9, "priv_hash", 9, "content_digest mismatch"),
        // L2: priv_hash is salted with pub_hash, so a public-field edit surfaces as a priv_hash mismatch.
        (.L2, "raw_spans.csv", 3, "start_ms", 3, "priv_hash mismatch"),
        (.L2, "raw_spans.csv", 7, "title", 7, "priv_hash mismatch"),
        (.L2, "edits.csv", 10, "payload", 10, "priv_hash mismatch"),    // recomputed priv ≠ priv_hash
        (.L0, "raw_spans.csv", 5, "redacted", 5, "unknown redacted value"),
        // A fields row showing a private value (fake title/url/payload) must fail, not slip past priv_hash.
        (.L0, "raw_spans.csv", 2, "title", 2, "withheld row carries private values"),
        (.L1, "raw_spans.csv", 6, "url", 6, "withheld row carries private values"),
        (.L0, "edits.csv", 10, "payload", 10, "withheld row carries private values"),
        // Blinding nonce: private, only at L2 — shown at L0 it fails; altered at L2 it breaks priv_hash.
        (.L0, "raw_spans.csv", 3, "blind", 3, "withheld row carries private values"),
        (.L2, "raw_spans.csv", 3, "blind", 3, "priv_hash mismatch"),
        (.L2, "edits.csv", 9, "blind", 9, "priv_hash mismatch"),
    ])
    func tamperIsCaughtAtThatRow(_ c: (Disclosure, String, Int64, String, Int64, String)) throws {
        let (dir, _) = try bundle(c.0)
        try exportTamper(dir, c.1, seq: c.2, column: c.3) { v in
            c.3.hasSuffix("_ms") ? String(Int64(v)! + 1) : exportUnhex(v) != nil ? exportFlipHex(v) : v + "x"
        }
        let rep = try ExportBundleVerifier.verify(dir)
        #expect(rep.firstBadSeq == c.4)
        #expect(rep.failure?.contains(c.5) == true, "\(rep.failure ?? "nil")")
        let py = try exportVerifyPy(dir)
        #expect(py.status == 1)
        #expect(py.out.contains("seq \(c.4) (\(c.1)): \(c.5)"), "\(py.out)")
    }

    /// Relabelling a shown row as digest-only must not switch off the field check.
    @Test func relabelledDigestOnlyRowWithFieldsFails() throws {
        let (dir, _) = try bundle()
        try exportTamper(dir, "raw_spans.csv", seq: 3, column: "redacted") { _ in "row" }
        try exportTamper(dir, "raw_spans.csv", seq: 3, column: "start_ms") { String(Int64($0)! - 600_000) }
        let rep = try ExportBundleVerifier.verify(dir)
        #expect(rep.firstBadSeq == 3 && rep.failure?.contains("digest-only row carries field values") == true)
        let py = try exportVerifyPy(dir)
        #expect(py.status == 1 && py.out.contains("seq 3 (raw_spans.csv): digest-only row carries field values"), "\(py.out)")
    }

    @Test func deletedRowIsReportedAtTheNext() throws {
        let (dir, _) = try bundle()
        let url = dir.appending(path: "raw_spans.csv")
        let kept = try text(dir, "raw_spans.csv").components(separatedBy: "\n").filter { !$0.hasPrefix("6,") }
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(try ExportBundleVerifier.verify(dir).firstBadSeq == 7)
        let py = try exportVerifyPy(dir)
        #expect(py.status == 1 && py.out.contains("seq 7 (raw_spans.csv): seq gap"), "\(py.out)")
    }

    @Test func editedNonChainFileFailsOnItsDigest() throws {
        let (dir, _) = try bundle()
        let url = dir.appending(path: "timesheet.csv")
        try (try text(dir, "timesheet.csv")).replacingOccurrences(of: "2.00,7200", with: "3.00,7200")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(try ExportBundleVerifier.verify(dir).failure == "file timesheet.csv: sha256 ≠ summary.json")
        let py = try exportVerifyPy(dir)
        #expect(py.status == 1 && py.out.contains("file timesheet.csv"), "\(py.out)")
    }

    @Test func rechainedBundleContradictsItsAnchor() async throws {
        let db = try exportFixtureDB()
        _ = try await Anchorer.runIfDue(db: db, now: Date(timeIntervalSince1970: Double(exportMs("2026-10-05 12:00")) / 1000),
                                        tz: exportUTCZone, tsas: [TSA(name: "t", url: URL(string: "https://tsa.invalid")!)],
                                        transport: { _, req in try exportFakeResponse(for: req) })
        let (dir, r) = try bundle(db: db)
        #expect(r.anchors.count == 1 && r.unanchoredRows == 0)
        #expect(try ExportBundleVerifier.verify(dir).ok)
        // Swap the anchored head hash for another 32 bytes: anchors.csv no longer matches the chain.
        try exportTamper(dir, "anchors.csv", seq: 1, column: "head_hash", exportFlipHex)
        #expect(try ExportBundleVerifier.verify(dir).failure?.contains("contradicts the chain at seq 10") == true)
        let py = try exportVerifyPy(dir)
        #expect(py.status == 1 && py.out.contains("contradicts the chain at seq 10"), "\(py.out)")
    }

    /// Full path with a real signed token: Anchorer's DER request → `openssl ts -reply` (local throwaway TSA)
    /// → parse/store → bundle → verify.py runs `openssl ts -verify` and reports the signature checked.
    @Test(.enabled(if: exportHasOpenSSL3, "needs Homebrew openssl@3"))
    func signedTokenEndToEnd() async throws {
        let ca = exportTempDir()
        let setup = """
        set -e; cd '\(ca.path)'; O='\(exportOpenSSL)'
        printf '[ tsa ]\\ndefault_tsa = c\\n[ c ]\\nserial = \(ca.path)/serial\\nsigner_digest = sha256\\ndefault_policy = 1.2.3.4.1\\ndigests = sha256\\ness_cert_id_alg = sha256\\n[ v3 ]\\nbasicConstraints = CA:FALSE\\nkeyUsage = critical, digitalSignature\\nextendedKeyUsage = critical, timeStamping\\n' > tsa.cnf
        echo 01 > serial
        $O req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 3650 -subj '/CN=hours test CA' 2>/dev/null
        $O req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout tsa.key -out tsa.csr -subj '/CN=hours test TSA' 2>/dev/null
        $O x509 -req -in tsa.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out tsa.pem -days 3650 -extfile tsa.cnf -extensions v3 2>/dev/null
        """
        let made = try exportRun("/bin/sh", ["-c", setup])
        #expect(made.status == 0, "\(made.out)")
        let tsa: Anchorer.Transport = { _, req in
            let q = ca.appending(path: "\(UUID().uuidString).tsq"), r = ca.appending(path: "\(UUID().uuidString).tsr")
            try req.write(to: q)
            _ = try exportRun(exportOpenSSL, ["ts", "-reply", "-config", ca.appending(path: "tsa.cnf").path, "-queryfile", q.path,
                                              "-inkey", ca.appending(path: "tsa.key").path,
                                              "-signer", ca.appending(path: "tsa.pem").path, "-out", r.path])
            return try Data(contentsOf: r)
        }
        let db = try exportFixtureDB()
        let outcome = try await Anchorer.runIfDue(db: db, tz: exportUTCZone, tsas: [TSA(name: "local", url: URL(string: "https://tsa.invalid")!)],
                                                  transport: tsa)
        guard case let .done(anchored, failures) = outcome else { Issue.record("\(outcome)"); return }
        #expect(anchored.count == 1, "\(failures)")

        let (dir, r) = try bundle(db: db)
        #expect(r.anchors.count == 1)
        #expect(try ExportBundleVerifier.verify(dir).ok)
        let py = try exportVerifyPy(dir, ["--cafile", ca.appending(path: "ca.pem").path])
        #expect(py.status == 0 && py.out.contains("signatures checked: 1"), "\(py.out)")
        // Wrong root: the signature check must fail.
        let other = try exportRun("/bin/sh", ["-c", "cd '\(ca.path)' && '\(exportOpenSSL)' req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout o.key -out other.pem -days 1 -subj '/CN=other' 2>/dev/null"])
        #expect(other.status == 0)
        let bad = try exportVerifyPy(dir, ["--cafile", ca.appending(path: "other.pem").path])
        #expect(bad.status == 1 && bad.out.contains("TSA signature does not verify"), "\(bad.out)")
    }

    /// Review-1 #8: a current-period export includes the open span (raw_seq 0), which isn't in the
    /// chain yet. It stays in the totals (they must equal Range), but the bundle flags it as unproven:
    /// summary.json `unchained_work_ms`, and README.txt says what raw_seq 0 means.
    @Test func openSpanIsFlaggedUnproven() throws {
        let db = try exportFixtureDB()
        let w = SpanWriter(db)
        try w.open(live: exportSpan("2026-09-30 09:00", "2026-09-30 09:00", bundle: "com.microsoft.VSCode", app: "Code",
                                    title: "live.swift — spells"))
        try w.heartbeat(lastSeenMs: exportMs("2026-09-30 09:30"))
        let (dir, _) = try bundle(db: db)
        let eff = ExportCSV.parse(try Data(contentsOf: dir.appending(path: "effective_spans.csv")))
        let live = try #require(eff.first { $0["start_ms"] == String(exportMs("2026-09-30 09:00")) })
        #expect(live["raw_seq"] == "0")
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "summary.json"))) as! [String: Any]
        #expect((summary["totals"] as! [String: Any])["unchained_work_ms"] as? Int == 1_800_000)
        #expect(try text(dir, "README.txt").contains("raw_seq 0"))
        #expect(try ExportBundleVerifier.verify(dir).ok)
        // A closed period carries the field too, at zero.
        let (closed, _) = try bundle()
        let s2 = try JSONSerialization.jsonObject(with: Data(contentsOf: closed.appending(path: "summary.json"))) as! [String: Any]
        #expect((s2["totals"] as! [String: Any])["unchained_work_ms"] as? Int == 0)
    }

    @Test func embeddedVerifierMatchesScript() throws {
        #expect(ExportVerifyScript.source == (try text(exportRepoRoot, "scripts/verify.py")),
                "scripts/verify.py changed: paste it into ExportVerifyScript.swift")
    }
}
