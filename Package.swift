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
        .executableTarget(name: "Spells", dependencies: ["SpellsKit", "SpellsUI"]),
        // Rewind, the time-tracking module: the former hub window plus RewindTracker as its login item.
        .executableTarget(name: "Rewind", dependencies: ["RewindUI", "RewindCore", "SpellsUI"]),
        .executableTarget(name: "RewindTracker", dependencies: ["TrackerCore", "RewindCore"]),
        .executableTarget(name: "spellsctl", dependencies: ["RewindCore", "ScryCore", "ScryPipeline"]),
        // Incant: the dictation spell (a second login item, only while switched on).
        .executableTarget(name: "Incant", dependencies: ["SpellsKit", "SpellsUI", "IncantCore"]),
        // Scry: meeting notes (a third login item, only while switched on).
        .executableTarget(name: "Scry", dependencies: ["SpellsKit", "SpellsUI", "ScryCore", "ScryPipeline", "IncantCore"]),
        .testTarget(name: "SpellsKitTests", dependencies: ["SpellsKit"]),
        .testTarget(name: "RewindCoreTests", dependencies: ["RewindCore"]),
        .testTarget(name: "TrackerCoreTests", dependencies: ["TrackerCore"]),
        .testTarget(name: "RewindUITests", dependencies: ["RewindUI"]),
        .testTarget(name: "IncantCoreTests", dependencies: ["IncantCore"]),
        .testTarget(name: "ScryCoreTests", dependencies: ["ScryCore", "ScryPipeline"]),
    ]
)
