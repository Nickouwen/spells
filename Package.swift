// swift-tools-version: 6.2
import PackageDescription

// ponytail: one package, script-assembled bundles (scripts/build.sh) — no .xcodeproj.
// Open Package.swift in Xcode for previews.
let package = Package(
    name: "Spells",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Spells", targets: ["Spells"]),
        .executable(name: "HoursSpell", targets: ["HoursSpell"]),
        .executable(name: "spellsctl", targets: ["spellsctl"]),
        .executable(name: "Incant", targets: ["Incant"]),
        .executable(name: "Scry", targets: ["Scry"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Pure logic + storage. Foundation/CryptoKit/GRDB only — never AppKit/SwiftUI.
        .target(name: "HoursCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "ScryCore"]),
        // Tracker engine + macOS adapters (AppKit/ApplicationServices, no SwiftUI).
        .target(name: "TrackerCore", dependencies: ["HoursCore"]),
        // Design system + views.
        .target(name: "HoursUI", dependencies: ["HoursCore", "IncantCore", "ScryCore", "ScryPipeline"]),
        // Incant's pure logic: gesture, cues, correction policy, Scribe/Cerebras wire formats, settings.
        .target(name: "IncantCore"),
        // Scry, the meeting-notes spell: pure logic (detection, transcript, summary/note formats, search)…
        .target(name: "ScryCore"),
        // …and the after-call pipeline (Scribe batch → claude -p → note), shared by Scry.app and spellsctl.
        .target(name: "ScryPipeline", dependencies: ["ScryCore", "HoursCore", "IncantCore"]),
        .executableTarget(name: "Spells", dependencies: ["HoursUI", "HoursCore"]),
        .executableTarget(name: "HoursSpell", dependencies: ["TrackerCore", "HoursCore"]),
        .executableTarget(name: "spellsctl", dependencies: ["HoursCore", "ScryCore", "ScryPipeline"]),
        // Incant: the dictation spell (a second login item, only while switched on).
        .executableTarget(name: "Incant", dependencies: ["HoursCore", "IncantCore"]),
        // Scry: meeting notes (a third login item, only while switched on).
        .executableTarget(name: "Scry", dependencies: ["HoursCore", "ScryCore", "ScryPipeline", "IncantCore"]),
        .testTarget(name: "HoursCoreTests", dependencies: ["HoursCore"]),
        .testTarget(name: "TrackerCoreTests", dependencies: ["TrackerCore"]),
        .testTarget(name: "HoursUITests", dependencies: ["HoursUI"]),
        .testTarget(name: "IncantCoreTests", dependencies: ["IncantCore"]),
        .testTarget(name: "ScryCoreTests", dependencies: ["ScryCore"]),
    ]
)
