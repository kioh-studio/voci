// Sources/Orchestrator/AppLinkHandler.swift — inbound `volar://` app-link routing (US4,
// specs/002-workflow-command-center/contracts/phase6-contract.md §A +
// specs/002-workflow-command-center/contracts/app-links.md, the authoritative behavioral spec).
//
// URL SCHEME: `volar` — confirmed in Volar/Resources/Info.plist's `CFBundleURLTypes` (the project
// was renamed Voci -> Volar; that Info.plist comment already documents that nothing implements
// `.onOpenURL` yet, i.e. this file is that missing handler). This file does not hard-fail on a
// different scheme (SwiftUI's `.onOpenURL` only ever routes URLs matching a registered scheme in
// the first place) but does log+ignore one, defensively, rather than assume the caller pre-filtered.
//
// CAPTURE SEAM: per this task's instructions, capture parsing itself is NOT implemented here
// (`volar://capture?text=...&source=...` must "hand text to the existing capture pipeline" without
// bypassing the confirm card — app-links.md). This file exposes `onCapture`, a closure the
// app-wiring agent sets in `AppState`/`VolarApp.swift` to the existing entry point
// (`AppState.proceedToCapture(transcript:)` per `Volar/Sources/App/AppState.swift`, which already
// runs transcripts through the parser + confirm-card flow — see that file's `finishRecording`/
// `proceedToCapture`). Leaving this file free of any UI/AppState import keeps it testable in
// isolation and keeps this task's file ownership to exactly the two Orchestrator files.
import Foundation
import VolarCore

/// Routes inbound `volar://` URLs (`.onOpenURL`). Inbound-only, one-way, idempotent,
/// non-destructive (Constitution I/II, app-links.md's own framing): a signal may surface work for
/// review but can never complete, delete, or create a task on its own.
@MainActor
final class AppLinkHandler {
    private let store: TaskStore

    /// Capture seam (see file header): the app-wiring agent assigns this to the existing capture
    /// pipeline entry point. `text` is already percent-decoded (URLComponents does this
    /// automatically); `source` is the optional origin reference app-links.md documents for
    /// `volar://capture`. Left `nil` (default) is a safe no-op — a capture link received before
    /// wiring is complete is logged and dropped, never silently guessed at or force-unwrapped.
    var onCapture: ((_ text: String, _ source: String?) -> Void)?

    /// When the last capture link was accepted — a second one within 2 s is dropped so a link
    /// that fires repeatedly (or a hostile page looping it) can't spam the parse pipeline.
    private var lastCaptureAt: Date?

    init(store: TaskStore) {
        self.store = store
    }

    /// SwiftUI `.onOpenURL` entry. Còn đúng một route: `<scheme>://capture?text=` — đẩy text vào
    /// đúng pipeline capture/parse sẵn có (không bao giờ đi vòng qua card xác nhận). Route
    /// `ai-done` đã bỏ cùng tính năng delegation 2026-08-22. Malformed input (unparsable URL,
    /// missing host, unknown host) is logged and
    /// ignored — this method never throws or crashes on bad input.
    func handle(_ url: URL) {
        guard let scheme = url.scheme, scheme.caseInsensitiveCompare("volar") == .orderedSame else {
            log("ignored URL with unexpected scheme: \(url.absoluteString)")
            return
        }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host,
            !host.isEmpty
        else {
            log("malformed or hostless URL, ignored: \(url.absoluteString)")
            return
        }
        let params = Self.queryDictionary(components)
        switch host {
        case "capture":
            handleCapture(params: params)
        default:
            log("unknown app-link host \(host), ignored")
        }
    }


    private func handleCapture(params: [String: String]) {
        guard let rawText = params["text"] else {
            log("capture link missing required text= param — ignored")
            return
        }
        // FIX 2 (abuse, reviewer): no length cap here previously — an arbitrarily large `text=`
        // could be handed straight into the parse pipeline. Same 2000-char cap
        // `CloudParser.maxTranscriptChars` enforces on typed/spoken transcripts
        // (Sources/Parsing/CloudParser.swift) — an app-link is just another capture entry point
        // and must not be able to smuggle a larger payload past it. `source` is cosmetic (stored
        // in notes) and capped shorter.
        let text = String(rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !text.isEmpty else {
            log("capture link text was empty after trimming — ignored")
            return
        }
        guard let onCapture else {
            log("capture link received before the capture pipeline hook was wired — dropped")
            return
        }
        let now = Date()
        if let last = lastCaptureAt, now.timeIntervalSince(last) < 2 {
            log("capture link arrived < 2 s after the previous one — ignored")
            return
        }
        lastCaptureAt = now
        let source = params["source"].map { String($0.prefix(200)) }
        onCapture(text, source)
    }

    // MARK: - Parsing helpers

    private static func queryDictionary(_ components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            result[item.name] = value
        }
        return result
    }

    private func log(_ message: String) {
        // Local-only diagnostic (Constitution I: inbound signals are logged locally, never
        // shipped anywhere) — mirrors `TaskStore`'s existing `print("[Volar...")` convention
        // (see `TaskStore.sanitizedConditions`).
        print("[Volar.AppLinkHandler] \(message)")
    }
}
