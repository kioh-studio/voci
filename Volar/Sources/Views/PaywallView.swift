// Sources/Views/PaywallView.swift — Volar Pro purchase sheet (paywall).
//
// UI ONLY. StoreKit plumbing (product loading, purchase, restore, server link/status round trip)
// already lives in `AppState`/`Entitlements` (specs/002-workflow-command-center/contracts/
// account-auth.md §3/§8) — this view never talks to `Entitlements` (a plain, non-`@MainActor`
// actor) directly, only reads `AppState`'s mirrored `@Observable` properties and calls its methods,
// exactly like every other tab in `SettingsView` does.
//
// Presented as a `.sheet` from `SettingsView`'s "Upgrade to Pro" button — this is now the ONLY
// purchase surface in the app (the old bare `productRow` pair inside `upgradeSection` is gone), so
// pricing/trial/plan copy can never drift between two independently-maintained UIs.
import SwiftUI
import StoreKit
import AppKit

struct PaywallView: View {
    /// Fired when a signed-out user taps the CTA. `Entitlements.purchase` (Entitlements.swift's
    /// `link(_:)`) throws `.notSignedIn` before the purchase can ever be recorded server-side, so
    /// attempting one while signed out is a guaranteed, confusing failure. Rather than let that
    /// round-trip happen and surface a technical error, the CTA routes here instead — the caller
    /// (`SettingsView`) dismisses this sheet and switches to the Account tab, where the existing
    /// sign-in forms already live. This view deliberately draws no sign-in UI of its own.
    var onNeedSignIn: () -> Void = {}

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Yearly pre-selected (the better deal whenever both products are available) — Apple's own
    /// paywall guidance recommends defaulting to the plan you want most people to land on.
    @State private var selected: VolarProduct = .yearly

    private var accentColors: Accent { appState.accent.accent }

    // MARK: - Fallback quota display

    /// Mirror của `supabase/functions/_shared/quota.ts` (DEFAULT_*_LIMIT_FREE/PRO). Chỉ dùng làm
    /// fallback hiển thị khi chưa có `subscriptionStatus` — server luôn là nguồn sự thật.
    private static let freeDailyLimit = 20
    private static let proDailyLimit = 500

    /// The Pro-tier daily caps advertised in `featureList` below. Deliberately NOT read from
    /// `appState.subscriptionStatus` unless the account is ALREADY Pro: that field mirrors the
    /// signed-in account's CURRENT tier limit, and this paywall's plan cards only ever render for a
    /// non-Pro account — so a signed-in free user's `subscriptionStatus?.speechLimit` is their FREE
    /// limit (e.g. 20), never the Pro number this screen is pitching (500). Trusting it
    /// unconditionally here would have shown "20 transcriptions a day" as the Pro benefit, which is
    /// exactly the kind of misleading copy the brief's "no bịa" constraint forbids. There is no live
    /// endpoint that answers "what would this account get on Pro" for a free account, so outside the
    /// already-Pro case the number is always the constant fallback above.
    private var displaySpeechLimit: Int {
        if appState.accountTier == .pro, let limit = appState.subscriptionStatus?.speechLimit {
            return limit
        }
        return Self.proDailyLimit
    }
    private var displayParseLimit: Int {
        if appState.accountTier == .pro, let limit = appState.subscriptionStatus?.parseLimit {
            return limit
        }
        return Self.proDailyLimit
    }

    // MARK: - Legal (Apple Guideline 3.1.2)

    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    // TODO(anh Khôi): thay bằng URL privacy policy thật trước khi submit — ASC cũng bắt buộc field này.
    private static let privacyURL = URL(string: "https://kioh.tech/volar/privacy")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            closeButton
            header
            if appState.accountTier == .pro {
                alreadyProBody
            } else {
                featureList
                planCards
                trialLine
                ctaButton
                if let accountError = appState.accountError {
                    Text(accountError)
                        .font(.system(size: 11.5))
                        // Was `VolarColor.destruct` (red) — a purchase/quota error is a warning
                        // state, not an irreversible destructive action, so it follows the same
                        // "no red for status" rule `SettingsView.accountCard` already applies to
                        // this exact `appState.accountError` value (see that file's identical row).
                        .foregroundStyle(VolarColor.reschedule)
                        .lineLimit(4)
                }
                restoreButton
                legalFooter
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(VolarColor.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .volarHairline(cornerRadius: 16)
        // A successful purchase (or a redeemed promo/restore that turns out to already be Pro)
        // flips `accountTier` via `refreshAccountState()` — closing the sheet automatically here
        // means the CTA's own success path doesn't need to know anything about sheet presentation.
        .onChange(of: appState.accountTier) { _, newTier in
            if newTier == .pro { dismiss() }
        }
    }

    // MARK: - Close

    private var closeButton: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                VolarIcon(.x, size: 11, color: VolarColor.textMut, weight: .medium)
                    .padding(6)
                    .background(VolarColor.veil(0.06))
                    .clipShape(Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay {
                    VolarIcon(.mic, size: 28, color: .white, weight: .regular)
                }
                .shadow(color: accentColors.glow, radius: 18, y: 6)

            Text("Volar Pro")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(VolarColor.textPri)

            Text("A much higher daily ceiling for cloud speech and parsing.")
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Feature list
    //
    // Every line here must stay factually true: the free tier ALREADY uses cloud speech and cloud
    // parsing (specs/002-workflow-command-center/contracts/account-auth.md §1) — Pro only raises
    // the daily ceiling. No "unlimited"/"no limits" wording anywhere, and no feature invented that
    // isn't real in `AppState`/`Entitlements` today.

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow(.waveform, "Cloud speech recognition — \(displaySpeechLimit) transcriptions a day (Free: \(Self.freeDailyLimit))")
            featureRow(.sparkle, "Cloud parsing & task breakdown — \(displayParseLimit) a day (Free: \(Self.freeDailyLimit))")
            // True by construction: entitlements are keyed on the ACCOUNT (`user_id`), not on the
            // device — `supabase/functions/_shared/auth.ts` resolves the tier from the signed-in
            // user's `entitlements` rows, so signing in on a second Mac carries Pro with it.
            featureRow(.bolt, "One subscription, every Mac you sign in on.")
        }
        .padding(14)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
    }

    private func featureRow(_ icon: VolarIconName, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VolarIcon(icon, size: 13, color: accentColors.solid, weight: .medium)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Plan cards

    private var planCards: some View {
        HStack(spacing: 10) {
            planCard(.monthly, product: appState.monthlyProduct)
            planCard(.yearly, product: appState.yearlyProduct)
        }
    }

    private var selectedProduct: Product? {
        selected == .monthly ? appState.monthlyProduct : appState.yearlyProduct
    }

    /// Real "cheaper than paying monthly" savings badge, computed from `Decimal` prices — never a
    /// hardcoded percentage (every non-US storefront prices these products differently, and Apple
    /// can reprice either tier independently). `nil` whenever either product hasn't loaded yet, or
    /// when the math doesn't actually come out ahead, so the badge never claims a saving the prices
    /// don't back.
    private var yearlySavingsPercent: Int? {
        guard let monthly = appState.monthlyProduct, let yearly = appState.yearlyProduct else { return nil }
        let yearlyIfPaidMonthly = monthly.price * 12
        guard yearlyIfPaidMonthly > 0 else { return nil }
        let savingsFraction = (yearlyIfPaidMonthly - yearly.price) / yearlyIfPaidMonthly
        guard savingsFraction > 0 else { return nil }
        // `Decimal` has no direct `floor`; truncating a POSITIVE `NSDecimalNumber` to `Int` drops
        // the fractional part exactly like `floor` would (e.g. 12.9% -> 12), so the badge never
        // rounds up past what the actual prices back.
        let percent = Int(truncating: NSDecimalNumber(decimal: savingsFraction * 100))
        return percent > 0 ? percent : nil
    }

    @ViewBuilder
    private func planCard(_ which: VolarProduct, product: Product?) -> some View {
        let isSelected = selected == which
        Button {
            selected = which
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(which == .monthly ? "Monthly" : "Yearly")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                    Spacer(minLength: 4)
                    if which == .yearly, let percent = yearlySavingsPercent {
                        Text("Save \(percent)%")
                            .font(Font.volarMono(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(VolarColor.done)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(VolarColor.done.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                if let product {
                    Text(product.displayPrice)
                        .font(Font.volarMono(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(VolarColor.textPri)
                    Text(which == .monthly ? "per month" : "per year")
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.textMut)
                } else {
                    Text("Unavailable")
                        .font(.system(size: 12))
                        .foregroundStyle(VolarColor.textMut)
                        .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? accentColors.surface : VolarColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? accentColors.solid : VolarColor.border, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(product == nil)
        .opacity(product == nil ? 0.6 : 1)
    }

    // MARK: - Trial line
    //
    // Real trial info only: `product.subscription?.introductoryOffer` is Apple's own source of
    // truth for whether/what trial is configured for THIS product on THIS storefront — never
    // hardcoded (a prior draft of this screen's copy said "14-day free trial" unconditionally,
    // which is exactly the kind of made-up number this file must not repeat).

    @ViewBuilder
    private var trialLine: some View {
        if let text = trialText {
            HStack(spacing: 6) {
                VolarIcon(.check, size: 11, color: VolarColor.done, weight: .medium)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textSec)
            }
        }
    }

    private var trialText: String? {
        guard let offer = selectedProduct?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial
        else { return nil }
        let period = offer.period
        let unitWord: String
        switch period.unit {
        case .day: unitWord = "day"
        case .week: unitWord = "week"
        case .month: unitWord = "month"
        case .year: unitWord = "year"
        @unknown default: unitWord = "period"
        }
        let price = selectedProduct?.displayPrice ?? ""
        return "\(period.value)-\(unitWord) free trial, then \(price)"
    }

    // MARK: - CTA

    private var isSignedIn: Bool { appState.accountEmail != nil }

    private var ctaButton: some View {
        Button {
            if isSignedIn {
                appState.purchase(selected)
            } else {
                onNeedSignIn()
            }
        } label: {
            HStack(spacing: 8) {
                if appState.accountBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isSignedIn ? "Subscribe" : "Sign in to subscribe")
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            // BUG FIX 2026-08-09 (tìm ra khi truy lỗi "sidebar bấm không vào" của anh Khôi, cùng
            // họ): `.background(accentColors.solid)` ngay dưới đây nằm NGOÀI `Button`, nên cái nền
            // accent 40pt mà mắt thấy KHÔNG thuộc label — với `.buttonStyle(.plain)` SwiftUI chỉ
            // hit-test phần label thực sự vẽ ra, tức chỉ mỗi chữ "Subscribe". Toàn bộ dải màu hai
            // bên chữ là vùng chết. Đây là nút MUA HÀNG: một cú bấm trượt ở đây là mất tiền thật,
            // và người dùng sẽ đọc nó thành "app hỏng" chứ không phải "bấm chưa trúng".
            //
            // Đối chiếu: plan picker ở `:253` đặt `.background` BÊN TRONG label nên label vẽ đầy và
            // hit test đúng — đó là lý do nó vẫn bấm tốt. Dấu hiệu nhận biết cả họ bug này là
            // `.background(` xuất hiện SAU `.buttonStyle(.plain)`.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(accentColors.solid)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Signed-out: always tappable (it only routes to sign-in, never purchases). Signed-in:
        // disabled while busy, or while the selected product hasn't actually loaded.
        .disabled(isSignedIn && (appState.accountBusy || selectedProduct == nil))
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            appState.restorePurchases()
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(VolarColor.textSec)
        .disabled(appState.accountBusy)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Already Pro

    private var alreadyProBody: some View {
        VStack(spacing: 10) {
            Text("You're on Volar Pro")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
            if let expiresText {
                Text(expiresText)
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textSec)
            }
            Button {
                openManageSubscriptions()
            } label: {
                Text("Manage subscription")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// `subscriptionStatus.expiresAt` is a raw ISO8601 `String`, not `Date` (`AccountModels.swift`'s
    /// own doc comment on why) — parsed defensively: a decode failure just omits the line instead of
    /// showing a garbled/placeholder date.
    private var expiresText: String? {
        guard let raw = appState.subscriptionStatus?.expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) {
            return "Renews \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) else { return nil }
        return "Renews \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// macOS has no `AppStore.showManageSubscriptions(in:)` equivalent (iOS-only StoreKit 2 call) —
    /// same approach `SettingsView.openManageSubscriptions()` already uses.
    private func openManageSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Legal footer (Apple Guideline 3.1.2)
    //
    // Plan name, length, price, and auto-renew disclosure in one place, plus tappable Terms +
    // Privacy links — all four required by the guideline. Derived from the SELECTED product so it
    // can never drift from what `planCards`/`ctaButton` are actually about to charge.

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(disclosureText)
                .font(.system(size: 10.5))
                .foregroundStyle(VolarColor.textMut)
                .lineSpacing(2)
            HStack(spacing: 10) {
                Button("Terms of Use") { NSWorkspace.shared.open(Self.termsURL) }
                    .buttonStyle(.plain)
                Button("Privacy Policy") { NSWorkspace.shared.open(Self.privacyURL) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(VolarColor.textSec)
        }
    }

    /// Subscription length rendered from the real `Product.SubscriptionPeriod` when the product has
    /// loaded, rather than a hardcoded "1 month"/"1 year" — the fallback strings are only used for
    /// the brief window before `AppState.startAccountLifecycle()`'s product fetch completes.
    private var selectedPeriodText: String {
        guard let period = selectedProduct?.subscription?.subscriptionPeriod else {
            return selected == .monthly ? "1 month" : "1 year"
        }
        let unitWord: String
        switch period.unit {
        case .day: unitWord = period.value == 1 ? "day" : "days"
        case .week: unitWord = period.value == 1 ? "week" : "weeks"
        case .month: unitWord = period.value == 1 ? "month" : "months"
        case .year: unitWord = period.value == 1 ? "year" : "years"
        @unknown default: unitWord = "period"
        }
        return "\(period.value) \(unitWord)"
    }

    private var disclosureText: String {
        let name = selectedProduct?.displayName ?? (selected == .monthly ? "Volar Pro Monthly" : "Volar Pro Yearly")
        let price = selectedProduct?.displayPrice ?? "—"
        return "\(name) — \(selectedPeriodText) — \(price). Subscriptions renew automatically unless auto-renew is turned off at least 24 hours before the end of the current period. Manage or cancel anytime in Settings > Apple ID > Subscriptions on your Mac."
    }
}

#Preview {
    PaywallView()
        .environment(AppState())
}
