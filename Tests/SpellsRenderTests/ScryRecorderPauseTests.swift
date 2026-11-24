import Foundation
import Synchronization
import Testing
@testable import Scry

/// Paused: both sides are silence in the file and on the live sockets, and the time still runs.
@Test func pausedAudioIsWrittenAsSilence() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "scry-pause-\(UUID().uuidString)/a.wav")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let r = try ScryRecorder(audio: url)
    let live = Mutex([Data]())
    r.feed(mic: { d in live.withLock { $0.append(d) } }, system: nil)
    let loud = [Int16](repeating: 9000, count: 1600)
    for paused in [false, true, false] {
        r.paused = paused
        #expect(r.paused == paused)   // waits for the queue
        r.append(loud, system: false)
    }
    #expect(r.stop().frames == 4800)
    let wav = try Data(contentsOf: url).dropFirst(44)
    let mic = stride(from: wav.startIndex, to: wav.endIndex, by: 4).map { Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8) }
    #expect(mic[..<1600].allSatisfy { $0 == 9000 } && mic[1600..<3200].allSatisfy { $0 == 0 } && mic[3200...].allSatisfy { $0 == 9000 })
    #expect(live.withLock { $0.map { $0.contains { $0 != 0 } } } == [true, false, true])
}
