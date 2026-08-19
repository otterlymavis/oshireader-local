import AppIntents

struct RefreshFeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Feed"
    static var description = IntentDescription("Fetches the latest items for all your OshiReader watch terms.")
    // Ingestion is deliberately foreground-only (see CLAUDE.md) and a full
    // refresh can run longer than a background App Intent's time budget, so
    // bring the app forward instead of trying to run it silently.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await LocalRefreshCoordinator.shared.refresh(.foreground)
        let dialog: IntentDialog = result.addedCount > 0
            ? "Found \(result.addedCount) new item\(result.addedCount == 1 ? "" : "s")."
            : "No new items."
        return .result(dialog: dialog)
    }
}

struct SearchOshiReaderIntent: AppIntent {
    static var title: LocalizedStringResource = "Search OshiReader"
    static var description = IntentDescription("Opens OshiReader and searches for a term.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Search Term")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentNavigationManager.shared.pendingSearchQuery = query
        return .result()
    }
}

/// `SearchOshiReaderIntent` isn't listed here (its `query: String` parameter
/// can't appear in a spoken `AppShortcut` phrase — the metadata validator
/// requires an `AppEntity`/`AppEnum` for phrase-interpolated parameters), but
/// it's still a normal `AppIntent` — the Shortcuts app can add it as an
/// action, prompting for the search term, without needing a voice phrase.
struct OshiReaderAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshFeedIntent(),
            phrases: [
                "Refresh \(.applicationName)",
                "Refresh my feed in \(.applicationName)"
            ],
            shortTitle: "Refresh Feed",
            systemImageName: "arrow.clockwise"
        )
    }
}
