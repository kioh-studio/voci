// Sources/Views/AmbientBackground.swift — ambient particle background + vignette
import SwiftUI
import AppKit

/// Ports `volar-ambient.jsx`'s `AmbientBackground` canvas: a per-mode backdrop gradient with a
/// `TimelineView(.animation)` + `Canvas` particle system (rain streaks / snow dots / rising
/// ember "fireflies"), a custom-image layer, and a radial vignette on top. No Metal — matches
/// `app-architecture.md` §1/§6 (native-first, `Canvas`-only particles).
struct AmbientBackground: View {
    var mode: AmbientMode
    var imageURL: URL?
    var intensity: Double

    init(mode: AmbientMode, imageURL: URL? = nil, intensity: Double = 0.7) {
        self.mode = mode
        self.imageURL = imageURL
        self.intensity = intensity
    }

    /// Fixed animation-clock anchor. `TimelineView(.animation)` still needs a real, moving clock
    /// to animate at all — this only anchors *elapsed time*, not particle identity/position;
    /// initial particle placement below is seeded from the particle's index, never from `Date()`.
    @State private var startDate = Date()
    @State private var particles: [Particle] = []

    var body: some View {
        Group {
            switch mode {
            case .none:
                EmptyView()

            case .custom:
                ZStack {
                    Color(volar: 0x101014)
                    CustomImageLayer(url: imageURL)
                    vignette
                }

            case .rain, .snow, .embers:
                ZStack {
                    backdrop
                    TimelineView(.animation) { timeline in
                        Canvas { context, size in
                            draw(size: size, date: timeline.date, context: &context)
                        }
                    }
                    vignette
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { particles = makeParticles(mode: mode, intensity: intensity) }
        .onChange(of: mode) { _, newMode in particles = makeParticles(mode: newMode, intensity: intensity) }
        .onChange(of: intensity) { _, newIntensity in particles = makeParticles(mode: mode, intensity: newIntensity) }
    }

    // MARK: - Backdrop (`AMBIENT_BACKDROPS`)

    private var backdrop: LinearGradient {
        switch mode {
        case .rain:
            return LinearGradient(gradient: Gradient(stops: [
                .init(color: Color(volar: 0x0C1220), location: 0),
                .init(color: Color(volar: 0x101A2E), location: 0.55),
                .init(color: Color(volar: 0x090E1A), location: 1),
            ]), startPoint: .top, endPoint: .bottom)
        case .snow:
            return LinearGradient(gradient: Gradient(stops: [
                .init(color: Color(volar: 0x0E1422), location: 0),
                .init(color: Color(volar: 0x16203A), location: 0.60),
                .init(color: Color(volar: 0x0B101E), location: 1),
            ]), startPoint: .top, endPoint: .bottom)
        case .embers:
            return LinearGradient(gradient: Gradient(stops: [
                .init(color: Color(volar: 0x120D0C), location: 0),
                .init(color: Color(volar: 0x1C120E), location: 0.60),
                .init(color: Color(volar: 0x0D0908), location: 1),
            ]), startPoint: .top, endPoint: .bottom)
        case .none, .custom:
            return LinearGradient(colors: [Color(volar: 0x101014)], startPoint: .top, endPoint: .bottom)
        }
    }

    /// `radial-gradient(120% 90% at 50% 30%, transparent 40%, rgba(0,0,0,0.45) 100%)` so the
    /// content on top of the ambient scene still reads clearly.
    private var vignette: some View {
        GeometryReader { proxy in
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: Color.black.opacity(0.45), location: 1.0),
                ]),
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadius: 0,
                endRadius: max(proxy.size.width, proxy.size.height) * 0.65
            )
        }
    }

    // MARK: - Particle drawing

    private func draw(size: CGSize, date: Date, context: inout GraphicsContext) {
        let elapsed = date.timeIntervalSince(startDate)
        switch mode {
        case .rain: drawRain(size: size, elapsed: elapsed, context: &context)
        case .snow: drawSnow(size: size, elapsed: elapsed, context: &context)
        case .embers: drawEmbers(size: size, elapsed: elapsed, context: &context)
        case .none, .custom: break
        }
    }

    /// Rain streaks: `len rand(0.02,0.05) sp rand(0.55,1.25) o rand(0.10,0.34)*oMul`,
    /// `rgba(172,194,235,o)`. Falls top→bottom, wraps at `y > 1.04` back to `y = -0.06`.
    private func drawRain(size: CGSize, elapsed: Double, context: inout GraphicsContext) {
        let cycleLen = 1.10, top = -0.06
        let color = Color(red: 172.0 / 255, green: 194.0 / 255, blue: 235.0 / 255)
        for p in particles {
            let y01 = top + wrappedPhase(p.phase0, speed: p.speed, elapsed: elapsed, cycleLen: cycleLen)
            let x = p.x * size.width
            let y = y01 * size.height
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - p.size * size.height * 0.12, y: y + p.size * size.height))
            context.stroke(path, with: .color(color.opacity(p.opacity)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    /// Snow dots: `r rand(0.8,2.6) sp rand(0.03,0.09) o rand(0.18,0.6)*oMul`,
    /// `rgba(230,238,252,o)`, gentle horizontal drift via `sin(t*0.7+ph)`.
    private func drawSnow(size: CGSize, elapsed: Double, context: inout GraphicsContext) {
        let cycleLen = 1.06, top = -0.03
        let color = Color(red: 230.0 / 255, green: 238.0 / 255, blue: 252.0 / 255)
        for p in particles {
            let y01 = top + wrappedPhase(p.phase0, speed: p.speed, elapsed: elapsed, cycleLen: cycleLen)
            let xDrift = 0.02 * sin(elapsed * 0.7 + p.phase)
            let x = (p.x + xDrift) * size.width
            let y = y01 * size.height
            let rect = CGRect(x: x - p.size, y: y - p.size, width: p.size * 2, height: p.size * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(p.opacity)))
        }
    }

    /// Fireflies/embers: `r rand(1,2.6) sp rand(0.006,0.02) o rand(0.25,0.7)*oMul`, rising
    /// bottom→top, glowing via a shadow filter, pulsing via `0.45+0.55*abs(sin(t*1.4+ph))`.
    private func drawEmbers(size: CGSize, elapsed: Double, context: inout GraphicsContext) {
        let cycleLen = 1.06, bottom = 1.03
        let glow = Color(red: 1.0, green: 190.0 / 255, blue: 110.0 / 255)
        let fill = Color(red: 1.0, green: 198.0 / 255, blue: 122.0 / 255)
        for p in particles {
            let y01 = bottom - wrappedPhase(p.phase0, speed: p.speed, elapsed: elapsed, cycleLen: cycleLen)
            let xDrift = 0.02 * sin(elapsed * 0.35 + p.phase)
            let x = (p.x + xDrift) * size.width
            let y = y01 * size.height
            let pulse = 0.45 + 0.55 * abs(sin(elapsed * 1.4 + p.phase))
            let rect = CGRect(x: x - p.size, y: y - p.size, width: p.size * 2, height: p.size * 2)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: glow.opacity(0.8), radius: 9))
                layer.fill(Path(ellipseIn: rect), with: .color(fill.opacity(p.opacity * pulse)))
            }
        }
    }

    /// Both `phase0` (initial position within the fall/rise cycle) and `speed` are non-negative,
    /// so this is always in `[0, cycleLen)` — no need to guard against a negative remainder.
    private func wrappedPhase(_ phase0: Double, speed: Double, elapsed: Double, cycleLen: Double) -> Double {
        (phase0 + speed * elapsed).truncatingRemainder(dividingBy: cycleLen)
    }

    // MARK: - Particle generation (deterministic, index-seeded — never `Date`-seeded)

    private func makeParticles(mode: AmbientMode, intensity: Double) -> [Particle] {
        let base: Double
        switch mode {
        case .rain: base = 130
        case .snow: base = 90
        case .embers: base = 38
        case .none, .custom: base = 0
        }
        guard base > 0 else { return [] }

        let count = max(1, Int((base * intensity).rounded()))
        let oMul = 0.35 + 0.65 * intensity
        var result: [Particle] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            var gen = SplitMix64(seed: seed(for: mode, index: i))
            switch mode {
            case .rain:
                let x = Double.random(in: 0...1, using: &gen)
                let len = Double.random(in: 0.02...0.05, using: &gen)
                let sp = Double.random(in: 0.55...1.25, using: &gen)
                let o = Double.random(in: 0.10...0.34, using: &gen) * oMul
                let phase0 = Double.random(in: 0..<1.10, using: &gen)
                result.append(Particle(x: x, size: len, speed: sp, opacity: o, phase: 0, phase0: phase0))
            case .snow:
                let x = Double.random(in: 0...1, using: &gen)
                let r = Double.random(in: 0.8...2.6, using: &gen)
                let sp = Double.random(in: 0.03...0.09, using: &gen)
                let o = Double.random(in: 0.18...0.6, using: &gen) * oMul
                let ph = Double.random(in: 0..<6.28, using: &gen)
                let phase0 = Double.random(in: 0..<1.06, using: &gen)
                result.append(Particle(x: x, size: r, speed: sp, opacity: o, phase: ph, phase0: phase0))
            case .embers:
                let x = Double.random(in: 0.04...0.96, using: &gen)
                let r = Double.random(in: 1...2.6, using: &gen)
                let sp = Double.random(in: 0.006...0.02, using: &gen)
                let o = Double.random(in: 0.25...0.7, using: &gen) * oMul
                let ph = Double.random(in: 0..<6.28, using: &gen)
                let phase0 = Double.random(in: 0..<1.06, using: &gen)
                result.append(Particle(x: x, size: r, speed: sp, opacity: o, phase: ph, phase0: phase0))
            case .none, .custom:
                break
            }
        }
        return result
    }

    private func seed(for mode: AmbientMode, index: Int) -> UInt64 {
        let modeSalt: UInt64
        switch mode {
        case .rain: modeSalt = 0x1
        case .snow: modeSalt = 0x2
        case .embers: modeSalt = 0x3
        case .none, .custom: modeSalt = 0x0
        }
        return (UInt64(index) &+ 1) &* 0x9E37_79B9_7F4A_7C15 &+ modeSalt
    }
}

/// One ambient particle. A single shape serves rain/snow/embers; unused fields per-mode (e.g.
/// `phase` for rain, which has no horizontal wobble) are simply left at their default.
private struct Particle: Sendable {
    var x: Double
    var size: Double
    var speed: Double
    var opacity: Double
    var phase: Double
    var phase0: Double
}

/// Deterministic seeded RNG (SplitMix64) so particle fields are reproducible from `(mode, index)`
/// alone — required so re-generating the array never depends on wall-clock time.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `.custom` mode: an on-disk image (dimmed, cover-fit), or a placeholder hatch pattern with
/// hint text when no image has been chosen yet. Loaded via `SecureImageBookmark.loadImage`
/// (sandbox-safe) instead of a raw `NSImage(contentsOf: url)` call — see that type's docs.
///
/// Loads once (`.task`/`.onChange`, not inline in `body`) into `@State`, rather than decoding on
/// every `body` evaluation the way the pre-sandbox version did — a small incidental perf
/// improvement, not a full fix: this mode has no `TimelineView` driving it, so `body` was already
/// infrequent, but eager per-body decode was still there before. Bookmark resolution + decode
/// still happens synchronously on the main thread when it *does* run (kept in scope per the
/// feature 002 Phase 1 boundary — flagged for the reviewer, not refactored further here).
private struct CustomImageLayer: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .brightness(-0.45)
                    .saturation(0.9)
                    .clipped()
            } else {
                ZStack {
                    Color(volar: 0x14141A)
                    HatchPattern()
                    Text("Choose an image in Settings → Appearance")
                        .font(.system(size: 12, design: .monospaced))
                        .tracking(0.48)
                        .foregroundStyle(VolarColor.veil(0.28))
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: url) { _, _ in reload() }
    }

    private func reload() {
        image = SecureImageBookmark.loadImage(fallbackRawURL: url)
    }
}

/// Security-scoped bookmark plumbing for the custom ambient background image (App Sandbox — T002).
///
/// `AppState.customImageURL` / `AppState.setCustomImage` (frozen §4 surface, not edited here)
/// keep persisting a *raw file path* under their own `"volar.customImageURL"` UserDefaults key —
/// that storage is left exactly as-is. This type layers an independent, sandbox-safe bookmark on
/// top under a NEW key (`"volar.customImageBookmarkData"`), written by `SettingsView`'s image
/// picker (`SecureImageBookmark.save(for:)`, alongside — not instead of — `appState.setCustomImage`)
/// and consulted here and by `SettingsView`'s thumbnail, instead of trusting the raw path.
///
/// **One-time migration**: if no bookmark was ever saved (e.g. the image was picked on a build
/// before this sandbox migration shipped, or while sandboxing was off), `loadImage` falls back to
/// a direct `NSImage(contentsOf:)` read of the legacy raw path. Under App Sandbox that only
/// succeeds if the file happens to still be in an already-granted location (e.g. the very same
/// launch/session that picked it, since `NSOpenPanel` grants a transient extension); after a
/// relaunch it will typically fail and this degrades *silently* to "no image" (the hatch
/// placeholder below) — never a crash. The user just needs to re-pick once via Settings, which
/// writes a durable bookmark and this fallback is never needed again for that image.
enum SecureImageBookmark {
    private static let bookmarkKey = "volar.customImageBookmarkData"

    /// Creates a security-scoped bookmark for `url` and persists it. `url` should come straight
    /// from an active `NSOpenPanel` selection (or a previously-resolved security-scoped URL,
    /// which `loadImage` also feeds back through here on stale-bookmark refresh) — that is what
    /// grants the scope needed to create the bookmark data in the first place.
    static func save(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            // Best-effort only: if bookmark creation fails (e.g. `.withSecurityScope` can throw
            // when the app isn't actually sandboxed, or the URL wasn't panel-granted), skip
            // silently — the legacy raw-path fallback in `loadImage` still covers that case, and
            // nothing here should ever crash the Settings UI over a background-image picker.
        }
    }

    /// Clears the saved bookmark. Call when the user removes the custom image (`Remove` button in
    /// SettingsView), so a stale bookmark from a previously-chosen image never gets picked back up.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Resolves the bookmark, decodes an `NSImage` while the security scope is active, then stops
    /// accessing it before returning. `NSImage(contentsOf:)` decodes eagerly, so the returned
    /// image is fully backed by in-memory data and safe to keep/draw after the scope closes —
    /// `startAccessingSecurityScopedResource()`/`stopAccessingSecurityScopedResource()` stay
    /// correctly paired via `defer`, so a failed decode still releases the scope (no leaked
    /// file-handle/scope-count, which would otherwise quietly exhaust over repeated calls).
    ///
    /// Never throws: any failure — missing bookmark, stale/moved file, tampered UserDefaults data,
    /// decode failure — returns `nil` so callers show the placeholder instead of crashing. A
    /// tampered/corrupt bookmark blob specifically fails via the `catch` below (fails closed).
    static func loadImage(fallbackRawURL: URL?) -> NSImage? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return legacyRawLoad(fallbackRawURL)
        }

        var isStale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            return legacyRawLoad(fallbackRawURL)
        }

        guard resolved.startAccessingSecurityScopedResource() else { return nil }
        defer { resolved.stopAccessingSecurityScopedResource() }

        let image = NSImage(contentsOf: resolved)

        if isStale {
            // Re-mint the bookmark from the just-resolved URL so future loads don't keep paying
            // the staleness-resolution path, and so a subsequent underlying-location change
            // (e.g. the file moved within an already-granted folder) keeps being picked up.
            save(for: resolved)
        }
        return image
    }

    private static func legacyRawLoad(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// `repeating-linear-gradient(135deg, #14141a 0 14px, #17171e 14px 28px)` approximated as
/// diagonal stripes drawn on a `Canvas`.
private struct HatchPattern: View {
    var body: some View {
        Canvas { context, size in
            let period: CGFloat = 14
            let stripeColor = Color(volar: 0x17171E)
            let diagonal = size.width + size.height
            var x: CGFloat = -size.height
            while x < diagonal {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                context.stroke(path, with: .color(stripeColor), style: StrokeStyle(lineWidth: period / 2))
                x += period
            }
        }
    }
}
