import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Testing
import HoursCore
@testable import HoursUI

/// Runtime render of every Settings tab, light + dark, to `$TMPDIR/hours-settings-<tab>-<scheme>.png`.
@MainActor
@Suite struct SettingsRenderTests {
    static let schemes: [ColorScheme] = [.light, .dark]

    /// `ImageRenderer` draws ScrollView and AppKit-backed controls (TextField, Picker, Toggle,
    /// Stepper, Menu) blank on macOS, so this renders through an offscreen window's `NSHostingView`
    /// (never ordered on screen) with `cacheDisplay`.
    @Test(arguments: SettingsTab.allCases)
    func renderTab(tab: SettingsTab) async throws {
        let model = try shellTempModel(seedDemo: 1...6)
        // Today: two apps no seed rule knows, so the review queue has rows.
        let tz = model.timeZone
        let writer = SpanWriter(model.db)
        for (app, h0, m0, h1, m1) in [("Figma", 9, 0, 9, 40), ("Linear", 9, 40, 10, 5)] {
            _ = try writer.append(RawSpan(seq: 0, startMs: shellMs(2026, 10, 5, h0, m0, tz: tz), endMs: shellMs(2026, 10, 5, h1, m1, tz: tz),
                                          tzId: tz.identifier, tzOffsetS: -25_200, kind: .active, bundleId: "com.example.\(app)",
                                          appName: app, title: "\(app) — Q4 board", url: nil))
        }
        await model.refetch()
        await model.setGoal(Goal(dailyWorkMs: 6 * 3_600_000))
        for scheme in Self.schemes {
            let size = NSSize(width: 680, height: 520)
            let host = NSHostingView(rootView: SettingsView.page(tab, model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            try await Task.sleep(for: .milliseconds(400))   // let `.task` loads (review queue, backups) land
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = try #require(rep.cgImage)
            #expect(image.width >= 680)
            defer { window.contentView = nil }

            let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
            let url = URL(fileURLWithPath: dir).appendingPathComponent("hours-settings-\(tab.rawValue)-\(scheme == .dark ? "dark" : "light").png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
            print("Settings \(tab.rawValue) (\(scheme)): \(url.path)")
        }
    }

    @Test func rulePreviewWinsAndLoses() throws {
        let cats = ClassifySeed.categories
        let github = ClassifyKey(bundleId: "com.google.Chrome", appName: "Chrome", title: "PR", url: "https://github.com/x")
        let gist = ClassifyKey(bundleId: "com.google.Chrome", appName: "Chrome", title: "g", url: "https://gist.github.com/y")
        let other = ClassifyKey(bundleId: "com.apple.Notes", appName: "Notes", title: nil, url: nil)
        let keys = [(key: github, totalMs: Int64(600_000)), (key: gist, totalMs: 60_000), (key: other, totalMs: 1_000)]

        // Same host as the seed rule, user origin → wins the tie on both github hosts.
        let draft = Rule(id: 0, origin: .user, host: "github.com", categoryId: ClassifySeed.research)
        let r = SettingsRulePreview.compute(draft: draft, rules: ClassifySeed.rules, categories: cats, projects: [], keys: keys)
        #expect(r.rows.count == 2)
        #expect(r.rows.allSatisfy { $0.verdict == "wins" })

        // Lower priority than a competing user rule → loses.
        let rival = Rule(id: 5000, origin: .user, priority: 5, host: "github.com", categoryId: ClassifySeed.coding)
        let r2 = SettingsRulePreview.compute(draft: draft, rules: ClassifySeed.rules + [rival], categories: cats, projects: [], keys: keys)
        #expect(r2.rows.count == 2)
        #expect(r2.rows.allSatisfy { $0.verdict.hasPrefix("loses to host github.com") })

        // Invalid draft → no preview.
        let bad = Rule(id: 0, origin: .user, titleRegex: "(", categoryId: ClassifySeed.coding)
        #expect(SettingsRulePreview.compute(draft: bad, rules: [], categories: cats, projects: [], keys: keys).rows.isEmpty)
    }
}
