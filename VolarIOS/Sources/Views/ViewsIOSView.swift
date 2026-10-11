// Sources/Views/ViewsIOSView.swift — Views tab (design/ios-companion/project/Views.dc.html).
// Add-a-view rows carry a muted `Soon` chip (contract D-L): those views don't exist on iOS.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

struct ViewsIOSView: View {
    @AppStorage("volar.view.goalRewards") private var goalRewardsOn = false

    private let upcoming: [(title: String, blurb: String)] = [
        ("Task board", "Columns by status when you do want the wide view."),
        ("Daily wins", "What you actually finished today, and a calm weekly review."),
        ("Soundscape", "Ambient sound that starts with focus and stops with it."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ScreenHeader("Views")
                    .padding(.bottom, 12)

                SectionLabel("Pinned")
                GroupedCard {
                    ValueRow(icon: "target", title: "Now", value: "always on", valueColor: IOSPalette.fg3, chevron: false)
                }
                .padding(.bottom, 14)

                SectionLabel("Customize")
                GroupedCard {
                    ToggleRow(icon: "flag", title: "Goal rewards", isOn: $goalRewardsOn)
                }
                .padding(.bottom, 14)

                SectionLabel("Add a view")
                GroupedCard {
                    ForEach(Array(upcoming.enumerated()), id: \.offset) { index, item in
                        if index > 0 { RowDivider(inset: 16) }
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(IOSFont.rowTitle).foregroundStyle(IOSPalette.fg)
                                Text(item.blurb).font(IOSFont.meta).foregroundStyle(IOSPalette.fg2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text("Soon")
                                .font(IOSFont.mono(12))
                                .foregroundStyle(IOSPalette.fg3)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(Capsule().stroke(IOSPalette.border, lineWidth: 1))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: 52)
                    }
                }
                .padding(.bottom, 14)

                GroupedCard {
                    NavigationLink {
                        SettingsIOSView()
                    } label: {
                        ValueRow(icon: "gearshape", title: "Settings", value: nil)
                    }
                    .buttonStyle(.plain)
                }

                HomeIndicatorSpacer()
                Color.clear.frame(height: 80) // clears the tab bar
            }
            .padding(.horizontal, IOSLayout.screenPadH)
            .padding(.top, 8)
        }
        .iosScreenBackground()
    }
}
