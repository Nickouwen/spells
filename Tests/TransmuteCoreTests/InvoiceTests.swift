import Foundation
import Testing
import RewindCore
@testable import TransmuteCore

private func metrics(_ days: [(Int, Int64, Int64)]) -> RangeMetrics {
    var r = RangeMetrics()
    for (day, work, tracked) in days {
        var m = DayMetrics()
        m.workMs = work; m.trackedMs = tracked; m.billableMs = work / 2
        r.days.append(.init(date: LocalDate(year: 2026, month: 10, day: day), metrics: m))
    }
    return r
}

private var settings: InvoiceSettings {
    var s = InvoiceSettings.load(["from_name": "Nic", "client_name": "Teagan", "rate": "45.50", "next_number": "12"])
    s.fromAddress = "1 Main St\nTown"
    return s
}

@Test func pricesHoursAtTheRate() {
    let p = ExportPeriod(from: LocalDate(year: 2026, month: 10, day: 1), through: LocalDate(year: 2026, month: 10, day: 15))
    let inv = Invoice.build(period: p, metrics: metrics([(1, 3_600_000, 4_000_000), (2, 0, 1_000_000), (3, 5_400_000, 5_400_000)]),
                            settings: settings, issued: p.through)
    #expect(inv.number == "INV-0012")
    #expect(inv.days.map(\.date.day) == [1, 3])          // the zero-work day is left out
    #expect(inv.totalHundredths == 250)                   // 1.00 h + 1.50 h
    #expect(inv.amountCents == 11375)                     // 2.5 × 45.50
    #expect(inv.amount == "$113.75")
    #expect(inv.title == "For development October 1–15, 2026")
    #expect(inv.fileName == "INV-0012.pdf")

    var tracked = settings; tracked.basis = .tracked
    let all = Invoice.build(period: p, metrics: metrics([(1, 3_600_000, 4_000_000), (2, 0, 1_000_000)]), settings: tracked, issued: p.through)
    #expect(all.days.count == 2)
    #expect(all.totalHundredths == 111 + 28)
}

@Test func settingsRoundTripAndRates() {
    #expect(InvoiceSettings.parseRate("45") == 4500)
    #expect(InvoiceSettings.parseRate("$1,200.5") == 120050)
    #expect(InvoiceSettings.parseRate("45.125") == 4512)
    #expect(InvoiceSettings.parseRate("abc") == nil)
    #expect(InvoiceSettings.rateString(4505) == "45.05")
    let s = settings
    let back = InvoiceSettings.load(s.rows)
    #expect(back == s)
    #expect(InvoiceSettings().missing == ["your name", "the client's name", "an hourly rate"])
    #expect(s.missing.isEmpty)
    #expect(InvoiceSettings.load(["folder": "~/x"]).folderURL.lastPathComponent == "x")
}

@Test func periodTitles() {
    func t(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> String {
        Invoice.periodTitle(ExportPeriod(from: LocalDate(year: a.0, month: a.1, day: a.2), through: LocalDate(year: b.0, month: b.1, day: b.2)))
    }
    #expect(t((2026, 10, 1), (2026, 10, 15)) == "October 1–15, 2026")
    #expect(t((2026, 9, 16), (2026, 10, 3)) == "September 16 – October 3, 2026")
    #expect(t((2025, 12, 20), (2026, 1, 4)) == "December 20, 2025 – January 4, 2026")
    #expect(t((2026, 10, 3), (2026, 10, 3)) == "October 3, 2026")
}

@Test func rendersAPDFAndPaginatesLongPeriods() throws {
    let p = ExportPeriod(from: LocalDate(year: 2026, month: 7, day: 1), through: LocalDate(year: 2026, month: 9, day: 30))
    let days = p.days.enumerated().map { (i, d) in (d.day + (i / 31) * 0, Int64(3_600_000 * (1 + i % 5)), Int64(0)) }
    var r = RangeMetrics()
    for (i, d) in p.days.enumerated() { var m = DayMetrics(); m.workMs = days[i].1; r.days.append(.init(date: d, metrics: m)) }
    var inv = Invoice.build(period: p, metrics: r, settings: settings, issued: p.through)
    inv.amendments = [.paidDays(LocalDate(year: 2026, month: 7, day: 1), LocalDate(year: 2026, month: 7, day: 6)),
                      .credit(cents: 5000, note: "Deposit received")]
    let (data, pages) = InvoicePDF.render(inv)
    #expect(data.starts(with: Array("%PDF".utf8)))
    #expect(pages >= 2)
    if let out = ProcessInfo.processInfo.environment["TRANSMUTE_SAMPLE_OUT"] { try data.write(to: URL(filePath: out)) }   // eyeballing the layout
    let dir = FileManager.default.temporaryDirectory.appending(path: "transmute-tests/\(UUID().uuidString)")
    let url = try InvoicePDF.write(inv, to: dir)
    #expect(url.lastPathComponent == "INV-0012.pdf")
    #expect(FileManager.default.fileExists(atPath: url.path))

    let ledger = InvoiceLedger(settings: dir.appending(path: "settings.json"))
    try ledger.append(.init(invoice: inv, path: url.path))
    #expect(ledger.list().map(\.id) == ["INV-0012"])
    try ledger.remove("INV-0012")
    #expect(ledger.list().isEmpty)
}

@Test func amendmentsBecomeLinesAndChangeTheTotal() throws {
    let p = ExportPeriod(from: LocalDate(year: 2026, month: 10, day: 1), through: LocalDate(year: 2026, month: 10, day: 15))
    func d(_ day: Int) -> LocalDate { LocalDate(year: 2026, month: 10, day: day) }
    let h = Int64(3_600_000)
    var inv = Invoice.build(period: p, metrics: metrics([(1, h, h), (2, 2 * h, 2 * h), (3, 3 * h, 3 * h), (10, h, h)]), settings: settings, issued: p.through)
    #expect(inv.amountCents == 31850)                     // 7 h × 45.50
    let paid = Amendment.paidDays(d(1), d(2))
    inv.amendments = [paid, .paidDays(d(2), d(3), note: "paid by deposit"), .credit(cents: 1000, note: "Deposit"), .charge(cents: 500, note: "Rush")]
    let lines = inv.lines
    #expect(lines.map(\.title) == ["For development October 1–15, 2026", "Less October 1–2, 2026 (already paid)",
                                   "Less October 2–3, 2026 (paid by deposit)", "Deposit", "Rush"])
    #expect(lines.map(\.hundredths) == [700, -300, -300, nil, nil])   // day 2 comes off once
    #expect(lines.map(\.cents) == [31850, -13650, -13650, -1000, 500])
    #expect(inv.amountCents == 4050)
    #expect(inv.billedHundredths == 100)
    #expect(inv.billedHours == "1.00")
    #expect(inv.paidBy(d(2))?.id == paid.id)
    #expect(inv.paidBy(d(10)) == nil)
    #expect(Money.format(cents: -13650, currency: "CAD") == "−$136.50")
    #expect(Invoice.hours(-300) == "−3.00")

    // Round-trips, and a ledger written before amendments existed still decodes.
    let data = try JSONEncoder().encode(inv)
    #expect(try JSONDecoder().decode(Invoice.self, from: data) == inv)
    var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    dict["amendments"] = nil
    let old = try JSONDecoder().decode(Invoice.self, from: JSONSerialization.data(withJSONObject: dict))
    #expect(old.amendments.isEmpty)
    #expect(old.amountCents == 31850)
}
