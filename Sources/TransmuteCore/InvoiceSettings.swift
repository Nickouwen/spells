import Foundation
import RewindCore

/// Transmute's settings (`transmute/settings.json`): who invoices whom, the rate, and which of Rewind's
/// hours count. Blank rows mean the defaults.
public struct InvoiceSettings: Sendable, Equatable {
    /// Which of Rewind's per-day totals an invoice bills.
    public enum Basis: String, CaseIterable, Sendable, Identifiable {
        case work, tracked, billable
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .work: "Work time"
            case .tracked: "All tracked time"
            case .billable: "Project time"
            }
        }
        public var detail: String {
            switch self {
            case .work: "Time in categories marked as work (what Rewind's Day view calls Work)."
            case .tracked: "Everything Rewind tracked, work or not."
            case .billable: "Work time assigned to a project (what Rewind's timesheet export bills)."
            }
        }
        public func ms(_ m: DayMetrics) -> Int64 {
            switch self {
            case .work: m.workMs
            case .tracked: m.trackedMs
            case .billable: m.billableMs
            }
        }
    }

    public var fromName = ""
    public var fromAddress = ""
    public var fromEmail = ""
    public var clientName = ""
    public var clientAddress = ""
    public var clientEmail = ""
    /// Hourly rate in cents (0 = not set yet).
    public var rateCents: Int64 = 0
    public var currency = "CAD"
    public var basis: Basis = .work
    public var prefix = "INV-"
    public var nextNumber = 1
    /// `{period}` becomes the period's title ("October 1–15, 2026").
    public var description = "For development {period}"
    public var terms = "Due on receipt."
    /// Where PDFs go; blank = `defaultFolder`.
    public var folder = ""

    public static let defaultFolder = "~/Documents/Invoices"

    public init() {}

    public var folderURL: URL {
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(filePath: ((f.isEmpty ? Self.defaultFolder : f) as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// `INV-0012`.
    public var number: String { prefix + String(format: "%04d", nextNumber) }

    /// Everything an invoice needs before it can be issued.
    public var missing: [String] {
        var out: [String] = []
        if fromName.trimmingCharacters(in: .whitespaces).isEmpty { out.append("your name") }
        if clientName.trimmingCharacters(in: .whitespaces).isEmpty { out.append("the client's name") }
        if rateCents <= 0 { out.append("an hourly rate") }
        return out
    }

    public enum Key {
        public static let fromName = "from_name", fromAddress = "from_address", fromEmail = "from_email"
        public static let clientName = "client_name", clientAddress = "client_address", clientEmail = "client_email"
        public static let rate = "rate", currency = "currency", basis = "basis", prefix = "number_prefix", next = "next_number"
        public static let description = "description", terms = "terms", folder = "folder"
    }

    public static func load(_ rows: [String: String]) -> InvoiceSettings {
        var s = InvoiceSettings()
        s.fromName = rows[Key.fromName] ?? ""
        s.fromAddress = rows[Key.fromAddress] ?? ""
        s.fromEmail = rows[Key.fromEmail] ?? ""
        s.clientName = rows[Key.clientName] ?? ""
        s.clientAddress = rows[Key.clientAddress] ?? ""
        s.clientEmail = rows[Key.clientEmail] ?? ""
        s.rateCents = rows[Key.rate].flatMap(parseRate) ?? 0
        if let c = rows[Key.currency], !c.isEmpty { s.currency = c }
        s.basis = rows[Key.basis].flatMap(Basis.init(rawValue:)) ?? .work
        if let p = rows[Key.prefix] { s.prefix = p }
        s.nextNumber = max(1, rows[Key.next].flatMap(Int.init) ?? 1)
        if let d = rows[Key.description], !d.isEmpty { s.description = d }
        if let t = rows[Key.terms] { s.terms = t }
        s.folder = rows[Key.folder] ?? ""
        return s
    }

    /// Every row, so a caller can diff against the saved copy and write only what changed.
    public var rows: [String: String] {
        [Key.fromName: fromName, Key.fromAddress: fromAddress, Key.fromEmail: fromEmail,
         Key.clientName: clientName, Key.clientAddress: clientAddress, Key.clientEmail: clientEmail,
         Key.rate: Self.rateString(rateCents), Key.currency: currency, Key.basis: basis.rawValue,
         Key.prefix: prefix, Key.next: String(nextNumber), Key.description: description, Key.terms: terms, Key.folder: folder]
    }

    /// `"45"`, `"45.5"`, `"$45.00"`, `"1,200"` → cents; nil when it isn't a number.
    public static func parseRate(_ s: String) -> Int64? {
        let cleaned = s.filter { $0.isNumber || $0 == "." }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, parts.count <= 2, let whole = Int64(parts[0].isEmpty ? "0" : String(parts[0])) else { return nil }
        var frac: Int64 = 0
        if parts.count == 2 {
            let f = String(parts[1]).prefix(2)
            guard let n = Int64(f.isEmpty ? "0" : String(f)) else { return nil }
            frac = f.count == 1 ? n * 10 : n
        }
        return whole * 100 + frac
    }

    /// `4550` → `"45.50"`.
    public static func rateString(_ cents: Int64) -> String { String(format: "%lld.%02lld", cents / 100, cents % 100) }
}

/// `123456` cents → `"$1,234.56"` for the currency (ISO code).
public enum Money {
    nonisolated(unsafe) private static var formatters: [String: NumberFormatter] = [:]
    private static let lock = NSLock()

    public static func format(cents: Int64, currency: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let f = formatters[currency] ?? {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = currency
            // A locale whose own currency this is prints the plain symbol ("$113.75", not "CA$113.75").
            let homes = ["en_US", "en_CA", "en_GB", "en_AU", "en_NZ", "en_IE", "de_CH", "ja_JP", "en_IN", "en_SG", "en_HK"]
            f.locale = homes.map { Locale(identifier: $0) }.first { $0.currency?.identifier == currency } ?? Locale(identifier: "en_US")
            formatters[currency] = f
            return f
        }()
        let s = f.string(from: NSDecimalNumber(mantissa: UInt64(abs(cents)), exponent: -2, isNegative: false)) ?? "\(abs(cents))"
        return cents < 0 ? "\u{2212}" + s : s
    }
}
