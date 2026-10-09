import Testing
@testable import HoursCore

@Test func demoDataIsContiguousWeekdaysOnly() {
    let s = DemoData.spans(from: LocalDate(year: 2026, month: 10, day: 5), through: LocalDate(year: 2026, month: 10, day: 11))
    #expect(!s.isEmpty)
    for (a, b) in zip(s, s.dropFirst()) { #expect(a.endMs <= b.startMs) }
    #expect(s.allSatisfy { $0.endMs > $0.startMs })
    let days = Set(s.map { ($0.startMs / 1000 + Int64($0.tzOffsetS)) / 86_400 })   // local days
    #expect(days.count == 5)   // Mon–Fri
    #expect(s == DemoData.spans(from: LocalDate(year: 2026, month: 10, day: 5), through: LocalDate(year: 2026, month: 10, day: 11)))
}
