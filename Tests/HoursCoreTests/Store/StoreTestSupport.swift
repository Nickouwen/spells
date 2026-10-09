import Foundation
@testable import HoursCore

/// A fresh DB in a temp dir (never ~/Library) with a unique notify name so tests don't wake a real app.
func storeTempDB(role: HoursDB.Role = .tracker, url: URL? = nil) throws -> HoursDB {
    try HoursDB.open(at: url ?? storeTempURL(), role: role, notifyName: storeTestNotifyName())
}

func storeTempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "hours-store-tests/\(UUID().uuidString)/hours.db")
}

func storeTestNotifyName() -> String { "dev.nic.spells.test.\(UUID().uuidString)" }

func storeRaw(_ seq: Int64, _ start: Int64, _ end: Int64, app: String = "X", tz: String = "UTC",
              kind: SpanKind = .active) -> RawSpan {
    RawSpan(seq: seq, startMs: start, endMs: end, tzId: tz, tzOffsetS: 0, kind: kind,
            bundleId: "b.\(app)", appName: app, title: nil, url: nil)
}

func storeEdit(_ seq: Int64, grp: Int64? = nil, _ payload: EditPayload, _ lo: Int64 = 0, _ hi: Int64 = 0,
               target: Int64? = nil) -> Edit {
    Edit(seq: seq, grp: grp ?? seq, createdMs: 0, tzId: "UTC", op: payload.op, loMs: lo, hiMs: hi,
         target: target, payload: payload)
}

extension EffectiveSpan {
    /// (start, end, rawSeq, categoryOverride) — the fields the derivation tests pin.
    var storeShape: [Int64?] { [startMs, endMs, rawSeq, categoryOverride] }
}
