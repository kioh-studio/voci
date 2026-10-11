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

extension UNUserNotificationCenter {
    nonisolated func volarDeliveredSummaries() async -> [DeliveredNotificationSummary] {
        await deliveredNotifications().map {
            DeliveredNotificationSummary(identifier: $0.request.identifier, date: $0.date)
        }
    }

    nonisolated func volarPendingIdentifiers() async -> [String] {
        await pendingNotificationRequests().map(\.identifier)
    }

    nonisolated func volarAuthorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}
