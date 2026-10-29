import Foundation
import SpellsKit
import ScryCore

/// Polls the Google Meet tab in a Chromium browser twice a second while a recording runs and appends what it
/// sees to `<dir>/speakers.jsonl` (`ScryMeet.Line`). Needs the browser's View ▸ Developer ▸ "Allow JavaScript
/// from Apple Events" (off: every poll returns nothing, logged once) and the Automation grant for the browser
/// (the first poll prompts). Runs on its own serial queue; nothing here touches the main thread.
public final class ScryMeetWatch: @unchecked Sendable {
    /// Browsers whose AppleScript dictionary has `execute … javascript`.
    public static let browsers: Set<String> = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser"]

    private let queue = DispatchQueue(label: "dev.nic.spells.scry.meet", qos: .utility)
    private let script: NSAppleScript
    private let startedAt: Date, out: URL
    private var timer: DispatchSourceTimer?
    private var marker = ScryMeet.Marker()
    private var lastParticipants: [String] = []
    private var empties = 0, warned = false
    /// The last sample's people, for the recording pill.
    public private(set) var participants: [String] = []
    public private(set) var speaking: String?

    public init(browser bundleID: String, dir: URL, startedAt: Date) {
        script = NSAppleScript(source: Self.appleScript(bundleID))!
        self.startedAt = startedAt
        out = dir.appending(path: "speakers.jsonl")
    }

    /// The whole-browser script: the first tab on a Meet call (any window, foreground or not) runs `ScryMeet.script`.
    public static func appleScript(_ bundleID: String) -> String {
        let js = ScryMeet.script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        with timeout of 3 seconds
          tell application id "\(bundleID)"
            repeat with w in windows
              repeat with t in tabs of w
                if URL of t starts with "https://meet.google.com/" then
                  return execute t javascript "\(js)"
                end if
              end repeat
            end repeat
            return ""
          end tell
        end timeout
        """
    }

    public func start(every interval: TimeInterval = 0.5) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
    }

    /// One poll, synchronously (for `spellsctl scry meet`): the sample and who it says is speaking.
    public func peek() -> (sample: ScryMeet.Sample, speaking: ScryMeet.Tile?, marker: String?)? {
        queue.sync {
            guard let s = read() else { return nil }
            let tile = marker.speaking(s)
            return (s, tile, marker.current)
        }
    }

    private func read() -> ScryMeet.Sample? {
        var error: NSDictionary?
        let reply = script.executeAndReturnError(&error)
        if let error {
            if !warned {
                warned = true
                SupportLog.scry.error("Meet speakers: AppleScript failed: \(String(describing: error[NSAppleScript.errorMessage] ?? error), privacy: .public)")
            }
            return nil
        }
        guard let json = reply.stringValue, !json.isEmpty, let s = ScryMeet.sample(fromJSON: json) else {
            empties += 1
            if empties == 20, !warned {   // ~10 s of nothing: no Meet tab, or JavaScript from Apple Events is off
                warned = true
                SupportLog.scry.info("Meet speakers: nothing from the browser (no Meet tab, or View ▸ Developer ▸ Allow JavaScript from Apple Events is off)")
            }
            return nil
        }
        return s
    }

    private func poll() {
        guard let s = read() else { return }
        let t = (Date().timeIntervalSince(startedAt) * 10).rounded() / 10
        let people = s.participants
        var lines: [ScryMeet.Line] = []
        if people != lastParticipants {
            lastParticipants = people
            lines.append(ScryMeet.Line(t: t, participants: people))
        }
        let tile = marker.speaking(s)
        let name = tile.flatMap { $0.isSelf ? nil : $0.name }
        if let name { lines.append(ScryMeet.Line(t: t, speaking: name)) }
        participants = people; speaking = name
        guard !lines.isEmpty else { return }
        append(lines.map { $0.encoded + "\n" }.joined())
    }

    private func append(_ text: String) {
        if let h = try? FileHandle(forWritingTo: out) {
            defer { try? h.close() }
            try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: out)
        }
    }
}
