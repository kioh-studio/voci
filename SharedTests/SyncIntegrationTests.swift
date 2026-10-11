// SharedTests/SyncIntegrationTests.swift — the REAL sync stack, two devices, production server.
//
// Runs only when CI hands the test process a session for the dedicated Pro test account
// (`.github/workflows/apple-build.yml` does a password grant and exports `TEST_RUNNER_VOLAR_SYNC_*`;
// xcodebuild strips the prefix). Anywhere else it is skipped, so a local run never touches the
// network. Everything it exercises is the shipping code path: `TaskStore` (SwiftData, in-memory),
// `SyncEngine` (debounce/poll/cursor), `SyncClient` (URLSession → PostgREST `sync_exchange`),
// `SyncPayload` encode/decode, `applyRemote`/`applyRemoteRewards` LWW. Two engines with their own
// `UserDefaults` suites and stores = two devices on one account.
import XCTest
import Foundation
import VolarCore
@testable import Volar

@MainActor
final class SyncIntegrationTests: XCTestCase {
    private struct Creds { let jwt: String; let refresh: String; let uid: String; let email: String }

    private static func creds() -> Creds? {
        let env = ProcessInfo.processInfo.environment
        guard let jwt = env["VOLAR_SYNC_TEST_JWT"], !jwt.isEmpty,
              let uid = env["VOLAR_SYNC_TEST_UID"], !uid.isEmpty else { return nil }
        return Creds(jwt: jwt, refresh: env["VOLAR_SYNC_TEST_REFRESH"] ?? "", uid: uid,
                     email: env["VOLAR_SYNC_TEST_EMAIL"] ?? "")
    }

    /// Polls `condition` on the main actor until it holds or `timeout` elapses.
    private func waitUntil(_ timeout: TimeInterval, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func makeDevice(_ name: String) throws -> (store: TaskStore, engine: SyncEngine) {
        let store = try TaskStore(inMemory: true)
        let defaults = UserDefaults(suiteName: "volar.synctest.\(name).\(UUID().uuidString)")!
        let engine = SyncEngine(client: .shared, defaults: defaults)
        engine.attach(store: store) // registers observers, starts polling, requests a first round
        return (store, engine)
    }

    func testTwoDevicesSyncTasksAndRewardsThroughProduction() async throws {
        guard let creds = Self.creds() else {
            throw XCTSkip("VOLAR_SYNC_TEST_JWT not set — integration test only runs on CI")
        }
        await AccountService.shared.adoptSession(AccountSession(
            accessToken: creds.jwt, refreshToken: creds.refresh,
            expiresAt: Date().timeIntervalSince1970 + 3000, tokenType: "bearer",
            user: AccountUser(id: creds.uid, email: creds.email)
        ))
        // Clean slate on the server for this account, and the gate must say Pro + enabled.
        _ = try await SyncAccountClient.shared.purge()
        let state = try await SyncAccountClient.shared.fetchState()
        XCTAssertTrue(state.isPro && state.syncEnabled, "CI account must be Pro with sync on: \(state)")

        // ── Device A (think: iPhone) captures a task and attaches an Earned-break reward ──
        let a = try makeDevice("A")
        let taskID = UUID()
        a.store.add(TaskItem(id: taskID, title: "Sync integration \(taskID.uuidString.prefix(8))", priority: .medium, when: .now))
        let reward = RewardItem(kind: .catalog, title: "Game", minutes: 30, icon: .gamepad)
        a.store.addReward(reward)
        a.store.addReward(RewardItem(kind: .grant, title: "Game", minutes: 30, icon: .gamepad, taskId: taskID, rewardId: reward.id))
        a.engine.requestSync(reason: .localEdit)
        try await waitUntil(40, "device A pushed everything") {
            a.store.pendingForSync(limit: 10).isEmpty && a.store.pendingRewardsForSync(limit: 10).isEmpty
        }
        XCTAssertNil(a.engine.lastFailure)

        // ── Device B (think: Mac), fresh install, pulls the same account ──
        let b = try makeDevice("B")
        try await waitUntil(40, "device B pulled the task and both rewards") {
            b.store.fetchAll().contains { $0.id == taskID } && b.store.fetchRewards().count == 2
        }
        XCTAssertEqual(b.store.fetchAll().first { $0.id == taskID }?.title, a.store.fetchAll().first { $0.id == taskID }?.title)
        XCTAssertEqual(b.store.liveGrant(for: taskID)?.rewardId, reward.id, "grant arrived with its reward snapshot")

        // ── B finishes the task; A must see it done (the "done on another device" case) ──
        b.store.toggle(taskID)
        b.engine.requestSync(reason: .localEdit)
        try await waitUntil(60, "device A sees the task done") {
            a.store.fetchAll().first { $0.id == taskID }?.status == .done
        }

        // ── B starts the break; A sees the running break stamped with B's device id ──
        if var grant = b.store.liveGrant(for: taskID) {
            grant.breakStartedAt = Date(); grant.breakEndsAt = Date().addingTimeInterval(1800)
            grant.startedDevice = b.engine.deviceId
            b.store.updateReward(grant)
            b.engine.requestSync(reason: .localEdit)
        } else {
            XCTFail("device B has no live grant")
        }
        try await waitUntil(60, "device A sees the break started on B") {
            a.store.liveGrant(for: taskID)?.startedDevice == b.engine.deviceId
        }
        XCTAssertNotEqual(a.engine.deviceId, b.engine.deviceId)

        // Leave the account clean for the next run.
        _ = try await SyncAccountClient.shared.purge()
        await AccountService.shared.signOut()
    }
}
