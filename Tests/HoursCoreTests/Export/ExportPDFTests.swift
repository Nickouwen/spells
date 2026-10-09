import Foundation
import PDFKit
import Testing
@testable import HoursCore

@Suite struct ExportPDFTests {
    static let generated = exportMs("2026-10-05 12:00")

    /// Page count and per-page text, via PDFKit (selectable text ⇒ vector Core Text, not an image).
    func read(_ url: URL) throws -> [String] {
        let doc = try #require(PDFDocument(url: url))
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    @Test func fixtureTotalsMatchTheCSV() throws {
        let db = try exportFixtureDB()
        let dir = exportTempDir()
        let r = try ExportPDF.write(db: db, period: exportFixturePeriod, mode: .plain, to: dir, tz: exportUTCZone,
                                    generatedMs: Self.generated, name: "Test Person")
        let pages = try read(r.url)
        #expect(pages.count == 1 && r.pages == 1)
        let text = pages.joined(separator: "\n")

        // Per-project totals from the CSV golden (ExportTimesheetTests): operations-dashboard 0.33,
        // hours 2.00 + 0.50 + 0.33 + 1.00 = 3.83; period 4.16.
        let csv = ExportTimesheetTests.golden
        #expect(r.data.timesheetCSV == Data(csv.utf8))
        let byProject = Dictionary(grouping: r.data.rows, by: \.project).mapValues { $0.reduce(0) { $0 + $1.hundredths } }
        #expect(byProject == ["operations-dashboard": 33, "spells": 383])
        for amount in ["0.33", "3.83", "2.00", "0.50", "1.00", "4.16 h"] { #expect(text.contains(amount), "missing \(amount)") }
        for project in ["operations-dashboard", "spells", "Wed Sep 16", "Fri Sep 18", "Wed Sep 30", "Test Person", "Sep 16–30, 2026"] {
            #expect(text.contains(project), "missing \(project)")
        }

        // Footer ties the PDF to timesheet.csv and to the chain head; the witness line is printed in full.
        let head = try db.head()
        #expect(text.contains("timesheet.csv sha256:\(exportSHA256Hex(Data(csv.utf8)).prefix(16))"))
        #expect(text.contains("Chain head #10 \(exportHex(head.hash).prefix(16))"))
        #expect(text.contains("head not yet anchored"))
        #expect(text.contains("page 1/1"))
        #expect(squash(text).contains(squash(try ExportWitness.line(db: db, period: exportFixturePeriod))))

        // The manual entry's label is private: the client timesheet says "Manual entry".
        #expect(text.contains(ExportPeriodData.manualLabel))
        #expect(!text.contains("Client call") && !text.contains("Alex"))
        #expect(!text.contains("Audit appendix"))
    }

    @Test func consultantNameComesFromSettingElseAccountName() throws {
        let db = try exportFixtureDB()
        func name() throws -> String {
            try ExportPDF.load(db: db, period: exportFixturePeriod, mode: .plain, tz: exportUTCZone, generatedMs: Self.generated).name
        }
        #expect(try name() == NSFullUserName())
        try SettingStore(db).set(ExportPDF.consultantNameKey, "Example User")
        #expect(try name() == "Example User")
        try SettingStore(db).set(ExportPDF.consultantNameKey, "   ")
        #expect(try name() == NSFullUserName())
        // An explicit name (CLI/tests) still wins.
        #expect(try ExportPDF.load(db: db, period: exportFixturePeriod, mode: .plain, name: "X").name == "X")
    }

    @Test func auditAppendixGatesEditDetailsByDisclosure() throws {
        let db = try exportFixtureDB()
        let l0 = try read(ExportPDF.write(db: db, period: exportFixturePeriod, mode: .audit, disclosure: .L0,
                                          to: exportTempDir(), tz: exportUTCZone, generatedMs: Self.generated).url)
        let t0 = l0.joined(separator: "\n")
        #expect(l0.count == 2)
        #expect(l0[1].contains("Audit appendix") && l0[1].contains("page 2/2"))
        // seq 9 (manual add, created 10-02 after the period) is flagged; seq 10 (delete) is listed.
        #expect(t0.contains("#9") && t0.contains("2026-10-02 12:00 †") && t0.contains("#10"))
        #expect(t0.contains("2, of which 1 recorded after the period ended"))
        #expect(!t0.contains("Client call"))

        let t2 = try read(ExportPDF.write(db: db, period: exportFixturePeriod, mode: .audit, disclosure: .L2,
                                          to: exportTempDir(), tz: exportUTCZone, generatedMs: Self.generated).url)
            .joined(separator: "\n")
        #expect(t2.contains("Client call, \"Alex\""))
    }

    @Test func anchoredHeadShowsInFooterAndAnchorTable() throws {
        let db = try exportFixtureDB()
        let head = try db.head()
        try AnchorStore(db).insert(ChainAnchor(headSeq: head.seq, headHash: head.hash, method: "rfc3161", tsa: "digicert",
                                               requestedMs: exportMs("2026-10-03 08:11"), genTimeMs: exportMs("2026-10-03 08:12")))
        let pages = try read(ExportPDF.write(db: db, period: exportFixturePeriod, mode: .audit, to: exportTempDir(),
                                             tz: exportUTCZone, generatedMs: Self.generated).url)
        for p in pages { #expect(p.contains("· anchored 2026-10-03 08:12Z by digicert ·")) }
        #expect(pages.last!.contains("#\(head.seq) \(exportHex(head.hash).prefix(16))"))
        #expect(pages.joined().contains("2026-10-03 08:11Z"))
    }

    @Test func pageCountForOneAndThirtyOneDays() throws {
        let oneDay = ExportPeriod(from: LocalDate(year: 2026, month: 9, day: 16), through: LocalDate(year: 2026, month: 9, day: 16))
        let one = try ExportPDF.write(db: try exportFixtureDB(), period: oneDay, mode: .plain, to: exportTempDir(),
                                      tz: exportUTCZone, generatedMs: Self.generated)
        let onePages = try read(one.url)
        #expect(onePages.count == 1 && onePages[0].contains("page 1/1") && onePages[0].contains("2.33 h"))

        let db = try storeTempDB(role: .app)
        _ = try ExportDemoSeed.run(db: db, days: 31, today: LocalDate(year: 2026, month: 9, day: 1), tzId: "UTC")
        let august = ExportPeriod(from: LocalDate(year: 2026, month: 8, day: 1), through: LocalDate(year: 2026, month: 8, day: 31))
        let r = try ExportPDF.write(db: db, period: august, mode: .plain, to: exportTempDir(), tz: exportUTCZone,
                                    generatedMs: Self.generated)
        let pages = try read(r.url)
        // ~21 workdays × ~5 projects ≈ 100 rows at ~45 per full page, plus the summaries.
        #expect((3...5).contains(pages.count), "\(pages.count) pages for \(r.data.rows.count) rows")
        #expect(r.pages == pages.count)
        for (i, p) in pages.enumerated() {
            #expect(p.contains("page \(i + 1)/\(pages.count)"))
            #expect(p.contains("timesheet.csv sha256:\(exportSHA256Hex(r.data.timesheetCSV).prefix(16))"))
        }
        let text = pages.joined(separator: "\n")
        #expect(text.contains("Aug 1–31, 2026") && text.contains("\(ExportPeriodData.hours(r.data.totalHundredths)) h"))
        // Continuation pages repeat the table header.
        #expect(pages[1].contains("DAY TOTAL"))
    }

    @Test func categorySplitSumsToBilledProjectTotals() throws {
        let data = try ExportPeriodData.load(try exportFixtureDB(), period: exportFixturePeriod)
        let projects = ExportPDF.projects(data)
        #expect(projects.map(\.project) == ["spells", "operations-dashboard"])
        for p in projects {
            #expect(p.categories.reduce(0) { $0 + $1.ms } == p.ms)
            #expect(ExportPDF.allocate(p.hundredths, p.categories.map(\.ms)).reduce(0, +) == p.hundredths)
        }
        // hours: 13 800 s billable, of which the 1 200 s manual add is Meetings.
        #expect(projects[0].ms == 13_800_000)
        #expect(projects[0].categories.first { $0.name == "Meetings" }?.ms == 1_200_000)
        #expect(ExportPDF.manualMs(data) == 1_200_000)
    }

    @Test func allocateIsLargestRemainder() {
        #expect(ExportPDF.allocate(100, [1, 1, 1]) == [34, 33, 33])
        // 383 × 12600/13800 = 349.70, 383 × 1200/13800 = 33.30 → the one leftover goes to the larger remainder.
        #expect(ExportPDF.allocate(383, [12_600, 1_200]) == [350, 33])
        #expect(ExportPDF.allocate(5, [0, 0]) == [0, 0])
    }

    @Test func periodTitles() {
        func p(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> ExportPeriod {
            ExportPeriod(from: LocalDate(year: a.0, month: a.1, day: a.2), through: LocalDate(year: b.0, month: b.1, day: b.2))
        }
        #expect(ExportPDFRender.periodTitle(p((2026, 9, 16), (2026, 9, 30))) == "Sep 16–30, 2026")
        #expect(ExportPDFRender.periodTitle(p((2026, 9, 28), (2026, 10, 3))) == "Sep 28 – Oct 3, 2026")
        #expect(ExportPDFRender.periodTitle(p((2026, 12, 28), (2027, 1, 3))) == "Dec 28, 2026 – Jan 3, 2027")
        #expect(ExportPDFRender.periodTitle(p((2026, 9, 16), (2026, 9, 16))) == "Sep 16, 2026")
        #expect(ExportPDFRender.hm(3_630_000) == "1h 01m")
    }
}
