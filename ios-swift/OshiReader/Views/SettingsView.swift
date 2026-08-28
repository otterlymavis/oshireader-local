import SwiftUI
import UniformTypeIdentifiers

struct LocalBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct EncryptedBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.oshiReaderEncryptedBackup, .data] }
    static var writableContentTypes: [UTType] { [.oshiReaderEncryptedBackup] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LocalProfileTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.oshiReaderProfile, .data] }
    static var writableContentTypes: [UTType] { [.oshiReaderProfile] }

    var data: Data

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum EncryptedBackupOperation: String, Identifiable {
    case export
    case `import`

    var id: String { rawValue }
}

private enum ProfileNameMode: Equatable {
    case create
    case rename
}

/// The one modal sheet SettingsView presents. Consolidated into a single
/// `.sheet(item:)` — stacking several `.sheet(isPresented:)` on the Form
/// (alongside its many `.alert` / `.fileImporter` / `.fileExporter`) made an
/// earlier one intermittently fail to present after an unrelated re-render.
private enum SettingsSheet: Identifiable, Equatable {
    case addKeyword
    case platformSubscription
    case profileName(mode: ProfileNameMode, renameTarget: UUID?)
    case sourceStatus

    var id: String {
        switch self {
        case .addKeyword: return "addKeyword"
        case .platformSubscription: return "platformSubscription"
        case .profileName: return "profileName"
        case .sourceStatus: return "sourceStatus"
        }
    }
}

struct SettingsView: View {
    @StateObject private var db = LocalDB.shared
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var i18n = I18nManager.shared
    @StateObject private var appearance = AppearanceManager.shared
    @StateObject private var notifications = NotificationManager.shared
    @StateObject private var profiles = LocalProfileStore.shared
    @StateObject private var refreshDiagnostics = RefreshDiagnostics.shared
    @StateObject private var cloudSync = CloudSyncManager.shared
    @StateObject private var plusStore = PlusStore.shared
    @StateObject private var pushSync = PushSyncCoordinator.shared
    @StateObject private var pushRegistry = PushTermRegistry.shared
    @StateObject private var paidBackend = PaidBackendFeedCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var activeSheet: SettingsSheet?
    @State private var showingClearAllAlert = false
    @State private var newKeyword = ""
    @State private var newCollectionMode = "all_info"
    @State private var newSourceMode: SourceMode = .all
    @State private var newSelectedPlatforms = Set<String>()
    @State private var addingAliasForId: String? = nil
    @State private var newAliasText = ""
    // API token lives in the Keychain now that ingestion runs on-device.
    @State private var twitterBearerToken = KeychainHelper.read(.twitterBearerToken) ?? ""
    @State private var quietHoursSettings = QuietHoursSettings.current()
    @State private var autoTranslateReader = UserDefaults.standard.bool(
        forKey: LocalProfileStore.defaultsKey("auto_translate_reader")
    )
    @State private var backupDocument = LocalBackupDocument()
    @State private var showingBackupExporter = false
    @State private var showingBackupImporter = false
    @State private var diagnosticsDocument = LocalBackupDocument()
    @State private var showingDiagnosticsExporter = false
    @State private var opmlDocument = OPMLDocument()
    @State private var showingOPMLExporter = false
    @State private var encryptedBackupDocument = EncryptedBackupDocument()
    @State private var showingEncryptedBackupExporter = false
    @State private var showingEncryptedBackupImporter = false
    @State private var encryptedBackupOperation: EncryptedBackupOperation?
    @State private var isSubmittingEncryptedBackup = false
    @State private var encryptedBackupTask: Task<Void, Never>?
    @State private var encryptedBackupPassword = ""
    @State private var encryptedBackupConfirmation = ""
    @State private var encryptedBackupError = ""
    @State private var pendingEncryptedBackupData: Data?
    @State private var backupMessage = ""
    @State private var showingBackupMessage = false
    @State private var profileTransferDocument = LocalProfileTransferDocument()
    @State private var showingProfileExporter = false
    @State private var showingProfileImporter = false
    @State private var profileName = ""
    @State private var profileError = ""
    @State private var showingAliasLimitMessage = false
    @State private var isProfileSectionExpanded = ProcessInfo.processInfo.arguments.contains("--uitesting")
    @State private var isDataSectionExpanded = ProcessInfo.processInfo.arguments.contains("--uitesting")
    @State private var isCloudSyncSectionExpanded = ProcessInfo.processInfo.arguments.contains("--uitesting")
    @State private var isAppearanceSectionExpanded = ProcessInfo.processInfo.arguments.contains("--uitesting")
    // Stay expanded whenever there's something actionable (first launch, or
    // permission was denied) so the enable/open-settings button isn't hidden
    // behind an extra tap.
    @State private var isNotificationsSectionExpanded = ProcessInfo.processInfo.arguments.contains("--uitesting")
        || NotificationManager.shared.authorizationStatus == .notDetermined
        || NotificationManager.shared.authorizationStatus == .denied
    @State private var currentBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    @State private var notificationTermBeingUpdated: String?
    @AppStorage(PaidHostedDiagnosticReporter.consentKey) private var paidDiagnosticsEnabled = false
    
    /// Computed once — PlatformRegistry.all is a static catalog, so there's no
    /// need to rebuild this mapping on every body evaluation / row.
    static let allPlatforms: [(String, String)] = PlatformRegistry.all.map { ($0.id, "\($0.icon) \($0.name)") }
    private var allPlatforms: [(String, String)] { Self.allPlatforms }

    // Refresh time grows roughly linearly with active term count since
    // ingestion only runs a few terms concurrently — past this many, a
    // full refresh is noticeably slower, so nudge the user rather than
    // hard-blocking additional terms.
    static let manyActiveTermsThreshold = 15
    private var activeTermCount: Int { db.terms.lazy.filter(\.is_active).count }

    /// A `Binding<Bool>` for sheet children that dismiss themselves by setting
    /// `isPresented = false`; clearing it drops the single `activeSheet`.
    private var sheetDismissBinding: Binding<Bool> {
        Binding(get: { activeSheet != nil }, set: { if !$0 { activeSheet = nil } })
    }

    private var isProfileNameSheetActive: Bool {
        if case .profileName = activeSheet { return true }
        return false
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
                // Section: Keywords management
                Section(header: Text(i18n.t("watchTerms"))) {
                    ForEach(db.terms) { term in
                        TermRowView(
                            term: term,
                            avatarURL: db.oshiAvatars[term.keyword],
                            db: db,
                            theme: theme,
                            i18n: i18n,
                            allPlatforms: allPlatforms,
                            addingAliasForId: $addingAliasForId,
                            newAliasText: $newAliasText,
                            notificationTermBeingUpdated: $notificationTermBeingUpdated,
                            onSetNotificationEnabled: setNotificationEnabled,
                            showsGuaranteedPush: PlusStore.isPaidPushConfigured,
                            pushTermLimit: plusStore.pushTermLimit,
                            pushTermCount: plusStore.activePushTermCount,
                            pushTermBeingUpdated: pushSync.termBeingUpdated,
                            manualPushTermBeingUpdated: pushSync.manualOperationTermID,
                            onSetPushEnabled: { enabled, term in
                                await pushSync.setPushEnabled(enabled, for: term)
                            },
                            onNotifyPushNow: { term in
                                await pushSync.notifyPendingNow(for: term)
                            },
                            onClearPushPending: { term in
                                await pushSync.clearPendingNotification(for: term)
                            },
                            onAliasLimitReached: { showingAliasLimitMessage = true }
                        )
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let term = db.terms[index]
                            if addingAliasForId == term.id { addingAliasForId = nil }
                            db.deleteTerm(id: term.id)
                        }
                    }
                    
                    Button(action: { activeSheet = .addKeyword }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text(i18n.t("addKeyword"))
                        }
                        .foregroundColor(theme.colors.primary)
                    }
                    .accessibilityIdentifier("settings.addKeywordButton")

                    if activeTermCount > Self.manyActiveTermsThreshold {
                        Label(i18n.tFormat("manyActiveTermsWarning", activeTermCount), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .accessibilityIdentifier("settings.manyActiveTermsWarning")
                    }
                }

                if PlusStore.isPaidPushConfigured {
                    Section(header: Text("Paid Backend")) {
                    HStack {
                        Label("Hosted feed refresh", systemImage: "server.rack")
                        Spacer()
                        Text(plusStore.hasActiveEntitlement ? "Active" : "Inactive")
                            .foregroundColor(plusStore.hasActiveEntitlement ? .green : theme.colors.textMuted)
                    }
                    .accessibilityIdentifier("settings.paidBackendRefreshStatus")
                    Text("All reading, storage, on-device refresh, and local alerts remain free. A purchase adds hosted polling and guaranteed push.")
                        .font(.caption)
                        .foregroundColor(theme.colors.textMuted)
                    HStack {
                        Label("Real-time push terms", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text("\(plusStore.activePushTermCount)/\(plusStore.pushTermLimit)")
                            .foregroundColor(theme.colors.textMuted)
                    }
                    Text("The bell controls free best-effort local alerts. The antenna controls paid guaranteed push.")
                        .font(.caption)
                        .foregroundColor(theme.colors.textMuted)

                    if Self.shouldShowHostedSourceStatus(
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

                    if Self.shouldShowPaidDiagnostics(
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
                    Button("Restore Purchases") { Task { await plusStore.restorePurchases() } }

                    if plusStore.pushDeliveryState == .selectionRequired {
                        Text("Guaranteed push is paused. Disable terms until usage is within your current limit.")
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
                                Button("Disable", role: .destructive) {
                                    Task { await pushSync.disable(binding) }
                                }
                            }
                        }
                    } else if plusStore.pushDeliveryState == .inactive && !pushRegistry.bindings.isEmpty {
                        Text("Guaranteed push is paused because there is no active purchase. Free local alerts remain available.")
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
                .task { await plusStore.loadProductsIfNeeded() }
                }
                
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

                // Section: Reader
                Section(header: Text(i18n.t("readerSection"))) {
                    Toggle(i18n.t("autoTranslate"), isOn: $autoTranslateReader)
                        .tint(theme.colors.primary)
                        .accessibilityIdentifier("settings.autoTranslateToggle")
                }

                // Section: Local Storage & Profiles
                localStorageSection

                // Section: Customizations / Appearance
                Section {
                    DisclosureGroup(isExpanded: $isAppearanceSectionExpanded) {
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

                        // Language selection
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

                        // Wallpaper reset
                        if db.wallpaper != nil {
                            Button(action: { db.setWallpaper(url: nil) }) {
                                Text(i18n.t("clearWallpaper"))
                                    .foregroundColor(.red)
                            }
                        }
                    } label: {
                        Label(i18n.t("appearanceSection"), systemImage: "paintbrush")
                    }
                }

                // Section: Notifications
                Section {
                    DisclosureGroup(isExpanded: $isNotificationsSectionExpanded) {
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
                    } label: {
                        HStack {
                            Label(i18n.t("notificationsSection"), systemImage: "bell.badge")
                            Spacer()
                            Text(notificationStatusText)
                                .foregroundColor(notifications.canScheduleNotifications ? theme.colors.primary : theme.colors.textMuted)
                        }
                        .accessibilityIdentifier("settings.notificationStatus")
                    }
                }

                // Section: Source Status (Diagnostics)
                sourceStatusSection

                // Section: Credentials
                Section(
                    header: Text(i18n.t("credentialsSection")),
                    footer: Text(i18n.t("credentialsFooter"))
                ) {
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

                // Section: Privacy
                Section(header: Text(i18n.t("privacySection"))) {
                    NavigationLink(destination: PrivacyPolicyView(theme: theme)) {
                        Label(i18n.t("privacyPolicy"), systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("settings.privacyPolicyLink")
                }

                // Section: iCloud Sync
                iCloudSyncSection

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
                case let .profileName(mode, renameTarget):
                    ProfileNameSheet(
                        mode: mode,
                        db: db,
                        i18n: i18n,
                        isPresented: sheetDismissBinding,
                        name: $profileName,
                        errorText: $profileError,
                        profileToRename: renameTarget,
                        localizedError: localizedProfileMessage
                    )
                case .sourceStatus:
                    SourceStatusSheet(
                        summaries: refreshDiagnostics.visibleSourceHealthSummaries,
                        theme: theme
                    )
                }
            }
            .alert(i18n.t("clearAllDataAlert"), isPresented: $showingClearAllAlert) {
                Button(i18n.t("cancel"), role: .cancel) {}
                Button(i18n.t("delete"), role: .destructive) {
                    db.clearAllData()
                }
            } message: {
                Text(i18n.t("clearAllDataMessage"))
            }
            .sheet(item: $encryptedBackupOperation) { operation in
                EncryptedBackupPasswordSheet(
                    operation: operation,
                    password: $encryptedBackupPassword,
                    confirmation: $encryptedBackupConfirmation,
                    errorMessage: $encryptedBackupError,
                    isSubmitting: isSubmittingEncryptedBackup,
                    onCancel: cancelEncryptedBackupPrompt,
                    onSubmit: submitEncryptedBackupPrompt
                )
                .interactiveDismissDisabled(isSubmittingEncryptedBackup)
                .presentationDetents([.medium])
            }
            // Swipe-to-dismiss sets encryptedBackupOperation directly,
            // bypassing cancelEncryptedBackupPrompt — catch that path too so
            // an in-flight submission can't outlive the dismissed sheet.
            .onChange(of: encryptedBackupOperation) { _, newValue in
                if newValue == nil {
                    encryptedBackupTask?.cancel()
                    isSubmittingEncryptedBackup = false
                }
            }
            .fileExporter(
                isPresented: $showingBackupExporter,
                document: backupDocument,
                contentType: .json,
                defaultFilename: "oshireader-backup.json"
            ) { result in
                if case .failure(let error) = result {
                    backupMessage = localizedBackupMessage(error)
                    showingBackupMessage = true
                }
            }
            .fileExporter(
                isPresented: $showingDiagnosticsExporter,
                document: diagnosticsDocument,
                contentType: .json,
                defaultFilename: "oshireader-diagnostics.json"
            ) { result in
                if case .failure(let error) = result {
                    backupMessage = localizedBackupMessage(error)
                    showingBackupMessage = true
                }
            }
            .fileExporter(
                isPresented: $showingOPMLExporter,
                document: opmlDocument,
                contentType: .opml,
                defaultFilename: "oshireader.opml"
            ) { result in
                if case .failure(let error) = result {
                    backupMessage = localizedBackupMessage(error)
                    showingBackupMessage = true
                }
            }
            .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json]) { result in
                let data: Data
                do {
                    let url = try result.get()
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    guard let byteCount = fileByteCount(at: url),
                          byteCount <= Int64(LocalDB.maximumBackupBytes) else {
                        backupMessage = i18n.t("backupFileTooLarge")
                        showingBackupMessage = true
                        return
                    }
                    // Read eagerly (not mapped) so the buffer stays valid after
                    // the security-scoped access ends and the decode/normalize
                    // work can move off the main thread below.
                    data = try Data(contentsOf: url)
                } catch {
                    backupMessage = localizedBackupMessage(error)
                    showingBackupMessage = true
                    return
                }
                Task {
                    do {
                        try await db.importBackupDataOffMain(data)
                        backupMessage = i18n.t("backupImported")
                    } catch {
                        backupMessage = localizedBackupMessage(error)
                    }
                    showingBackupMessage = true
                }
            }
            .fileExporter(
                isPresented: $showingEncryptedBackupExporter,
                document: encryptedBackupDocument,
                contentType: .oshiReaderEncryptedBackup,
                defaultFilename: "oshireader-backup.oshireader"
            ) { result in
                if case .failure(let error) = result {
                    backupMessage = localizedBackupMessage(error)
                    showingBackupMessage = true
                }
            }
            .fileImporter(
                isPresented: $showingEncryptedBackupImporter,
                allowedContentTypes: [.oshiReaderEncryptedBackup, .data]
            ) { result in
                do {
                    let url = try result.get()
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    guard let byteCount = fileByteCount(at: url),
                          byteCount <= Int64(EncryptedBackupCodec.maximumEnvelopeBytes) else {
                        throw EncryptedBackupError.payloadTooLarge
                    }
                    pendingEncryptedBackupData = try Data(contentsOf: url, options: [.mappedIfSafe])
                    encryptedBackupPassword = ""
                    encryptedBackupConfirmation = ""
                    encryptedBackupError = ""
                    encryptedBackupOperation = .import
                } catch {
                    backupMessage = localizedBackupMessage(error)
                    showingBackupMessage = true
                }
            }
            .alert(i18n.t("backupStatus"), isPresented: $showingBackupMessage) {
                Button(i18n.t("ok"), role: .cancel) {}
            } message: {
                Text(backupMessage)
            }
            .fileExporter(
                isPresented: $showingProfileExporter,
                document: profileTransferDocument,
                contentType: .oshiReaderProfile,
                defaultFilename: "oshireader-profile.oshireaderprofile"
            ) { result in
                if case .failure(let error) = result { profileError = localizedProfileMessage(error) }
            }
            .fileImporter(isPresented: $showingProfileImporter, allowedContentTypes: [.oshiReaderProfile, .data]) { result in
                let data: Data
                do {
                    let url = try result.get()
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    guard let byteCount = fileByteCount(at: url),
                          byteCount <= Int64(LocalDB.maximumProfileTransferBytes) else { throw LocalProfileError.invalidPackage }
                    data = try Data(contentsOf: url)
                } catch {
                    profileError = localizedProfileMessage(error)
                    return
                }
                Task {
                    do {
                        let imported = try await db.importProfileTransferData(data)
                        profileError = i18n.t("profileImported").replacingOccurrences(of: "%@", with: imported.name)
                    } catch {
                        profileError = localizedProfileMessage(error)
                    }
                }
            }
            .alert(i18n.t("profileStatus"), isPresented: Binding(
                get: { !profileError.isEmpty && !isProfileNameSheetActive },
                set: { if !$0 { profileError = "" } }
            )) {
                Button(i18n.t("ok"), role: .cancel) { profileError = "" }
            } message: { Text(profileError) }
            .alert(i18n.t("addAlias"), isPresented: $showingAliasLimitMessage) {
                Button(i18n.t("ok"), role: .cancel) {}
            } message: {
                Text(i18n.t("aliasLimitReached"))
            }
        }
        .onChange(of: profiles.activeProfileID) { _, profileID in
            autoTranslateReader = UserDefaults.standard.bool(
                forKey: LocalProfileStore.defaultsKey("auto_translate_reader", profileID: profileID)
            )
        }
        .onChange(of: autoTranslateReader) { _, enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: LocalProfileStore.defaultsKey("auto_translate_reader", profileID: profiles.activeProfileID)
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            currentBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
            Task { await notifications.refreshAuthorizationStatus() }
        }
        .onChange(of: notifications.authorizationStatus) { _, status in
            guard status == .notDetermined || status == .denied else { return }
            isNotificationsSectionExpanded = true
        }
    }

    @ViewBuilder
    private var sourceStatusSection: some View {
        Section(header: Text(i18n.t("sourceStatusTitle"))) {
            HStack(spacing: 6) {
                Image(systemName: refreshDiagnostics.isRefreshing ? "arrow.triangle.2.circlepath" : "clock")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text(refreshDiagnostics.statusText)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundColor(theme.colors.textMuted)
            .accessibilityIdentifier("settings.refreshStatus")

            if !refreshDiagnostics.visibleSourceHealthSummaries.isEmpty || !refreshDiagnostics.sourceStatuses.isEmpty {
                Button {
                    activeSheet = .sourceStatus
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: refreshDiagnostics.hasSourceFailures ? "exclamationmark.triangle" : "chart.bar.xaxis")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(refreshDiagnostics.sourceSummaryText)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                    .foregroundColor(refreshDiagnostics.hasSourceFailures ? .orange : theme.colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.sourceStatus")
            }
        }
    }

    private var localStorageSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isProfileSectionExpanded) {
                ForEach(profiles.profiles) { profile in
                    HStack {
                        Button {
                            do {
                                try db.switchProfile(to: profile.id)
                            } catch {
                                profileError = localizedProfileMessage(error)
                            }
                        } label: {
                            HStack {
                                Image(systemName: profile.id == profiles.activeProfileID ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(profile.name)
                                    if profile.id == profiles.activeProfileID {
                                        Text(i18n.t("active"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.profile.\(profile.id.uuidString)")

                        Spacer()

                        Button {
                            profileName = profile.name
                            profileError = ""
                            activeSheet = .profileName(mode: .rename, renameTarget: profile.id)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel(i18n.t("renameProfile"))
                        .accessibilityIdentifier("settings.profileRename.\(profile.id.uuidString)")

                        Button(role: .destructive) {
                            do {
                                try db.deleteProfile(id: profile.id)
                            } catch {
                                profileError = localizedProfileMessage(error)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(i18n.t("deleteProfile"))
                        .accessibilityIdentifier("settings.profileDelete.\(profile.id.uuidString)")
                    }
                }

                Button {
                    profileName = ""
                    profileError = ""
                    activeSheet = .profileName(mode: .create, renameTarget: nil)
                } label: {
                    Label(i18n.t("addProfile"), systemImage: "plus")
                }
                .accessibilityIdentifier("settings.addProfileButton")

                Button {
                    do {
                        profileTransferDocument = LocalProfileTransferDocument(data: try db.exportProfileTransferData())
                        showingProfileExporter = true
                    } catch {
                        profileError = localizedProfileMessage(error)
                    }
                } label: {
                    Label(i18n.t("exportProfile"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.exportProfileButton")

                Button {
                    showingProfileImporter = true
                } label: {
                    Label(i18n.t("importProfile"), systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("settings.importProfileButton")

                Text(i18n.t("profilesFooter"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                HStack {
                    Label(i18n.t("profiles"), systemImage: "person.crop.circle")
                    Spacer()
                    Text(activeProfileName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            DisclosureGroup(isExpanded: $isDataSectionExpanded) {
                Button {
                    do {
                        backupDocument = LocalBackupDocument(data: try db.exportBackupData())
                        showingBackupExporter = true
                    } catch {
                        backupMessage = localizedBackupMessage(error)
                        showingBackupMessage = true
                    }
                } label: {
                    Label(i18n.t("exportBackup"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.exportBackupButton")

                Button {
                    if let data = RefreshDiagnostics.shared.exportHealthHistoryJSON() {
                        diagnosticsDocument = LocalBackupDocument(data: data)
                        showingDiagnosticsExporter = true
                    } else {
                        backupMessage = i18n.t("diagnosticsExportFailed")
                        showingBackupMessage = true
                    }
                } label: {
                    Label(i18n.t("exportDiagnostics"), systemImage: "stethoscope")
                }
                .accessibilityIdentifier("settings.exportDiagnosticsButton")

                Button {
                    opmlDocument = OPMLDocument(text: OPMLExporter.export(
                        terms: db.terms,
                        subscribedPlatforms: db.subscribedPlatforms,
                        customUrls: db.customUrls,
                        amebloBlogs: db.amebloBlogs,
                        generatedAt: Date()
                    ))
                    showingOPMLExporter = true
                } label: {
                    Label(i18n.t("exportOPML"), systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("settings.exportOPMLButton")

                Button {
                    showingBackupImporter = true
                } label: {
                    Label(i18n.t("importBackup"), systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("settings.importBackupButton")

                Button {
                    beginEncryptedExport()
                } label: {
                    Label(i18n.t("exportEncryptedBackup"), systemImage: "lock.square.stack")
                }
                .accessibilityIdentifier("settings.exportEncryptedBackupButton")

                Button {
                    showingEncryptedBackupImporter = true
                } label: {
                    Label(i18n.t("importEncryptedBackup"), systemImage: "lock.open")
                }
                .accessibilityIdentifier("settings.importEncryptedBackupButton")

                Button(role: .destructive) {
                    showingClearAllAlert = true
                } label: {
                    Label(i18n.t("clearAllData"), systemImage: "trash")
                }
                .accessibilityIdentifier("settings.clearAllDataButton")
            } label: {
                Label(i18n.t("dataSection"), systemImage: "externaldrive")
            }
        }
    }

    private var iCloudSyncSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isCloudSyncSectionExpanded) {
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

                Text(i18n.t("iCloudSyncFooter"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                Label(i18n.t("iCloudSyncSection"), systemImage: "icloud")
            }
        }
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

    private var activeProfileName: String {
        profiles.profiles.first { $0.id == profiles.activeProfileID }?.name ?? i18n.t("active")
    }

    private func beginEncryptedExport() {
        encryptedBackupPassword = ""
        encryptedBackupConfirmation = ""
        encryptedBackupError = ""
        encryptedBackupOperation = .export
    }

    private func cancelEncryptedBackupPrompt() {
        encryptedBackupTask?.cancel()
        // PBKDF2 itself can't be interrupted mid-derivation, so the
        // cancelled Task's own `defer` won't clear this until that
        // (now-orphaned, effect-free thanks to the isCancelled checks)
        // computation finally finishes. Reset it here instead, so
        // resubmitting right after cancelling isn't blocked by the
        // re-entry guard for however long that takes.
        isSubmittingEncryptedBackup = false
        encryptedBackupOperation = nil
        encryptedBackupPassword = ""
        encryptedBackupConfirmation = ""
        encryptedBackupError = ""
        pendingEncryptedBackupData = nil
    }

    private func submitEncryptedBackupPrompt() {
        // Making this async (to move PBKDF2 off the main thread) reopened a
        // double-tap window the old synchronous call implicitly closed by
        // freezing the UI — guard re-entry explicitly instead.
        guard !isSubmittingEncryptedBackup else { return }
        do {
            try EncryptedBackupCodec.validatePassword(encryptedBackupPassword)
        } catch {
            encryptedBackupError = localizedEncryptedBackupMessage(error)
            return
        }
        switch encryptedBackupOperation {
        case .export:
            guard encryptedBackupPassword == encryptedBackupConfirmation else {
                encryptedBackupError = i18n.t("passwordsDoNotMatch")
                return
            }
            let password = encryptedBackupPassword
            isSubmittingEncryptedBackup = true
            // exportEncryptedBackupData runs its PBKDF2 work off the main
            // thread; awaiting it here keeps this button tap from freezing
            // the UI for the duration of key derivation. Cancellation is
            // checked after the await since export doesn't mutate any
            // persisted state — there's nothing to undo, just UI to skip.
            encryptedBackupTask = Task {
                defer { isSubmittingEncryptedBackup = false }
                do {
                    let data = try await db.exportEncryptedBackupData(password: password)
                    guard !Task.isCancelled else { return }
                    encryptedBackupDocument = EncryptedBackupDocument(data: data)
                    encryptedBackupOperation = nil
                    encryptedBackupPassword = ""
                    encryptedBackupConfirmation = ""
                    // Deferred a tick so the sheet dismissal above (from
                    // clearing encryptedBackupOperation) settles before the
                    // file exporter presents — presenting immediately in the
                    // same update as a dismiss can silently no-op in SwiftUI.
                    DispatchQueue.main.async {
                        showingEncryptedBackupExporter = true
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    encryptedBackupError = localizedEncryptedBackupMessage(error)
                }
            }
        case .import:
            guard let data = pendingEncryptedBackupData else {
                encryptedBackupError = localizedEncryptedBackupMessage(EncryptedBackupError.invalidEnvelope)
                return
            }
            let password = encryptedBackupPassword
            isSubmittingEncryptedBackup = true
            encryptedBackupTask = Task {
                defer { isSubmittingEncryptedBackup = false }
                do {
                    // Unlike export, importBackupData mutates local data and
                    // can't be undone — decrypt (the slow PBKDF2 step) first,
                    // check for cancellation, and only then apply the import,
                    // instead of letting an already-cancelled request still
                    // overwrite the user's data.
                    let plaintext = try await Task.detached(priority: .userInitiated) {
                        try EncryptedBackupCodec.decrypt(data, password: password)
                    }.value
                    guard !Task.isCancelled else { return }
                    try await db.importBackupDataOffMain(plaintext)
                    encryptedBackupOperation = nil
                    encryptedBackupPassword = ""
                    pendingEncryptedBackupData = nil
                    backupMessage = i18n.t("backupImported")
                    showingBackupMessage = true
                } catch {
                    guard !Task.isCancelled else { return }
                    encryptedBackupError = localizedEncryptedBackupMessage(error)
                }
            }
        case nil:
            break
        }
    }

    private func localizedProfileMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "OshiReaderProfile", nsError.code == 5 {
            return i18n.t("profilePackageTooLarge")
        }
        guard let profileError = error as? LocalProfileError else { return error.localizedDescription }
        switch profileError {
        case .invalidName: return i18n.t("profileInvalidName")
        case .duplicateName: return i18n.t("profileDuplicateName")
        case .profileNotFound: return i18n.t("profileNotFound")
        case .cannotDeleteLastProfile: return i18n.t("cannotDeleteLastProfile")
        case .invalidPackage: return i18n.t("invalidProfilePackage")
        case .unsupportedPackageVersion: return i18n.t("unsupportedProfilePackageVersion")
        }
    }

    private func localizedEncryptedBackupMessage(_ error: Error) -> String {
        guard let backupError = error as? EncryptedBackupError else { return error.localizedDescription }
        switch backupError {
        case .invalidPassword: return i18n.t("encryptedBackupInvalidPassword")
        case .invalidEnvelope: return i18n.t("encryptedBackupInvalidEnvelope")
        case .unsupportedVersion: return i18n.t("encryptedBackupUnsupportedVersion")
        case .authenticationFailed: return i18n.t("encryptedBackupAuthenticationFailed")
        case .keyDerivationFailed: return i18n.t("encryptedBackupKeyDerivationFailed")
        case .payloadTooLarge: return i18n.t("encryptedBackupPayloadTooLarge")
        }
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

    private func localizedBackupMessage(_ error: Error) -> String {
        if let backupError = error as? EncryptedBackupError {
            return localizedEncryptedBackupMessage(backupError)
        }
        let nsError = error as NSError
        guard nsError.domain == "OshiReaderBackup" else { return error.localizedDescription }
        switch nsError.code {
        case 2:
            return i18n.t("backupTooManyPlatforms")
        case 3:
            return i18n.t("backupRestoreStagingIncomplete")
        case 4:
            return i18n.t("backupTooMuchData")
        case 5:
            return i18n.t("backupFileTooLarge")
        case 6:
            if nsError.localizedDescription == "Invalid restore staging path" {
                return i18n.t("backupInvalidRestoreStagingPath")
            }
            return i18n.t("backupInvalidRestoreManifest")
        default:
            return error.localizedDescription
        }
    }

    /// Byte size of a security-scoped file, or `nil` when the OS won't report
    /// it. `FileManager.attributesOfItem(atPath:)` is unreliable for
    /// document-picker / iCloud URLs; the old `?? 0` fallback made every
    /// `<= max` guard pass on failure and `Data(contentsOf:)` then loaded the
    /// whole file. Callers must treat `nil` as a hard failure.
    private func fileByteCount(at url: URL) -> Int64? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return Int64(size)
    }

    private func displayName(for style: AppColorStyle) -> String {
        switch style {
        case .colourful: return i18n.t("styleColourful")
        case .standard: return i18n.t("styleStandard")
        }
    }

    private func profileName(for profileID: UUID) -> String {
        profiles.profiles.first(where: { $0.id == profileID })?.name ?? "Unknown profile"
    }

    private func displayName(for choice: AppFontChoice) -> String {
        choice.displayName
    }

    private func displayName(for choice: AppFontSizeChoice) -> String {
        switch choice {
        case .normal: return i18n.t("fontSizeNormal")
        case .large: return i18n.t("fontSizeLarge")
        case .extraLarge: return i18n.t("fontSizeExtraLarge")
        }
    }

    private func setNotificationEnabled(_ enabled: Bool, for term: WatchTerm) async {
        if enabled {
            guard await notifications.requestAuthorizationIfNeededForLocalAlerts() else { return }
        }
        db.updateTerm(id: term.id, notifyOnNew: enabled)
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
}

private struct TermRowView: View {
    let term: WatchTerm
    /// Looked up by the parent (which observes `db`) so this row only
    /// depends on the one piece of `LocalDB` state it actually renders,
    /// instead of re-rendering on every unrelated `LocalDB` publish (e.g. a
    /// background refresh appending feed items).
    let avatarURL: String?
    /// Not observed — used only to invoke mutating methods (`updateTerm`),
    /// never read reactively in `body`.
    let db: LocalDB
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    let allPlatforms: [(String, String)]
    @Binding var addingAliasForId: String?
    @Binding var newAliasText: String
    @Binding var notificationTermBeingUpdated: String?
    let onSetNotificationEnabled: (Bool, WatchTerm) async -> Void
    let showsGuaranteedPush: Bool
    let pushTermLimit: Int
    let pushTermCount: Int
    let pushTermBeingUpdated: String?
    let manualPushTermBeingUpdated: String?
    let onSetPushEnabled: (Bool, WatchTerm) async -> Void
    let onNotifyPushNow: (WatchTerm) async -> Void
    let onClearPushPending: (WatchTerm) async -> Void
    let onAliasLimitReached: () -> Void
    @State private var showingSourceSelection = false

    var body: some View {
        HStack {
            NavigationLink(destination: AvatarEditorView(keyword: term.keyword)) {
                ZStack {
                    Circle()
                        .fill(theme.colors.divider)
                        .frame(width: 38, height: 38)
                    if let avatarURL, let url = URL(string: avatarURL) {
                        FeedThumbnailView(url: url, size: 38, cornerRadius: 19, placeholderText: "🎨")
                            .clipShape(Circle())
                    } else {
                        Text("🎨")
                            .font(.body)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(i18n.tFormat("editAvatarFmt", term.keyword))
            .accessibilityIdentifier("settings.keywordAvatar.\(term.keyword)")

            VStack(alignment: .leading, spacing: 4) {
                Text(term.keyword)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.colors.text)
                // Alias chips
                if !term.aliases.isEmpty || addingAliasForId == term.id {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(term.aliases, id: \.self) { alias in
                                HStack(spacing: 2) {
                                    Text(alias)
                                        .font(.caption2)
                                        .foregroundColor(theme.colors.textSub)
                                    Button {
                                        let updated = term.aliases.filter { $0 != alias }
                                        db.updateTerm(id: term.id, aliases: updated)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(theme.colors.textMuted)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(i18n.tFormat("removeAliasFmt", alias))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(theme.colors.divider)
                                .cornerRadius(99)
                            }
                            if addingAliasForId == term.id {
                                TextField(i18n.t("keyword"), text: $newAliasText)
                                    .font(.caption2)
                                    .frame(width: 80)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .submitLabel(.done)
                                    .onSubmit { commitAlias() }
                            }
                            Button {
                                if addingAliasForId == term.id {
                                    commitAlias()
                                } else {
                                    newAliasText = ""
                                    addingAliasForId = term.id
                                }
                            } label: {
                                Image(systemName: addingAliasForId == term.id ? "checkmark" : "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(theme.colors.primary)
                                    .frame(width: 20, height: 18)
                                    .background(theme.colors.primaryBg)
                                    .cornerRadius(99)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(addingAliasForId == term.id ? i18n.t("save") : i18n.t("addAlias"))
                        }
                    }
                } else {
                    Button {
                        newAliasText = ""
                        addingAliasForId = term.id
                    } label: {
                        Label(i18n.t("addAlias"), systemImage: "plus")
                            .font(.caption2)
                            .foregroundColor(theme.colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()

            Button {
                let next = term.collection_mode == "all_info" ? "media_only" : "all_info"
                db.updateTerm(id: term.id, collectionMode: next)
            } label: {
                Text(term.collection_mode == "media_only" ? "📹" : "📄")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.colors.divider)
                    .foregroundColor(theme.colors.textSub)
                    .clipShape(Capsule())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(term.collection_mode == "media_only" ? i18n.t("mediaOnly") : i18n.t("allInfo"))
            .accessibilityIdentifier("settings.keywordMode.\(term.keyword)")

            sourceSelectionButton

            // Push notifications bell button
            Button {
                guard notificationTermBeingUpdated == nil else { return }
                let next = !term.notify_on_new
                notificationTermBeingUpdated = term.id
                Task { @MainActor in
                    await onSetNotificationEnabled(next, term)
                    notificationTermBeingUpdated = nil
                }
            } label: {
                Image(systemName: term.notify_on_new ? "bell.fill" : "bell.slash")
                    .foregroundColor(term.notify_on_new ? theme.colors.primary : theme.colors.textMuted)
                    .font(.body)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(notificationTermBeingUpdated != nil)
            .accessibilityLabel("Local alerts")
            .accessibilityValue(term.notify_on_new ? "on" : "off")
            .accessibilityIdentifier("settings.keywordBell.\(term.keyword)")

            if showsGuaranteedPush {
                Button {
                    Task { await onSetPushEnabled(term.backendTermID == nil, term) }
                } label: {
                    Image(systemName: term.backendTermID == nil ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                        .foregroundColor(term.backendTermID == nil ? theme.colors.textMuted : theme.colors.primary)
                        .font(.body)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(
                    pushTermBeingUpdated != nil
                        || manualPushTermBeingUpdated != nil
                        || (term.backendTermID == nil && (pushTermLimit == 0 || pushTermCount >= pushTermLimit))
                )
                .accessibilityLabel("Guaranteed push")
                .accessibilityValue(term.backendTermID == nil ? "off" : "on")
                .accessibilityIdentifier("settings.keywordPush.\(term.keyword)")
                .contextMenu {
                    if PaidNotificationControlPolicy.showsPendingActions(backendTermID: term.backendTermID) {
                        Button {
                            Task { await onNotifyPushNow(term) }
                        } label: {
                            Label(i18n.t("paidPushNotifyNow"), systemImage: "bell.and.waves.left.and.right")
                        }
                        Button(role: .destructive) {
                            Task { await onClearPushPending(term) }
                        } label: {
                            Label(i18n.t("paidPushClearPending"), systemImage: "bell.slash")
                        }
                    }
                }
            }

            Toggle(i18n.t("active"), isOn: Binding(
                get: { term.is_active },
                set: { next in
                    db.updateTerm(id: term.id, isActive: next)
                }
            ))
            .labelsHidden()
            .tint(theme.colors.primary)
            .accessibilityLabel(i18n.t("active"))
            .accessibilityIdentifier("settings.keywordToggle.\(term.keyword)")
        }
        .accessibilityIdentifier("settings.keywordRow.\(term.keyword)")
    }

    private func commitAlias() {
        let trimmed = newAliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newAliasText = ""
            addingAliasForId = nil
            return
        }
        guard !term.aliases.contains(trimmed) else {
            newAliasText = ""
            addingAliasForId = nil
            return
        }
        if term.aliases.count >= IngestionService.maximumAliasesPerTerm {
            onAliasLimitReached()
        } else {
            db.updateTerm(id: term.id, aliases: term.aliases + [trimmed])
        }
        newAliasText = ""
        addingAliasForId = nil
    }

    private var sourceSelectionButton: some View {
        Button {
            showingSourceSelection = true
        } label: {
            Image(systemName: term.source_mode == .all ? "globe" : "line.3.horizontal.decrease.circle")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.colors.divider)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(i18n.t("sourceSelectionMenu"))
        .accessibilityIdentifier("settings.keywordSources.\(term.keyword)")
        .sheet(isPresented: $showingSourceSelection) {
            NavigationStack {
                List {
                    Button {
                        db.updateTerm(id: term.id, sourceMode: .all, selectedPlatforms: [])
                    } label: {
                        Label(i18n.t("allSources"), systemImage: term.source_mode == .all ? "checkmark.circle.fill" : "globe")
                    }
                    .accessibilityIdentifier("settings.keywordSourceAll.\(term.keyword)")

                    ForEach(allPlatforms, id: \.0) { key, label in
                        Toggle(
                            label,
                            isOn: Binding(
                                get: { term.source_mode == .selected && term.selected_platforms.contains(key) },
                                set: { isOn in
                                    var selected = term.source_mode == .selected ? Set(term.selected_platforms) : []
                                    if term.source_mode == .all {
                                        selected = isOn ? [key] : []
                                    } else if isOn {
                                        selected.insert(key)
                                    } else {
                                        selected.remove(key)
                                    }
                                    guard !selected.isEmpty else { return }
                                    db.updateTerm(
                                        id: term.id,
                                        sourceMode: .selected,
                                        selectedPlatforms: Array(selected).sorted()
                                    )
                                }
                            )
                        )
                        .accessibilityIdentifier("settings.keywordSource.\(term.keyword).\(key)")
                    }
                }
                .navigationTitle(i18n.t("sourceSelectionMenu"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(i18n.t("close")) { showingSourceSelection = false }
                            .accessibilityIdentifier("settings.keywordSourcesDone.\(term.keyword)")
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .accessibilityIdentifier("settings.keywordSourcesSheet.\(term.keyword)")
        }
    }
}

private struct AddKeywordSheet: View {
    @ObservedObject var db: LocalDB
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    let allPlatforms: [(String, String)]
    @Binding var isPresented: Bool
    @Binding var keyword: String
    @Binding var collectionMode: String
    @Binding var sourceMode: SourceMode
    @Binding var selectedPlatforms: Set<String>

    var body: some View {
        VStack(spacing: 16) {
            Text(i18n.t("addKeyword"))
                .font(.headline)
                .padding(.top, 14)

            TextField(i18n.t("inputKeyword"), text: $keyword)
                .padding()
                .background(theme.colors.divider)
                .cornerRadius(8)
                .accessibilityIdentifier("settings.keywordField")

            Picker(i18n.t("collectionMode"), selection: $collectionMode) {
                Text("📄 " + i18n.t("allInfo")).tag("all_info")
                Text("📹 " + i18n.t("mediaOnly")).tag("media_only")
            }
            .pickerStyle(.segmented)

            Picker(i18n.t("sourceSelection"), selection: $sourceMode) {
                Text(i18n.t("allSources")).tag(SourceMode.all)
                Text(i18n.t("selectedSources")).tag(SourceMode.selected)
            }
            .pickerStyle(.segmented)
            if sourceMode == .selected {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 8)], spacing: 8) {
                        ForEach(allPlatforms, id: \.0) { key, label in
                            Button {
                                if selectedPlatforms.contains(key) {
                                    selectedPlatforms.remove(key)
                                } else {
                                    selectedPlatforms.insert(key)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selectedPlatforms.contains(key) ? "checkmark.square.fill" : "square")
                                    Text(label).lineLimit(1)
                                }
                                .font(.caption)
                                .foregroundColor(theme.colors.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityIdentifier("settings.newKeywordSource.\(key)")
                            .accessibilityAddTraits(selectedPlatforms.contains(key) ? [.isSelected] : [])
                        }
                    }
                }
                .frame(maxHeight: 90)
            }
            HStack(spacing: 10) {
                Button(i18n.t("cancel")) {
                    keyword = ""
                    isPresented = false
                }
                .accessibilityIdentifier("settings.cancelAddKeywordButton")
                .frame(maxWidth: .infinity)
                .padding()
                .background(theme.colors.divider)
                .cornerRadius(10)

                Button(i18n.t("add")) {
                    let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    guard !db.terms.contains(where: { $0.keyword == trimmed }) else {
                        keyword = ""
                        isPresented = false
                        return
                    }
                    let savedMode = sourceMode == .selected && !selectedPlatforms.isEmpty ? SourceMode.selected : .all
                    let savedTerm = db.saveTerm(
                        keyword: trimmed,
                        collectionMode: collectionMode,
                        sourceMode: savedMode,
                        selectedPlatforms: Array(selectedPlatforms).sorted()
                    )
                    let sourceRevision = db.dataRevision

                    // Fetch the new keyword right away rather than waiting
                    // for the next feed refresh.
                    Task {
                        if ProcessInfo.processInfo.arguments.contains("--uitesting") { return }
                        let subscribed = Set(db.subscribedPlatforms.filter { $0 != "custom" })
                        let items = await IngestionService.shared.ingest(term: savedTerm, platforms: subscribed)
                        if !items.isEmpty {
                            _ = db.mergeItems(newItems: items, sourceRevision: sourceRevision)
                        }
                    }

                    keyword = ""
                    sourceMode = .all
                    selectedPlatforms = []
                    isPresented = false
                }
                .accessibilityIdentifier("settings.confirmAddKeywordButton")
                .frame(maxWidth: .infinity)
                .padding()
                .background(theme.colors.primary)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .padding(.top, 10)

            Spacer()
        }
        // No `.accessibilityIdentifier` on this VStack: applied to a bare
        // layout container it collapses the sheet into one accessibility
        // element and shadows every child's identifier (`settings.keywordField`,
        // `settings.confirmAddKeywordButton`, `settings.newKeywordSource.*`).
        .padding()
        .background(theme.colors.bg)
        .presentationDetents([.medium])
    }
}

private struct PlatformSubscriptionSheet: View {
    @ObservedObject var db: LocalDB
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    let allPlatforms: [(String, String)]
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    ForEach(allPlatforms, id: \.0) { key, label in
                        Button {
                            toggle(key)
                        } label: {
                            HStack {
                                Image(systemName: db.subscribedPlatforms.contains(key) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(db.subscribedPlatforms.contains(key) ? theme.colors.primary : theme.colors.textMuted)
                                Text(label).lineLimit(1)
                            }
                            .font(.subheadline)
                            .foregroundColor(theme.colors.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("settings.platformToggle.\(key)")
                    }
                }
                .padding()
            }
            .background(theme.colors.bg)
            .navigationTitle(i18n.t("platformSettings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(db.subscribedPlatforms.count == allPlatforms.count ? i18n.t("deselectAll") : i18n.t("selectAll")) {
                        if db.subscribedPlatforms.count == allPlatforms.count {
                            db.setSubscribedPlatforms(platforms: [])
                        } else {
                            db.setSubscribedPlatforms(platforms: allPlatforms.map { $0.0 })
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t("close")) {
                        isPresented = false
                    }
                    .accessibilityIdentifier("settings.platformSheetCloseButton")
                }
            }
        }
        .accessibilityIdentifier("settings.platformSheet")
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ key: String) {
        var list = db.subscribedPlatforms
        if list.contains(key) {
            list.removeAll(where: { $0 == key })
        } else {
            list.append(key)
        }
        db.setSubscribedPlatforms(platforms: list)
    }
}

private struct ProfileNameSheet: View {
    let mode: ProfileNameMode
    @ObservedObject var db: LocalDB
    @ObservedObject var i18n: I18nManager
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var errorText: String
    let profileToRename: UUID?
    let localizedError: (Error) -> String

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .create ? i18n.t("addProfile") : i18n.t("renameProfile"))
                .font(.headline)
            TextField(i18n.t("profileName"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.profileNameField")
            if !errorText.isEmpty { Text(errorText).foregroundStyle(.red).font(.caption) }
            HStack {
                Button(i18n.t("cancel")) { isPresented = false }
                    .accessibilityIdentifier("settings.profileCancelButton")
                Button(i18n.t("save")) {
                    do {
                        switch mode {
                        case .create: _ = try db.createProfile(name: name)
                        case .rename:
                            guard let profileToRename else { throw LocalProfileError.profileNotFound }
                            try db.renameProfile(id: profileToRename, name: name)
                        }
                        isPresented = false
                        errorText = ""
                    } catch { errorText = localizedError(error) }
                }
                .accessibilityIdentifier("settings.profileSaveButton")
            }
        }
        .padding()
        .presentationDetents([.medium])
    }
}

private struct EncryptedBackupPasswordSheet: View {
    let operation: EncryptedBackupOperation
    @Binding var password: String
    @Binding var confirmation: String
    @Binding var errorMessage: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @StateObject private var i18n = I18nManager.shared

    private var isExport: Bool { operation == .export }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(i18n.t("password"), text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.encryptedBackupPasswordField")

                    if isExport {
                        SecureField(i18n.t("confirmPassword"), text: $confirmation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("settings.encryptedBackupConfirmationField")
                    }
                } footer: {
                    Text(isExport
                         ? i18n.t("encryptedBackupExportPasswordHint")
                         : i18n.t("encryptedBackupImportPasswordHint"))
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .accessibilityIdentifier("settings.encryptedBackupError")
                }

                Section {
                    Button {
                        onSubmit()
                    } label: {
                        if isSubmitting {
                            HStack {
                                ProgressView()
                                Text(isExport ? i18n.t("exportEncryptedBackup") : i18n.t("importEncryptedBackup"))
                            }
                        } else {
                            Text(isExport ? i18n.t("exportEncryptedBackup") : i18n.t("importEncryptedBackup"))
                        }
                    }
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("settings.encryptedBackupSubmitButton")
                    Button(i18n.t("cancel"), role: .cancel, action: onCancel)
                        .accessibilityIdentifier("settings.encryptedBackupCancelButton")
                }
            }
            .navigationTitle(isExport ? i18n.t("encryptedBackupTitle") : i18n.t("unlockBackup"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

enum HostedSourceHealthBadgeKind: Equatable {
    case success
    case empty
    case filtered
    case failure
    case unknown
}

struct HostedSourceHealthPresentation: Equatable {
    let kind: HostedSourceHealthBadgeKind
    let labelKey: String
    let symbolName: String

    init(status: String?) {
        switch status?.lowercased() {
        case "success":
            kind = .success
            labelKey = "sourceStatusBadgeOK"
            symbolName = "checkmark.circle.fill"
        case "empty":
            kind = .empty
            labelKey = "sourceStatusBadgeEmpty"
            symbolName = "circle.dashed"
        case "filtered":
            kind = .filtered
            labelKey = "sourceStatusBadgeFiltered"
            symbolName = "line.diagonal"
        case "failure":
            kind = .failure
            labelKey = "sourceStatusBadgeFailed"
            symbolName = "exclamationmark.triangle.fill"
        default:
            kind = .unknown
            labelKey = "sourceStatusBadgeUnknown"
            symbolName = "questionmark.circle"
        }
    }
}

enum HostedSourceHealthLoadFailure: Equatable {
    case accessUnavailable
    case requestFailed
}

@MainActor
final class HostedSourceHealthViewModel: ObservableObject {
    typealias Fetch = (TimeInterval) async throws -> [HostedSourceHealthEntry]
    typealias RefreshEntitlement = () async -> Void

    @Published private(set) var entries: [HostedSourceHealthEntry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var loadFailure: HostedSourceHealthLoadFailure?

    private let fetch: Fetch
    private let refreshEntitlement: RefreshEntitlement

    init(
        fetch: @escaping Fetch = { timeout in
            try await BackendClient.shared.fetchHostedSourceHealth(timeout: timeout)
        },
        refreshEntitlement: @escaping RefreshEntitlement = {
            await PlusStore.shared.refreshStatus()
        }
    ) {
        self.fetch = fetch
        self.refreshEntitlement = refreshEntitlement
    }

    func load(timeout: TimeInterval = 15) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await fetch(timeout)
            try Task.checkCancellation()
            entries = fetched
            loadFailure = nil
        } catch is CancellationError {
            return
        } catch let BackendClientError.httpStatus(_, code, _) where code == "paid_backend_required" {
            loadFailure = .accessUnavailable
            await refreshEntitlement()
        } catch {
            loadFailure = .requestFailed
        }
    }
}

@MainActor
struct HostedSourceStatusView: View {
    let theme: ThemeManager
    @StateObject private var i18n = I18nManager.shared
    @StateObject private var model: HostedSourceHealthViewModel

    init(theme: ThemeManager) {
        self.theme = theme
        _model = StateObject(wrappedValue: HostedSourceHealthViewModel())
    }

    init(theme: ThemeManager, model: HostedSourceHealthViewModel) {
        self.theme = theme
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        List {
            if model.isLoading && model.entries.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if model.entries.isEmpty {
                ContentUnavailableView(
                    emptyStateText,
                    systemImage: model.loadFailure == nil ? "server.rack" : "exclamationmark.triangle"
                )
            } else {
                if let loadFailure = model.loadFailure {
                    Text(failureText(loadFailure))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("settings.hostedSourceStatus.reloadError")
                }
                ForEach(model.entries) { entry in
                    row(for: entry)
                }
            }
        }
        .accessibilityIdentifier("settings.hostedSourceStatus.screen")
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("hostedSourceStatus"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var emptyStateText: String {
        guard let loadFailure = model.loadFailure else {
            return i18n.t("hostedSourceStatusEmpty")
        }
        return failureText(loadFailure)
    }

    private func failureText(_ failure: HostedSourceHealthLoadFailure) -> String {
        switch failure {
        case .accessUnavailable:
            return i18n.t("hostedSourceStatusAccessUnavailable")
        case .requestFailed:
            return i18n.t("hostedSourceStatusLoadError")
        }
    }

    private func row(for entry: HostedSourceHealthEntry) -> some View {
        let definition = PlatformRegistry.definition(for: entry.platform)
        let presentation = HostedSourceHealthPresentation(status: entry.status)
        let statusLabel = i18n.t(presentation.labelKey)
        var accessibilityParts = [definition?.name ?? entry.platform, statusLabel]
        if let checked = checkedText(entry) { accessibilityParts.append(checked) }
        accessibilityParts.append(itemCountText(entry.last_item_count ?? 0))
        accessibilityParts.append(failureCountText(entry.consecutive_failures))
        if presentation.kind == .failure, let error = entry.last_error, !error.isEmpty {
            accessibilityParts.append(error)
        }
        if entry.jina_ok == false {
            accessibilityParts.append(jinaText(entry))
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let icon = definition?.icon { Text(icon) }
                Text(definition?.name ?? entry.platform)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.colors.text)
                Spacer()
                Label(statusLabel, systemImage: presentation.symbolName)
                    .font(.caption)
                    .foregroundColor(badgeColor(presentation.kind))
            }
            if let checked = checkedText(entry) {
                Text(checked)
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)
            }
            HStack(spacing: 12) {
                Text(itemCountText(entry.last_item_count ?? 0))
                Text(failureCountText(entry.consecutive_failures))
            }
            .font(.caption)
            .foregroundColor(theme.colors.textMuted)
            if presentation.kind == .failure, let error = entry.last_error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)
                    .lineLimit(2)
            }
            if entry.jina_ok == false {
                Text(jinaText(entry))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityParts.joined(separator: ", "))
        .accessibilityIdentifier("settings.hostedSourceStatus.row.\(entry.platform)")
    }

    private func checkedText(_ entry: HostedSourceHealthEntry) -> String? {
        guard let raw = entry.last_checked_at, let date = parseISO8601Date(raw) else { return nil }
        return i18n.t("hostedSourceLastChecked")
            .replacingOccurrences(of: "{time}", with: relativeTimeString(from: date))
    }

    private func itemCountText(_ count: Int) -> String {
        i18n.t("hostedSourceRecentItems").replacingOccurrences(of: "{count}", with: "\(count)")
    }

    private func failureCountText(_ count: Int) -> String {
        i18n.t("hostedSourceConsecutiveFailures").replacingOccurrences(of: "{count}", with: "\(count)")
    }

    private func jinaText(_ entry: HostedSourceHealthEntry) -> String {
        let base = i18n.t("hostedSourceJinaDegraded")
        guard let error = entry.jina_error, !error.isEmpty else { return base }
        return "\(base): \(error)"
    }

    private func badgeColor(_ kind: HostedSourceHealthBadgeKind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return .red
        case .empty, .filtered, .unknown: return theme.colors.textMuted
        }
    }
}

private struct SourceStatusSheet: View {
    let summaries: [SourceHealthSummary]
    let theme: ThemeManager
    @StateObject private var i18n = I18nManager.shared

    var body: some View {
        NavigationStack {
            if summaries.isEmpty {
                ContentUnavailableView(i18n.t("noSourceHistoryYet"), systemImage: "chart.bar.xaxis")
            } else {
                List(summaries) { summary in
                    SourceStatusRow(summary: summary, theme: theme)
                }
                .accessibilityIdentifier("settings.sourceStatusSheet")
            }
        }
        .navigationTitle(i18n.t("sourceStatusTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("settings.sourceStatus.screen")
    }
}

private struct SourceStatusRow: View {
    let summary: SourceHealthSummary
    let theme: ThemeManager
    @StateObject private var i18n = I18nManager.shared

    var body: some View {
        HStack(spacing: 10) {
            let metadata = theme.metadata(for: summary.id)
            Text(metadata.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata.name)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("settings.sourceStatus.\(summary.id)")
                Text(summaryText)
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)
            }
            Spacer()
            Text("\(summary.currentStatus?.itemCount ?? 0)")
                .font(.caption.monospacedDigit())
                .foregroundColor(theme.colors.textMuted)
        }
        .accessibilityIdentifier("settings.sourceStatus.row.\(summary.id)")
    }

    private var summaryText: String {
        let current = summary.currentStatus.map(statusText) ?? i18n.t("notChecked")
        let lastFailure = summary.lastFailure.map {
            i18n.t("sourceLastFailure").replacingOccurrences(of: "{failure}", with: $0.displayName)
        } ?? ""
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.unitsStyle = .short
        let checked = formatter.localizedString(for: summary.lastCheckedAt, relativeTo: Date())
        return i18n.t("sourceHistorySummary")
            .replacingOccurrences(of: "{current}", with: current)
            .replacingOccurrences(of: "{received}", with: "\(summary.receivedCount)")
            .replacingOccurrences(of: "{stale}", with: "\(summary.staleCount)")
            .replacingOccurrences(of: "{empty}", with: "\(summary.emptyCount)")
            .replacingOccurrences(of: "{failed}", with: "\(summary.failedCount)")
            .replacingOccurrences(of: "{total}", with: "\(summary.totalItemCount)")
            .replacingOccurrences(of: "{checked}", with: checked)
            .replacingOccurrences(of: "{lastFailure}", with: lastFailure)
    }

    private func statusText(_ status: SourceRefreshStatus) -> String {
        switch status.outcome {
        case .received:
            return i18n.t("sourceItemsQueries")
                .replacingOccurrences(of: "{items}", with: "\(status.itemCount)")
                .replacingOccurrences(of: "{queries}", with: "\(status.queryCount)")
        case .stale:
            return i18n.t("sourceStaleItemsQueries")
                .replacingOccurrences(of: "{items}", with: "\(status.itemCount)")
                .replacingOccurrences(of: "{queries}", with: "\(status.queryCount)")
        case .noResults:
            return i18n.t("sourceNoMatchingItemsQueries")
                .replacingOccurrences(of: "{queries}", with: "\(status.queryCount)")
        case .failed(let failure):
            return i18n.t("sourceFailureQueries")
                .replacingOccurrences(of: "{failure}", with: failure.displayName)
                .replacingOccurrences(of: "{queries}", with: "\(status.queryCount)")
        case .cooldown:
            return i18n.t("sourceCooldown")
        }
    }

    private var localeIdentifier: String {
        switch i18n.lang {
        case "zh-TW": return "zh_Hant_TW"
        case "zh-CN": return "zh_Hans_CN"
        case "ja": return "ja_JP"
        default: return "en_US"
        }
    }
}

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
