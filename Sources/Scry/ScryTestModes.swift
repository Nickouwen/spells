import AppKit
import AVFoundation
import ScryCore

/// `Scry --mic-users` and `Scry --test-capture <seconds> <dir>`: no UI, no single-instance lock.
enum ScryTestModes {
    static func micUsers() -> Int32 {
        let users = ScryAudioProcesses.micUsers()
        if users.isEmpty { print("no process is using an audio input") }
        for u in users {
            var name = u.bundleID
            if name.isEmpty {   // a CLI: no bundle ID, so show its process name
                var buf = [UInt8](repeating: 0, count: 256)
                let n = proc_name(u.pid, &buf, UInt32(buf.count))
                name = String(decoding: buf.prefix(Int(max(n, 0))), as: UTF8.self)
            }
            print("pid \(u.pid)\t\(name)\t\(u.callApp.map { "\($0) (\(ScryCallApps.known[$0] ?? $0))" } ?? "-")")
        }
        return 0
    }

    /// Records tap + mic into `<dir>/audio.wav` (+ capture.json), prints per-channel RMS and sample counts.
    /// 0 = recorded; 2 = a permission is missing (named); 1 = anything else.
    static func testCapture(seconds: Double, dir: String) async -> Int32 {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined where await AVCaptureDevice.requestAccess(for: .audio): break
        default:
            print("denied: Microphone (System Settings → Privacy & Security → Microphone)")
            return 2
        }
        let url = URL(filePath: dir, directoryHint: .isDirectory)
        let recorder: ScryRecorder
        do { recorder = try ScryRecorder(audio: url.appending(path: "audio.wav")) } catch {
            print("can't write \(dir): \(error.localizedDescription)"); return 1
        }
        do { try recorder.startMic() } catch {
            _ = recorder.stop()
            print("denied: Microphone — the input wouldn't start (\(error.localizedDescription))"); return 2
        }
        // Creating the tap blocks while its permission prompt is unanswered: give up after 10 s.
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(10))
            print("denied: Screen & System Audio Recording — the tap is still waiting on its permission prompt after 10 s")
            exit(2)
        }
        do { try recorder.startSystem() } catch {
            watchdog.cancel()
            _ = recorder.stop()
            print("denied: Screen & System Audio Recording — the system-audio tap failed: \(error)"); return 2
        }
        watchdog.cancel()
        let started = Date()
        try? await Task.sleep(for: .seconds(seconds))
        let stats = recorder.stop()
        let capture = ScryCapture(audioFile: "audio.wav", startedAt: started, endedAt: Date(), app: nil, screenshotText: [], userNotes: "")
        do { try capture.encoded().write(to: url.appending(path: "capture.json")) } catch {
            print("can't write capture.json: \(error.localizedDescription)"); return 1
        }
        print(String(format: "ch0 mic:    %7d samples in, RMS %.5f", stats.micSamples, stats.micRMS))
        print(String(format: "ch1 system: %7d samples in, RMS %.5f", stats.systemSamples, stats.systemRMS))
        print("wav: \(stats.frames) frames (\(String(format: "%.2f", Double(stats.frames) / 16000)) s, 2 ch, 16 kHz)")
        // ponytail: there's no public preflight for the audio-capture grant; a denied tap delivers digital
        // silence. Exact zeros on ch 1 without the Screen Recording grant (which implies audio) = denied.
        if stats.systemAllZero && !CGPreflightScreenCaptureAccess() {
            print("denied: Screen & System Audio Recording — ch 1 was digital silence (or nothing played)")
            return 2
        }
        return 0
    }
}
