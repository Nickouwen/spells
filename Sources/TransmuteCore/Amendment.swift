import Foundation
import RewindCore

/// A change to an invoice beyond "the period's hours at the rate": days the client already paid for
/// (their hours come off at the rate), a fixed amount off, or a fixed amount added. Each one is its own
/// line on the PDF under the period line, so the client sees what moved and why.
public struct Amendment: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case paidDays, credit, charge
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .paidDays: "Days already paid"
            case .credit: "Deduct an amount"
            case .charge: "Add an amount"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Why: "already paid", "deposit received", "rush fee". Printed on the line.
    public var note: String
    /// `paidDays`: the dates (inclusive) whose hours come off.
    public var from: LocalDate?
    public var through: LocalDate?
    /// `credit` / `charge`: the amount, positive.
    public var amountCents: Int64

    public init(id: UUID = UUID(), kind: Kind, note: String = "", from: LocalDate? = nil, through: LocalDate? = nil, amountCents: Int64 = 0) {
        self.id = id; self.kind = kind; self.note = note; self.from = from; self.through = through; self.amountCents = amountCents
    }

    public static func paidDays(_ from: LocalDate, _ through: LocalDate, note: String = "") -> Amendment {
        Amendment(kind: .paidDays, note: note, from: from, through: through)
    }
    public static func credit(cents: Int64, note: String = "") -> Amendment { Amendment(kind: .credit, note: note, amountCents: cents) }
    public static func charge(cents: Int64, note: String = "") -> Amendment { Amendment(kind: .charge, note: note, amountCents: cents) }

    /// The paid days, either way round.
    public var range: ExportPeriod? {
        guard kind == .paidDays, let from, let through else { return nil }
        return ExportPeriod(from: min(from, through), through: max(from, through))
    }

    public func covers(_ d: LocalDate) -> Bool {
        guard let r = range else { return false }
        return r.from <= d && d <= r.through
    }

    /// The note, or a stock reason when it's blank.
    public var reason: String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.isEmpty else { return n }
        switch kind {
        case .paidDays: return "already paid"
        case .credit: return "Credit"
        case .charge: return "Additional charge"
        }
    }

    /// `"Less October 1–6, 2026 (already paid)"`, `"Deposit received"`, `"Rush fee"`.
    public var title: String {
        kind == .paidDays ? "Less \(range.map(Invoice.periodTitle) ?? "") (\(reason))" : reason
    }
}
