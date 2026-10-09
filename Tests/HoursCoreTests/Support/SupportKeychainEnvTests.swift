import Foundation
import Testing
@testable import HoursCore

@Suite struct SupportKeychainEnvTests {
    @Test func envFileParsesAndWritesBack() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "spells-env-\(UUID().uuidString)")
        try "# keys\nELEVENLABS_API_KEY=\"abc 123\"\n\nOTHER = x\nbroken line\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(SupportKeychain.envFile(url) == ["ELEVENLABS_API_KEY": "abc 123", "OTHER": "x"])
        SupportKeychain.writeFile(SupportKeychain.cerebras, " k2 ", url: url)
        SupportKeychain.writeFile(SupportKeychain.elevenLabs, "", url: url)   // empty removes
        #expect(SupportKeychain.envFile(url) == ["CEREBRAS_API_KEY": "k2", "OTHER": "x"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(SupportKeychain.envName("some-api-key") == "SOME_API_KEY")
    }
}
