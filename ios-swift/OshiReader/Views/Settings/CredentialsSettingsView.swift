import SwiftUI

/// Drill-down page for third-party API credentials. The Keychain read is
/// deferred to `.onAppear` (it used to run eagerly in `SettingsView.init`).
struct CredentialsSettingsView: View {
    @ObservedObject var db: LocalDB
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager

    @State private var twitterBearerToken = ""

    var body: some View {
        Form {
            Section(footer: Text(i18n.t("credentialsFooter"))) {
                if db.subscribedPlatforms.contains("twitter"),
                   twitterBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(i18n.t("twitterTokenMissingHint"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("settings.twitterTokenMissingHint")
                }
                SecureField(i18n.t("twitterBearerTokenPlaceholder"), text: $twitterBearerToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { KeychainHelper.save(.twitterBearerToken, twitterBearerToken) }
                    .onDisappear { KeychainHelper.save(.twitterBearerToken, twitterBearerToken) }
                    .accessibilityIdentifier("settings.twitterBearerTokenField")
            }
        }
        .font(appearance.font(size: 13))
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("credentialsSection"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.credentialsScreen")
        .onAppear { twitterBearerToken = KeychainHelper.read(.twitterBearerToken) ?? "" }
    }
}
