// Sources/Speech/HotkeyManager.swift — global ⌃⌥M (toggle-to-talk) + ⌃⌥T (typed capture) hotkeys
// (Carbon, sandbox-safe)
import Carbon.HIToolbox

/// Registers TWO system-wide hotkeys using Carbon's `RegisterEventHotKey`/`InstallEventHandler`:
/// ⌃⌥M ("press to toggle voice capture — press to start, press again to stop", unchanged since the
/// pre-second-hotkey version of this file) and ⌃⌥T ("open the typed-capture popup", new — see
/// `docs`/the task brief for "type → Add task → done"). Both share the same `InstallEventHandler`
/// registration (one handler, `kEventHotKeyPressed`/`kEventHotKeyReleased`, covers every hotkey
/// registered against `GetApplicationEventTarget()`) but each gets its OWN `RegisterEventHotKey`
/// call and its own `EventHotKeyRef` — see `start()`/`stop()` below for why that independence
/// matters (one hotkey's registration failing must never disable the other).
///
/// Why Carbon at all (unchanged rationale): `NSEvent.addGlobalMonitorForEvents` only delivers
/// events system-wide once the user has granted **Accessibility** permission, which is unacceptable
/// under Mac App Store review + App Sandbox (Volar.entitlements sets `com.apple.security.app-sandbox`).
/// `RegisterEventHotKey` is a first-class Carbon Event Manager API: sandbox-legal, needs no
/// permission prompt at all, and fires uniformly regardless of which app is frontmost, INCLUDING
/// Volar itself.
///
/// Public API is UNCHANGED from the single-hotkey version: same class name, same
/// `start(appState:onKeyDown:onKeyUp:)` / `stop()` signatures. `AppState.activateServices()` (the
/// only call site, `hotkey.start(appState: self)`, no closures) needs no changes — ⌃⌥T's dispatch
/// target is reached by calling `appState.openTextCapture()` directly from `handle(hotKeyID:isKeyDown:)`
/// below, the exact same pattern ⌃⌥M already used for `appState.handleHotkey()`. `onKeyDown`/
/// `onKeyUp` remain ⌃⌥M-only (never invoked for ⌃⌥T) — mirrors ⌃⌥M's own pre-existing "onKeyUp is
/// stored but intentionally never invoked" behavior (toggle mode never needed it either).
///
/// UNVERIFIED (authored on a Windows machine with no Xcode/Carbon to compile against — verify on
/// Mac): `import Carbon.HIToolbox` availability/name, `EventHandlerUPP`'s exact Swift-imported
/// closure signature, `EventTypeSpec`'s memberwise-init argument labels, whether
/// `GetApplicationEventTarget()`/`GetEventKind()` return optionals, that none of the Carbon Event
/// Manager hot-key APIs used here are deprecated-and-removed on the macOS 14 SDK floor, AND (new to
/// this file) the exact `GetEventParameter(..., kEventParamDirectObject, typeEventHotKeyID, ...)`
/// call shape used in `carbonEventHandler` below to identify which of the two hotkeys fired — this
/// is a widely-used Carbon idiom (the standard way to read an `EventHotKeyID` back out of a hotkey
/// event) but has never been compiled against a real Carbon.HIToolbox header on this machine.
@MainActor
final class HotkeyManager {
    // MARK: - Hotkey identity

    /// `kVK_ANSI_M` = 46 — ⌃⌥M, unchanged from the single-hotkey version.
    private static let hotkeyKeyCodeCapture = UInt32(kVK_ANSI_M)
    /// `kVK_ANSI_T` — ⌃⌥T, new: "add a task by typing" (see `AppState.openTextCapture()`).
    private static let hotkeyKeyCodeTextCapture = UInt32(kVK_ANSI_T)
    /// `kVK_ANSI_N` — ⌃⌥N, "N for NOW": show Glance.
    private static let hotkeyKeyCodeGlance = UInt32(kVK_ANSI_N)
    /// Carbon's legacy Menu-Manager-style modifier bitmask (`controlKey`/`optionKey` from
    /// <HIToolbox/Events.h>), NOT `NSEvent.ModifierFlags`. Same physical combo (Control+Option) for
    /// both hotkeys — only the letter differs.
    private static let hotkeyModifiers = UInt32(controlKey | optionKey)
    /// Four-char-code "app signature" shared by both hotkeys; the `id` is what
    /// `handle(hotKeyID:isKeyDown:)` actually dispatches on — `1` = ⌃⌥M (unchanged id from the
    /// single-hotkey version, so nothing about the FIRST hotkey's identity changes), `2` = ⌃⌥T.
    private static let hotkeyIDCapture = EventHotKeyID(signature: fourCharCode("Volar"), id: 1)
    private static let hotkeyIDTextCapture = EventHotKeyID(signature: fourCharCode("Volar"), id: 2)
    /// `3` = ⌃⌥N, Glance (`Sources/Views/GlanceHUD.swift`). Bấm-bật/bấm-tắt như ⌃⌥M — chế độ
    /// giữ-để-xem đã bỏ (anh Khôi 2026-08-24), nên `onGlanceUp` thường là `nil`. File này vẫn báo
    /// cả press lẫn release y như cũ: ai muốn dùng key-up thì gắn handler, không thì thôi.
    private static let hotkeyIDGlance = EventHotKeyID(signature: fourCharCode("Volar"), id: 3)

    /// Packs up to 4 ASCII characters into the `OSType`/`FourCharCode` Carbon expects for a
    /// hotkey signature — a plain arithmetic helper, no Carbon API involved.
    private static func fourCharCode(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for scalar in s.unicodeScalars.prefix(4) {
            result = (result << 8) | (scalar.value & 0xFF)
        }
        return result
    }

    // MARK: - Carbon handles (torn down in `stop()`)

    /// ⌃⌥M's registration. Kept in its own property (rather than an array/dictionary) so `stop()`
    /// can unregister each hotkey explicitly and independently, matching how `start()` registers
    /// them independently.
    private var hotKeyRefCapture: EventHotKeyRef?
    /// ⌃⌥T's registration — see `hotKeyRefCapture` above for why this is a separate property.
    private var hotKeyRefTextCapture: EventHotKeyRef?
    /// ⌃⌥N's registration — see `hotKeyRefCapture` above for why each gets its own property.
    private var hotKeyRefGlance: EventHotKeyRef?
    /// One shared event handler covers press/release for BOTH hotkeys (Carbon dispatches by
    /// matching `EventHotKeyID`, not by handler) — unchanged shape from the single-hotkey version.
    private var eventHandlerRef: EventHandlerRef?
    /// The `Unmanaged.passRetained(self)` pointer handed to Carbon as `userData` so the
    /// C-function-pointer callback (which cannot capture Swift context) can recover `self`.
    /// Retained on `start()`, released on `stop()`/a fully-failed `start()` — the only way this
    /// class avoids either a dangling pointer or a retain-cycle-shaped leak.
    private var retainedSelfPointer: UnsafeMutableRawPointer?

    /// ⌃⌥M's auto-repeat guard (unchanged name/semantics from the single-hotkey version — toggle
    /// mode: press starts/stops, key-up is accepted but never acted on).
    private var isDown = false
    /// ⌃⌥T's own auto-repeat guard. Deliberately a SEPARATE flag from `isDown` — the two hotkeys'
    /// key-down/key-up events are entirely independent and must never share bookkeeping (holding
    /// one down while tapping the other must not desync either guard).
    private var isTextDown = false
    /// ⌃⌥N's own auto-repeat guard. Load-bearing in a way the other two aren't: if OS key-repeat
    /// ever did redeliver a press, a repeated "down" would restart the hold timer and turn every
    /// long hold into a tap — i.e. peek would silently become pin.
    private var isGlanceDown = false
    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?
    /// ⌃⌥N press/release. Separate from `onKeyDown`/`onKeyUp` (which are ⌃⌥M-only by long-standing
    /// contract) so neither hotkey can ever be routed into the other's handler.
    private var onGlanceDown: (() -> Void)?
    private var onGlanceUp: (() -> Void)?
    /// Stored (weak) because the Carbon callback only receives `self` via `userData` — it has no
    /// way to also capture `appState` directly, so `start()` stashes it here instead. Weak to avoid
    /// `HotkeyManager` keeping `AppState` alive (matches the old code's `[weak appState]` capture).
    private weak var appState: AppState?

    /// Starts monitoring for BOTH ⌃⌥M and ⌃⌥T. `appState.handleHotkey()` fires on ⌃⌥M key-down
    /// (unchanged toggle semantics); `appState.openTextCapture()` fires on ⌃⌥T key-down (key-down
    /// only — "there is no hold-to-type" per the task brief; ⌃⌥T's key-up is delivered by the same
    /// shared handler but intentionally ignored, see `handle(hotKeyID:isKeyDown:)` below).
    /// `onKeyDown`/`onKeyUp` remain ⌃⌥M-only, same as before Carbon. Safe to call again without a
    /// prior `stop()` — any existing registration is torn down first. Glance handlers (set via
    /// `setGlanceHandlers` or the parameters here) are kept across `stop()`/`start()`.
    func start(
        appState: AppState,
        onKeyDown: (() -> Void)? = nil,
        onKeyUp: (() -> Void)? = nil,
        onGlanceDown: (() -> Void)? = nil,
        onGlanceUp: (() -> Void)? = nil
    ) {
        stop()
        self.appState = appState
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        // Glance handlers are attached once (setGlanceHandlers) and survive repeated start() calls.
        if let onGlanceDown { self.onGlanceDown = onGlanceDown }
        if let onGlanceUp { self.onGlanceUp = onGlanceUp }

        let selfPointer = Unmanaged.passRetained(self).toOpaque()
        retainedSelfPointer = selfPointer

        // One handler covers press AND release for BOTH hotkeys — Carbon tells them apart by the
        // `EventHotKeyID` carried on the event itself (see `carbonEventHandler` below), not by
        // having a separate handler per hotkey.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            HotkeyManager.carbonEventHandler,
            2,
            &eventTypes,
            selfPointer,
            &handlerRef
        )
        guard installStatus == noErr else {
            print("[Volar.HotkeyManager] InstallEventHandler failed: status \(installStatus)")
            Unmanaged<HotkeyManager>.fromOpaque(selfPointer).release()
            retainedSelfPointer = nil
            return
        }
        eventHandlerRef = handlerRef

        // ⌃⌥M and ⌃⌥T are registered INDEPENDENTLY, each in its own `RegisterEventHotKey` call with
        // its own success/failure handling — a conflict with another app owning one combo (e.g.
        // ⌃⌥T already bound elsewhere) must never prevent the OTHER hotkey from registering. This
        // is a deliberate change from the single-hotkey version's all-or-nothing failure path:
        // there, one hotkey meant one `guard ... else { return }` was correct; with two independent
        // hotkeys sharing one handler, a partial failure (one registered, one didn't) must still
        // leave the handler installed and the succeeding hotkey live.
        var registeredCaptureRef: EventHotKeyRef?
        let registerCaptureStatus = RegisterEventHotKey(
            Self.hotkeyKeyCodeCapture,
            Self.hotkeyModifiers,
            Self.hotkeyIDCapture,
            GetApplicationEventTarget(),
            0,
            &registeredCaptureRef
        )
        if registerCaptureStatus == noErr {
            hotKeyRefCapture = registeredCaptureRef
        } else {
            print("[Volar.HotkeyManager] RegisterEventHotKey(⌃⌥M) failed: status \(registerCaptureStatus)")
        }

        var registeredTextRef: EventHotKeyRef?
        let registerTextStatus = RegisterEventHotKey(
            Self.hotkeyKeyCodeTextCapture,
            Self.hotkeyModifiers,
            Self.hotkeyIDTextCapture,
            GetApplicationEventTarget(),
            0,
            &registeredTextRef
        )
        if registerTextStatus == noErr {
            hotKeyRefTextCapture = registeredTextRef
        } else {
            print("[Volar.HotkeyManager] RegisterEventHotKey(⌃⌥T) failed: status \(registerTextStatus)")
        }

        // ⌃⌥N (Glance) — registered independently for the same reason as the two above: another app
        // owning this combo must cost us Glance and nothing else.
        var registeredGlanceRef: EventHotKeyRef?
        let registerGlanceStatus = RegisterEventHotKey(
            Self.hotkeyKeyCodeGlance,
            Self.hotkeyModifiers,
            Self.hotkeyIDGlance,
            GetApplicationEventTarget(),
            0,
            &registeredGlanceRef
        )
        if registerGlanceStatus == noErr {
            hotKeyRefGlance = registeredGlanceRef
        } else {
            print("[Volar.HotkeyManager] RegisterEventHotKey(⌃⌥N) failed: status \(registerGlanceStatus)")
        }

        // Only tear the whole thing down (handler + retained pointer) if ALL THREE registrations
        // failed — at that point this instance has genuinely nothing to do and holding the retained
        // pointer/handler would just be a leak. A PARTIAL failure (any subset registered) is left
        // running: some hotkeys working is strictly better than silently disabling all of them over
        // one conflict, and each failure was already logged above.
        //
        // ⌃⌥N ADDED TO THIS CONDITION DELIBERATELY: it used to read `capture || text`, which — once
        // a third hotkey existed — would have removed the shared event handler in the case where
        // only Glance registered, leaving a live `EventHotKeyRef` whose events nothing listens to.
        guard hotKeyRefCapture != nil || hotKeyRefTextCapture != nil || hotKeyRefGlance != nil else {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
            Unmanaged<HotkeyManager>.fromOpaque(selfPointer).release()
            retainedSelfPointer = nil
            return
        }
    }

    /// Attaches ⌃⌥N's press/release handlers after the fact.
    ///
    /// Exists because `start()` is called from `AppState.activateServices()` (in `Shared/`, which
    /// knows nothing about Glance — a macOS-only surface), while the `GlanceController` that must
    /// receive these events is owned by `AppDelegate`. Assigning the two closures here avoids both
    /// widening the shared `activateServices()` signature and paying a full unregister/re-register
    /// cycle just to attach a callback. Safe before or after `start()`: the closures are only ever
    /// read at event time.
    func setGlanceHandlers(down: (() -> Void)?, up: (() -> Void)?) {
        onGlanceDown = down
        onGlanceUp = up
    }

    /// Unregisters BOTH hotkeys, removes the event handler, and releases the retained `self`
    /// pointer handed to Carbon — clears all in-progress hold state (Glance handlers are kept). Idempotent: safe to call when
    /// nothing (or only one of the two hotkeys) is registered.
    func stop() {
        if let hotKeyRefCapture {
            UnregisterEventHotKey(hotKeyRefCapture)
        }
        hotKeyRefCapture = nil
        if let hotKeyRefTextCapture {
            UnregisterEventHotKey(hotKeyRefTextCapture)
        }
        hotKeyRefTextCapture = nil
        if let hotKeyRefGlance {
            UnregisterEventHotKey(hotKeyRefGlance)
        }
        hotKeyRefGlance = nil
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
        if let retainedSelfPointer {
            Unmanaged<HotkeyManager>.fromOpaque(retainedSelfPointer).release()
        }
        retainedSelfPointer = nil
        isDown = false
        isTextDown = false
        isGlanceDown = false
        onKeyDown = nil
        onKeyUp = nil
        appState = nil
    }

    // No `deinit`: teardown happens via `stop()`. Same reasoning as the single-hotkey version —
    // `start()` hands Carbon `Unmanaged.passRetained(self)`, which keeps this instance alive for as
    // long as either `EventHotKeyRef` is registered, and `stop()` is the only thing that releases
    // that pointer. Swift 6 also forbids a `deinit` on a `@MainActor`-isolated class from touching
    // actor-isolated stored properties like these, so even if reachable it could not be written
    // this way.

    /// Dispatches on WHICH hotkey fired (`hotKeyID.id`, extracted from the raw Carbon event by
    /// `carbonEventHandler` below) and whether this is press or release. ⌃⌥M keeps its EXACT
    /// pre-existing toggle-to-talk semantics (auto-repeat guard via `isDown`, key-up intentionally
    /// a no-op). ⌃⌥T is key-down only: no hold-to-type, opens the typed-capture popup on every
    /// non-repeated press and otherwise does nothing (its own `isTextDown` guard exists purely to
    /// ignore OS-level key-repeat, mirroring `isDown`'s role for ⌃⌥M).
    private func handle(hotKeyID: EventHotKeyID, isKeyDown: Bool) {
        guard let appState else { return }
        switch hotKeyID.id {
        case Self.hotkeyIDCapture.id:
            if isKeyDown {
                // Defensive: Carbon hot keys are not expected to redeliver `kEventHotKeyPressed` on
                // OS-level key-repeat, but this guard costs nothing and keeps the exact same
                // anti-double-toggle behavior the single-hotkey version had.
                guard !isDown else { return }
                isDown = true
                // Real hotkey entry point — routes through `handleHotkey()` (not `toggleCapture()`)
                // so a press while a confirm card is already up (`captureState == .parsed`) SAVES
                // it instead of blowing it away to start a brand-new recording; see
                // `handleHotkey()`'s own doc comment in `AppState.swift` for the full state table
                // (which, as of this file's change, also closes the ⌃⌥T text-capture popup first if
                // it happens to be open — "whichever hotkey the user pressed wins").
                appState.handleHotkey()
                onKeyDown?()
            } else {
                isDown = false
                // onKeyUp intentionally not invoked — matches the pre-existing behavior: toggle
                // mode has no use for key-up, and AppState.activateServices() never passes a
                // closure for it.
            }
        case Self.hotkeyIDGlance.id:
            // `isGlanceDown` chống auto-repeat: Carbon bắn press liên tục khi phím bị giữ, mà
            // `hotkeyDown()` nay là toggle — không chặn thì giữ phím sẽ nhấp nháy thẻ.
            if isKeyDown {
                guard !isGlanceDown else { return }
                isGlanceDown = true
                onGlanceDown?()
            } else {
                isGlanceDown = false
                onGlanceUp?()
            }
        case Self.hotkeyIDTextCapture.id:
            guard isKeyDown else {
                // Key-up delivered (same shared handler as ⌃⌥M) but deliberately ignored — ⌃⌥T has
                // no hold-to-type behavior, only "open on press".
                isTextDown = false
                return
            }
            guard !isTextDown else { return }
            isTextDown = true
            // `AppState.openTextCapture()` itself handles the mutual-exclusion rule (closes any
            // in-flight voice recording/confirm card/consent prompt first) — nothing extra needed
            // here beyond the auto-repeat guard above.
            appState.openTextCapture()
        default:
            // Unrecognized id — should be unreachable (only `hotkeyIDCapture`/`hotkeyIDTextCapture`
            // are ever registered), but dropped rather than guessed, same principle as a failed
            // `GetEventParameter` read in `carbonEventHandler` below.
            break
        }
    }

    /// The actual Carbon callback. Must be a context-free `@convention(c)` function (or, as here, a
    /// closure literal with no captures assigned to a `static let` of the matching type) since
    /// Carbon invokes it as a raw C function pointer — it cannot capture `self`. `self` instead
    /// travels through `userData`, using the `Unmanaged` retained-pointer pattern set up in
    /// `start()`. `nonisolated` for the same reason as before: Carbon calls this as a raw
    /// `@convention(c)` function pointer, from whatever thread the event arrives on, and Swift 6
    /// refuses to form a C function pointer from an actor-isolated closure.
    ///
    /// NEW (second hotkey): recovers WHICH hotkey fired via `GetEventParameter(...,
    /// kEventParamDirectObject, typeEventHotKeyID, ...)` — the single-hotkey version never needed
    /// this since only one hotkey (and therefore only one possible `EventHotKeyID`) existed. If
    /// extraction fails for ANY reason (non-`noErr` status), the event is DROPPED entirely rather
    /// than guessing which hotkey it was — firing the wrong capture surface (e.g. starting a voice
    /// recording when the user meant to open the typed popup) off an unidentifiable event is worse
    /// than silently missing one keypress.
    // UNVERIFIED: see file header — the exact `GetEventParameter` call shape (buffer-size/out-param
    // arrangement) below has never been compiled against a real Carbon.HIToolbox header.
    private nonisolated static let carbonEventHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else { return noErr }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        let isKeyDown = GetEventKind(eventRef) == UInt32(kEventHotKeyPressed)

        var hotKeyID = EventHotKeyID()
        let paramStatus = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard paramStatus == noErr else { return noErr }

        Task { @MainActor in
            manager.handle(hotKeyID: hotKeyID, isKeyDown: isKeyDown)
        }
        return noErr
    }
}
