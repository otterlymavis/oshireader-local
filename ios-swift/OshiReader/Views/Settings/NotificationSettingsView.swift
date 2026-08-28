import SwiftUI

/// Root Settings row that drills into `NotificationSettingsView`. A separate view
/// so it can own `NotificationManager` — enough to show an attention badge when
/// local-alert permission still needs the user's action — without the root
/// Settings Form observing `NotificationManager`.
struct NotificationsSettingsLink: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager
    @StateObject private var notifications = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    private var needsAttention: Bool {
        notifications.authorizationStatus == .notDetermined
            || notifications.authorizationStatus == .denied
    }

    var body: some View {
        NavigationLink {
            NotificationSettingsView(theme: theme, i18n: i18n, appearance: appearance)
        } label: {
            HStack {
                Label(i18n.t("notificationsSection"), systemImage: "bell.badge")
                if needsAttention {
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityIdentifier("settings.notificationsLink")
        .accessibilityValue(needsAttention ? i18n.t("notificationStatusNotRequested") : "")
        .onAppear { Task { await notifications.refreshAuthorizationStatus() } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await notifications.refreshAuthorizationStatus() }
        }
    }
}

/// Drill-down page for local-alert permission, background-refresh status, and
/// quiet hours. Owns `NotificationManager` so a permission-status publish only
/// re-evaluates this page, never the root Settings Form.
struct NotificationSettingsView: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager
    @StateObject private var notifications = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var quietHoursSettings = QuietHoursSettings.current()
    @State private var currentBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(i18n.t("notificationsSection"), systemImage: "bell.badge")
                    Spacer()
                    Text(notificationStatusText)
                        .foregroundColor(notifications.canScheduleNotifications ? theme.colors.primary : theme.colors.textMuted)
                }
                .accessibilityIdentifier("settings.notificationStatus")

                Label(i18n.t("notificationSetupHint"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)
                    .accessibilityIdentifier("settings.notificationSetupHint")

                HStack {
                    Label(i18n.t("localAlertBackgroundRefresh"), systemImage: "arrow.clockwise")
                    Spacer()
                    Text(backgroundRefreshStatusText)
                        .foregroundColor(backgroundRefreshStatusColor)
                }
                .accessibilityIdentifier("settings.localAlertBackgroundStatus")

                switch notifications.authorizationStatus {
                case .notDetermined:
                    Button {
                        Task { _ = await notifications.requestAuthorization() }
                    } label: {
                        Label(i18n.t("enableNotifications"), systemImage: "bell.badge.fill")
                            .foregroundColor(theme.colors.primary)
                    }
                    .accessibilityIdentifier("settings.enableNotificationsButton")
                case .denied:
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label(i18n.t("openIOSSettings"), systemImage: "gear")
                            .foregroundColor(theme.colors.primary)
                    }
                    .accessibilityIdentifier("settings.openSettingsButton")
                default:
                    EmptyView()
                }
            }

            Section {
                Toggle(i18n.t("quietHoursToggle"), isOn: Binding(
                    get: { quietHoursSettings.enabled },
                    set: { quietHoursSettings.enabled = $0; quietHoursSettings.save() }
                ))
                .tint(theme.colors.primary)
                .accessibilityIdentifier("settings.quietHoursToggle")

                if quietHoursSettings.enabled {
                    DatePicker(i18n.t("quietHoursStart"), selection: Binding(
                        get: { Self.date(fromMinuteOfDay: quietHoursSettings.startMinuteOfDay) },
                        set: { quietHoursSettings.startMinuteOfDay = Self.minuteOfDay(from: $0); quietHoursSettings.save() }
                    ), displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("settings.quietHoursStartPicker")

                    DatePicker(i18n.t("quietHoursEnd"), selection: Binding(
                        get: { Self.date(fromMinuteOfDay: quietHoursSettings.endMinuteOfDay) },
                        set: { quietHoursSettings.endMinuteOfDay = Self.minuteOfDay(from: $0); quietHoursSettings.save() }
                    ), displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("settings.quietHoursEndPicker")

                    Text(i18n.t("quietHoursFooter"))
                        .font(.caption)
                        .foregroundColor(theme.colors.textMuted)
                }
            }
        }
        .font(appearance.font(size: 13))
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("notificationsSection"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.notificationsScreen")
        .onAppear {
            currentBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
            quietHoursSettings = QuietHoursSettings.current()
            Task { await notifications.refreshAuthorizationStatus() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            currentBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
            Task { await notifications.refreshAuthorizationStatus() }
        }
    }

    private var notificationStatusText: String {
        switch notifications.authorizationStatus {
        case .authorized:
            return i18n.t("notificationStatusEnabled")
        case .provisional:
            return i18n.t("notificationStatusQuiet")
        case .denied:
            return i18n.t("notificationStatusDisabled")
        case .ephemeral:
            return i18n.t("notificationStatusTemporary")
        case .notDetermined:
            return i18n.t("notificationStatusNotRequested")
        @unknown default:
            return i18n.t("notificationStatusUnknown")
        }
    }

    private var backgroundRefreshStatusText: String {
        switch currentBackgroundRefreshStatus {
        case .available:
            return i18n.t("backgroundRefreshAvailable")
        case .denied:
            return i18n.t("backgroundRefreshDenied")
        case .restricted:
            return i18n.t("backgroundRefreshRestricted")
        @unknown default:
            return i18n.t("notificationStatusUnknown")
        }
    }

    private var backgroundRefreshStatusColor: Color {
        currentBackgroundRefreshStatus == .available
            ? theme.colors.primary
            : theme.colors.textMuted
    }

    private static func date(fromMinuteOfDay minutes: Int) -> Date {
        var comps = DateComponents()
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func minuteOfDay(from date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}
