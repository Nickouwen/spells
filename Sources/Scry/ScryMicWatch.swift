import AppKit
import CoreAudio
import ScryCore

/// CoreAudio's per-process objects: who is recording from an input right now.
enum ScryAudioProcesses {
    struct MicUser { var pid: pid_t; var bundleID: String; var callApp: String? }

    /// Processes with `IsRunningInput` == 1, bundle IDs resolved (empty → `NSRunningApplication`), mapped to
    /// call apps through `ScryCallApps.owner`. This process is left out.
    static func micUsers() -> [MicUser] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))   // Safari ↔ WebKit
        return objects().compactMap { obj in
            guard prop(obj, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0 else { return nil }
            let pid = prop(obj, kAudioProcessPropertyPID, pid_t(0))
            guard pid != getpid() else { return nil }
            var id = string(obj, kAudioProcessPropertyBundleID)
            if id.isEmpty { id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            return MicUser(pid: pid, bundleID: id, callApp: id.isEmpty ? nil : ScryCallApps.owner(ofBundleID: id, running: running))
        }
    }

    /// This process's CoreAudio object (to exclude it from the system tap).
    static func object(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid, obj = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    static func prop<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ def: T) -> T {
        var addr = address(sel), v = def, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : def
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
        var addr = address(sel), cf: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return "" }
        return s as String
    }

    private static func objects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Polls the mic users once a second on the main run loop and feeds `ScryDetector`; `onAction` gets
/// everything but `.none`. `recording` says what's being recorded right now.
@MainActor final class ScryMicWatch {
    var detector = ScryDetector()
    var recording: () -> ScryRecording = { .none }
    var onAction: (ScryDetectAction) -> Void = { _ in }
    /// Every poll: ms until a recorded call auto-stops (its app has let go of the mic), or nil.
    var onTick: (Int64?) -> Void = { _ in }
    /// The call app holding the mic at the last poll ("Record call" from the menu uses it).
    private(set) var callApp: String?
    private var timer: Timer?

    func start() {
        // ponytail: a 1 s poll (a few property reads) instead of per-process property listeners.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        callApp = ScryAudioProcesses.micUsers().lazy.compactMap(\.callApp).first
        let ms = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        let action = detector.update(callApp: callApp, recording: recording(), atMs: ms)
        if action != .none { onAction(action) }
        onTick(detector.stopsIn(atMs: ms))
    }
}
