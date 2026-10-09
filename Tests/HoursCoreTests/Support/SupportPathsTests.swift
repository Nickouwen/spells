import Foundation
import Testing
@testable import HoursCore

@Suite struct SupportPathsTests {
    @Test func hoursHomeRelocatesEverything() {
        let p = SupportPaths.current(environment: ["SPELLS_HOME": "/tmp/hours-dev"])
        #expect(p.home.path == "/tmp/hours-dev")
        #expect(p.db.path == "/tmp/hours-dev/hours.db")
        #expect(p.backups.path == "/tmp/hours-dev/backups")
        #expect(p.exports.path == "/tmp/hours-dev/exports")
        #expect(p.logs.path == "/tmp/hours-dev/logs")
    }

    @Test func defaultsToLibraryDirs() {
        let p = SupportPaths.current(environment: [:])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(p.home.path == home + "/Library/Application Support/Spells")
        #expect(p.db.path == home + "/Library/Application Support/Spells/hours.db")
        #expect(p.backups.path == home + "/Library/Application Support/Spells/backups")
        #expect(p.logs.path == home + "/Library/Logs/Spells")
    }

    @Test func emptyHoursHomeIsIgnored() {
        #expect(SupportPaths.current(environment: ["SPELLS_HOME": ""]) == SupportPaths.current(environment: [:]))
    }

    @Test func createDirectoriesUnderTempHome() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hours-paths-\(UUID().uuidString)")
        let p = SupportPaths.current(environment: ["SPELLS_HOME": tmp.path])
        try p.createDirectories()
        for dir in [p.home, p.backups, p.exports, p.logs] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        }
        try FileManager.default.removeItem(at: tmp)
    }
}
