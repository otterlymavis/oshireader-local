import SwiftUI

/// Per-term settings, opened by tapping a Watch Term row. Everything that used
/// to crowd the row inline — collection mode, source selection, guaranteed
/// push, avatar and alias editing — lives here so the list row stays scannable
/// (avatar, keyword, one bell button, the active toggle).
struct WatchTermDetailView: View {
    let termID: String
    /// Title fallback if the term is deleted while this screen is open.
    let initialKeyword: String
    /// Observed here (unlike the list row) so source/mode toggles reflect
    /// immediately; this is a single leaf screen, not the hot list path.
    @ObservedObject var db: LocalDB
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    let allPlatforms: [(String, String)]

    let showsGuaranteedPush: Bool
    let pushTermLimit: Int
    let pushTermCount: Int
    let pushTermBeingUpdated: String?
    let manualPushTermBeingUpdated: String?
    let onSetPushEnabled: (Bool, WatchTerm) async -> Void
    let onNotifyPushNow: (WatchTerm) async -> Void
    let onClearPushPending: (WatchTerm) async -> Void
    let onAliasLimitReached: () -> Void

    @State private var addingAlias = false
    @State private var newAliasText = ""

    private var term: WatchTerm? { db.terms.first { $0.id == termID } }

    var body: some View {
        Group {
            if let term {
                Form {
                    avatarSection(for: term)
                    collectionModeSection(for: term)
                    sourceSection(for: term)
                    aliasSection(for: term)
                    if showsGuaranteedPush {
                        guaranteedPushSection(for: term)
                    }
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle(term?.keyword ?? initialKeyword)
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.colors.bg)
        .accessibilityIdentifier("settings.keywordDetail.\(term?.keyword ?? initialKeyword)")
    }

    // MARK: - Sections

    @ViewBuilder
    private func avatarSection(for term: WatchTerm) -> some View {
        Section {
            NavigationLink {
                AvatarEditorView(keyword: term.keyword)
            } label: {
                Label(i18n.t("editAvatar"), systemImage: "paintpalette")
            }
            .accessibilityIdentifier("settings.keywordAvatar.\(term.keyword)")
        }
    }

    @ViewBuilder
    private func collectionModeSection(for term: WatchTerm) -> some View {
        Section(header: Text(i18n.t("collectionMode"))) {
            Picker(i18n.t("collectionMode"), selection: Binding(
                get: { term.collection_mode },
                set: { db.updateTerm(id: term.id, collectionMode: $0) }
            )) {
                Text("📄 " + i18n.t("allInfo")).tag("all_info")
                Text("📹 " + i18n.t("mediaOnly")).tag("media_only")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.keywordMode.\(term.keyword)")
        }
    }

    @ViewBuilder
    private func sourceSection(for term: WatchTerm) -> some View {
        Section(header: Text(i18n.t("sourceSelectionMenu"))) {
            Button {
                db.updateTerm(id: term.id, sourceMode: .all, selectedPlatforms: [])
            } label: {
                Label(
                    i18n.t("allSources"),
                    systemImage: term.source_mode == .all ? "checkmark.circle.fill" : "globe"
                )
            }
            .accessibilityIdentifier("settings.keywordSourceAll.\(term.keyword)")

            ForEach(allPlatforms, id: \.0) { key, label in
                Toggle(label, isOn: Binding(
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
                ))
                .accessibilityIdentifier("settings.keywordSource.\(term.keyword).\(key)")
            }
        }
    }

    @ViewBuilder
    private func aliasSection(for term: WatchTerm) -> some View {
        Section(header: Text(i18n.t("aliases"))) {
            ForEach(term.aliases, id: \.self) { alias in
                HStack {
                    Text(alias)
                    Spacer()
                    Button {
                        db.updateTerm(id: term.id, aliases: term.aliases.filter { $0 != alias })
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i18n.tFormat("removeAliasFmt", alias))
                }
            }

            if addingAlias {
                HStack {
                    TextField(i18n.t("keyword"), text: $newAliasText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { commitAlias(for: term) }
                    Button(i18n.t("save")) { commitAlias(for: term) }
                        .buttonStyle(.plain)
                }
            } else {
                Button {
                    newAliasText = ""
                    addingAlias = true
                } label: {
                    Label(i18n.t("addAlias"), systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private func guaranteedPushSection(for term: WatchTerm) -> some View {
        let bound = term.backendTermID != nil
        let busy = pushTermBeingUpdated != nil || manualPushTermBeingUpdated != nil
        let atLimit = !bound && (pushTermLimit == 0 || pushTermCount >= pushTermLimit)

        Section {
            Button {
                Task { await onSetPushEnabled(!bound, term) }
            } label: {
                HStack {
                    Label(
                        i18n.t("guaranteedPush"),
                        systemImage: bound
                            ? "antenna.radiowaves.left.and.right"
                            : "antenna.radiowaves.left.and.right.slash"
                    )
                    .foregroundColor(bound ? theme.colors.primary : theme.colors.text)
                    Spacer()
                    if bound {
                        Image(systemName: "checkmark")
                            .foregroundColor(theme.colors.primary)
                    }
                }
            }
            .disabled(busy || atLimit)
            .accessibilityLabel("Guaranteed push")
            .accessibilityValue(bound ? "on" : "off")
            .accessibilityIdentifier("settings.keywordPush.\(term.keyword)")

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
        } footer: {
            if atLimit {
                Text(i18n.t("paidPushPausedSelection"))
            }
        }
    }

    // MARK: - Alias commit

    private func commitAlias(for term: WatchTerm) {
        let trimmed = newAliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            newAliasText = ""
            addingAlias = false
        }
        guard !trimmed.isEmpty, !term.aliases.contains(trimmed) else { return }
        if term.aliases.count >= IngestionService.maximumAliasesPerTerm {
            onAliasLimitReached()
        } else {
            db.updateTerm(id: term.id, aliases: term.aliases + [trimmed])
        }
    }
}
