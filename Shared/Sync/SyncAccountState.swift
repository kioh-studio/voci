// Shared/Sync/SyncAccountState.swift — account-level sync toggle + rejects reader.
//
// UNVERIFIED: written on Windows, never compiled — no Swift/Xcode toolchain on this dev machine.
//
// Group C (specs/008-sync/client-contract.md §0). Hand-rolled `URLSession`, same shape as
// `Shared/Account/AccountService.swift` — no SPM package, matching that file's own reasoning (a
// large third-party dependency's Swift 6 concurrency story can't be evaluated from a machine that
// can't compile it). `SyncAccountClient` owns exactly the account-level surface: reading/setting
// the server-side sync toggle, purging server data, and reading `sync_rejects`. It does NOT own
// `sync_exchange` (push/pull) — that belongs to `SyncEngine` (group B, `Shared/Sync/SyncEngine.swift`).
//
// Base URL + apikey are COPIED from `AccountService`'s own constants, not re-derived — that file
// keeps them `private`, so there is no way to reach them from here. If the project's publishable
// key ever rotates, BOTH copies need the same edit. That's an accepted duplication (same trade
// `AccountService` itself made when it hand-rolled instead of centralizing this once behind a
// client library — see that file's own header comment), not a lookup bug.
//
// Types consumed here (`SyncState`, `SyncDevice`, `SyncReject`, `SyncFailure`) are pinned VERBATIM
// by client-contract.md §2 and owned by group B (`Shared/Sync/SyncContracts.swift`). This file only
// USES them — it never redefines or edits them. `SyncDate` (client-contract.md §6) is owned by
// group B too (`Shared/Sync/SyncPayload.swift`).
import Foundation

actor SyncAccountClient {
    /// Same "plain, non-`@MainActor` actor, `nonisolated static let shared`" shape as
    /// `AccountService.shared` — spelled out explicitly for the same reason that file's own doc
    /// comment gives (this repo has been bitten specifically by `@MainActor` TYPES' `static let`s
    /// inheriting isolation; writing `nonisolated` here removes any doubt for a reader).
    nonisolated static let shared = SyncAccountClient()

    private static let baseURL = URL(string: "https://cjaamylayaylbuuhwlnz.supabase.co")!
    private static let apiKey = "sb_publishable_WkBa-2lGcl10NBf8JrCfJA__FPNjjf0"

    private let session: URLSession

    /// Last successful `volar_sync_state()`/`volar_set_sync_enabled()` result. `nil` means never
    /// successfully fetched — NOT "not allowed". `SyncEngine` reads this (through
    /// `SyncMerge.gate(state:)`) before starting a round, so the client-side pre-check in
    /// `SyncEngine.currentGate()` never has to make its own separate network call in the common
    /// case. `AppState.syncState` holds its own copy for the UI; the two stay consistent because
    /// both are assigned from the return value of these same two calls, never from each other.
    private(set) var cachedState: SyncState?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - volar_sync_state (client-contract.md §3.2 — NOT gated, see design.md §8.2)

    /// `POST /rest/v1/rpc/volar_sync_state`, body `{}`. Deliberately reachable with no local
    /// Pro/toggle pre-check — the RPC itself is ungated server-side precisely so a machine that's
    /// been locked out (expired Pro, toggle switched off on another device) can still find out WHY
    /// instead of a 403 reading as a generic network failure. Call at launch, at foreground, and
    /// after any `SyncFailure` `SyncEngine` reports from `sync_exchange` (client-contract.md §3.2).
    func fetchState() async throws -> SyncState {
        let data = try await rpc("volar_sync_state", body: [:])
        let state = try Self.decodeState(data)
        cachedState = state
        return state
    }

    // MARK: - volar_set_sync_enabled

    /// `POST /rest/v1/rpc/volar_set_sync_enabled`, body `{"p_enabled":…, "p_device":…}`. Turning ON
    /// requires Pro (enforced server-side by the RLS policy on `sync_prefs`, design.md §8.3) —
    /// turning OFF is always allowed, even with a lapsed Pro subscription ("tắt thì LUÔN được, kể
    /// cả đã hết Pro"). This method does not pre-check either condition itself; it calls straight
    /// through and lets the caller read the real `SyncState`/thrown `SyncFailure` back.
    func setEnabled(_ enabled: Bool, deviceLabel: String?) async throws -> SyncState {
        let body: [String: Any] = [
            "p_enabled": enabled,
            "p_device": deviceLabel ?? NSNull()
        ]
        let data = try await rpc("volar_set_sync_enabled", body: body)
        let state = try Self.decodeState(data)
        cachedState = state
        return state
    }

    // MARK: - volar_sync_purge

    /// `POST /rest/v1/rpc/volar_sync_purge`. The ONE and ONLY path that deletes server-side sync
    /// rows — no job ever calls this; only a user tapping "Delete data on server" does (design.md
    /// §8.3). Never touches local data — local tasks are untouched regardless of what this returns.
    func purge() async throws -> (tasks: Int, completions: Int) {
        let data = try await rpc("volar_sync_purge", body: [:])
        struct PurgeResult: Decodable {
            let deletedTasks: Int
            let deletedCompletions: Int
            // Optional; unknown keys are ignored by synthesis, so a newer server may add reward counts.
            let deletedRewards: Int?
        }
        guard let result = try? JSONDecoder().decode(PurgeResult.self, from: data) else {
            throw SyncFailure.server(status: 200, message: "purge response undecodable")
        }
        return (result.deletedTasks, result.deletedCompletions)
    }

    // MARK: - sync_rejects (plain PostgREST select, NOT an RPC — client-contract.md §3.2)

    /// `GET /rest/v1/sync_rejects?select=…&order=rejected_at.desc&limit=…`. Read-only in v1
    /// (design.md §12 defers full conflict UI) — this is the "one path to see the black box" Opus's
    /// exception carves out (client-contract.md §9): a table that holds the losing side of a
    /// conflict but that nobody can open is functionally the same as having lost the edit.
    func fetchRejects(limit: Int) async throws -> [SyncReject] {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("rest/v1/sync_rejects"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,task_id,updated_at,payload,origin_device,rejected_at"),
            URLQueryItem(name: "order", value: "rejected_at.desc"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else {
            throw SyncFailure.server(status: 0, message: "could not build sync_rejects URL")
        }
        guard let token = try await AccountService.shared.validAccessToken() else {
            throw SyncFailure.signedOut
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncFailure.offline("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapFailure(status: http.statusCode, data: data)
        }
        return Self.decodeRejects(data)
    }

    // MARK: - Networking core

    /// One RPC POST — `apikey` + `Authorization: Bearer <access_token>` + JSON body, the exact same
    /// shape as every other hand-rolled client in this repo (`AccountService.send`,
    /// `GroqTranscriptionClient`). Throws `SyncFailure` (never a bare `URLError`/`AccountError`) so
    /// every caller in group C's UI switches over exactly ONE error type end to end.
    private func rpc(_ name: String, body: [String: Any]) async throws -> Data {
        guard let token = try await AccountService.shared.validAccessToken() else {
            throw SyncFailure.signedOut
        }
        let url = Self.baseURL.appendingPathComponent("rest/v1/rpc/\(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // NEVER log `body` here or anywhere below — every body this method ever sends is harmless
        // on its own (`{}`, `{p_enabled, p_device}`), but this helper is shared plumbing, and the
        // discipline has to be "this helper never logs a body," not "remember which call sites
        // happen to be safe today." design.md §9: sync payloads elsewhere in this feature can carry
        // `sourceTranscript` — the user's raw spoken words — so nothing in `Shared/Sync/` logs a
        // request/response body, this file included, even though none of ITS OWN bodies are that
        // sensitive.
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncFailure.offline("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapFailure(status: http.statusCode, data: data)
        }
        return data
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            // Transport failure: offline/timeout/DNS/TLS. `.offline` is the ONE case the UI shows
            // NOTHING for (client-contract.md §3.3) — never log `error.localizedDescription` itself
            // either, matching `AccountService.send`'s own privacy stance (some platforms echo
            // request details into a transport error's description).
            throw SyncFailure.offline(String(describing: (error as NSError).code))
        }
    }

    // MARK: - Error mapping (client-contract.md §3.3 — the ONE lookup table, no second copy)

    /// PostgREST puts the `raise exception`'s `message` verbatim into the response body's
    /// `"message"` field — this is the ONLY place that string gets interpreted into a `SyncFailure`
    /// case. Every UI surface in group C switches on the resulting enum, never on a raw string, so
    /// there is exactly one place a status/message pair could ever be mis-triaged.
    private static func mapFailure(status: Int, data: Data) -> SyncFailure {
        let message = (try? JSONDecoder().decode(PostgRESTErrorBody.self, from: data))?.message
        switch (status, message) {
        case (403, "sync_pro_required"): return .proRequired
        case (403, "sync_disabled"): return .disabled
        case (401, _): return .signedOut
        default: return .server(status: status, message: message)
        }
    }

    private struct PostgRESTErrorBody: Decodable {
        let message: String?
    }

    // MARK: - Decoding

    /// `SyncState`/`SyncDevice` (SyncContracts.swift) carry real `Date` fields (`enabledAt`,
    /// `SyncDevice.lastSeen`) populated from Postgres `timestamptz` values with up to 6 fractional
    /// digits — the default `JSONDecoder` date strategy (`ISO8601DateFormatter`, 0 or 3 digits)
    /// rejects those outright. Routed through `SyncDate.parse` (client-contract.md §6, group B's
    /// `SyncPayload.swift`) so this decodes with the SAME date parser `SyncEngine` uses for
    /// `updatedAt`/`deletedAt`/`completedAt`, rather than a second hand-rolled one that could drift.
    private static func decodeState(_ data: Data) throws -> SyncState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = SyncDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "unparseable sync date: \(raw)")
            }
            return date
        }
        guard let state = try? decoder.decode(SyncState.self, from: data) else {
            throw SyncFailure.server(status: 200, message: "volar_sync_state response undecodable")
        }
        return state
    }

    /// `sync_rejects` rows are plain PostgREST JSON with snake_case keys (`task_id`, `updated_at`,
    /// `origin_device`, `rejected_at`) and a freeform `payload` JSONB blob — decoded by hand via
    /// `JSONSerialization` rather than `Decodable`, because `SyncReject.payloadJSON` needs the
    /// payload RE-SERIALIZED as a pretty string (for the rejects viewer, client-contract.md §2's
    /// doc comment: "kept as a string ... this row exists precisely because the shape may be from
    /// another build"), and `title` is a best-effort field lifted OUT of that same blob. A single
    /// row that's missing/malformed a required field is dropped rather than failing the whole
    /// fetch — one bad historical row must never hide every other row in the list.
    private static func decodeRejects(_ data: Data) -> [SyncReject] {
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rawArray.compactMap { row in
            guard
                let idString = row["id"] as? String, let id = UUID(uuidString: idString),
                let taskIdString = row["task_id"] as? String, let taskId = UUID(uuidString: taskIdString),
                let updatedAtString = row["updated_at"] as? String, let updatedAt = SyncDate.parse(updatedAtString),
                let rejectedAtString = row["rejected_at"] as? String, let rejectedAt = SyncDate.parse(rejectedAtString)
            else { return nil }
            let originDevice = row["origin_device"] as? String
            let payload = row["payload"] as? [String: Any] ?? [:]
            let title = payload["title"] as? String
            return SyncReject(
                id: id,
                taskId: taskId,
                updatedAt: updatedAt,
                rejectedAt: rejectedAt,
                originDevice: originDevice,
                payloadJSON: prettyPrint(payload),
                title: title
            )
        }
    }

    private static func prettyPrint(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

// MARK: - Settings copy (shared between macOS `SettingsView` and iOS `SettingsIOSView`)

extension SyncState {
    /// The ONE place the "sync is off" / "sync needs Pro" status line is worded — read by BOTH
    /// `SettingsView.swift` (macOS) and `SettingsIOSView.swift` (iOS) so the two platforms literally
    /// cannot say two different things about the same account state (client-contract.md §5: "Cùng
    /// một khái niệm. Đừng để hai bên nói hai kiểu."). `nil` means sync is actually on — callers show
    /// the "enabled since …" line instead in that case.
    ///
    /// Deliberately does NOT cover the offline case: offline has NO line at all (client-contract.md
    /// §3.3 — "im lặng, thử lại sau"), so there is no third branch here to keep it that way; a
    /// caller that hasn't fetched state yet just shows nothing until it has.
    var settingsStatusLine: String? {
        if !isPro { return "Sync is a Pro feature." }
        if !syncEnabled { return "Sync is off for this account." }
        return nil
    }
}
