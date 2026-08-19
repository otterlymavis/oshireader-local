import SwiftUI
import WidgetKit

struct OshiReaderWidgetEntry: TimelineEntry {
    let date: Date
    let termKeyword: String?
    let items: [FeedItem]
}

struct OshiReaderWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = OshiReaderWidgetEntry
    typealias Intent = SelectWatchTermIntent

    func placeholder(in context: Context) -> OshiReaderWidgetEntry {
        OshiReaderWidgetEntry(date: Date(), termKeyword: nil, items: [])
    }

    func snapshot(for configuration: SelectWatchTermIntent, in context: Context) async -> OshiReaderWidgetEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectWatchTermIntent, in context: Context) async -> Timeline<OshiReaderWidgetEntry> {
        // The host app pushes a fresh snapshot + WidgetCenter.reloadAllTimelines()
        // on every feed change, so this fallback window only matters if the
        // app hasn't been opened in a while.
        let nextRefresh = Date().addingTimeInterval(4 * 60 * 60)
        return Timeline(entries: [entry(for: configuration)], policy: .after(nextRefresh))
    }

    private func entry(for configuration: SelectWatchTermIntent) -> OshiReaderWidgetEntry {
        guard let term = configuration.term else {
            return OshiReaderWidgetEntry(date: Date(), termKeyword: nil, items: [])
        }
        let items = WidgetSnapshotStore.read()?.itemsByTermID[term.id] ?? []
        return OshiReaderWidgetEntry(date: Date(), termKeyword: term.keyword, items: items)
    }
}

struct OshiReaderWidgetEntryView: View {
    let entry: OshiReaderWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let termKeyword = entry.termKeyword {
                Text(termKeyword)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if entry.items.isEmpty {
                Spacer(minLength: 0)
                Text(entry.termKeyword == nil ? "Long-press to choose a watch term" : "No recent items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.items.prefix(3)) { item in
                    Link(destination: widgetArticleURL(for: item) ?? URL(string: "oshireader://feed")!) {
                        HStack(alignment: .top, spacing: 6) {
                            Text(platformIcon(for: item.platform))
                                .font(.caption)
                            Text(item.title ?? item.url)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func platformIcon(for platform: String) -> String {
        PlatformRegistry.definition(for: PlatformRegistry.normalizeID(platform))?.icon ?? "📰"
    }
}

struct OshiReaderWidget: Widget {
    let kind = "com.otterpia.oshireader.OshiReaderWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectWatchTermIntent.self, provider: OshiReaderWidgetProvider()) { entry in
            OshiReaderWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("OshiReader")
        .description("Latest items for one of your watch terms.")
        .supportedFamilies([.systemMedium])
    }
}
