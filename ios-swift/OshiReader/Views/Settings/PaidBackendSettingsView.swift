import SwiftUI

/// Drill-down page for the optional paid hosted lane. Owns every paid/push store
/// it reads so their frequent publishes (push sync progress, entitlement
/// refreshes, backend errors) never re-evaluate the root Settings Form.
///
/// Only reached from a root `NavigationLink` gated on `PlusStore.isPaidPushConfigured`.
struct PaidBackendSettingsView: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager
    @StateObject private var plusStore = PlusStore.shared
    @StateObject private var pushSync = PushSyncCoordinator.shared
    @StateObject private var pushRegistry = PushTermRegistry.shared
    @StateObject private var paidBackend = PaidBackendFeedCoordinator.shared
    @StateObject private var notifications = NotificationManager.shared
    @StateObject private var profiles = LocalProfileStore.shared
    @AppStorage(PaidHostedDiagnosticReporter.consentKey) private var paidDiagnosticsEnabled = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(i18n.t("paidHostedFeedRefresh"), systemImage: "server.rack")
                    Spacer()
                    Text(i18n.t(plusStore.hasActiveEntitlement ? "paidStatusActive" : "paidStatusInactive"))
                        .foregroundColor(plusStore.hasActiveEntitlement ? .green : theme.colors.textMuted)
                }
                .accessibilityIdentifier("settings.paidBackendRefreshStatus")
                Text(i18n.t("paidFreeExplainer"))
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)
                HStack {
                    Label(i18n.t("paidRealtimePushTerms"), systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Text("\(plusStore.activePushTermCount)/\(plusStore.pushTermLimit)")
                        .foregroundColor(theme.colors.textMuted)
                }
                Text(i18n.t("paidBellAntennaExplainer"))
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)

                if SettingsView.shouldShowHostedSourceStatus(
                    isPaidConfigured: PlusStore.isPaidPushConfigured,
                    hasActiveEntitlement: plusStore.hasActiveEntitlement
                ) {
                    NavigationLink {
                        HostedSourceStatusView(theme: theme)
                    } label: {
                        Label(i18n.t("hostedSourceStatus"), systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("settings.hostedSourceStatus")
                }

                if SettingsView.shouldShowPaidDiagnostics(
                    isPaidConfigured: PlusStore.isPaidPushConfigured,
                    hasActiveEntitlement: plusStore.hasActiveEntitlement
                ) {
                    Toggle(i18n.t("paidDiagnosticsToggle"), isOn: $paidDiagnosticsEnabled)
                        .tint(theme.colors.primary)
                        .accessibilityIdentifier("settings.paidDiagnosticsToggle")
                    Text(i18n.t("paidDiagnosticsFooter"))
                        .font(.caption)
                        .foregroundColor(theme.colors.textMuted)
                }

                ForEach(plusStore.products, id: \.id) { product in
                    Button {
                        Task { await plusStore.purchase(product) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName)
                                Text(plusStore.billingLabel(for: product))
                                    .font(.caption2)
                                    .foregroundColor(theme.colors.textMuted)
                                if PlusStore.isOneWatchWordPlan(productID: product.id) {
                                    Text(i18n.t("paidOneTimeWatchWordPlan"))
                                        .font(.caption2)
                                        .foregroundColor(theme.colors.textMuted)
                                }
                            }
                            Spacer()
                            if plusStore.currentProductID == product.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(theme.colors.primary)
                            }
                            Text(product.displayPrice)
                        }
                    }
                    .disabled(plusStore.isPurchasing || plusStore.currentProductID == product.id)
                }
                // Under UI tests `loadProductsIfNeeded()` bails before touching
                // StoreKit, so `products` stays empty forever — rendering this
                // fallback there would add rows that shift every element below
                // it mid-test.
                if plusStore.products.isEmpty, !PlusStore.isUITesting {
                    if plusStore.isLoadingProducts {
                        HStack {
                            ProgressView()
                            Text(i18n.t("paidLoadingPurchases"))
                                .foregroundColor(theme.colors.textMuted)
                        }
                    } else {
                        Text(i18n.t("paidPurchasesUnavailable"))
                            .font(.caption)
                            .foregroundColor(theme.colors.textMuted)
                        Button(i18n.t("paidReloadPurchases")) {
                            Task { await plusStore.reloadProducts() }
                        }
                        .accessibilityIdentifier("settings.reloadPurchases")
                    }
                }
                Button(i18n.t("paidRestorePurchases")) { Task { await plusStore.restorePurchases() } }

                HStack {
                    Link(i18n.t("privacyPolicy"), destination: URL(string: "https://otterlymavis.github.io/oshireader-local/privacy/")!)
                    Text("·")
                        .foregroundColor(theme.colors.textMuted)
                    Link(i18n.t("termsOfUse"), destination: PlusStore.standardEULAURL)
                }
                .font(.caption2)
                .foregroundColor(theme.colors.textMuted)
                .accessibilityIdentifier("settings.paidBackendLegalLinks")

                if plusStore.pushDeliveryState == .selectionRequired {
                    Text(i18n.t("paidPushPausedSelection"))
                        .font(.caption)
                        .foregroundColor(.orange)
                    ForEach(pushRegistry.bindings) { binding in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(binding.keyword)
                                Text(profileName(for: binding.profileID))
                                    .font(.caption2)
                                    .foregroundColor(theme.colors.textMuted)
                            }
                            Spacer()
                            Button(i18n.t("paidDisable"), role: .destructive) {
                                Task { await pushSync.disable(binding) }
                            }
                        }
                    }
                } else if plusStore.pushDeliveryState == .inactive && !pushRegistry.bindings.isEmpty {
                    Text(i18n.t("paidPushPausedNoPurchase"))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if let message = plusStore.errorMessage
                    ?? pushSync.errorMessage
                    ?? notifications.lastRemoteRegistrationError {
                    Text(message).font(.caption).foregroundColor(.red)
                }
                if let message = paidBackend.errorMessage {
                    Text(message).font(.caption).foregroundColor(.orange)
                }
            }
            .accessibilityIdentifier("settings.guaranteedPushSection")
        }
        .font(appearance.font(size: 13))
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("paidBackendSectionTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.paidBackendScreen")
        .task { await plusStore.loadProductsIfNeeded() }
    }

    private func profileName(for profileID: UUID) -> String {
        profiles.profiles.first(where: { $0.id == profileID })?.name ?? "Unknown profile"
    }
}
