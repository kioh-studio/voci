// Shared/Reminders/NotificationCenterSendable.swift — Sendable projections of
// `UNUserNotificationCenter`'s async getters.
//
// WHY (first CI build on Xcode 16.4 / Swift 6, 2026-10-11): `deliveredNotifications()`,
// `pendingNotificationRequests()` and `notificationSettings()` return non-Sendable ObjC classes,
// so calling them from a `@MainActor` context is rejected under strict concurrency ("non-sendable
// result type cannot be sent from nonisolated context"). The actor-crossing is legal only when
// the value crossing is Sendable — so these `nonisolated` helpers do the call off any actor and
// hand back plain value types (identifiers, dates, the status enum). Every caller in the app only
// ever needed those fields anyway.
import Foundation
import UserNotifications

/// Identifier + real delivery moment of one notification still in Notification Center.
struct DeliveredNotificationSummary: Sendable, Equatable {
    let identifier: String
    let date: Date
}

// STATIC on purpose (CI round 3): an instance method called on a `@MainActor`-owned `center`
// property still "sends" the non-Sendable instance across isolation. `current()` is a process-wide
// singleton, so resolving it inside the nonisolated helper is equivalent and crosses nothing.
extension UNUserNotificationCenter {
    nonisolated static func volarDeliveredSummaries() async -> [DeliveredNotificationSummary] {
        await current().deliveredNotifications().map {
            DeliveredNotificationSummary(identifier: $0.request.identifier, date: $0.date)
        }
    }

    nonisolated static func volarPendingIdentifiers() async -> [String] {
        await current().pendingNotificationRequests().map(\.identifier)
    }

    nonisolated static func volarAuthorizationStatus() async -> UNAuthorizationStatus {
        await current().notificationSettings().authorizationStatus
    }

    /// `add(_:)`'s async form sends the non-Sendable request across isolation; the completion-
    /// handler form is a plain synchronous ObjC call from the caller's actor, so nothing crosses.
    func volarAdd(_ request: UNNotificationRequest) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            add(request) { _ in continuation.resume() }
        }
    }
}
