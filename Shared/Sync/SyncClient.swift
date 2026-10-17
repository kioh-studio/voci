// Shared/Sync/SyncClient.swift — thin networking actor for `POST /rest/v1/rpc/sync_exchange`.
//
// UNVERIFIED: written on Windows, never compiled.
//
// Mirrors `AccountService.swift`'s hand-rolled `URLSession` shape (plain `actor`, injected
// session, base URL + publishable key declared locally — same convention `Entitlements.swift`
// also follows rather than sharing a single constant, per this repo's existing precedent) rather
// than reusing any of `AccountService`'s private networking helpers directly (they're `private` to
// that actor) or pulling in a Supabase SPM package (constitution/repo-wide: this app has never
// once compiled, so a large third-party dependency's own concurrency surface is an unreviewable
// risk — see `AccountService.swift`'s own header for the fuller argument).
//
// JUDGMENT CALL not spelled out by the contract: request/response bodies here are built via
// `Codable` + `SyncCoding`'s `JSONEncoder`/`JSONDecoder` (configured to route every `Date` through
// `SyncDate`), NOT via `AccountService`'s `[String: Any]` + `JSONSerialization.data(withJSONObject:)`
// idiom. That idiom fits AccountService's few flat, simple bodies; `sync_exchange`'s body is
// nested arrays of `TaskPayload`/`CompletionPayload` with ~25 fields each, where hand-building
// dictionaries would be exactly the kind of place a stray key typo goes unnoticed until a Mac
// build. Still "hand-rolled `URLSession`, no SPM package" — the deviation is in how the BODY is
// serialized, not in how the request is sent.
//
// PRIVACY (design.md §9): `payload` carries `title`/`notes`/`sourceTranscript` — verbatim spoken
// text. Nothing in this file ever logs/prints a request or response body, only status codes and
// already-classified `SyncFailure` values.
import Foundation

actor SyncClient {
    /// `nonisolated` spelled out for the same reason `AccountService.shared` documents it — a
    /// plain (non-`@MainActor`) actor's `static let` is nonisolated by default, but this repo has
    /// been bitten specifically by the `@MainActor`-type version of this rule, so every actor here
    /// says it explicitly rather than relying on a reader to remember the distinction.
    nonisolated static let shared = SyncClient()

    private static let baseURL = ConfigParseCredentialProvider.defaultBaseURL
    /// Publishable key — NOT a secret (same reasoning as `AccountService.apiKey`'s doc comment:
    /// every client of a Supabase project embeds its project's public anon/publishable key).
    private static let apiKey = "sb_publishable_WkBa-2lGcl10NBf8JrCfJA__FPNjjf0"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The ONE method this actor exposes (client-contract.md §3: "Đúng một method chính"). Every
    /// failure surfaces as a `SyncFailure` — never a raw `URLError`/`DecodingError`/`AccountError`
    /// — via `SyncMerge.classify`, so `SyncEngine` has exactly one error type to switch on.
    func exchange(_ request: SyncExchangeRequest) async throws -> SyncExchangeResponse {
        let token: String
        do {
            guard let validToken = try await AccountService.shared.validAccessToken() else {
                throw SyncFailure.signedOut
            }
            token = validToken
        } catch let failure as SyncFailure {
            throw failure
        } catch {
            // `validAccessToken()` only throws when a refresh attempt ITSELF fails (that method's
            // own doc comment) — by definition a session already exists at that point, so this is
            // a transient networking problem reaching GoTrue, not "no session". Classifying it as
            // `.offline` (silent, retried later) rather than `.signedOut` (which would send the
            // user to a sign-in screen for what is, from their side, just "no internet right now")
            // matches `SyncFailure.offline`'s own doc comment.
            throw SyncMerge.classify(status: nil, message: nil, transportError: error)
        }

        var urlRequest = URLRequest(url: Self.baseURL.appendingPathComponent("rest/v1/rpc/sync_exchange"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(Self.apiKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            urlRequest.httpBody = try SyncCoding.makeEncoder().encode(request)
        } catch {
            // Encoding OUR OWN request struct failing is a programmer error (a field that can't
            // serialize), not a runtime sync condition any other `SyncFailure` case describes.
            // `.server` with a sentinel status keeps it visible in the diagnostics row instead of
            // silently reading as "offline" (which would be actively misleading — retrying this
            // will fail identically every time, unlike a real transport error).
            throw SyncFailure.server(status: -1, message: "request encoding failed")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw SyncMerge.classify(status: nil, message: nil, transportError: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SyncMerge.classify(status: nil, message: nil, transportError: nil)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SyncMerge.classify(
                status: http.statusCode, message: Self.errorMessage(from: data), transportError: nil
            )
        }

        do {
            return try SyncExchangeResponse.decode(from: data)
        } catch {
            // A 2xx response that doesn't even parse as the expected shape — treat like any other
            // unrecognized server behavior (`.server`), never silently swallowed.
            throw SyncFailure.server(status: http.statusCode, message: "response decoding failed")
        }
    }

    /// PostgREST's own error shape (`{"code":..., "details":..., "hint":..., "message":...}`) —
    /// DIFFERENT from `AccountErrorBody`'s `{"error":"..."}` (that shape belongs to Volar's own
    /// edge functions; `sync_exchange` is a direct PostgREST RPC call, contract §3.3: "PostgREST
    /// đặt nguyên văn `message` của `raise exception` vào `body.message`"). `try?` — a body that
    /// doesn't even decode this far still classifies fine with `message: nil` (falls through to
    /// `.server` in `SyncMerge.classify` unless the status alone is already meaningful, e.g. 401).
    private static func errorMessage(from data: Data) -> String? {
        struct PostgRESTErrorBody: Decodable { var message: String? }
        return (try? JSONDecoder().decode(PostgRESTErrorBody.self, from: data))?.message
    }
}
