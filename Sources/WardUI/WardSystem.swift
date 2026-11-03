import AppKit
import SpellsKit
import WardCore

/// What Ward asks the system: the daemon's state (no root needed) and the scripts run as root through
/// macOS's administrator-password dialog (`do shell script … with administrator privileges`, via
/// osascript so the wait never blocks the app). Never logs the output: it names hosts.
public enum WardSystem {
    /// The bundled scripts: this app's own when it is Ward, else the installed Ward.app's (the hub).
    static var scriptsDir: URL {
        if let own = Bundle.main.resourceURL?.appending(path: "scripts"), FileManager.default.fileExists(atPath: own.appending(path: Ward.snapshotScript).path) {
            return own
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications/Spells/Ward.app/Contents/Resources/scripts", directoryHint: .isDirectory)
    }

    public static func status() async -> WardStatus {
        await Task.detached {
            let (out, code) = run("/bin/launchctl", ["print", "system/\(Ward.label)"])
            let fm = FileManager.default
            return WardStatus.parse(launchctl: code == 0 ? out : nil, plistExists: fm.fileExists(atPath: Ward.plistPath),
                                    tools: fm.isExecutableFile(atPath: Ward.dumpcap) && fm.isExecutableFile(atPath: Ward.tshark))
        }.value
    }

    struct Failure: LocalizedError {
        var message: String
        var cancelled: Bool { message.contains("User canceled") || message.contains("-128") }
        var errorDescription: String? { cancelled ? "Cancelled" : message }
    }

    /// `sudo bash <script> args…`, with the password asked by the system. Throws with osascript's
    /// message (cancelled, wrong password, the script's own failure).
    static func privileged(_ script: String, _ args: [String]) async throws -> String {
        let path = scriptsDir.appending(path: script).path
        guard FileManager.default.fileExists(atPath: path) else { throw Failure(message: "\(script) isn't in Ward's bundle (\(scriptsDir.path))") }
        let command = (["/bin/bash", path] + args).map(shellQuoted).joined(separator: " ")
        let source = "do shell script \"\(appleScriptQuoted(command))\" with administrator privileges"
        let (out, code, err) = await Task.detached { runWithStderr("/usr/bin/osascript", ["-e", source]) }.value
        guard code == 0 else { throw Failure(message: err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out
    }

    static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ tool: String, _ args: [String]) -> (String, Int32) {
        let (out, code, _) = runWithStderr(tool, args)
        return (out, code)
    }

    private static func runWithStderr(_ tool: String, _ args: [String]) -> (String, Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return ("", -1, error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: o, as: UTF8.self), p.terminationStatus, String(decoding: e, as: UTF8.self))
    }
}
