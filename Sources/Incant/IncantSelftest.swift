import AVFoundation
import HoursCore
import IncantCore

/// `Incant --selftest <file.wav>`: streams a 16 kHz mono 16-bit recording at real-time pace through the
/// same socket and correction a dictation uses, then prints the texts and timings. No UI, key tap or
/// paste. Printing the text is the point here; the app never logs it.
enum IncantSelftest {
    static func run(_ path: String) async -> Int32 {
        guard let key = SupportKeychain.read(SupportKeychain.elevenLabs) else {
            print("no \(SupportKeychain.elevenLabs) in the Keychain"); return 1
        }
        guard let pcm = pcm(path) else { print("usage: Incant --selftest <16 kHz mono 16-bit WAV>"); return 1 }
        let settings = IncantSession.loadSettings()
        let fix = IncantFixClients(settings: settings)   // made and warmed at start, as at Fn-down
        let socket = IncantScribeSocket(apiKey: key, keyterms: settings.keyterms)

        var chunks = stride(from: 0, to: pcm.count, by: 3200).map { pcm.subdata(in: $0..<min($0 + 3200, pcm.count)) }
        let last = chunks.popLast() ?? Data()
        for chunk in chunks {
            try? await Task.sleep(for: .milliseconds(100))
            socket.send(chunk)
        }
        try? await Task.sleep(for: .milliseconds(100))
        let released = incantNowMs()
        let committed = await socket.finish(last)
        let commitMs = incantNowMs() - released
        let result = await fix.run(committed, settings: settings)
        print("""
            committed: \(committed)
            commit_ms: \(commitMs)
            fixed: \(result.text)
            source: \(result.source.rawValue)
            fix_ms: \(result.ms)
            total_ms: \(incantNowMs() - released)
            """)
        return committed.isEmpty ? 1 : 0
    }

    private static func pcm(_ path: String) -> Data? {
        guard let file = try? AVAudioFile(forReading: URL(filePath: path), commonFormat: .pcmFormatInt16, interleaved: true),
              file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return nil }
        return Data(bytes: buf.int16ChannelData![0], count: Int(buf.frameLength) * 2)
    }
}
