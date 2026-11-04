// swift-tools-version: 6.2
import PackageDescription

// ponytail: one package, script-assembled bundles (scripts/build.sh) — no .xcodeproj.
// Open Package.swift in Xcode for previews.
let package = Package(
    name: "Spells",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Spells", targets: ["Spells"]),
        .executable(name: "Rewind", targets: ["Rewind"]),
        .executable(name: "RewindTracker", targets: ["RewindTracker"]),
        .executable(name: "spellsctl", targets: ["spellsctl"]),
        .executable(name: "Incant", targets: ["Incant"]),
        .executable(name: "Scry", targets: ["Scry"]),
        .executable(name: "Transmute", targets: ["Transmute"]),
        .executable(name: "Ward", targets: ["Ward"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // What every module shares with the launcher: identifiers, log, keychain, paths, per-module settings files.
        .target(name: "SpellsKit"),
        // Pure logic + storage. Foundation/CryptoKit/GRDB only — never AppKit/SwiftUI.
        .target(name: "RewindCore", dependencies: ["SpellsKit", .product(name: "GRDB", package: "GRDB.swift"), "ScryCore"]),
        // Tracker engine + macOS adapters (AppKit/ApplicationServices, no SwiftUI).
        .target(name: "TrackerCore", dependencies: ["RewindCore"]),
        // Design primitives + the module-app shell (settings scaffold, URL verbs), shared by every module's UI.
        .target(name: "SpellsUI", dependencies: ["SpellsKit"]),
        // Rewind's views.
        .target(name: "RewindUI", dependencies: ["RewindCore", "SpellsUI", "ScryCore"]),
        // Incant's pure logic: gesture, cues, correction policy, Scribe/Cerebras wire formats, settings.
        .target(name: "IncantCore"),
        // Scry, the meeting-notes spell: pure logic (detection, transcript, summary/note formats, search)…
        .target(name: "ScryCore"),
        // …and the after-call pipeline (Scribe batch → claude -p → note), shared by Scry.app and spellsctl.
        .target(name: "ScryPipeline", dependencies: ["ScryCore", "SpellsKit", "IncantCore"]),
        // The launcher: finds module apps in ~/Applications/Spells and starts, stops and opens them. Installs nothing.
        .executableTarget(name: "Spells", dependencies: ["SpellsKit", "SpellsUI", "RewindUI", "RewindCore", "ScryUI", "ScryCore", "IncantUI", "TransmuteUI", "TransmuteCore", "WardUI", "WardCore"]),
        // Rewind, the time-tracking module: the former hub window plus RewindTracker as its login item.
        .executableTarget(name: "Rewind", dependencies: ["RewindUI", "RewindCore", "SpellsUI"]),
        .executableTarget(name: "RewindTracker", dependencies: ["TrackerCore", "RewindCore"]),
        .executableTarget(name: "spellsctl", dependencies: ["RewindCore", "ScryCore", "ScryPipeline"]),
        // Incant: the dictation spell (a second login item, only while switched on).
        // Each module's windows as a library, so the Spells hub can show the same views.
        .target(name: "IncantUI", dependencies: ["IncantCore", "SpellsKit", "SpellsUI"]),
        .target(name: "ScryUI", dependencies: ["ScryCore", "ScryPipeline", "SpellsKit", "SpellsUI"]),
        .executableTarget(name: "Incant", dependencies: ["SpellsKit", "SpellsUI", "IncantCore", "IncantUI"]),
        // Scry: meeting notes (a third login item, only while switched on).
        .executableTarget(name: "Scry", dependencies: ["SpellsKit", "SpellsUI", "ScryCore", "ScryPipeline", "IncantCore", "ScryUI"]),
        // Transmute: invoices from Rewind's hours (pure model + PDF, then its views, then the windowed app).
        .target(name: "TransmuteCore", dependencies: ["RewindCore"]),
        .target(name: "TransmuteUI", dependencies: ["TransmuteCore", "RewindCore", "SpellsKit", "SpellsUI"]),
        .executableTarget(name: "Transmute", dependencies: ["SpellsKit", "SpellsUI", "RewindCore", "TransmuteCore", "TransmuteUI"]),
        // Ward: network watch — the rolling packet capture's facts and parsing (pure), its views, the windowed app.
        .target(name: "WardCore"),
        .target(name: "WardUI", dependencies: ["WardCore", "SpellsKit", "SpellsUI"]),
        .executableTarget(name: "Ward", dependencies: ["SpellsKit", "SpellsUI", "WardCore", "WardUI"]),
        .testTarget(name: "SpellsKitTests", dependencies: ["SpellsKit"]),
        .testTarget(name: "RewindCoreTests", dependencies: ["RewindCore"]),
        .testTarget(name: "TrackerCoreTests", dependencies: ["TrackerCore"]),
        .testTarget(name: "RewindUITests", dependencies: ["RewindUI"]),
        .testTarget(name: "IncantCoreTests", dependencies: ["IncantCore"]),
        .testTarget(name: "ScryCoreTests", dependencies: ["ScryCore", "ScryPipeline"]),
        .testTarget(name: "TransmuteCoreTests", dependencies: ["TransmuteCore"]),
        .testTarget(name: "WardCoreTests", dependencies: ["WardCore"]),
        // Screenshots of every window and overlay against demo data; runs only with SPELLS_RENDER_DIR set.
        .testTarget(name: "SpellsRenderTests", dependencies: ["Spells", "Incant", "Scry", "RewindCore", "RewindUI",
                                                              "ScryCore", "SpellsKit", "SpellsUI", "WardUI", "TransmuteUI",
                                                              "IncantUI", "ScryUI"]),
    ]
)
