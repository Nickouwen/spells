import Foundation
import FoundationModels
import SpellsKit
import IncantCore

/// One dictation's correction clients, made (and warmed) at `.start`: Cerebras primary, on-device
/// FoundationModels fallback — or on-device alone when there's no Cerebras key.
struct IncantFixClients: Sendable {
    private struct Unavailable: Error {}
    private let primary: (@Sendable (String) async throws -> String)?
    private let fallback: (@Sendable (String) async throws -> String)?

    init(settings: IncantSettings) {
        guard settings.mode != .off else { primary = nil; fallback = nil; return }
        var cerebras: (@Sendable (String) async throws -> String)?
        if let key = SupportKeychain.read(SupportKeychain.cerebras) {
            // Open the TLS connection now, so the correction reuses it.
            var warm = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/models")!)
            warm.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            Task { _ = try? await URLSession.shared.data(for: warm) }
            let model = settings.model, prompt = settings.instructions
            cerebras = { text in
                let req = IncantCerebras.request(text: text, instructions: prompt, model: model, apiKey: key)
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    return try IncantCerebras.parse(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
                } catch {
                    SupportLog.incant.error("Cerebras pass failed: \(String(describing: error), privacy: .public)")
                    throw error
                }
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
