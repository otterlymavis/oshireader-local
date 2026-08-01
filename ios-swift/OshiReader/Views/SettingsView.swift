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

struct SettingsView: View {
    @StateObject private var db = LocalDB.shared
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var i18n = I18nManager.shared
    @StateObject private var appearance = AppearanceManager.shared
    @StateObject private var notifications = NotificationManager.shared
    
    @State private var showingAddKeywordAlert = false
    @State private var showingClearAllAlert = false
    @State private var newKeyword = ""
    @State private var newCollectionMode = "all_info"
    @State private var newSourceMode: SourceMode = .all
    @State private var newSelectedPlatforms = Set<String>()
    @State private var addingAliasForId: String? = nil
    @State private var newAliasText = ""
    // API token lives in the Keychain now that ingestion runs on-device.
    @State private var twitterBearerToken = KeychainHelper.read(.twitterBearerToken) ?? ""
    @AppStorage("auto_translate_reader") private var autoTranslateReader = false
    @State private var backupDocument = LocalBackupDocument()
    @State private var showingBackupExporter = false
    @State private var showingBackupImporter = false
    @State private var backupMessage = ""
    @State private var showingBackupMessage = false
    @State private var showingAliasLimitMessage = false
    
    var allPlatforms: [(String, String)] {
        PlatformRegistry.all.map { ($0.id, "\($0.icon) \($0.name)") }
    }

    private var selectablePlatforms: [(String, String)] {
        let subscribed = Set(db.subscribedPlatforms)
        return allPlatforms.filter { key, _ in
            key != "custom" && subscribed.contains(key)
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // Section: Keywords management
                Section(header: Text(i18n.t("watchTerms"))) {
                    ForEach(db.terms) { term in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                NavigationLink(destination: AvatarEditorView(keyword: term.keyword)) {
                                    ZStack {
                                        Circle()
                                            .fill(theme.colors.divider)
                                            .frame(width: 38, height: 38)
                                        if let avatar = db.oshiAvatars[term.keyword], let url = URL(string: avatar) {
                                            AsyncImage(url: url) { image in
                                                image
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                            } placeholder: {
                                                Text("🎨")
                                            }
                                            .frame(width: 38, height: 38)
                                            .clipShape(Circle())
                                        } else {
                                            Text("🎨")
                                                .font(.body)
                                        }
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                                .accessibilityIdentifier("settings.keywordAvatar.\(term.keyword)")

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(term.keyword)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(theme.colors.text)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
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
                                                    }
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(theme.colors.divider)
                                                    .cornerRadius(99)
                                                }
                                                if addingAliasForId == term.id {
                                                    TextField(i18n.t("keyword"), text: $newAliasText)
                                                        .font(.caption2)
                                                        .frame(minWidth: 80, maxWidth: 140)
                                                        .autocorrectionDisabled()
                                                        .textInputAutocapitalization(.never)
                                                        .submitLabel(.done)
                                                        .onSubmit { commitAlias(for: term) }
                                                }
                                                Button {
                                                    if addingAliasForId == term.id {
                                                        if term.aliases.count >= IngestionService.maximumAliasesPerTerm {
                                                            showingAliasLimitMessage = true
                                                            newAliasText = ""
                                                            addingAliasForId = nil
                                                            return
                                                        }
                                                        commitAlias(for: term)
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
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Toggle("", isOn: Binding(
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

                            HStack(spacing: 8) {
                                Button {
                                    let next = term.collection_mode == "all_info" ? "media_only" : "all_info"
                                    db.updateTerm(id: term.id, collectionMode: next)
                                } label: {
                                    Label(term.collection_mode == "media_only" ? i18n.t("mediaOnly") : i18n.t("allInfo"),
                                          systemImage: term.collection_mode == "media_only" ? "play.rectangle" : "doc.text")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(theme.colors.divider)
                                        .foregroundColor(theme.colors.textSub)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(PlainButtonStyle())
                                .accessibilityIdentifier("settings.keywordMode.\(term.keyword)")

                                Button(action: {
                                    let next = !term.notify_on_new
                                    db.updateTerm(id: term.id, notifyOnNew: next)
                                }) {
                                    Label(term.notify_on_new ? i18n.t("notificationsOn") : i18n.t("notificationsOff"),
                                          systemImage: term.notify_on_new ? "bell.fill" : "bell.slash")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(term.notify_on_new ? theme.colors.primaryBg : theme.colors.divider)
                                        .foregroundColor(term.notify_on_new ? theme.colors.primary : theme.colors.textMuted)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(PlainButtonStyle())
                                .accessibilityIdentifier("settings.keywordBell.\(term.keyword)")

                                Spacer()
                            }

                            sourceSelectionMenu(for: term)
                        }
                        .accessibilityIdentifier("settings.keywordRow.\(term.keyword)")
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let term = db.terms[index]
                            if addingAliasForId == term.id { addingAliasForId = nil }
                            db.deleteTerm(id: term.id)
                        }
                    }
                    
                    Button(action: { showingAddKeywordAlert.toggle() }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text(i18n.t("addKeyword"))
                        }
                        .foregroundColor(theme.colors.primary)
                    }
                    .accessibilityIdentifier("settings.addKeywordButton")
                }
                
                // Section: Subscribed Platforms
                Section(header: Text(i18n.t("platformSettings"))) {
                    ForEach(allPlatforms, id: \.0) { key, label in
                        let isSubscribed = db.subscribedPlatforms.contains(key)
                        Toggle(label, isOn: Binding(
                            get: { isSubscribed },
                            set: { value in
                                var list = db.subscribedPlatforms
                                if value {
                                    if !list.contains(key) { list.append(key) }
                                } else {
                                    list.removeAll(where: { $0 == key })
                                }
                                db.setSubscribedPlatforms(platforms: list)
                            }
                        ))
                        .tint(theme.colors.primary)
                        .accessibilityIdentifier("settings.platformToggle.\(key)")
                    }
                }

                Section(header: Text(i18n.t("notificationsSection"))) {
                    HStack {
                        Label(i18n.t("pushNotifications"), systemImage: "bell.badge")
                        Spacer()
                        Text(notificationStatusText)
                            .foregroundColor(notifications.canScheduleNotifications ? theme.colors.primary : theme.colors.textMuted)
                    }
                    .accessibilityIdentifier("settings.notificationStatus")

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
                        Button {
                            Task { try? await notifications.sendTestNotification() }
                        } label: {
                            Label(i18n.t("sendTestNotification"), systemImage: "paperplane.fill")
                                .foregroundColor(theme.colors.primary)
                        }
                        .accessibilityIdentifier("settings.testNotificationButton")
                    }
                }

                Section(header: Text(i18n.t("readerSection"))) {
                    Toggle(i18n.t("autoTranslate"), isOn: $autoTranslateReader)
                        .tint(theme.colors.primary)
                        .accessibilityIdentifier("settings.autoTranslateToggle")
                }

                Section(
                    header: Text(i18n.t("credentialsSection")),
                    footer: Text(i18n.t("credentialsFooter"))
                ) {
                    SecureField("X Bearer Token", text: $twitterBearerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { KeychainHelper.save(.twitterBearerToken, twitterBearerToken) }
                        .onDisappear { KeychainHelper.save(.twitterBearerToken, twitterBearerToken) }
                        .accessibilityIdentifier("settings.twitterBearerTokenField")
                }
                
                // Section: Customizations
                Section(header: Text(i18n.t("appearanceSection"))) {
                    Picker(i18n.t("appTheme"), selection: $theme.mode) {
                        Text(i18n.t("themeLight")).tag(AppThemeMode.light)
                        Text(i18n.t("themeDark")).tag(AppThemeMode.dark)
                        Text(i18n.t("themeSepia")).tag(AppThemeMode.sepia)
                    }
                    .pickerStyle(.segmented)

                    Picker(i18n.t("style"), selection: $theme.style) {
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
                            Text(displayName(for: choice)).tag(choice)
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
                }


                Section(header: Text(i18n.t("privacySection"))) {
                    NavigationLink(destination: PrivacyPolicyView(theme: theme)) {
                        Label(i18n.t("privacyPolicy"), systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("settings.privacyPolicyLink")
                }

                Section(header: Text(i18n.t("dataSection"))) {
                    Button {
                        do {
                            backupDocument = LocalBackupDocument(data: try db.exportBackupData())
                            showingBackupExporter = true
                        } catch {
                            backupMessage = error.localizedDescription
                            showingBackupMessage = true
                        }
                    } label: {
                        Label(i18n.t("exportBackup"), systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("settings.exportBackupButton")

                    Button {
                        showingBackupImporter = true
                    } label: {
                        Label(i18n.t("importBackup"), systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("settings.importBackupButton")

                    Button(role: .destructive) {
                        showingClearAllAlert = true
                    } label: {
                        Label(i18n.t("clearAllData"), systemImage: "trash")
                    }
                    .accessibilityIdentifier("settings.clearAllDataButton")
                }
                
            }
            .font(.system(size: 13))
            .accessibilityIdentifier("settings.screen")
            .navigationTitle(i18n.t("settingsTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .background(theme.colors.bg)
            .sheet(isPresented: $showingAddKeywordAlert) {
                VStack(spacing: 16) {
                    Text(i18n.t("addKeyword"))
                        .font(.headline)
                        .padding(.top, 14)
                    
                    TextField(i18n.t("inputKeyword"), text: $newKeyword)
                        .padding()
                        .background(theme.colors.divider)
                        .cornerRadius(8)
                        .accessibilityIdentifier("settings.keywordField")
                    
                    Picker(i18n.t("collectionMode"), selection: $newCollectionMode) {
                        Text("📄 " + i18n.t("allInfo")).tag("all_info")
                        Text("📹 " + i18n.t("mediaOnly")).tag("media_only")
                    }
                    .pickerStyle(.segmented)

                    Picker(i18n.t("sourceSelection"), selection: $newSourceMode) {
                        Text(i18n.t("allSources")).tag(SourceMode.all)
                        Text(i18n.t("selectedSources")).tag(SourceMode.selected)
                    }
                    .pickerStyle(.segmented)

                    if newSourceMode == .selected {
                        Menu {
                            ForEach(selectablePlatforms, id: \.0) { key, label in
                                Button {
                                    if newSelectedPlatforms.contains(key) {
                                        newSelectedPlatforms.remove(key)
                                    } else {
                                        newSelectedPlatforms.insert(key)
                                    }
                                } label: {
                                    Label(label, systemImage: newSelectedPlatforms.contains(key) ? "checkmark.square" : "square")
                                }
                                .accessibilityIdentifier("settings.newKeywordSource.\(key)")
                            }
                        } label: {
                            Label(
                                newSelectedPlatforms.isEmpty
                                    ? i18n.t("chooseSources")
                                    : i18n.tFormat("sourcesSelectedCount", newSelectedPlatforms.count),
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("settings.newKeywordSources")
                    }
                    
                    HStack(spacing: 10) {
                        Button(i18n.t("cancel")) {
                            newKeyword = ""
                            showingAddKeywordAlert = false
                        }
                        .accessibilityIdentifier("settings.cancelAddKeywordButton")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(theme.colors.divider)
                        .cornerRadius(10)
                        
                        Button(i18n.t("add")) {
                            let trimmed = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            guard !db.terms.contains(where: { $0.keyword == trimmed }) else {
                                newKeyword = ""
                                showingAddKeywordAlert = false
                                return
                            }
                            let savedMode = newSourceMode == .selected && !newSelectedPlatforms.isEmpty ? SourceMode.selected : .all
                            let savedTerm = db.saveTerm(
                                keyword: trimmed,
                                collectionMode: newCollectionMode,
                                sourceMode: savedMode,
                                selectedPlatforms: Array(newSelectedPlatforms).sorted()
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

                            newKeyword = ""
                            newSourceMode = .all
                            newSelectedPlatforms = []
                            showingAddKeywordAlert = false
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
                .padding()
                .background(theme.colors.bg)
                .presentationDetents([.medium])
            }
            .alert(i18n.t("clearAllDataTitle"), isPresented: $showingClearAllAlert) {
                Button(i18n.t("cancel"), role: .cancel) {}
                Button(i18n.t("delete"), role: .destructive) {
                    db.clearAllData()
                }
            } message: {
                Text(i18n.t("clearAllDataMessage"))
            }
            .fileExporter(
                isPresented: $showingBackupExporter,
                document: backupDocument,
                contentType: .json,
                defaultFilename: "oshireader-backup.json"
            ) { result in
                if case .failure(let error) = result {
                    backupMessage = error.localizedDescription
                    showingBackupMessage = true
                }
            }
            .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    guard byteCount <= Int64(LocalDB.maximumBackupBytes) else {
                        throw NSError(domain: "OshiReaderBackup", code: 5, userInfo: [NSLocalizedDescriptionKey: "Backup file is too large"])
                    }
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    try db.importBackupData(data)
                    backupMessage = i18n.t("backupImported")
                } catch {
                    backupMessage = error.localizedDescription
                }
                showingBackupMessage = true
            }
            .alert(i18n.t("backupStatus"), isPresented: $showingBackupMessage) {
                Button(i18n.t("ok"), role: .cancel) {}
            } message: {
                Text(backupMessage)
            }
            .alert(i18n.t("addAlias"), isPresented: $showingAliasLimitMessage) {
                Button(i18n.t("ok"), role: .cancel) {}
            } message: {
                Text(i18n.t("aliasLimitReached"))
            }
        }
    }

    private func displayName(for style: AppColorStyle) -> String {
        switch style {
        case .colourful: return i18n.t("styleColourful")
        case .standard: return i18n.t("styleStandard")
        }
    }

    private func commitAlias(for term: WatchTerm) {
        let trimmed = newAliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !term.aliases.contains(trimmed),
           term.aliases.count < IngestionService.maximumAliasesPerTerm {
            db.updateTerm(id: term.id, aliases: term.aliases + [trimmed])
        }
        newAliasText = ""
        addingAliasForId = nil
    }

    @ViewBuilder
    private func sourceSelectionMenu(for term: WatchTerm) -> some View {
        Menu {
            Button {
                db.updateTerm(id: term.id, sourceMode: .all, selectedPlatforms: [])
            } label: {
                Label(i18n.t("allSources"), systemImage: term.source_mode == .all ? "checkmark" : "globe")
            }

            Divider()

            ForEach(selectablePlatforms, id: \.0) { key, label in
                Button {
                    var selected = term.source_mode == .selected ? Set(term.selected_platforms) : []
                    if selected.contains(key) {
                        selected.remove(key)
                    } else {
                        selected.insert(key)
                    }
                    db.updateTerm(
                        id: term.id,
                        sourceMode: selected.isEmpty ? .all : .selected,
                        selectedPlatforms: Array(selected).sorted()
                    )
                } label: {
                    Label(label, systemImage: term.source_mode == .selected && term.selected_platforms.contains(key) ? "checkmark.square" : "square")
                }
                .accessibilityIdentifier("settings.keywordSource.\(term.keyword).\(key)")
            }
        } label: {
            Label(
                term.source_mode == .all
                    ? i18n.t("allSources")
                    : i18n.tFormat("sourcesSelectedCount", term.selected_platforms.count),
                systemImage: term.source_mode == .all ? "globe" : "line.3.horizontal.decrease.circle"
            )
            .font(.caption)
            .foregroundColor(theme.colors.textMuted)
        }
        .accessibilityIdentifier("settings.keywordSources.\(term.keyword)")
    }

    private func displayName(for choice: AppFontChoice) -> String {
        switch choice {
        case .normal: return i18n.t("fontNormal")
        case .comicSans: return i18n.t("fontComicSans")
        }
    }

    private func displayName(for choice: AppFontSizeChoice) -> String {
        switch choice {
        case .normal: return i18n.t("fontSizeNormal")
        case .large: return i18n.t("fontSizeLarge")
        case .extraLarge: return i18n.t("fontSizeExtraLarge")
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
