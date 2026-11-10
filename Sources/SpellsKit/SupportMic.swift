import AVFoundation
import CoreAudio

/// The mic as 16 kHz mono s16le, for Incant and Scry. Records the default input, but the built-in mic
/// when the default input is a Bluetooth headset: opening a headset's mic flips it into its call profile
/// (16 kHz mono both ways), which spoils its sound and Scry's capture of the call.
///
/// AVCaptureSession on one named device, not AVAudioEngine: the engine always opens the default input,
/// and pointing it at another device (kAudioOutputUnitProperty_CurrentDevice) loops on its
/// configuration-change notifications. The session only opens the device it's given.
public final class SupportMic: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public struct NoInput: Error {}

    /// Each buffer's samples, on the mic's own queue. Set before `start`.
    public var onPCM: (@Sendable ([Int16]) -> Void)?
    public private(set) var deviceName = ""

    private let session = AVCaptureSession(), output = AVCaptureAudioDataOutput()
    private let q = DispatchQueue(label: "dev.nic.spells.mic")
    private var input: AVCaptureDeviceInput?
    private var listener: AudioObjectPropertyListenerBlock?
    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    public override init() {
        super.init()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
                                AVLinearPCMIsBigEndianKey: false]
        output.setSampleBufferDelegate(self, queue: q)
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    /// Points the session at the mic to use now. Does nothing when it already uses that mic.
    public func select() throws {
        let uid = Self.uniqueID()
        if let input, input.device.uniqueID == uid { return }
        guard let device = AVCaptureDevice(uniqueID: uid) ?? AVCaptureDevice.default(for: .audio) else { throw NoInput() }
        let new = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input { session.removeInput(input) }
        guard session.canAddInput(new) else { input = nil; throw NoInput() }
        session.addInput(new)
        input = new; deviceName = device.localizedName
    }

    /// Starts capture, and follows default-input changes (AirPods in or out) until `stop`.
    public func start() throws {
        try select()
        session.startRunning()
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            do { try self?.select() } catch { SupportLog.app.error("mic switch failed: \(error.localizedDescription, privacy: .public)") }
        }
        var addr = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        listener = block
    }

    /// Stops capture. Buffers already delivered have reached `onPCM` when this returns.
    public func stop() {
        session.stopRunning()
        if let listener {
            var addr = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }
        listener = nil
        q.sync {}
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let data = CMSampleBufferGetDataBuffer(sb) else { return }
        var pcm = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(data) / 2)
        guard !pcm.isEmpty, CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: pcm.count * 2, destination: &pcm) == noErr else { return }
        onPCM?(pcm)
    }

    /// The UID of the mic to record: the default input, or the built-in mic when that's a Bluetooth headset.
    static func uniqueID() -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var input = AudioDeviceID(0)
        _ = get(system, kAudioHardwarePropertyDefaultInputDevice, &input)
        if [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(input)),
           let builtIn = devices().first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }) {
            input = builtIn
        }
        var uid: Unmanaged<CFString>?
        guard get(input, kAudioDevicePropertyDeviceUID, &uid), let s = uid?.takeRetainedValue() else { return "" }
        return s as String
    }

    private static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var t = UInt32(0); _ = get(id, kAudioDevicePropertyTransportType, &t); return t
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func devices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
