import Foundation
import HoursCore

/// Settings → Data: export and anchor through item 9's APIs (same paths and defaults as `spellsctl`).
extension AppModel {
    public struct ExportOutcome: Sendable {
        public var dir: URL
        public var summary: String
    }

    /// `spec`: "current" | "previous" billing half. Writes to `exports/<from>_<through>[-audit]`.
    public func export(_ spec: String, mode: ExportMode, disclosure: Disclosure = .L0) async throws -> ExportOutcome {
        guard let period = ExportPeriod.parse(spec, today: today) else { throw ShellExportError.badPeriod(spec) }
        let (db, tz) = (self.db, self.timeZone)
        let dir = paths.exports.appending(path: "\(period.from)_\(period.through)\(mode == .audit ? "-audit" : "")",
                                          directoryHint: .isDirectory)
        let r = try await Task.detached(priority: .userInitiated) {
            try ExportBundle.write(db: db, period: period, mode: mode, disclosure: disclosure, to: dir, tz: tz)
        }.value
        var summary = "\(period): \(ExportPeriodData.hours(r.data.totalHundredths)) h billable · \(r.files.count) files"
        if mode == .audit, r.unanchoredRows > 0 { summary += " · \(r.unanchoredRows) rows not yet anchored" }
        return ExportOutcome(dir: dir, summary: summary)
    }

    /// Forced anchor of the chain head (network: DigiCert + FreeTSA). Returns a one-line status.
    public func anchorNow() async -> String {
        let (db, tz, mirror) = (self.db, self.timeZone, paths.home.appending(path: "anchors", directoryHint: .isDirectory))
        do {
            switch try await Anchorer.runIfDue(db: db, force: true, tz: tz, mirrorDir: mirror) {
            case .notDue(let why):
                return "Not anchored: \(why)."
            case .done(let anchored, let failures):
                let ok = anchored.map { "head #\($0.headSeq) by \($0.tsa ?? "?")" }
                return ok.isEmpty ? "Anchor failed: \(failures.joined(separator: "; "))"
                    : "Anchored \(ok.joined(separator: ", "))" + (failures.isEmpty ? "." : " (\(failures.count) TSA failed).")
            }
        } catch {
            return "Anchor failed: \(error.localizedDescription)"
        }
    }
}

enum ShellExportError: Error, CustomStringConvertible {
    case badPeriod(String)
    var description: String { switch self { case .badPeriod(let s): "Unknown period “\(s)”" } }
}
