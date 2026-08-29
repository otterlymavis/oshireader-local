import SwiftUI

struct PrivacyPolicyView: View {
    let theme: ThemeManager
    @StateObject private var i18n = I18nManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                policySection(
                    title: i18n.t("privacyStoredTitle"),
                    body: i18n.t("privacyStoredBody")
                )

                policySection(
                    title: i18n.t("privacySentTitle"),
                    body: i18n.t("privacySentBody")
                )

                policySection(
                    title: i18n.t("privacyTrackingTitle"),
                    body: i18n.t("privacyTrackingBody")
                )

                policySection(
                    title: i18n.t("privacyPermissionsTitle"),
                    body: i18n.t("privacyPermissionsBody")
                )
            }
            .padding(18)
        }
        .accessibilityIdentifier("privacy.screen")
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("privacyPolicy"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policySection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(theme.colors.text)
            Text(body)
                .font(.body)
                .foregroundColor(theme.colors.textSub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
