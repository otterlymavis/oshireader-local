import AppIntents

/// Lightweight `AppEntity` wrapping a `WidgetTermOption` so the widget's
/// configuration UI can list watch terms without depending on `WatchTerm` or
/// `LocalDB` — the extension only ever sees what the host app published into
/// the shared App Group container.
struct WatchTermEntity: AppEntity {
    let id: String
    let keyword: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Watch Term"
    static var defaultQuery = WatchTermEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(keyword)")
    }
}

struct WatchTermEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WatchTermEntity] {
        let options = WidgetSnapshotStore.read()?.terms ?? []
        return options
            .filter { identifiers.contains($0.id) }
            .map { WatchTermEntity(id: $0.id, keyword: $0.keyword) }
    }

    func suggestedEntities() async throws -> [WatchTermEntity] {
        let options = WidgetSnapshotStore.read()?.terms ?? []
        return options.map { WatchTermEntity(id: $0.id, keyword: $0.keyword) }
    }
}

struct SelectWatchTermIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Watch Term"
    static var description = IntentDescription("Choose which watch term this widget follows.")

    @Parameter(title: "Watch Term")
    var term: WatchTermEntity?
}
