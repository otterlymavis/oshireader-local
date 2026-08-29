import SwiftUI

/// Drill-down page for theme, language, and typography. Observes only the
/// appearance-related stores; wallpaper state is passed in as a plain value so a
/// `LocalDB` feed-merge publish never re-evaluates this view.
struct AppearanceSettingsView: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager
    let hasWallpaper: Bool
    let onClearWallpaper: () -> Void

    var body: some View {
        Form {
            Section {
                Picker(i18n.t("appTheme"), selection: $theme.mode) {
                    Text(i18n.t("themeLight")).tag(AppThemeMode.light)
                    Text(i18n.t("themeDark")).tag(AppThemeMode.dark)
                    Text(i18n.t("themeSepia")).tag(AppThemeMode.sepia)
                }
                .pickerStyle(.segmented)

                Picker(i18n.t("themeStyle"), selection: $theme.style) {
                    ForEach(AppColorStyle.allCases) { style in
                        Text(displayName(for: style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.colorStylePicker")

                Picker(i18n.t("language"), selection: Binding(
                    get: { i18n.lang },
                    set: {
                        i18n.setLanguage($0)
                        NotificationManager.shared.registerNotificationCategories()
                    }
                )) {
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                    Text("繁體中文").tag("zh-TW")
                    Text("简体中文").tag("zh-CN")
                }

                Picker(i18n.t("font"), selection: $appearance.fontChoice) {
                    ForEach(AppFontChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.fontPicker")

                Picker(i18n.t("fontSize"), selection: $appearance.fontSizeChoice) {
                    ForEach(AppFontSizeChoice.allCases) { choice in
                        Text(displayName(for: choice)).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.fontSizePicker")

                if hasWallpaper {
                    Button(action: onClearWallpaper) {
                        Text(i18n.t("clearWallpaper"))
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .font(appearance.font(size: 13))
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("appearanceSection"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.appearanceScreen")
    }

    private func displayName(for style: AppColorStyle) -> String {
        switch style {
        case .colourful: return i18n.t("styleColourful")
        case .standard: return i18n.t("styleStandard")
        }
    }

    private func displayName(for choice: AppFontSizeChoice) -> String {
        switch choice {
        case .normal: return i18n.t("fontSizeNormal")
        case .large: return i18n.t("fontSizeLarge")
        case .extraLarge: return i18n.t("fontSizeExtraLarge")
        }
    }
}
