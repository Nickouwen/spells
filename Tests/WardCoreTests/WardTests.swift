import Foundation
import Testing
@testable import WardCore

@Suite struct WardStatusTests {
    @Test func statusComesFromLaunchctlThePlistAndTheTools() {
        let out = "system/com.bluepeak.netcap = {\n\tactive count = 1\n\tpath = /Library/LaunchDaemons/com.bluepeak.netcap.plist\n\tstate = running\n\tpid = 10136\n"
        let s = WardStatus.parse(launchctl: out, plistExists: true, tools: true)
        #expect(s.daemon == .loaded(pid: 10136) && s.running && s.installed)
        #expect(s.title == "Capturing (pid 10136)")
        #expect(WardStatus.parse(launchctl: "state = waiting\n", plistExists: true, tools: true).daemon == .loaded(pid: nil))
        #expect(WardStatus.parse(launchctl: nil, plistExists: true, tools: true).daemon == .stopped)
        #expect(WardStatus.parse(launchctl: nil, plistExists: false, tools: false) == WardStatus(daemon: .notInstalled, toolsInstalled: false))
    }
}

@Suite struct WardSnapshotTests {
    @Test func theReportParsesIntoFactsTablesAndHits() {
        let report = """
        files\t20
        bytes\t1048576000
        first\t1762102800.5
        last\t2026-11-02 17:00:00.123456 PST
        window\tframe.time >= "2026-11-02 09:00:00"
        error\tcapinfos: no such file
        section\tdst
        120\t17.253.144.10
        3\t1.1.1.1
        bogus line
        section\tdns
        44\tapi.cerebras.ai
        section\tsni
        9\tapi.elevenlabs.io
        section\tioc
        2026-11-02 10:00:00\t10.0.0.5\t85.193.68.245

        """
        let s = WardSnapshot.parse(report, takenAt: Date(timeIntervalSince1970: 0))
        #expect(s.files == 20 && s.bytes == 1_048_576_000)
        #expect(s.first == Date(timeIntervalSince1970: 1762102800.5))
        #expect(s.last != nil && s.coverage != nil)
        #expect(s.window.hasPrefix("frame.time"))
        #expect(s.errors == ["capinfos: no such file"])
        #expect(s.destinations == [.init(count: 120, name: "17.253.144.10"), .init(count: 3, name: "1.1.1.1")])
        #expect(s.dns.first?.name == "api.cerebras.ai" && s.sni.first?.count == 9)
        #expect(s.iocHits.count == 1)
        #expect(WardSnapshot.parse("").destinations.isEmpty)
    }

    @Test func windowsMakeATsharkFilterAndACutoff() {
        let now = Date(timeIntervalSince1970: 1_762_140_000)
        let hour = WardWindow.hour.filter(now: now)
        #expect(hour.display.hasPrefix("frame.time >= \"") && hour.sinceEpoch == 1_762_140_000 - 3600)
        #expect(WardWindow.all.filter(now: now) == ("", 0))
        #expect(Ward.ringBytes == 1_048_576_000)
    }
}
