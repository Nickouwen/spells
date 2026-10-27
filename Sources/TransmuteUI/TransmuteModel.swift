import AppKit
import Observation
import RewindCore
import SpellsKit
import TransmuteCore

/// Which period the invoice covers: the usual semi-month (1–15 / 16–end) just finished, the one in
/// progress, or any two dates.
public enum InvoicePreset: String, CaseIterable, Identifiable, Sendable {
    case previous, current, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .previous: "Last period"
        case .current: "This period"
        case .custom: "Custom"
        }
    }
}

/// Transmute's state: the chosen period, its hours priced as an invoice (re-read from Rewind's database
/// whenever the period or the settings change), and the ledger of invoices already issued.
@MainActor @Observable public final class TransmuteModel {
    public let db: RewindDB
    public let timeZone: TimeZone
    let settingsFile: SpellSettingsFile
    let ledger: InvoiceLedger

    public private(set) var settings = InvoiceSettings()
    public var preset: InvoicePreset = .previous { didSet { reload() } }
    public var customFrom: LocalDate { didSet { if preset == .custom { reload() } } }
    public var customThrough: LocalDate { didSet { if preset == .custom { reload() } } }
    public private(set) var preview: Invoice?
    public private(set) var loading = false
    public private(set) var error: String?
    public private(set) var issued: [InvoiceLedger.Entry] = []
    /// The PDF just written, until the period or settings change.
    public private(set) var justIssued: InvoiceLedger.Entry?
    private var generation = 0

    public init(db: RewindDB, timeZone: TimeZone = .current, settings: SpellSettingsFile = .transmute()) {
        self.db = db
        self.timeZone = timeZone
        settingsFile = settings
        ledger = InvoiceLedger(settings: settings.url)
        let today = Invoice.today(timeZone)
        let current = ExportPeriod.semiMonth(containing: today)
        customFrom = current.from
        customThrough = today
    }

    public var today: LocalDate { Invoice.today(timeZone) }

    public var period: ExportPeriod {
        switch preset {
        case .previous: ExportPeriod.parse("previous", today: today)!
        case .current: ExportPeriod.semiMonth(containing: today)
        case .custom: ExportPeriod(from: min(customFrom, customThrough), through: max(customFrom, customThrough))
        }
    }

    public func start() {
        reloadSettings()
        issued = ledger.list()
    }

    /// After Settings saved (here or in the hub).
    public func reloadSettings() {
        settings = InvoiceSettings.load(settingsFile.all())
        reload()
    }

    public func reload() {
        justIssued = nil
        guard settings.missing.isEmpty else { preview = nil; return }
        generation += 1
        let gen = generation
        let (db, period, settings, issued) = (db, period, settings, period.through)
        loading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Invoice.load(db: db, period: period, settings: settings, issued: issued) }
            }.value
            guard gen == generation else { return }
            loading = false
            switch result {
            case .success(let inv): preview = inv; error = nil
            case .failure(let e): preview = nil; error = "Couldn't read Rewind's hours: \(e)"
            }
        }
    }

    /// Writes the PDF, records it, moves the number on and shows it in the Finder.
    public func issue() {
        guard var inv = preview else { return }
        inv.issued = today
        do {
            let url = try InvoicePDF.write(inv, to: settings.folderURL)
            let entry = InvoiceLedger.Entry(invoice: inv, path: url.path)
            try ledger.append(entry)
            try settingsFile.set(InvoiceSettings.Key.next, String(settings.nextNumber + 1))
            settings.nextNumber += 1
            issued = ledger.list()
            justIssued = entry
            preview?.number = settings.number
            error = nil
            SupportLog.transmute.info("issued \(inv.number, privacy: .public) for \(inv.period.description, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            self.error = "Couldn't write the invoice: \(error.localizedDescription)"
            SupportLog.transmute.error("issue failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func open(_ e: InvoiceLedger.Entry) { NSWorkspace.shared.open(e.url) }
    public func reveal(_ e: InvoiceLedger.Entry) { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }

    /// Trashes the PDF and forgets the invoice (the number is not reused).
    public func delete(_ e: InvoiceLedger.Entry) {
        do {
            if FileManager.default.fileExists(atPath: e.path) { try FileManager.default.trashItem(at: e.url, resultingItemURL: nil) }
            try ledger.remove(e.id)
            issued = ledger.list()
            if justIssued?.id == e.id { justIssued = nil }
        } catch {
            self.error = "Couldn't delete \(e.id): \(error.localizedDescription)"
        }
    }

    public func revealFolder() {
        try? FileManager.default.createDirectory(at: settings.folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([settings.folderURL])
    }
}
