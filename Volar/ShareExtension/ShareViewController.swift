// Volar/ShareExtension/ShareViewController.swift — the macOS Share Extension ("Volar" in any
// share sheet: Safari, Mail, Notes, Preview…).
//
// WHY THIS IS TINY, AND WHY THERE IS NO APP GROUP: the backlog entry for this originally assumed a
// shared container — extension writes, app reads. It doesn't need one. `volar://capture` already
// exists, is already registered, and already routes into the confirm-card-gated capture pipeline
// (`AppLinkHandler.onCapture` → `AppState.proceedToCapture`). So the extension's entire job is:
// pull text off the share, percent-encode it into that URL, hand it to the system, and get out of
// the way. No shared container, no entitlement pairing on the developer portal, no second copy of
// any parsing or storage code. See `docs/url-scheme.md` for the user-facing side of the same door.
//
// SCREEN-PRESENT, SO CONFIRM-CARD-GATED: the user just picked "Volar" out of a share sheet with
// their own hand. Eyes on screen, one glance is cheap, a mis-parsed date is catchable. Same rule as
// the Services menu, and deliberately different from Siri/Shortcuts (`Shared/Intents/`), which read
// the parse back aloud because nobody is looking. The rule is "show what you parsed through the
// channel the user is actually on" — see `Shared/Intents/IntentBridge.swift`'s header.
//
// NO UI ON PURPOSE: a share extension may present a compose sheet. This one doesn't — a second
// window to dismiss is exactly the context switch Volar exists to avoid, and Volar's own confirm
// card is about to appear anyway. Two review surfaces back-to-back would be worse than one.
//
// UNVERIFIED, and one specific thing to check first on the Mac: `NSExtensionContext.open(_:)` is
// the sanctioned way for an app extension to hand a URL to the system (`NSWorkspace` is not
// available to extensions). If it turns out to be refused for a share extension under the sandbox,
// the fallback is the app-group route this file was written to avoid — write the text to a shared
// container and have the main app drain it on activate. Do not reach for that fallback until the
// simple path has actually been observed to fail.
import AppKit
import Foundation

final class ShareViewController: NSViewController {

    /// Extensions are instantiated from the Info.plist principal class with no nib, so a view must
    /// be supplied explicitly. Zero-sized: nothing is ever shown.
    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        _Concurrency.Task { await run() }
    }

    private func run() async {
        guard let context = extensionContext else { return }

        guard let text = await Self.extractText(from: context), !text.isEmpty else {
            // Nothing usable was shared. Cancel rather than complete — cancelling is what tells the
            // host app "this did not happen", so the user isn't left thinking a task exists.
            context.cancelRequest(withError: ShareError.nothingToCapture)
            return
        }

        guard let url = Self.captureURL(text: text) else {
            context.cancelRequest(withError: ShareError.nothingToCapture)
            return
        }

        // Complete only after the host has taken the URL, or the extension can die before delivery.
        context.open(url) { @Sendable _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    // MARK: - Extraction

    /// Pulls the first usable string out of the share, preferring plain text and falling back to a
    /// URL's absolute string.
    ///
    /// Both are worth accepting: sharing a selection from Mail gives text, sharing the current page
    /// from Safari gives a URL, and "read this later" is a perfectly good task either way. The URL
    /// lands in the task text as-is — the parser keeps it, and the user can see what they saved.
    /// `nonisolated` deliberately: `NSViewController` is `@MainActor`, so without this these two
    /// statics inherit main-actor isolation — and the `NSItemProvider` completion handler below is
    /// invoked on an arbitrary background queue, which under Swift 6 strict concurrency is the
    /// "converting non-Sendable function value" error. Neither function touches any UI or any
    /// isolated state; they only shuttle strings.
    nonisolated private static func extractText(from context: NSExtensionContext) async -> String? {
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier("public.plain-text"),
                   let value = await loadString(provider, type: "public.plain-text") {
                    return value
                }
            }
        }
        // Second pass so plain text anywhere in the share always beats a URL — a page shared with a
        // quoted selection should capture the words, not the address.
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier("public.url"),
                   let value = await loadString(provider, type: "public.url") {
                    return value
                }
            }
        }
        // `attributedContentText` is what a plain "share this selection" often arrives as when no
        // attachment is attached at all.
        return items.compactMap { $0.attributedContentText?.string }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Bridges `NSItemProvider`'s completion-handler API into `async`, normalizing the three shapes
    /// a text/URL item can arrive as (`String`, `URL`, `Data`).
    nonisolated private static func loadString(_ provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                switch item {
                case let string as String: continuation.resume(returning: string)
                case let url as URL: continuation.resume(returning: url.absoluteString)
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - URL

    /// Builds `volar://capture?text=…&source=Share`.
    ///
    /// The 2000-character ceiling matches `AppLinkHandler.handleCapture` and
    /// `VolarServicesProvider.captureText` — every capture entry point caps at the same number, so
    /// none of them can hand the parse pipeline a bigger payload than the others. A shared web page
    /// can trivially exceed it.
    nonisolated static func captureURL(text raw: String) -> URL? {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !text.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "volar"
        components.host = "capture"
        // `URLComponents` percent-encodes these on `.url`, which is what keeps a shared sentence
        // containing `&`, `#`, or Vietnamese diacritics from breaking the URL.
        components.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "source", value: "Share")
        ]
        return components.url
    }

    enum ShareError: Swift.Error {
        case nothingToCapture
    }
}
