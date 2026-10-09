import Testing
@testable import TrackerCore

@Test(arguments: [
    ("https://github.com/org/repo/pull/1?diff=split#r1", "https://github.com/org/repo/pull/1"),
    ("https://a.com/#/route?x=1", "https://a.com/"),
    ("https://user:pw@a.com/p?q", "https://a.com/p"),
    ("http://localhost:3000/x", "http://localhost:3000/x"),
    ("   ", nil),
] as [(String, String?)])
func urlStripping(raw: String, expected: String?) {
    #expect(TrackerSanitize.url(raw) == expected)
}

@Test func urlAndTitleTruncation() {
    #expect(TrackerSanitize.url("https://a.com/" + String(repeating: "p", count: 600))?.count == 512)
    #expect(TrackerSanitize.title(String(repeating: "é", count: 300))?.count == 256)
    #expect(TrackerSanitize.title("  ") == nil)
    #expect(TrackerSanitize.title(nil) == nil)
}

@Test func chromiumReplies() {
    let ok = TrackerBrowser.observation(bundleId: "com.google.Chrome", appName: "Chrome", axTitle: "w",
                                        scriptReply: "https://a.com/p?q=1\nTab title")
    #expect(ok == TrackerObservation(bundleId: "com.google.Chrome", appName: "Chrome",
                                     title: "Tab title", url: "https://a.com/p?q=1")) // engine strips the query
    let incognito = TrackerBrowser.observation(bundleId: "com.brave.Browser", appName: "Brave", axTitle: "w",
                                               scriptReply: "PRIVATE")
    #expect(incognito.isPrivate)
    // Automation denied/undetermined: incognito can't be ruled out → AX title not trusted.
    let unknown = TrackerBrowser.observation(bundleId: "com.google.Chrome", appName: "Chrome", axTitle: "Secret",
                                             scriptReply: nil)
    #expect(unknown.isPrivate)
    let noWin = TrackerBrowser.observation(bundleId: "com.google.Chrome", appName: "Chrome", axTitle: nil,
                                           scriptReply: "NOWIN")
    #expect(noWin == TrackerObservation(bundleId: "com.google.Chrome", appName: "Chrome"))
}

@Test func safariArcAreOpaqueFirefoxDetectsByTitle() {
    #expect(TrackerBrowser.observation(bundleId: "com.apple.Safari", appName: "Safari", axTitle: "x",
                                       scriptReply: nil).isPrivate)
    #expect(TrackerBrowser.observation(bundleId: "company.thebrowser.Browser", appName: "Arc", axTitle: "x",
                                       scriptReply: nil).isPrivate)
    #expect(TrackerBrowser.observation(bundleId: "org.mozilla.firefox", appName: "Firefox",
                                       axTitle: "Page — Mozilla Firefox Private Browsing", scriptReply: nil).isPrivate)
    #expect(!TrackerBrowser.observation(bundleId: "org.mozilla.firefox", appName: "Firefox",
                                        axTitle: "Page — Mozilla Firefox", scriptReply: nil).isPrivate)
    #expect(TrackerBrowser.observation(bundleId: "com.apple.TextEdit", appName: "TextEdit", axTitle: "Doc",
                                       scriptReply: nil) == TrackerObservation(bundleId: "com.apple.TextEdit",
                                                                               appName: "TextEdit", title: "Doc"))
}
