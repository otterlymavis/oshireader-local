import SwiftUI

/// The "Watch Terms" Settings section, extracted into its own child view so the
/// push/entitlement stores it needs (`PushSyncCoordinator`, `PlusStore`,
/// `NotificationManager`) are observed here only — a push-sync progress publish
/// re-evaluates this section, not the whole root Settings Form.
struct WatchTermsSection: View {
    @ObservedObject var db: LocalDB
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    /// Root owns the consolidated `.sheet(item:)`; this fires `activeSheet = .addKeyword`.
    let onAddKeyword: () -> Void
    /// Root owns the alias-limit `.alert`; this flips its `@State` to `true`.
    let onAliasLimitReached: () -> Void

    @StateObject private var plusStore = PlusStore.shared
    @StateObject private var pushSync = PushSyncCoordinator.shared
    @StateObject private var notifications = NotificationManager.shared

    @State private var addingAliasForId: String? = nil
    @State private var newAliasText = ""
    @State private var notificationTermBeingUpdated: String?

    private var activeTermCount: Int { db.terms.lazy.filter(\.is_active).count }

    var body: some View {
        Section(header: Text(i18n.t("watchTerms"))) {
            ForEach(db.terms) { term in
                TermRowView(
                    term: term,
                    avatarURL: db.oshiAvatars[term.keyword],
                    db: db,
                    theme: theme,
                    i18n: i18n,
                    allPlatforms: SettingsView.allPlatforms,
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
                    onAliasLimitReached: onAliasLimitReached
                )
            }
            .onDelete { offsets in
                for index in offsets {
                    let term = db.terms[index]
                    if addingAliasForId == term.id { addingAliasForId = nil }
                    db.deleteTerm(id: term.id)
                }
            }

            Button(action: onAddKeyword) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(i18n.t("addKeyword"))
                }
                .foregroundColor(theme.colors.primary)
            }
            .accessibilityIdentifier("settings.addKeywordButton")

            if activeTermCount > SettingsView.manyActiveTermsThreshold {
                Label(i18n.tFormat("manyActiveTermsWarning", activeTermCount), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .accessibilityIdentifier("settings.manyActiveTermsWarning")
            }
        }
    }

    private func setNotificationEnabled(_ enabled: Bool, for term: WatchTerm) async {
        if enabled {
            guard await notifications.requestAuthorizationIfNeededForLocalAlerts() else { return }
        }
        db.updateTerm(id: term.id, notifyOnNew: enabled)
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
        VStack(alignment: .leading, spacing: 10) {
            // Identity + the primary on/off control.
            HStack(spacing: 12) {
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

                Text(term.keyword)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.colors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

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

            // Secondary actions — one uniform, evenly spaced row of
            // thumb-sized targets, each tinted when its feature is on.
            HStack(spacing: 8) {
                modeButton
                sourceSelectionButton
                bellButton
                if showsGuaranteedPush {
                    pushButton
                }
            }

            aliasEditor
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("settings.keywordRow.\(term.keyword)")
    }

    @ViewBuilder
    private var aliasEditor: some View {
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

    private var modeButton: some View {
        Button {
            let next = term.collection_mode == "all_info" ? "media_only" : "all_info"
            db.updateTerm(id: term.id, collectionMode: next)
        } label: {
            Text(term.collection_mode == "media_only" ? "📹" : "📄")
                .modifier(KeywordActionChrome(theme: theme, isActive: term.collection_mode == "media_only"))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(term.collection_mode == "media_only" ? i18n.t("mediaOnly") : i18n.t("allInfo"))
        .accessibilityIdentifier("settings.keywordMode.\(term.keyword)")
    }

    private var bellButton: some View {
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
                .modifier(KeywordActionChrome(theme: theme, isActive: term.notify_on_new))
                // Only the row whose bell is mid-update dims; the shared
                // `disabled` guard below still serializes across rows.
                .opacity(notificationTermBeingUpdated == term.id ? 0.4 : 1)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(notificationTermBeingUpdated != nil)
        .accessibilityLabel("Local alerts")
        .accessibilityValue(term.notify_on_new ? "on" : "off")
        .accessibilityIdentifier("settings.keywordBell.\(term.keyword)")
    }

    private var pushButton: some View {
        Button {
            Task { await onSetPushEnabled(term.backendTermID == nil, term) }
        } label: {
            Image(systemName: term.backendTermID == nil ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                .modifier(KeywordActionChrome(theme: theme, isActive: term.backendTermID != nil))
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
            Image(systemName: term.source_mode == .all ? "globe" : "line.3.horizontal.decrease.circle.fill")
                .modifier(KeywordActionChrome(theme: theme, isActive: term.source_mode != .all))
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

/// Shared chrome for the Watch Term row's secondary action buttons so mode,
/// sources, alerts, and guaranteed push read as one control group: a uniform
/// rounded target that stretches to an equal share of the row width and tints
/// itself when its feature is on.
private struct KeywordActionChrome: ViewModifier {
    @ObservedObject var theme: ThemeManager
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(isActive ? theme.colors.primaryBg : theme.colors.divider)
            .foregroundColor(isActive ? theme.colors.primary : theme.colors.textSub)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct AddKeywordSheet: View {
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

struct PlatformSubscriptionSheet: View {
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
