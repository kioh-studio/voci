// Sources/Parsing/ConfigParseCredentialProvider.swift — account-token-backed cloud-parse
// credentials.
//
// UPDATED (specs/002-workflow-command-center/contracts/account-auth.md, 2026-07-26): this used to
// read a hand-typed `volar.parseProxyToken` from UserDefaults as a placeholder for the real
// StoreKit-JWS/DeviceCheck composite (see this file's git history). The contract supersedes that
// design entirely: EVERY cloud request (parse AND Groq) now carries a single
// `Authorization: Bearer <supabase access_token>` regardless of tier — the server looks up
// `entitlements.tier` by `user_id`, not by which client-side auth shape was sent. Free vs Pro is no
// longer decided here at all for `/parse` (contract §1: free = 20/day, pro = 500/day, BOTH tiers
// call the exact same route, just with different daily limits) — only Groq is tier-gated
// client-side (see `GroqTranscriptionClient.swift`'s `EnvironmentGroqCredentialProvider`).
//
// `CloudParser`'s only auth shape is `.bearer(String)` -> `Authorization: Bearer <value>`.

// Base URL (unchanged): the Supabase project ref (`cjaamylayaylbuuhwlnz`) is fixed and checked
// into this file as `defaultBaseURL` — NOT a secret (every client of a Supabase project embeds its
// project ref/URL). `volar.parseProxyBaseURL` in UserDefaults overrides it in DEBUG builds only, useful for
// pointing at a local `supabase functions serve` during development.
import Foundation

struct ConfigParseCredentialProvider: ParseCredentialProvider {
    /// UserDefaults key for the Supabase parse-proxy base URL, e.g. `https://<ref>.supabase.co`.
    /// Overrides `defaultBaseURL` below when set (DEBUG builds only) — for pointing at a local
    /// `supabase functions serve` during development.
    static let baseURLKey = "volar.parseProxyBaseURL"

    /// Default parse-proxy base URL — the project's Supabase project ref, not a secret (see file
    /// doc comment). Force-unwrap is safe: this is a fixed, hand-verified literal, never user input.
    static let defaultBaseURL = URL(string: "https://cjaamylayaylbuuhwlnz.supabase.co")!

    /// `true` iff a Keychain-backed account session exists — i.e. the user is signed in. Cloud
    /// parsing is available to ANY signed-in tier now (free = 20/day, pro = 500/day — contract
    /// §1), so "configured" means "signed in", not "has a paid credential" like it did before this
    /// change. `KeychainStore.loadSession()` is a synchronous Keychain read (replacing the old
    /// synchronous `UserDefaults` read this used to be) — cheap enough for a SwiftUI view body,
    /// same cost class as what it replaces. See `SettingsView`'s Account tab, which drives the
    /// actual sign-in flow this flag now reflects.
    static var isConfigured: Bool {
        KeychainStore.loadSession() != nil
    }

    func baseURL() async throws -> URL {
        #if DEBUG
        // Debug-only: a release build must never let a UserDefaults value redirect the bearer token.
        if let raw = UserDefaults.standard.string(forKey: Self.baseURLKey), !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        #endif
        return Self.defaultBaseURL
    }

    /// Signed out, or a refresh attempt failed -> `nil`, per `ParseCredentialProvider`'s own
    /// contract ("`nil` is the ONLY signal ... must never throw"). `AccountService
    /// .validAccessToken()` is `async throws`; any thrown error here is swallowed to `nil` via
    /// `try?` rather than propagated, so an expired/unrefreshable session degrades to on-device
    /// silently instead of surfacing an error mid-capture — exactly the same "not configured ->
    /// quietly fall back" behavior this file has always had, now driven by account state instead
    /// of a hand-typed UserDefaults token.
    func authHeader() async -> ParseAuthHeader? {
        guard let token = try? await AccountService.shared.validAccessToken() else { return nil }
        // Tier is decided server-side; the client always sends the account access token.
        return .bearer(token)
    }
}

enum ParseCredentialError: Error { case notConfigured }
