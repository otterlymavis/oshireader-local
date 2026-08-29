import SwiftUI

/// Drill-down page for iCloud sync. Owns `CloudSyncManager` so sync-status
/// publishes stay off the root Settings Form.
struct ICloudSyncSettingsView: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager
    @StateObject private var cloudSync = CloudSyncManager.shared
    @StateObject private var profiles = LocalProfileStore.shared

    var body: some View {
        Form {
            Section {
                if profiles.profiles.count > 1 {
                    Text(i18n.t("iCloudSyncMultiProfileUnavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(i18n.t("iCloudSyncToggle"), isOn: $cloudSync.isEnabled)
                        .tint(theme.colors.primary)
                        .accessibilityIdentifier("settings.iCloudSyncToggle")

                    if cloudSync.isEnabled {
                        HStack {
                            Text(i18n.t("iCloudSyncStatusLabel"))
                            Spacer()
                            Text(cloudSyncStatusText)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityIdentifier("settings.iCloudSyncStatus")

                        Button {
                            Task { await cloudSync.syncNow() }
                        } label: {
                            Label(i18n.t("iCloudSyncNow"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                        .disabled(cloudSync.status == .syncing)
                        .accessibilityIdentifier("settings.iCloudSyncNowButton")
                    }
                }
            } footer: {
                Text(i18n.t("iCloudSyncFooter"))
            }
        }
        .font(appearance.font(size: 13))
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("iCloudSyncSection"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.iCloudSyncScreen")
    }

    private var cloudSyncStatusText: String {
        switch cloudSync.status {
        case .idle:
            if let lastSyncedAt = cloudSync.lastSyncedAt {
                return relativeTimeString(from: lastSyncedAt)
            }
            return i18n.t("iCloudSyncNeverSynced")
        case .syncing:
            return i18n.t("iCloudSyncSyncing")
        case .succeeded(let date):
            return relativeTimeString(from: date)
        case .failed(let message):
            return message
        case .unavailable(let message):
            return message
        }
    }
}
