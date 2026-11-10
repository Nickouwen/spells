import Foundation
import FoundationModels
import os
import SpellsKit
import IncantCore

/// One dictation's correction clients, made (and warmed) at `.start`: Cerebras primary, on-device
/// FoundationModels fallback — or on-device alone when there's no Cerebras key.
struct IncantFixClients: Sendable {
    private struct Unavailable: Error {}
    private let primary: (@Sendable (String) async throws -> String)?
    private let fallback: (@Sendable (String) async throws -> String)?
    /// Cerebras's pause pass: (the settled text's tail, the new words) → the joiner and the words cleaned.
    private let seamPass: (@Sendable (String, String) async throws -> (joiner: String, text: String))?

    init(settings: IncantSettings) {
        guard settings.mode != .off else { primary = nil; fallback = nil; seamPass = nil; return }
        var cerebras: (@Sendable (String) async throws -> String)?
        var seam: (@Sendable (String, String) async throws -> (joiner: String, text: String))?
        if let key = SupportKeychain.read(SupportKeychain.cerebras) {
            // Open the TLS connection now, so the correction reuses it.
            var warm = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/models")!)
            warm.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            Task { _ = try? await URLSession.shared.data(for: warm) }
            let model = settings.model, prompt = settings.instructions, seamPrompt = settings.seam.instructions
            @Sendable func send(_ req: URLRequest) async throws -> String {
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    return try IncantCerebras.parse(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
                } catch {
                    SupportLog.incant.error("Cerebras pass failed: \(String(describing: error), privacy: .public)")
                    throw error
                }
            }
            cerebras = { try await send(IncantCerebras.request(text: $0, instructions: prompt, model: model, apiKey: key)) }
            seam = { typed, text in
                try IncantCerebras.seam(await send(IncantCerebras.request(text: text, instructions: seamPrompt, model: model, apiKey: key, after: typed)))
            }
        }
        var onDevice: (@Sendable (String) async throws -> String)?
        if SystemLanguageModel.default.availability == .available {
            let session = LanguageModelSession(instructions: settings.instructions)
            session.prewarm()
            // IncantFix.run cancels its task at the cutoff; respond(to:) is cancellable, and a fallback
            // started after the cutoff never begins.
            onDevice = { text in
                try Task.checkCancellation()
                return try await session.respond(to: text, options: GenerationOptions(sampling: .greedy)).content
            }
        }
        primary = cerebras ?? onDevice
        fallback = cerebras == nil ? nil : onDevice
        seamPass = seam
    }

    /// Stream mode's pause pass: `raw` cleaned with the settled text's tail (`typed`) in view, and the joiner
    /// the model chose between them. The joiner is nil when Cerebras didn't answer (the on-device model sees
    /// the new words alone) or nothing is typed yet: then the plain rule decides (`IncantStream.joiner`).
    func seam(after typed: String, _ raw: String, settings: IncantSettings, cutoffMs: Int) async -> (result: IncantFixResult, lead: String?) {
        guard let seamPass, !typed.isEmpty else { return (await run(raw, settings: settings, cutoffMs: cutoffMs), nil) }
        let joiner = OSAllocatedUnfairLock<String?>(initialState: nil)
        let r = await IncantFix.run(raw, settings: settings, cutoffMs: cutoffMs, hedgeMs: 0, primary: { text in
            let answer = try await seamPass(typed, text)
            joiner.withLock { $0 = answer.joiner }
            return answer.text
        }, fallback: fallback)
        return (r, r.source == .primary ? joiner.withLock { $0 } : nil)
    }

    /// `cutoffMs`: past it the raw text stands. Stream mode's passes revise text that's already typed,
    /// so they can wait longer than the one paste on release.
    func run(_ text: String, settings: IncantSettings, cutoffMs: Int = 600) async -> IncantFixResult {
        // Hedge 0: on-device starts with Cerebras, so a slow Cerebras reply (seen up to 600+ ms on the
        // free tier) is covered by the ~400 ms local answer; Cerebras still wins when it's fast.
        await IncantFix.run(text, settings: settings, cutoffMs: cutoffMs, hedgeMs: 0,
                            primary: primary ?? { _ in throw Unavailable() }, fallback: fallback)
    }
}
