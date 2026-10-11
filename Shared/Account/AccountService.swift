// Sources/Account/AccountService.swift — Supabase Auth over plain URLSession.
//
// WHY NO supabase-swift SPM PACKAGE: this app has never once been compiled (Windows dev machine,
// no Swift/Xcode toolchain here — see repo convention). Adding a large dependency tree with its
// own Swift 6 concurrency surface is a risk this session cannot evaluate at all (we'd be trusting
// that package's actor/Sendable story compiles clean on a toolchain we can't run). We need exactly
// 5 endpoints (contract §2) — hand-rolling them with `URLSession`, matching the existing
// `GroqTranscriptionClient.swift`/`CloudParser.swift` pattern (struct/actor, injected session,
// typed error enum, no hardcoded secrets), keeps the risk surface to "did I call 5 URLs right"
// instead of "does a third-party package's whole concurrency model compile."
//
// specs/002-workflow-command-center/contracts/account-auth.md is the CHỐT design — every endpoint,
// header, and status code below matches it exactly.
import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Supabase Auth (GoTrue) + the two account-lifecycle edge functions (`subscription/status` is
/// `Entitlements`'s concern; `subscription/link` too — this file owns identity + session only,
/// plus `delete-account` since that's account lifecycle, not subscription state).
///
/// A plain `actor` (NOT `@MainActor`): all state here (`cachedSession`, `refreshTask`) is mutated
/// only through actor-isolated methods, and every method does real networking, which per this
/// task's constraints must stay off the main actor. `AppState` (a `@MainActor @Observable` type)
/// awaits into this actor and mirrors the bits of state its views need into its own `@Observable`
/// properties — see `AppState`'s "Account & Entitlements" section.
actor AccountService {
    /// `nonisolated` is spelled out even though a plain (non-`@MainActor`) actor's `static let` is
    /// nonisolated by default — this repo has been bitten specifically by `@MainActor` TYPES'
    /// `static let`s inheriting that isolation (a different situation from this plain `actor`),
    /// so this is written explicitly rather than relying on a reader to remember the distinction.
    /// A single shared instance because the credential providers below (`ConfigParseCredentialProvider`,
    /// `EnvironmentGroqCredentialProvider` in `GroqTranscriptionClient.swift`) are constructed
    /// fresh, with no-argument inits, at call sites this task does not own (`AppState.swift`'s
    /// `router` default parameter is one; `GroqEngine.swift`'s default parameter — NOT an owned
    /// file — is another) — they all need to reach the SAME session state, so it can't be a
    /// per-instance dependency threaded through every one of those call sites.
    nonisolated static let shared = AccountService()

    private static let baseURL = URL(string: "https://cjaamylayaylbuuhwlnz.supabase.co")!
    /// Publishable key, contract §2 — NOT a secret (same reasoning as
    /// `ConfigParseCredentialProvider.defaultBaseURL`'s doc comment: every client of a Supabase
    /// project embeds its project's public anon/publishable key; only the service-role key is
    /// secret, and that never leaves the server). Required as the `apikey` header on every GoTrue
    /// call (contract §2: "mọi request kèm header apikey").
    private static let apiKey = "sb_publishable_WkBa-2lGcl10NBf8JrCfJA__FPNjjf0"

    private let session: URLSession
    private var cachedSession: AccountSession?
    /// Serializes concurrent `validAccessToken()` refreshes into ONE in-flight request — see that
    /// method's doc comment for the exact serialization argument.
    private var refreshTask: Task<String, Error>?

    init(session: URLSession = .shared) {
        self.session = session
        self.cachedSession = KeychainStore.loadSession()
    }

    // MARK: - Observable-ish state (read by `AppState` to mirror into its own `@Observable` props)

    var isSignedIn: Bool { cachedSession != nil }
    var currentEmail: String? { cachedSession?.user.email }
    var currentUserID: String? { cachedSession?.user.id }

    // MARK: - Email OTP

    func sendEmailOTP(email: String) async throws {
        _ = try await authRequest(path: "auth/v1/otp", body: ["email": email, "create_user": true])
    }

    func verifyEmailOTP(email: String, code: String) async throws -> AccountUser {
        let data = try await authRequest(path: "auth/v1/verify", body: ["email": email, "token": code, "type": "email"])
        let session = try Self.decodeSession(data)
        return store(session)
    }

    // MARK: - Refresh

    /// Returns a valid access token, transparently refreshing when within ~60s of expiry (or
    /// already expired). Returns `nil` — never throws — when there's simply no session at all
    /// (signed out); DOES throw if a session exists but the refresh attempt itself fails, so
    /// callers that need to distinguish "never signed in" from "session died" can (the credential
    /// providers in `ConfigParseCredentialProvider`/`GroqTranscriptionClient` swallow either case
    /// to "no credential" via `try?`, per their own contract).
    ///
    /// Concurrency: serializes concurrent callers onto ONE in-flight refresh `Task`, stored in
    /// `refreshTask`. This works BECAUSE actor isolation means the synchronous "is a refresh
    /// already running?" check-and-set below runs atomically up to the first `await` — a second
    /// caller's call to this same actor method can only start running once the first caller has
    /// already reached (and thus already executed) its own check-and-set, so the second caller
    /// always observes `refreshTask` either still nil (and starts the one real task) or already
    /// set (and just awaits that same task's `.value`) — ten simultaneous callers (e.g. a parse
    /// request and a Groq request firing at once) can never race into ten separate refreshes.
    func validAccessToken() async throws -> String? {
        guard let current = cachedSession else { return nil }
        if current.expiresAtDate.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let refreshToken = current.refreshToken
        let task = Task<String, Error> {
            try await self.performRefresh(refreshToken: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// On 400/401 (contract §2's refresh endpoint failing means the refresh token itself is dead)
    /// — clear the Keychain and drop the cached session so the app falls back to signed-out
    /// instead of retrying the same dead refresh token forever. Any other failure (network,
    /// decode) is NOT treated as "sign out"; it's transient and the next call may succeed.
    private func performRefresh(refreshToken: String) async throws -> String {
        do {
            let session = try await tokenRequest(query: "grant_type=refresh_token", body: ["refresh_token": refreshToken])
            _ = store(session)
            return session.accessToken
        } catch let error as AccountError {
            if case .http(let status, _) = error, status == 400 || status == 401 {
                cachedSession = nil
                KeychainStore.clearSession()
            }
            throw error
        }
    }

    // MARK: - Sign out / delete

    /// Best-effort server-side logout (contract §2), then ALWAYS clears local state regardless of
    /// whether the network call succeeded — a signed-out UI state must never depend on the logout
    /// request actually reaching the server (e.g. offline sign-out must still work locally).
    func signOut() async {
        if let token = cachedSession?.accessToken {
            _ = try? await authRequest(path: "auth/v1/logout", body: [:], bearer: token)
        }
        cachedSession = nil
        KeychainStore.clearSession()
    }

    /// Contract §3 `POST /functions/v1/subscription/delete-account` — Apple Guideline 5.1.1(v).
    /// Clears local state ONLY after the server confirms deletion (unlike `signOut()` above,
    /// which clears regardless) — a failed delete-account call must leave the user's session
    /// intact so they can retry, not silently sign them out of an account that still exists.
    func deleteAccount() async throws {
        guard let token = try await validAccessToken() else { throw AccountError.signedOut }
        _ = try await functionsRequest(path: "functions/v1/subscription/delete-account", body: [:], bearer: token)
        cachedSession = nil
        KeychainStore.clearSession()
    }

    // MARK: - Promo code redemption

    /// `POST /functions/v1/subscription/redeem` (backlog: "1 free month of Pro" promo codes — ONE
    /// code string shared by many people, each may redeem it exactly once). Requires an account
    /// (same `validAccessToken()` gate as `deleteAccount()` above) — redemption is meaningless
    /// without a signed-in identity to attach the grant to, so a `nil` token throws `.signedOut`
    /// rather than silently no-op'ing.
    ///
    /// Normalization happens in `normalizeCode(_:)` below and ONLY there — callers
    /// (`AppState.redeemPromoCode`) pass through whatever the user typed untouched, so there is
    /// exactly one seam in the whole client that could ever drift from the server's own
    /// normalization instead of two call sites that could quietly disagree.
    func redeemPromoCode(_ code: String) async throws -> RedeemResult {
        guard let token = try await validAccessToken() else { throw AccountError.signedOut }
        let normalized = Self.normalizeCode(code)
        let data = try await functionsRequest(
            path: "functions/v1/subscription/redeem",
            body: ["code": normalized],
            bearer: token,
            errorMapper: Self.mapRedeemError
        )
        guard let result = try? JSONDecoder().decode(RedeemResult.self, from: data) else {
            throw AccountError.decoding
        }
        return result
    }

    /// The ONE place client-side code normalization happens: trim surrounding whitespace/newlines
    /// (a pasted code very plausibly carries them — e.g. copied from an email/Slack message with a
    /// trailing newline) then uppercase, because the server stores/matches codes uppercase (this
    /// comment is the other half of that agreement — if the server's normalization rule ever
    /// changes, this is the one line that needs to change to match it).
    ///
    /// `nonisolated static` (not `private`, unlike most of this actor's internals) specifically so
    /// this ONE pure transformation is reachable — and tested — without any networking or actor
    /// isolation involved, mirroring `AppState.applyTextCaptureParseResult`'s own precedent
    /// (`AppState.swift`) of loosening a method's access specifically so a test can drive it
    /// directly instead of only being reachable through a real, network-bound call.
    nonisolated static func normalizeCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: - Networking helpers

    private func tokenRequest(query: String, body: [String: Any]) async throws -> AccountSession {
        let (status, data) = try await send(path: "auth/v1/token", query: query, body: body)
        guard (200..<300).contains(status) else { throw Self.mapError(status: status, data: data) }
        return try Self.decodeSession(data)
    }

    /// GoTrue endpoints (contract §2) — always send `apikey` (default `includeApiKey: true`).
    private func authRequest(path: String, body: [String: Any], bearer: String? = nil) async throws -> Data {
        let (status, data) = try await send(path: path, body: body, bearer: bearer)
        guard (200..<300).contains(status) else { throw Self.mapError(status: status, data: data) }
        return data
    }

    /// Edge functions (contract §3) authenticate purely via `Authorization: Bearer <access_token>`
    /// — no `apikey` header, matching the existing `CloudParser`/`GroqTranscriptionClient`
    /// convention of sending Authorization only (config.toml's `verify_jwt = false`, see contract
    /// §7 — the function verifies the account token itself via `auth.getUser()`).
    ///
    /// `errorMapper` defaults to the shared `Self.mapError` — every existing call site (`redeem`
    /// is the only exception, see `redeemPromoCode` below) gets the exact same opaque `.http(status:
    /// code:)` mapping it always has. This is a deliberate seam rather than a second networking
    /// path: `redeemPromoCode`'s contract hands back SPECIFIC, user-presentable meanings for 404/
    /// 409/410/429 (see `AccountError`'s doc comments on those cases) that only apply to THAT one
    /// endpoint — folding that switch into the shared `mapError` would make every OTHER edge
    /// function on this actor (e.g. `deleteAccount`) misreport an unrelated 404/409 as a promo-code
    /// failure. Passing a mapper keeps the single 2xx-check-then-throw shape shared by every caller
    /// while letting the meaning of a non-2xx stay endpoint-specific.
    private func functionsRequest(
        path: String,
        body: [String: Any],
        bearer: String,
        errorMapper: (Int, Data) -> AccountError = AccountService.mapError
    ) async throws -> Data {
        let (status, data) = try await send(path: path, body: body, bearer: bearer, includeApiKey: false)
        guard (200..<300).contains(status) else { throw errorMapper(status, data) }
        return data
    }

    private func send(
        path: String,
        query: String? = nil,
        body: [String: Any],
        bearer: String? = nil,
        includeApiKey: Bool = true
    ) async throws -> (status: Int, data: Data) {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if let query { components?.percentEncodedQuery = query }
        guard let url = components?.url else { throw AccountError.network("Couldn't build request URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if includeApiKey { request.setValue(Self.apiKey, forHTTPHeaderField: "apikey") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { throw AccountError.decoding }
        request.httpBody = httpBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Never log `error.localizedDescription` here — on some platforms transport errors
            // can echo request details, and this subsystem's privacy contract (never log tokens/
            // email) errs on the side of logging nothing at the network-failure boundary either.
            throw AccountError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AccountError.network("Non-HTTP response") }
        return (http.statusCode, data)
    }

    private static func decodeSession(_ data: Data) throws -> AccountSession {
        guard let session = try? JSONDecoder().decode(AccountSession.self, from: data) else {
            throw AccountError.decoding
        }
        return session
    }

    private static func mapError(status: Int, data: Data) -> AccountError {
        let body = try? JSONDecoder().decode(AccountErrorBody.self, from: data)
        return .http(status: status, code: body?.error)
    }

    /// `redeemPromoCode`'s `errorMapper` — the documented contract (see `POST subscription/redeem`
    /// in this feature's contract doc) has FOUR statuses with a specific, distinct meaning worth
    /// surfacing to the user; everything else (400 malformed, 401 dead session, 503, or any status
    /// this contract didn't document) falls through to the same opaque `.http` shape every other
    /// endpoint on this actor already uses via `mapError` — deliberately NOT invented a second
    /// fallback shape just for this one endpoint.
    ///
    /// `static` (not `private`, same reasoning as `normalizeCode` above) so this pure status ->
    /// `AccountError` mapping is directly testable with no networking.
    static func mapRedeemError(status: Int, data: Data) -> AccountError {
        switch status {
        case 404: return .promoCodeInvalid
        case 409: return .promoCodeAlreadyRedeemed
        case 410: return .promoCodeExhausted
        case 429: return .promoCodeTooManyAttempts
        default: return mapError(status: status, data: data)
        }
    }

    /// Test seam (`SharedTests/SyncIntegrationTests.swift`, 2026-10-11): adopts a session obtained
    /// out-of-band (CI does a password grant with a dedicated Pro test user) so the REAL sync
    /// stack — `SyncClient` → `validAccessToken()` → `sync_exchange` — runs against production
    /// inside the test process. Internal, not private, for `@testable import` only; no app code
    /// calls it. Same effect as `verifyEmailOTP` succeeding.
    func adoptSession(_ session: AccountSession) {
        store(session)
    }

    @discardableResult
    private func store(_ session: AccountSession) -> AccountUser {
        cachedSession = session
        KeychainStore.saveSession(session)
        return session.user
    }
}
