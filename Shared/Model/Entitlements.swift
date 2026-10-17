// Sources/Model/Entitlements.swift — StoreKit 2 purchases + entitlement/quota cache.
// specs/002-workflow-command-center/contracts/account-auth.md §3 (subscription/link, /status),
// §8 (StoreKit product ids/pricing).
//
// Hand-rolled network layer over `URLSession`, same "no extra SPM package" reasoning as
// `AccountService.swift` — StoreKit itself is a first-party system framework, not a third-party
// dependency, so it's used directly (`Product`, `Transaction`, `AppStore`), but the HTTP calls to
// this app's own edge functions get the same small hand-rolled treatment as everywhere else in
// this codebase (`CloudParser`, `GroqTranscriptionClient`, `AccountService`).
import Foundation
import StoreKit

/// The two auto-renewable products in the single "Volar Pro" subscription group (contract §8).
enum VolarProduct: String, CaseIterable, Sendable, Identifiable {
    case monthly = "tech.kioh.Volar.pro.monthly"
    case yearly = "tech.kioh.Volar.pro.yearly"
    var id: String { rawValue }
}

enum EntitlementError: Error, Sendable, Equatable {
    case notSignedIn
    case productNotFound
    case verificationFailed
    case userCancelled
    case pending
    case network(String)
    case http(status: Int, code: String?)
    /// 409 `subscription_already_linked` (contract §3) — first-claim-wins: this Apple subscription
    /// is already attached to a DIFFERENT Volar account.
    case alreadyLinkedToAnotherAccount
}

extension EntitlementError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in first to link a purchase."
        case .productNotFound: return "That product isn't available right now — try again in a moment."
        case .verificationFailed: return "Apple couldn't verify this purchase."
        case .userCancelled: return "Purchase cancelled."
        case .pending: return "Purchase is pending approval (e.g. Ask to Buy)."
        case .network(let message): return "Network error: \(message)"
        case .http(let status, let code): return "Request failed (\(code ?? "http_\(status)"))."
        case .alreadyLinkedToAnotherAccount:
            return "This Apple subscription is already linked to a different Volar account."
        }
    }
}

/// Owns StoreKit 2 product loading/purchase + the server-side link/status round trip. A plain
/// `actor` (not `@MainActor`) for the same reason as `AccountService`: StoreKit 2's own API
/// (`Product.products(for:)`, `product.purchase()`, `Transaction.updates`) is already async/
/// Sendable-safe, and the networking half of this type should stay off the main actor.
/// `AppState`/`SettingsView` await into this actor exactly like they do `AccountService`.
actor Entitlements {
    /// See `AccountService.shared`'s doc comment for why this is a singleton and why `nonisolated`
    /// is spelled out explicitly even though it's the default for a plain actor's `static let`.
    nonisolated static let shared = Entitlements()

    private static let baseURL = ConfigParseCredentialProvider.defaultBaseURL

    /// UserDefaults (NOT Keychain — this is cached DERIVED state, "free"/"pro", never a
    /// credential) snapshot of the last known tier, so `EnvironmentGroqCredentialProvider
    /// .isConfigured` (`GroqTranscriptionClient.swift`) and `AppState.selectedEngine` can gate
    /// Groq (Pro-only, contract §1) SYNCHRONOUSLY — from a SwiftUI view body / plain computed
    /// property — without awaiting this actor on every capture. Absent/unrecognized -> `false`:
    /// never grants a Pro-gated feature before the server has actually confirmed it at least once.
    private static let cachedTierKey = "volar.entitlementTierCache"
    nonisolated static var cachedIsPro: Bool {
        UserDefaults.standard.string(forKey: cachedTierKey) == AccountTier.pro.rawValue
    }
    private static func cacheTier(_ tier: AccountTier) {
        UserDefaults.standard.set(tier.rawValue, forKey: cachedTierKey)
    }

    /// Drops the tier snapshot AND the in-memory `status`. Called on sign-out / account deletion
    /// (`AppState`), and by `refreshStatus()` below whenever it learns there is no session at all.
    ///
    /// Without this the snapshot is write-only: `cachedIsPro` keeps returning `true` after signing
    /// out, so the next launch's `AppState.refreshAccountState()` — which falls back to
    /// `cachedIsPro` when `refreshStatus()` returns nil for lack of a token — shows a signed-out
    /// user as Pro. Note this is a stale-STATE bug, not an entitlement bypass: Groq stays shut
    /// because `GroqTranscriptionClient.isConfigured` also requires a stored session.
    func clearEntitlementCache() {
        status = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedTierKey)
    }

    private(set) var products: [Product] = []
    private(set) var status: SubscriptionStatus?
    private var updatesTask: Task<Void, Never>?

    private init() {}

    // MARK: - Products

    func loadProducts() async {
        products = (try? await Product.products(for: VolarProduct.allCases.map(\.rawValue))) ?? []
    }

    func product(_ which: VolarProduct) -> Product? {
        products.first { $0.id == which.rawValue }
    }

    // MARK: - Purchase

    /// Purchases `which`, links the resulting transaction to the signed-in account, THEN finishes
    /// the transaction — in that exact order. Task brief: "do not finish before the server has
    /// recorded it, or a crash loses the link" — `transaction.finish()` tells StoreKit this
    /// transaction has been fully processed and it can stop redelivering it via
    /// `Transaction.updates`/`currentEntitlements`; finishing before `link` succeeds means a crash
    /// (or any failure) between the two would leave the purchase real on Apple's side but
    /// unrecorded on ours, with no future redelivery to retry the link.
    @discardableResult
    func purchase(_ which: VolarProduct) async throws -> SubscriptionLinkResponse {
        // Deliberately NOT folded into a `product(which) ?? <fetch>`: `??` takes its right-hand
        // side as a non-`async` `@autoclosure`, so no `await` can appear there. The cold path also
        // goes through `loadProducts()` rather than a one-off `Product.products(for: [id])` so the
        // result lands in `products` — a retry (or the Account tab reading `product(_:)`) doesn't
        // hit the network a second time.
        var resolved = product(which)
        if resolved == nil {
            await loadProducts()
            resolved = product(which)
        }
        guard let product = resolved else {
            throw EntitlementError.productNotFound
        }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw EntitlementError.network(error.localizedDescription)
        }
        switch result {
        case .success(let verification):
            let transaction = try Self.checkVerified(verification)
            let linked = try await link(verification)
            await transaction.finish()
            await refreshStatus()
            return linked
        case .userCancelled:
            throw EntitlementError.userCancelled
        case .pending:
            throw EntitlementError.pending
        @unknown default:
            throw EntitlementError.verificationFailed
        }
    }

    /// Re-links every currently-active entitlement — called at app launch (`AppState`) and after
    /// the `Transaction.updates` listener below observes a change. Contract §8: "Renew: client gọi
    /// lại /subscription/link ... ở mỗi lần khởi động app. Không dựng App Store Server
    /// Notifications trong đợt này" — this re-link-at-launch (plus the live listener) IS the
    /// renewal/refund-propagation mechanism until that's built. Best-effort per transaction: one
    /// failing to link (e.g. a stale/edge-case entitlement) must not stop the others.
    func relinkCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard (try? Self.checkVerified(result)) != nil else { continue }
            _ = try? await link(result)
        }
        await refreshStatus()
    }

    /// Starts the renewal/refund/Ask-to-Buy listener once (idempotent — a second call while
    /// already running is a no-op, since `AppState` may call this again across app lifecycle
    /// events). `Task.detached` because `Transaction.updates` is a long-lived, effectively
    /// infinite `AsyncSequence` — running its loop detached (only hopping back into `self` for
    /// the actual per-update `link`/`finish` work) keeps this actor free to serve other calls in
    /// between updates instead of pinning one of its "slots" to a loop that almost never returns.
    func startTransactionUpdatesListener() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let transaction = try? Self.checkVerified(update) else { continue }
                guard let self else { return }
                do {
                    _ = try await self.link(update)
                    await transaction.finish()
                } catch {
                    // Leaving it UNFINISHED is the whole retry mechanism: StoreKit keeps
                    // redelivering an unfinished transaction through `Transaction.updates` (and
                    // `relinkCurrentEntitlements()` re-sees it at next launch), which is what
                    // stands in for App Store Server Notifications this round (contract §8).
                    // Only a failure that can never succeed gets finished — see below.
                    if Self.isPermanentLinkFailure(error) {
                        await transaction.finish()
                    }
                }
            }
        }
    }

    /// Is retrying this `link` failure pointless? Used only by the listener above, to decide
    /// between "leave unfinished so StoreKit redelivers it" and "finish it, the answer will never
    /// change". Getting this wrong in the permissive direction is the worse failure: a transaction
    /// finished on a transient error is never redelivered, so the server silently never learns
    /// about that renewal — hence everything not provably permanent is treated as retryable.
    private static func isPermanentLinkFailure(_ error: Error) -> Bool {
        guard let error = error as? EntitlementError else { return false }
        switch error {
        case .alreadyLinkedToAnotherAccount:
            // Contract §3 first-claim-wins — this Apple subscription belongs to a different Volar
            // account. No number of retries changes that, and `purchase()` throws before finishing
            // in this case too, so without this the transaction would be redelivered forever.
            return true
        case .http(let status, _):
            // 4xx = the request itself is wrong for this account. Except the transient three:
            // 401 (a later token refresh may fix it), 408, 429 (rate limited).
            return (400..<500).contains(status) && ![401, 408, 429].contains(status)
        default:
            // `.notSignedIn` (user signs in later), `.network`, 5xx, decode failures, and any
            // `AccountError` thrown out of `validAccessToken()` — all plausibly fixed by a retry.
            return false
        }
    }

    /// Restore = `AppStore.sync()` (task brief), then re-link whatever that surfaces.
    func restorePurchases() async throws {
        do {
            try await AppStore.sync()
        } catch {
            throw EntitlementError.network(error.localizedDescription)
        }
        await relinkCurrentEntitlements()
    }

    // MARK: - Status (contract §3 `GET /functions/v1/subscription/status`)

    /// Fetches the latest tier + quota. Returns (and leaves `status` at) whatever was last known
    /// on any failure — signed out, offline, decode failure — rather than clearing it out from
    /// under a concurrent reader; `SettingsView` only shows this while signed in anyway.
    @discardableResult
    func refreshStatus() async -> SubscriptionStatus? {
        let token: String?
        do {
            token = try await AccountService.shared.validAccessToken()
        } catch {
            // THROWN = transient (offline, decode, a refresh that failed for a reason other than a
            // dead token). Keep what we last knew rather than downgrading a paying user offline.
            return status
        }
        guard let token else {
            // RETURNED nil = definitive, not transient: `validAccessToken()` only does that when
            // there is no session at all — the user signed out, or `performRefresh` found the
            // refresh token dead (400/401) and cleared it. Either way the Pro snapshot has to go.
            clearEntitlementCache()
            return nil
        }
        do {
            let (code, data) = try await Self.send(
                path: "functions/v1/subscription/status", method: "GET", body: nil, bearer: token
            )
            guard (200..<300).contains(code) else { return status }
            guard let decoded = try? JSONDecoder().decode(SubscriptionStatus.self, from: data) else { return status }
            status = decoded
            Self.cacheTier(decoded.tier)
            return decoded
        } catch {
            return status
        }
    }

    // MARK: - Networking (mirrors `AccountService`'s hand-rolled URLSession layer)

    /// Takes the `VerificationResult`, NOT the unwrapped `Transaction`: the signed JWS the server
    /// re-verifies (contract §3) lives on `VerificationResult.jwsRepresentation` — `Transaction`
    /// itself only exposes `jsonRepresentation`, which carries no signature and so is worthless to
    /// the edge function. Callers still unwrap separately via `checkVerified` when they need the
    /// `Transaction` for `finish()`.
    private func link(_ verification: VerificationResult<Transaction>) async throws -> SubscriptionLinkResponse {
        guard let token = try await AccountService.shared.validAccessToken() else {
            throw EntitlementError.notSignedIn
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["jws": verification.jwsRepresentation]) else {
            throw EntitlementError.verificationFailed
        }
        let (code, data) = try await Self.send(
            path: "functions/v1/subscription/link", method: "POST", body: body, bearer: token
        )
        guard (200..<300).contains(code) else {
            let errorBody = try? JSONDecoder().decode(AccountErrorBody.self, from: data)
            if code == 409, errorBody?.error == "subscription_already_linked" {
                throw EntitlementError.alreadyLinkedToAnotherAccount
            }
            throw EntitlementError.http(status: code, code: errorBody?.error)
        }
        guard let decoded = try? JSONDecoder().decode(SubscriptionLinkResponse.self, from: data) else {
            throw EntitlementError.verificationFailed
        }
        Self.cacheTier(decoded.tier)
        return decoded
    }

    /// Edge function — `Authorization: Bearer <access_token>` only, no `apikey` header (same
    /// convention as `AccountService.functionsRequest`/`CloudParser`/`GroqTranscriptionClient`).
    private static func send(path: String, method: String, body: Data?, bearer: String) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EntitlementError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw EntitlementError.network("Non-HTTP response") }
        return (http.statusCode, data)
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw EntitlementError.verificationFailed
        case .verified(let value): return value
        }
    }
}
