import Testing
@testable import HoursCore

@Suite struct ClassifyURLTests {
    @Test func hostNormalises() {
        #expect(ClassifyURL.host("https://WWW.GitHub.com/acme/x") == "github.com")
        #expect(ClassifyURL.host("http://localhost:3000/a") == "localhost")
        #expect(ClassifyURL.host("gist.github.com/abc") == "gist.github.com")
        #expect(ClassifyURL.host(nil) == nil)
        #expect(ClassifyURL.host("") == nil)
    }

    @Test func pathDefaultsToSlash() {
        #expect(ClassifyURL.path("https://zoom.us/wc/123/join") == "/wc/123/join")
        #expect(ClassifyURL.path("https://github.com") == "/")
    }

    @Test func suffixMatchIsLabelBounded() {
        #expect(ClassifyURL.hostMatches("github.com", "github.com"))
        #expect(ClassifyURL.hostMatches("github.com", "gist.github.com"))
        #expect(!ClassifyURL.hostMatches("github.com", "notgithub.com"))
        #expect(ClassifyURL.hostMatches("x.com", "x.com"))
        #expect(!ClassifyURL.hostMatches("x.com", "box.com"))
        #expect(!ClassifyURL.hostMatches("gist.github.com", "github.com"))
    }

    @Test func suffixesForIndexProbe() {
        #expect(ClassifyURL.suffixes("a.b.github.com") == ["a.b.github.com", "b.github.com", "github.com", "com"])
        #expect(ClassifyURL.suffixes("localhost") == ["localhost"])
    }
}
