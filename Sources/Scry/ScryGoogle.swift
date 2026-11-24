import AppKit
import AuthenticationServices
import CryptoKit
import Observation
import os
import SpellsKit
import ScryCore

/// Google Calendar, read-only: "Sign in with Google" in your browser, the refresh token in the Keychain (only
/// there), your main calendar's events re-read every minute for the alarm and the invite matcher.
@MainActor @Observable final class ScryGoogle: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = ScryGoogle()
    private static let keychain = "scry-google-refresh-token"

    enum Failure: Error, CustomStringConvertible {
        case noClientID, cancelled, badReply, signedOut, http(Int)
        var description: String {
            switch self {
            case .noClientID: "Set the Google client ID first."
            case .cancelled: "Sign-in was cancelled."
            case .badReply: "Google sent an unexpected reply."
            case .signedOut: "Google signed Scry out. Connect again."
            case .http(let s): "Google answered HTTP \(s)."
            }
        }
    }

    private(set) var connected = SupportKeychain.read(keychain) != nil
    /// The address of the connected calendar, once it has been read.
    private(set) var account: String?
    private(set) var error: String?
    private(set) var busy = false
    @ObservationIgnored private(set) var events: [ScryCalendarEvent] = []
    @ObservationIgnored private var access: (token: String, until: Date)?
    @ObservationIgnored private var readAt = Date.distantPast
    @ObservationIgnored private var session: ASWebAuthenticationSession?

    func connect() async {
        busy = true
        defer { busy = false }
        do {
            let id = ScryApp.loadSettings().settings.googleClientID
            let verifier = ScryGoogleAuth.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))   // SystemRandomNumberGenerator
            let state = UUID().uuidString
            let challenge = ScryGoogleAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            guard let scheme = ScryGoogleAuth.scheme(id), let redirect = ScryGoogleAuth.redirect(id),
                  let url = ScryGoogleAuth.authURL(clientID: id, challenge: challenge, state: state) else { throw Failure.noClientID }
            let callback: URL = try await withCheckedThrowingContinuation { c in
                // Called off the main thread, and maybe as well as `start` returning false: resumed once.
                let done = OSAllocatedUnfairLock(initialState: false)
                let finish: @Sendable (URL?) -> Void = { url in
                    guard !done.withLock({ was in defer { was = true }; return was }) else { return }
                    c.resume(with: url.map { .success($0) } ?? .failure(Failure.cancelled))
                }
                let s = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { @Sendable url, _ in finish(url) }
                s.presentationContextProvider = self
                session = s
                if !s.start() { SupportLog.scry.error("google: the sign-in window didn't open"); finish(nil) }
            }
            session = nil
            guard let code = ScryGoogleAuth.code(in: callback, state: state) else { throw Failure.cancelled }
            let r = try await token(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                     "client_id": id, "redirect_uri": redirect])
            guard let refresh = r.refresh_token, SupportKeychain.write(Self.keychain, refresh, file: false) else { throw Failure.badReply }
            access = (r.access_token, Date().addingTimeInterval(r.expires_in - 60))
            connected = true
            SupportLog.scry.info("google: connected")
            await reload()
        } catch {
            session = nil
            report(error)
        }
    }

    /// Takes the grant back at Google and forgets it here.
    func disconnect() async {
        if let t = SupportKeychain.read(Self.keychain) {
            var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            r.httpMethod = "POST"
            r.httpBody = ScryGoogleAuth.form(["token": t])
            _ = try? await URLSession.shared.data(for: r)   // offline: still forgotten here
        }
        forget()
        error = nil
    }

    private func forget() {
        SupportKeychain.write(Self.keychain, "", file: false)
        (connected, account, access, events) = (false, nil, nil, [])
    }

    /// Re-reads the events at most once a minute. While Google can't be reached the last ones stay (12 hours ahead).
    func refreshIfDue() {
        guard connected, Date().timeIntervalSince(readAt) >= 60 else { return }
        readAt = Date()
        Task { await reload() }
    }

    private func reload() async {
        readAt = Date()
        do {
            var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
            let now = Date(), iso = ISO8601DateFormatter()
            c.queryItems = [.init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"),
                            .init(name: "maxResults", value: "250"),
                            .init(name: "timeMin", value: iso.string(from: now.addingTimeInterval(-4 * 3600))),
                            .init(name: "timeMax", value: iso.string(from: now.addingTimeInterval(12 * 3600)))]
            var r = URLRequest(url: c.url!, timeoutInterval: 20)
            r.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: r)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { access = nil }   // taken back early: a new one next time
            guard status == 200 else { throw Failure.http(status) }
            let read = try ScryCalendarEvent.google(data)
            guard connected else { return }   // disconnected meanwhile
            if account == nil { SupportLog.scry.info("google: \(read.events.count, privacy: .public) event(s) read") }
            (account, events) = (read.account, read.events)
            error = nil
        } catch { report(error) }
    }

    private struct Token: Decodable { var access_token: String, expires_in: Double, refresh_token: String? }

    private func accessToken() async throws -> String {
        if let a = access, a.until > Date() { return a.token }
        guard let t = SupportKeychain.read(Self.keychain) else { throw Failure.signedOut }
        let r = try await token(["grant_type": "refresh_token", "refresh_token": t, "client_id": ScryApp.loadSettings().settings.googleClientID])
        access = (r.access_token, Date().addingTimeInterval(r.expires_in - 60))
        return r.access_token
    }

    private func token(_ fields: [String: String]) async throws -> Token {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = ScryGoogleAuth.form(fields)
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct E: Decodable { var error: String }
            if (try? JSONDecoder().decode(E.self, from: data))?.error == "invalid_grant" { forget(); throw Failure.signedOut }
            throw Failure.http(status)
        }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    private func report(_ e: any Error) {
        let text = (e as? Failure)?.description ?? "Google Calendar can't be reached: \(e.localizedDescription)"
        if text != error { SupportLog.scry.error("google: \(text, privacy: .public)") }   // once, not every minute
        error = text
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor() }
    }
}
