import SwiftUI
import RewindCore
import SpellsKit
import SpellsUI
import TransmuteCore
import TransmuteUI

/// Transmute: hours → invoice. Reads Rewind's database (never writes it) and prices a period at your
/// rate as a PDF. A windowed module like Rewind: the launcher opens it, it updates itself.
@main
struct TransmuteApp: App {
    @State private var launch: Result<TransmuteModel, any Error> = Result {
        let paths = SupportPaths.current()
        guard FileManager.default.fileExists(atPath: paths.db.path) else { throw Missing() }
        return TransmuteModel(db: try RewindDB.open(at: paths.db, role: .app))
    }
    @Environment(\.openSettings) private var openSettings

    struct Missing: Error {}

    var body: some Scene {
        Window("Transmute", id: "main") {
            switch launch {
            case .success(let model):
                InvoicesView(model: model, openSettings: { openSettings() })
                    .navigationTitle("Invoices")
                    .task { ModuleUpdater.start(settings: .transmute()) }
            case .failure(let error):
                EmptyState(symbol: "clock.arrow.circlepath", title: error is Missing ? "Rewind hasn't tracked anything yet" : "Couldn't open Rewind's database",
                           detail: error is Missing ? "Transmute invoices the hours Rewind records. Install Rewind from Spells and let it run for a day."
                                                    : String(describing: error))
                    .frame(minWidth: 700, minHeight: 480)
            }
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            TransmuteSettingsView(onSaved: { if case .success(let m) = launch { m.reloadSettings() } })
        }
    }
}
