import SwiftUI

struct SettingsView: View {
    @StateObject private var db = LocalDB.shared
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var i18n = I18nManager.shared
    @StateObject private var appearance = AppearanceManager.shared

    @State private var activeSheet: SettingsSheet?
    @State private var showingAliasLimitMessage = false

    // Add-keyword form state — bound into `AddKeywordSheet`, which the root's
    // consolidated `.sheet(item:)` presents.
    @State private var newKeyword = ""
    @State private var newCollectionMode = "all_info"
    @State private var newSourceMode: SourceMode = .all
    @State private var newSelectedPlatforms = Set<String>()

    /// Computed once — `PlatformRegistry.all` is a static catalog, so there's no
    /// need to rebuild this mapping on every body evaluation / row.
    static let allPlatforms: [(String, String)] = PlatformRegistry.all.map { ($0.id, "\($0.icon) \($0.name)") }
    private var allPlatforms: [(String, String)] { Self.allPlatforms }

    // Refresh time grows roughly linearly with active term count since
    // ingestion only runs a few terms concurrently — past this many, a
    // full refresh is noticeably slower, so nudge the user rather than
    // hard-blocking additional terms.
    static let manyActiveTermsThreshold = 15

    private var sheetDismissBinding: Binding<Bool> {
        Binding(get: { activeSheet != nil }, set: { if !$0 { activeSheet = nil } })
    }

    static func shouldShowHostedSourceStatus(
        isPaidConfigured: Bool,
        hasActiveEntitlement: Bool
    ) -> Bool {
        isPaidConfigured && hasActiveEntitlement
    }

    static func shouldShowPaidDiagnostics(
        isPaidConfigured: Bool,
        hasActiveEntitlement: Bool
    ) -> Bool {
        isPaidConfigured && hasActiveEntitlement
    }

    var body: some View {
        NavigationStack {
            Form {
                WatchTermsSection(
                    db: db,
                    theme: theme,
                    i18n: i18n,
                    onAddKeyword: { activeSheet = .addKeyword },
                    onAliasLimitReached: { showingAliasLimitMessage = true }
                )

                // Section: Subscribed Platforms
                Section {
                    Button(action: { activeSheet = .platformSubscription }) {
                        HStack {
                            Label(i18n.t("platformSettings"), systemImage: "dot.radiowaves.left.and.right")
                                .foregroundColor(theme.colors.text)
                            Spacer()
                            Text("\(db.subscribedPlatforms.count)/\(allPlatforms.count)")
                                .font(.subheadline)
                                .foregroundColor(theme.colors.textMuted)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(theme.colors.textMuted)
                        }
                    }
                    .accessibilityIdentifier("settings.platformMenu")
                }

                // Section: App configuration
                Section {
                    NavigationLink {
                        AppearanceSettingsView(
                            theme: theme,
                            i18n: i18n,
                            appearance: appearance,
                            hasWallpaper: db.wallpaper != nil,
                            onClearWallpaper: { db.setWallpaper(url: nil) }
                        )
                    } label: {
                        Label(i18n.t("appearanceSection"), systemImage: "paintbrush")
                    }
                    .accessibilityIdentifier("settings.appearanceLink")

                    NavigationLink {
                        ReaderSettingsView(theme: theme, i18n: i18n, appearance: appearance)
                    } label: {
                        Label(i18n.t("readerSection"), systemImage: "book")
                    }
                    .accessibilityIdentifier("settings.readerLink")

                    // Own view so it can observe NotificationManager for the
                    // attention badge without the root Form observing it.
                    NotificationsSettingsLink(theme: theme, i18n: i18n, appearance: appearance)

                    if PlusStore.isPaidPushConfigured {
                        NavigationLink {
                            PaidBackendSettingsView(theme: theme, i18n: i18n, appearance: appearance)
                        } label: {
                            Label(i18n.t("paidBackendSectionTitle"), systemImage: "server.rack")
                        }
                        .accessibilityIdentifier("settings.paidBackendLink")
                    }
                }

                // Section: Data & sync
                Section {
                    NavigationLink {
                        DataProfilesSettingsView(db: db, theme: theme, i18n: i18n, appearance: appearance)
                    } label: {
                        Label(i18n.t("dataAndProfilesSection"), systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier("settings.dataProfilesLink")

                    NavigationLink {
                        ICloudSyncSettingsView(theme: theme, i18n: i18n, appearance: appearance)
                    } label: {
                        Label(i18n.t("iCloudSyncSection"), systemImage: "icloud")
                    }
                    .accessibilityIdentifier("settings.iCloudSyncLink")
                }

                // Section: About
                Section {
                    NavigationLink {
                        CredentialsSettingsView(db: db, theme: theme, i18n: i18n, appearance: appearance)
                    } label: {
                        Label(i18n.t("credentialsSection"), systemImage: "key")
                    }
                    .accessibilityIdentifier("settings.credentialsLink")

                    NavigationLink(destination: PrivacyPolicyView(theme: theme)) {
                        Label(i18n.t("privacyPolicy"), systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("settings.privacyPolicyLink")
                }

                // Section: Source Status (local refresh diagnostics) — kept
                // last so the day-to-day controls above stay above the fold.
                SourceStatusSummarySection(theme: theme, i18n: i18n)
            }
            .font(appearance.font(size: 13))
            .accessibilityIdentifier("settings.screen")
            .navigationTitle(i18n.t("settingsTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .background(theme.colors.bg)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .addKeyword:
                    AddKeywordSheet(
                        db: db,
                        theme: theme,
                        i18n: i18n,
                        allPlatforms: allPlatforms,
                        isPresented: sheetDismissBinding,
                        keyword: $newKeyword,
                        collectionMode: $newCollectionMode,
                        sourceMode: $newSourceMode,
                        selectedPlatforms: $newSelectedPlatforms
                    )
                case .platformSubscription:
                    PlatformSubscriptionSheet(
                        db: db,
                        theme: theme,
                        i18n: i18n,
                        allPlatforms: allPlatforms,
                        isPresented: sheetDismissBinding
                    )
                }
            }
            .alert(i18n.t("addAlias"), isPresented: $showingAliasLimitMessage) {
                Button(i18n.t("ok"), role: .cancel) {}
            } message: {
                Text(i18n.t("aliasLimitReached"))
            }
        }
    }
}
