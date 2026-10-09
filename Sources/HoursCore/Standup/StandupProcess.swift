import Foundation

/// Runs a child process with stdin from data, stdout/stderr captured, and a hard timeout.
/// stdout/stderr go through temp files rather than pipes, so a 250 KB dump can't deadlock a full
/// pipe buffer and no reader threads are needed. The files live in the per-user `$TMPDIR` and are
/// removed before returning.
public enum StandupProcess {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        public var stderrText: String { String(decoding: stderr.suffix(4000), as: UTF8.self) }
    }

    public struct TimedOut: Error, CustomStringConvertible {
        public var seconds: Int
        public var stderr: String
        public var description: String { "timed out after \(seconds) s" + (stderr.isEmpty ? "" : "; stderr: \(stderr)") }
    }

    /// launchd's PATH (app / helper) is /usr/bin:/bin:… — the dump script needs jq, claude may need node.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        return env
    }

    public static func run(_ executable: URL, _ args: [String], stdin: Data? = nil, timeout: TimeInterval) throws -> Result {
        let tmp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let outURL = tmp.appending(path: "hours-standup-\(id).out"), errURL = tmp.appending(path: "hours-standup-\(id).err")
        let inURL = tmp.appending(path: "hours-standup-\(id).in")
        defer { for u in [outURL, errURL, inURL] { try? FileManager.default.removeItem(at: u) } }
        for u in [outURL, errURL] { FileManager.default.createFile(atPath: u.path, contents: nil, attributes: [.posixPermissions: 0o600]) }

        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.environment = environment()
        p.currentDirectoryURL = tmp
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            FileManager.default.createFile(atPath: inURL.path, contents: stdin, attributes: [.posixPermissions: 0o600])
            p.standardInput = try FileHandle(forReadingFrom: inURL)
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
            throw TimedOut(seconds: Int(timeout), stderr: String(decoding: ((try? Data(contentsOf: errURL)) ?? Data()).suffix(2000), as: UTF8.self))
        }
        return Result(status: p.terminationStatus, stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL))
    }
}
