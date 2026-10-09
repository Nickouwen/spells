import Foundation
@testable import HoursCore

/// Repo root, from this file's location (Tests/HoursCoreTests/Export/…).
let exportRepoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

let exportOpenSSL = "/opt/homebrew/opt/openssl@3/bin/openssl"
var exportHasOpenSSL3: Bool { FileManager.default.isExecutableFile(atPath: exportOpenSSL) }

func exportTempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appending(path: "hours-export-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// UTC "2026-09-16 09:00" → ms.
func exportMs(_ s: String) -> Int64 {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return Int64(f.date(from: s)!.timeIntervalSince1970 * 1000)
}

func exportSpan(_ from: String, _ to: String, bundle: String?, app: String, title: String?, url: String? = nil) -> RawSpan {
    RawSpan(seq: 0, startMs: exportMs(from), endMs: exportMs(to), tzId: "UTC", tzOffsetS: 0, kind: .active,
            bundleId: bundle, appName: app, title: title, url: url)
}

let exportUTCZone = TimeZone(identifier: "UTC")!
let exportFixturePeriod = ExportPeriod(from: LocalDate(year: 2026, month: 9, day: 16),
                                       through: LocalDate(year: 2026, month: 9, day: 30))

/// The fixture (all UTC, day start 04:00, seed config via the empty-DB fallback):
///   seq 1  09-15 10:00–11:00 Code   "a.swift — spells"                    before the period
///   seq 2  09-16 09:00–10:30 Code   "CANARYT Store.swift — spells"        coding · spells (trimmed to 10:20 by seq 10)
///   seq 3  09-16 10:30–10:50 Code   "route.ts — operations-dashboard"   coding · operations-dashboard
///   seq 4  09-16 10:50–11:00 Chrome youtube.com                          entertainment (not work → digest only)
///   seq 5  09-16 11:00–11:30 Slack  "general (Channel)"                  communication, no project
///   seq 6  09-16 11:30–11:40 Chrome github.com/ExampleOrg/spells/pull/1    coding · spells (URL canary)
///   seq 7  09-17 03:30–04:30 cmux   "~/Documents/GitHub/spells"           crosses 04:00: 30 min on 16th, 30 on 17th
///   seq 8  10-01 03:00–05:00 cmux   same                                 1 h on 09-30, 1 h on 10-01 (outside)
///   seq 9  edit add 09-18 13:00–13:20 "CANARYL Client call, \"Alex\"" meetings · hours, created 10-02 (after period end)
///   seq 10 edit delete 09-16 10:20–10:30, created 09-20
func exportFixtureDB() throws -> HoursDB {
    let db = try storeTempDB(role: .app)
    let w = SpanWriter(db)
    let code = "com.microsoft.VSCode", chrome = "com.google.Chrome", cmux = "com.cmuxterm.app"
    for s in [
        exportSpan("2026-09-15 10:00", "2026-09-15 11:00", bundle: code, app: "Code", title: "a.swift — spells"),
        exportSpan("2026-09-16 09:00", "2026-09-16 10:30", bundle: code, app: "Code", title: "CANARYT Store.swift — spells"),
        exportSpan("2026-09-16 10:30", "2026-09-16 10:50", bundle: code, app: "Code", title: "route.ts — operations-dashboard"),
        exportSpan("2026-09-16 10:50", "2026-09-16 11:00", bundle: chrome, app: "Google Chrome", title: "YouTube",
                   url: "https://www.youtube.com/watch"),
        exportSpan("2026-09-16 11:00", "2026-09-16 11:30", bundle: "com.tinyspeck.slackmacgap", app: "Slack",
                   title: "general (Channel)"),
        exportSpan("2026-09-16 11:30", "2026-09-16 11:40", bundle: chrome, app: "Google Chrome", title: "CANARYT PR",
                   url: "https://github.com/ExampleOrg/spells/pull/1#CANARYU"),
        exportSpan("2026-09-17 03:30", "2026-09-17 04:30", bundle: cmux, app: "cmux", title: "~/Documents/GitHub/spells"),
        exportSpan("2026-10-01 03:00", "2026-10-01 05:00", bundle: cmux, app: "cmux", title: "~/Documents/GitHub/spells"),
    ] { try w.append(s) }
    let e = EditWriter(db)
    try e.apply([.add(exportMs("2026-09-18 13:00"), exportMs("2026-09-18 13:20"), label: "CANARYL Client call, \"Alex\"",
                      categoryId: ClassifySeed.meetings, projectId: 6)],
                createdMs: exportMs("2026-10-02 12:00"), tzId: "UTC")
    try e.apply([.delete(exportMs("2026-09-16 10:20"), exportMs("2026-09-16 10:30"))],
                createdMs: exportMs("2026-09-20 12:00"), tzId: "UTC")
    return db
}

@discardableResult
func exportRun(_ exe: String, _ args: [String], stdin: Data? = nil) throws -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(filePath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

func exportVerifyPy(_ dir: URL, _ extra: [String] = []) throws -> (status: Int32, out: String) {
    try exportRun("/usr/bin/env", ["python3", exportRepoRoot.appending(path: "scripts/verify.py").path, dir.path] + extra)
}

/// Rewrites one CSV cell (by seq and column) in a bundle file.
func exportTamper(_ dir: URL, _ file: String, seq: Int64, column: String, _ change: (String) -> String) throws {
    let url = dir.appending(path: file)
    var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    let header = lines[0].components(separatedBy: ",")
    let col = header.firstIndex(of: column)!
    for i in 1..<lines.count where lines[i].hasPrefix("\(seq),") {
        var cells = lines[i].components(separatedBy: ",")   // fixture rows touched here have no quoted commas
        cells[col] = change(cells[col])
        lines[i] = cells.joined(separator: ",")
    }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

/// Flips the low bit of the first hex digit.
func exportFlipHex(_ s: String) -> String {
    let c = s.first!
    let flipped = String(Int(String(c), radix: 16)! ^ 1, radix: 16)
    return flipped + s.dropFirst()
}

/// A structurally valid (unsigned) TimeStampResp answering `request` — for Anchorer logic tests.
func exportFakeResponse(for request: Data, genTime: String = "20261006120000Z", status: Int = 0,
                        nonceOverride: [UInt8]? = nil) throws -> Data {
    let req = try ExportDER.parse(ArraySlice(request)).children
    let imprint = req[1]
    let requestNonce: [UInt8] = req.dropFirst(2).first(where: { $0.tag == 0x02 }).map { Array($0.raw) } ?? []
    let nonce = nonceOverride.map { ExportDER.unsigned($0) } ?? requestNonce
    let tst = ExportDER.sequence([0x02, 0x01, 0x01], ExportDER.oid("1.2.3.4.1"), Array(imprint.raw), [0x02, 0x01, 0x07],
                                 ExportDER.tlv(0x18, Array(genTime.utf8)), nonce)
    let encap = ExportDER.sequence(RFC3161.tstInfoOID, ExportDER.tlv(0xA0, ExportDER.octets(tst)))
    let signed = ExportDER.sequence([0x02, 0x01, 0x03], ExportDER.tlv(0x31, []), encap, ExportDER.tlv(0x31, []))
    let token = ExportDER.sequence(RFC3161.signedDataOID, ExportDER.tlv(0xA0, signed))
    return Data(ExportDER.sequence(ExportDER.sequence([0x02, 0x01, UInt8(status)]), status <= 1 ? token : []))
}

/// Every file in a bundle, recursively (incl. anchors/), as paths relative to `dir`.
func exportAllFiles(_ dir: URL) throws -> [String] {
    (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).filter {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.appending(path: $0).path, isDirectory: &isDir) && !isDir.boolValue
    }
}
