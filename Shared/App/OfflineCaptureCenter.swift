// Shared/App/OfflineCaptureCenter.swift — feature 011 contract §7.
// Remembers tasks that were saved while offline as title-only, so the app can offer to "tidy them up"
// (re-parse with AI) once back online. UNVERIFIED: written blind on Windows, never compiled.
import Foundation
import Network
import Observation

struct PendingReparse: Codable, Identifiable, Sendable {
    let id: UUID // task id
    let transcript: String
    let capturedAt: Date
}

@MainActor
@Observable
final class OfflineCaptureCenter {
    /// `true` until the first path callback says otherwise (same default as `DefaultCloudParseGate`).
    private(set) var isOnline = true
    private(set) var pending: [PendingReparse] = []
    /// Now shows "Saved. Nothing lost." for a few seconds after this.
    private(set) var lastSavedOfflineAt: Date?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "volar.offline.pendingReparse"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([PendingReparse].self, from: data) {
            pending = saved
        }
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            _Concurrency.Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "volar.offlineCapture.reachability"))
    }

    deinit { monitor.cancel() }

    func recordOfflineSave(taskIds: [UUID], transcript: String) {
        guard !taskIds.isEmpty else { return }
        let now = Date()
        pending.append(contentsOf: taskIds.map { PendingReparse(id: $0, transcript: transcript, capturedAt: now) })
        lastSavedOfflineAt = now
        persist()
    }

    func remove(_ id: UUID) {
        pending.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: Self.key) }
    }
}
