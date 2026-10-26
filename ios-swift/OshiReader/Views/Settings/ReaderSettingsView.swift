import SwiftUI

/// Drill-down page for reader behaviour. Owns the `auto_translate_reader`
/// preference; the `UserDefaults` read is deferred to `.onAppear` instead of the
/// old eager read in `SettingsView.init`.
struct ReaderSettingsView: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager
    @StateObject private var profiles = LocalProfileStore.shared
    @StateObject private var feedTranslation = FeedTranslationState.shared

    @State private var autoTranslateReader = false
    @State private var translateFeed = false

    var body: some View {
        Form {
            Section {
                Toggle(i18n.t("autoTranslate"), isOn: $autoTranslateReader)
                    .tint(theme.colors.primary)
                    .accessibilityIdentifier("settings.autoTranslateToggle")
            }

            if FeedTranslationState.isSupported {
                Section {
                    Toggle(i18n.t("translateFeed"), isOn: $translateFeed)
                        .tint(theme.colors.primary)
                        .accessibilityIdentifier("settings.translateFeedToggle")
                    Text(i18n.t("translateFeedFooter"))
                        .font(.caption)
                        .foregroundColor(theme.colors.textMuted)
                }
            }

            if #available(iOS 26.0, *), translateFeed {
                NotificationTranslationSection(
                    theme: theme,
                    i18n: i18n,
                    headerKey: "translationLanguagesHeader",
                    footerKey: "feedTranslationFooter"
                )
            }
        }
        .font(appearance.font(size: 13))
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("readerSection"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.readerScreen")
        .onAppear {
            autoTranslateReader = readStoredValue(for: profiles.activeProfileID)
            translateFeed = feedTranslation.isEnabled(profileID: profiles.activeProfileID)
        }
        .onChange(of: profiles.activeProfileID) { _, profileID in
            autoTranslateReader = readStoredValue(for: profileID)
            translateFeed = feedTranslation.isEnabled(profileID: profileID)
        }
        .onChange(of: translateFeed) { _, enabled in
            guard enabled != feedTranslation.isEnabled(profileID: profiles.activeProfileID) else { return }
            feedTranslation.setEnabled(enabled, profileID: profiles.activeProfileID)
        }
        .onChange(of: autoTranslateReader) { _, enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: LocalProfileStore.defaultsKey("auto_translate_reader", profileID: profiles.activeProfileID)
            )
        }
    }

    private func readStoredValue(for profileID: UUID?) -> Bool {
        UserDefaults.standard.bool(
            forKey: LocalProfileStore.defaultsKey("auto_translate_reader", profileID: profileID)
        )
    }
}
