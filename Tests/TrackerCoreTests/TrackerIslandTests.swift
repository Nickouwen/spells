import CoreGraphics
import Testing
@testable import TrackerCore

// W18 notch island: pure geometry, label format and the style setting. Expectations are worked out
// by hand from this MacBook's NSScreen values (1800×1169, notch 220×38 at x 790–1010).

private let builtIn = TrackerIslandScreen(
    frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130),
    safeAreaTop: 38, auxiliaryTopLeft: CGRect(x: 0, y: 1131, width: 790, height: 38),
    auxiliaryTopRight: CGRect(x: 1010, y: 1131, width: 790, height: 38))
private let external = TrackerIslandScreen(
    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415))

@Test func notchRectFromAuxiliaryAreas() {
    #expect(builtIn.notch == CGRect(x: 790, y: 1131, width: 220, height: 38))
    #expect(external.notch == nil)
    // Built-in to the right of a main external display: local and global auxiliary rects agree.
    var moved = builtIn
    moved.frame.origin.x = 2560
    #expect(moved.notch == CGRect(x: 3350, y: 1131, width: 220, height: 38))
    moved.auxiliaryTopLeft = CGRect(x: 2560, y: 1131, width: 790, height: 38)
    moved.auxiliaryTopRight = CGRect(x: 3570, y: 1131, width: 790, height: 38)
    #expect(moved.notch == CGRect(x: 3350, y: 1131, width: 220, height: 38))
}

@Test func notchGeometryBothEars() throws {
    let g = try #require(TrackerIslandGeometry.make(screens: [builtIn], style: .both))
    #expect(g.mode == .notch)
    // 72 pt ears either side of the 220 pt notch, exactly the notch's height, flush with the top.
    #expect(g.collapsed == CGRect(x: 718, y: 1131, width: 364, height: 38))
    #expect(g.leftEar == CGRect(x: 718, y: 1131, width: 72, height: 38))
    #expect(g.rightEar == CGRect(x: 1010, y: 1131, width: 72, height: 38))
    // 6 pt top flares on each side.
    #expect(g.collapsedWindow == CGRect(x: 712, y: 1131, width: 376, height: 38))
    // Card: 220 + 2 × (72 + 6) = 376 wide, 38 + 98 = 136 tall, centred on the notch, top at 1169.
    #expect(g.expanded == CGRect(x: 712, y: 1033, width: 376, height: 136))
    #expect(g.collapsedRadius == 10)
}

@Test func notchGeometryRightEarOnly() throws {
    let g = try #require(TrackerIslandGeometry.make(screens: [builtIn], style: .right))
    #expect(g.leftEar == nil)
    #expect(g.collapsed == CGRect(x: 790, y: 1131, width: 292, height: 38))
    #expect(g.expanded == CGRect(x: 712, y: 1033, width: 376, height: 136))
}

@Test func notchScreenWinsOverMenuBarScreen() throws {
    let g = try #require(TrackerIslandGeometry.make(screens: [external, builtIn], style: .both))
    #expect(g.mode == .notch)
    #expect(g.notch == CGRect(x: 790, y: 1131, width: 220, height: 38))
}

@Test func pillWithoutNotch() throws {
    let g = try #require(TrackerIslandGeometry.make(screens: [external], style: .both))
    #expect(g.mode == .pill)
    #expect(g.flare == 0)
    // Centred (x 1280), 6 pt under the menu bar (visible top 1415), 30 pt tall, two 72 pt halves.
    #expect(g.collapsed == CGRect(x: 1208, y: 1379, width: 144, height: 30))
    #expect(g.collapsedWindow == g.collapsed)
    #expect(g.collapsedRadius == 15)
    #expect(g.expanded == CGRect(x: 1092, y: 1281, width: 376, height: 128))
    let r = try #require(TrackerIslandGeometry.make(screens: [external], style: .right))
    #expect(r.collapsed == CGRect(x: 1244, y: 1379, width: 72, height: 30))
    // Auto-hidden menu bar: visibleFrame reaches the top.
    var hidden = external
    hidden.visibleFrame.size.height = 1440
    #expect(TrackerIslandGeometry.make(screens: [hidden], style: .both)?.collapsed.maxY == 1434)
}

@Test func earWidthFromMeasuredText() throws {
    // 8 pt notch gap + text + 13 pt outer inset, rounded up; never under 64.
    #expect(TrackerIslandGeometry.earWidth(forText: 52) == 73)
    #expect(TrackerIslandGeometry.earWidth(forText: 52.4) == 74)
    #expect(TrackerIslandGeometry.earWidth(forText: 30) == 64)
    let g = try #require(TrackerIslandGeometry.make(screens: [builtIn], style: .both, earWidth: 74))
    #expect(g.leftEar == CGRect(x: 716, y: 1131, width: 74, height: 38))
    #expect(g.rightEar == CGRect(x: 1010, y: 1131, width: 74, height: 38))
    // 220 + 2 × (74 + 6) = 380 wide, centred on the notch (midX 900).
    #expect(g.expanded == CGRect(x: 710, y: 1033, width: 380, height: 136))
}

@Test func offOrNoScreensShowsNothing() {
    #expect(TrackerIslandGeometry.make(screens: [builtIn], style: .off) == nil)
    #expect(TrackerIslandGeometry.make(screens: [], style: .both) == nil)
}

@Test func durationLabel() {
    let m: Int64 = 60_000, h = 60 * m
    #expect(TrackerIslandFormat.duration(ms: 0) == "0m")
    #expect(TrackerIslandFormat.duration(ms: -5 * m) == "0m")
    #expect(TrackerIslandFormat.duration(ms: 30_000) == "<1m")
    #expect(TrackerIslandFormat.duration(ms: 17 * m) == "17m")
    #expect(TrackerIslandFormat.duration(ms: 6 * h) == "6h")
    #expect(TrackerIslandFormat.duration(ms: 4 * h + 17 * m) == "4h 17m")
    #expect(TrackerIslandFormat.duration(ms: 4 * h + 17 * m + 29_999) == "4h 17m")
    #expect(TrackerIslandFormat.duration(ms: 4 * h + 17 * m + 30_000) == "4h 18m")
    #expect(TrackerIslandFormat.duration(ms: 59 * m + 30_000) == "1h")
    #expect(TrackerIslandFormat.duration(ms: 10 * h + 59 * m) == "10h 59m")
}

@Test func styleSettingParse() {
    #expect(TrackerIslandStyle.key == "island_style")
    #expect(TrackerIslandStyle.parse(nil) == .both)
    #expect(TrackerIslandStyle.parse("both") == .both)
    #expect(TrackerIslandStyle.parse("off") == .off)
    #expect(TrackerIslandStyle.parse("right") == .right)
    #expect(TrackerIslandStyle.parse(" Right ") == .right)
    #expect(TrackerIslandStyle.parse("left") == .both)
    #expect(TrackerIslandStyle.parse("") == .both)
}
