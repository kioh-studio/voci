// SharedTests/RewardSyncTests.swift — wire codec for the rewards stream (011 contract §5).
//
// UNVERIFIED: written on Windows, never compiled. `RewardItem` is built by DECODING JSON (its decode
// is tolerant: only `id` is required), so these tests do not depend on its memberwise initializer.
import XCTest
import Foundation
@testable import Volar

final class RewardSyncTests: XCTestCase {
    private let id1 = "11111111-1111-1111-1111-111111111111"
    private let id2 = "22222222-2222-2222-2222-222222222222"
    private let stamp = "2026-10-11T09:00:00.000Z"

    private func rewardItem(id: String, kind: String = "grant") throws -> RewardItem {
        let json = #"{"id":"\#(id)","kind":"\#(kind)"}"#
        return try SyncCoding.makeDecoder().decode(RewardItem.self, from: Data(json.utf8))
    }

    private func row(id: String, payload: String, deletedAt: String? = nil) -> String {
        let deleted = deletedAt.map { #""\#($0)""# } ?? "null"
        return #"{"id":"\#(id)","updatedAt":"\#(stamp)","deletedAt":\#(deleted),"payload":\#(payload),"schemaVersion":1,"serverUpdatedAt":"\#(stamp)","originDevice":null}"#
    }

    func testRequestEncodesRewardsAndCursor() throws {
        let item = try rewardItem(id: id1)
        let pending = PendingReward(item: item, updatedAt: Date(timeIntervalSince1970: 1_800_000_000), deletedAt: nil)
        let request = SyncExchangeRequest(
            cursorTasks: nil, cursorCompletions: nil, device: "dev", deviceLabel: nil,
            tasks: [], completions: [],
            cursorRewards: "2026-10-11T09:00:00.123456+00:00",
            rewards: [SyncRewardOutbound(pending)],
            limit: 500
        )
        let data = try SyncCoding.makeEncoder().encode(request)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["p_cursor_rewards"] as? String, "2026-10-11T09:00:00.123456+00:00")
        let rewards = try XCTUnwrap(root["p_rewards"] as? [[String: Any]])
        XCTAssertEqual(rewards.count, 1)
        let payload = try XCTUnwrap(rewards[0]["payload"] as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, "grant")
        XCTAssertEqual(rewards[0]["schemaVersion"] as? Int, 1)
    }

    func testOldServerResponseWithoutRewardsKeyDecodes() throws {
        let body = #"{"cursorTasks":null,"cursorCompletions":null,"tasks":[],"completions":[],"hasMore":false,"rejected":[]}"#
        let response = try SyncExchangeResponse.decode(from: Data(body.utf8))
        XCTAssertEqual(response.rewards.count, 0)
        XCTAssertNil(response.cursorRewards)
    }

    func testBadRewardRowIsDroppedGoodRowKept() throws {
        let good = row(id: id1, payload: #"{"id":"\#(id1)","kind":"catalog"}"#)
        let bad = #"{"id":"not-a-uuid","updatedAt":"garbage"}"#
        let body = #"{"cursorRewards":"c1","rewards":[\#(bad),\#(good)],"hasMore":false}"#
        let response = try SyncExchangeResponse.decode(from: Data(body.utf8))
        XCTAssertEqual(response.cursorRewards, "c1")
        let remote = response.rewards.map(\.asRemoteReward)
        XCTAssertEqual(remote.count, 1)
        XCTAssertEqual(remote[0].id, UUID(uuidString: id1))
        XCTAssertNotNil(remote[0].item)
    }

    func testUnparseablePayloadWithDeletedAtStillYieldsTombstone() throws {
        let tomb = row(id: id2, payload: #""not an object""#, deletedAt: stamp)
        let body = #"{"rewards":[\#(tomb)],"hasMore":false}"#
        let response = try SyncExchangeResponse.decode(from: Data(body.utf8))
        let remote = try XCTUnwrap(response.rewards.map(\.asRemoteReward).first)
        XCTAssertNil(remote.item)
        XCTAssertNotNil(remote.deletedAt)
    }
}
