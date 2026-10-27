import Foundation
import Testing
@testable import SpellsKit

@Suite struct ModuleCatalogTests {
    @Test func decodesAndCompares() throws {
        let json = """
        {"modules":[{"bundleID":"dev.nic.spells.incant","name":"Incant","summary":"Dictation","symbol":"waveform","scheme":"incant",
                     "loginItem":true,"version":"0.2.0","url":"https://example.com/Incant-0.2.0.zip","sha256":"ab"}],
         "launcher":{"bundleID":"dev.nic.spells.launcher","name":"Spells","summary":"","symbol":"book","scheme":"spells",
                     "loginItem":false,"version":"0.3.0","url":"https://example.com/Spells-0.3.0.zip","sha256":"cd"}}
        """
        let c = try ModuleCatalog.decode(Data(json.utf8))
        #expect(c.modules.count == 1 && c.modules[0].name == "Incant" && c.modules[0].loginItem && c.modules[0].id == "dev.nic.spells.incant")
        #expect(c.entry(for: "dev.nic.spells.launcher")?.version == "0.3.0" && c.entry(for: "dev.nic.spells.incant")?.name == "Incant"
                && c.entry(for: "dev.nic.spells") == nil)
        #expect(try ModuleCatalog.decode(Data(#"{"modules":[]}"#.utf8)).launcher == nil)
        #expect(ModuleCatalog.isNewer("0.2.0", than: "0.1.9") && ModuleCatalog.isNewer("0.10", than: "0.9.1") && ModuleCatalog.isNewer("1", than: "0.99"))
        #expect(!ModuleCatalog.isNewer("1.2", than: "1.2.0") && !ModuleCatalog.isNewer("1.2.0", than: "1.2") && !ModuleCatalog.isNewer("", than: "0.1"))
        #expect(!ModuleCatalog.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func urlOverride() {
        #expect(ModuleCatalog.url([:]) == ModuleCatalog.defaultURL)
        #expect(ModuleCatalog.url([ModuleCatalog.urlKey: " "]) == ModuleCatalog.defaultURL)
        #expect(ModuleCatalog.url([ModuleCatalog.urlKey: "file:///tmp/catalog.json"]) == URL(string: "file:///tmp/catalog.json"))
    }
}
