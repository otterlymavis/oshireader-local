import SwiftUI

/// Drill-down page for reader behaviour. Owns the `auto_translate_reader`
/// preference; the `UserDefaults` read is deferred to `.onAppear` instead of the
/// old eager read in `SettingsView.init`.
struct ReaderSettingsView: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager
    @StateObject private var profiles = LocalProfileStore.shared

    @State private var autoTranslateReader = false

    var body: some View {
        Form {
            Section {
                Toggle(i18n.t("autoTranslate"), isOn: $autoTranslateReader)
                    .tint(theme.colors.primary)
                    .accessibilityIdentifier("settings.autoTranslateToggle")
            }
        }
        .font(appearance.font(size: 13))
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("readerSection"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.readerScreen")
        .onAppear { autoTranslateReader = readStoredValue(for: profiles.activeProfileID) }
        .onChange(of: profiles.activeProfileID) { _, profileID in
            autoTranslateReader = readStoredValue(for: profileID)
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
