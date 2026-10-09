import Foundation
import Testing
@testable import TrackerCore

/// Review-1 #9: the browser AppleScript (up to 2 s) runs off the main thread; the reply comes back on main.
@Test @MainActor func browserScriptRunsOffTheMainThread() async {
    let runner = TrackerScriptRunner { _, _ in Thread.isMainThread ? "main" : "background" }
    let (reply, onMain) = await withCheckedContinuation { (c: CheckedContinuation<(String?, Bool), Never>) in
        runner.run("com.google.Chrome", ask: false) { reply in c.resume(returning: (reply, Thread.isMainThread)) }
    }
    #expect(reply == "background")
    #expect(onMain)
}
