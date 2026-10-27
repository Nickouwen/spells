import Foundation
import RewindCore

/// One invoice: a period's hours from Rewind, priced at a rate. Everything the PDF shows and the
/// ledger keeps; `build` is pure over Rewind's range metrics so it's testable without a database.
public struct Invoice: Codable, Sendable, Equatable {
    public struct Day: Codable, Sendable, Equatable {
        public var date: LocalDate
        public var ms: Int64
        /// Hours × 100, rounded half up per day — the same rounding Rewind's timesheet uses.
        public var hundredths: Int64 { ExportPeriodData.hundredths(ms: ms) }
        public init(date: LocalDate, ms: Int64) { self.date = date; self.ms = ms }
    }

    public var number: String
    public var issued: LocalDate
    public var from: LocalDate
    public var through: LocalDate
    public var fromName: String
    public var fromAddress: String
    public var fromEmail: String
    public var clientName: String
    public var clientAddress: String
    public var clientEmail: String
    public var currency: String
    public var rateCents: Int64
    public var basis: String
    public var description: String
    public var terms: String
    /// Days with time on them, in date order.
    public var days: [Day]

    public var period: ExportPeriod { ExportPeriod(from: from, through: through) }
    public var totalHundredths: Int64 { days.reduce(0) { $0 + $1.hundredths } }
    public var totalMs: Int64 { days.reduce(0) { $0 + $1.ms } }
    /// Hours × rate, rounded half up to the cent.
    public var amountCents: Int64 { (totalHundredths * rateCents + 50) / 100 }
    /// `12.34`.
    public var hours: String { ExportPeriodData.hours(totalHundredths) }
    public var amount: String { Money.format(cents: amountCents, currency: currency) }
    public var rate: String { Money.format(cents: rateCents, currency: currency) }
    /// The description with `{period}` filled in.
    public var title: String { description.replacingOccurrences(of: "{period}", with: Self.periodTitle(period)) }
    /// `INV-0012.pdf`.
    public var fileName: String { "\(number).pdf" }

    /// Prices `metrics` (one `RangeMetrics.Day` per date in the period) with `settings`.
    public static func build(period: ExportPeriod, metrics: RangeMetrics, settings: InvoiceSettings, issued: LocalDate) -> Invoice {
        let days = metrics.days.map { Day(date: $0.date, ms: settings.basis.ms($0.metrics)) }.filter { $0.ms > 0 }
        return Invoice(number: settings.number, issued: issued, from: period.from, through: period.through,
                       fromName: settings.fromName, fromAddress: settings.fromAddress, fromEmail: settings.fromEmail,
                       clientName: settings.clientName, clientAddress: settings.clientAddress, clientEmail: settings.clientEmail,
                       currency: settings.currency, rateCents: settings.rateCents, basis: settings.basis.rawValue,
                       description: settings.description, terms: settings.terms, days: days)
    }

    /// Reads the period from Rewind's database (classified the way Rewind's own views and exports are).
    public static func load(db: RewindDB, period: ExportPeriod, settings: InvoiceSettings, issued: LocalDate) throws -> Invoice {
        build(period: period, metrics: try ExportPeriodData.load(db, period: period).metrics, settings: settings, issued: issued)
    }

    // MARK: - Dates

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }()

    static func noon(_ d: LocalDate) -> Date { utc.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))! }

    static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = pattern
        return f
    }

    /// `October 1–15, 2026`, `September 16 – October 3, 2026`, `December 20, 2025 – January 4, 2026`.
    public static func periodTitle(_ p: ExportPeriod) -> String {
        let a = noon(p.from), b = noon(p.through)
        if p.from.year != p.through.year {
            return "\(formatter("MMMM d, yyyy").string(from: a)) – \(formatter("MMMM d, yyyy").string(from: b))"
        }
        if p.from.month != p.through.month {
            return "\(formatter("MMMM d").string(from: a)) – \(formatter("MMMM d, yyyy").string(from: b))"
        }
        if p.from == p.through { return formatter("MMMM d, yyyy").string(from: a) }
        return "\(formatter("MMMM d").string(from: a))–\(p.through.day), \(p.through.year)"
    }

    /// `October 15, 2026`.
    public static func longDate(_ d: LocalDate) -> String { formatter("MMMM d, yyyy").string(from: noon(d)) }
    /// `Wed, Oct 15`.
    public static func dayLabel(_ d: LocalDate) -> String { formatter("EEE, MMM d").string(from: noon(d)) }

    /// The store day containing now.
    public static func today(_ tz: TimeZone = .current) -> LocalDate {
        LocalDate.containing(ms: Int64(Date().timeIntervalSince1970 * 1000), in: tz)
    }
}

/// `invoices.json` next to Transmute's settings: every invoice issued, newest first, with where its PDF went.
public struct InvoiceLedger: Sendable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var invoice: Invoice
        public var path: String
        public var id: String { invoice.number }
        public var url: URL { URL(filePath: path) }
        public init(invoice: Invoice, path: String) { self.invoice = invoice; self.path = path }
    }

    public let url: URL
    public init(url: URL) { self.url = url }
    /// Next to the settings file.
    public init(settings: URL) { url = settings.deletingLastPathComponent().appending(path: "invoices.json") }

    public func list() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    public func append(_ e: Entry) throws { try write([e] + list().filter { $0.id != e.id }) }
    public func remove(_ number: String) throws { try write(list().filter { $0.id != number }) }

    func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(entries).write(to: url, options: .atomic)
    }
}
