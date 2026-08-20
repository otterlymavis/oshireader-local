import SwiftUI
import ImageIO
import UIKit

/// Feed cards only need small images. Downsampling before UIImage creation keeps
/// large source images from causing scroll-time memory spikes.
actor FeedThumbnailLoader {
    static let shared = FeedThumbnailLoader()
    /// Larger instance used by avatar layers, which can render near 300 pt.
    static let avatar = FeedThumbnailLoader(maxPixelSize: 900)

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let maxPixelSize: Int

    init(session: URLSession = .shared, maxPixelSize: Int = 144) {
        self.session = session
        self.maxPixelSize = maxPixelSize
        cache.countLimit = 100
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let maxPixelSize = maxPixelSize
        let session = session
        let task = Task<UIImage?, Never> {
            guard !Task.isCancelled,
                  let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !Task.isCancelled else { return nil }
            return Self.downsample(data: data, maxPixelSize: maxPixelSize)
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result {
            // Estimate decoded memory from actual pixels rather than points.
            let cost = result.cgImage.map { $0.bytesPerRow * $0.height }
                ?? Int(result.size.width * result.scale * result.size.height * result.scale * 4)
            cache.setObject(result, forKey: url as NSURL, cost: cost)
        }
        return result
    }

    nonisolated static func downsample(data: Data, maxPixelSize: Int) -> UIImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary
              ) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Downsampling, caching image view. Prefer this over raw `AsyncImage` for
/// any thumbnail-sized remote image — `AsyncImage` decodes at full
/// resolution with no cross-render cache, which spikes memory on scrolling
/// grids and re-fetches on every reappearance.
struct FeedThumbnailView: View {
    let url: URL
    let size: CGFloat
    let loader: FeedThumbnailLoader
    let cornerRadius: CGFloat
    let contentMode: ContentMode
    let placeholderText: String?

    @State private var image: UIImage?

    init(url: URL, size: CGFloat = 72, loader: FeedThumbnailLoader = .shared, cornerRadius: CGFloat = 8, contentMode: ContentMode = .fill, placeholderText: String? = nil) {
        self.url = url
        self.size = size
        self.loader = loader
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        self.placeholderText = placeholderText
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let placeholderText {
                Text(placeholderText)
            } else {
                Color.gray.opacity(0.1)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .cornerRadius(cornerRadius)
        .task(id: url) {
            image = nil
            let loadedImage = await loader.image(for: url)
            guard !Task.isCancelled else { return }
            image = loadedImage
        }
    }
}

struct FeedView: View {
    @StateObject private var db = LocalDB.shared
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var i18n = I18nManager.shared
    @StateObject private var refreshDiagnostics = RefreshDiagnostics.shared
    @StateObject private var refreshCoordinator = LocalRefreshCoordinator.shared
    @StateObject private var recentTermUsage = RecentTermUsageStore.shared
    
    @State private var selectedKeyword: String? = nil
    @State private var selectedPlatform: String? = nil
    @State private var mediaFilter: String = "all" // "all" | "media_only"
    @State private var daysFilter: Int = 30
    
    @State private var hasLoadedOnce = false
    @State private var displayedCount: Int = 20
    @State private var cachedFilteredItems: [FeedItem]
    @State private var cachedVisibleItems: [FeedItem]
    @State private var cachedOrderedPlatforms: [String]
    @State private var savedItemIds: Set<String>
    @State private var showFilterSheet = false
    @State private var showAddUrlSheet = false
    @State private var customUrlAddFailure: CustomUrlAddResult?
    @State private var showReorderSheet = false
    @State private var pendingHiddenFeedItem: FeedItem? = nil
    @State private var pendingUnfollowTerm: WatchTerm? = nil
    
    @State private var customUrlString = ""
    @State private var customUrlTitle = ""
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedItem: FeedItem? = nil

    init() {
        let db = LocalDB.shared
        let initialFilteredItems = Self.makeFilteredItems(
            db: db,
            keyword: nil,
            platform: nil,
            mediaFilter: "all",
            days: 30
        )
        _cachedFilteredItems = State(initialValue: initialFilteredItems)
        _cachedVisibleItems = State(initialValue: Array(initialFilteredItems.prefix(20)))
        _savedItemIds = State(initialValue: Set(db.savedPages.map(\.id)))
        _cachedOrderedPlatforms = State(initialValue: Self.makeOrderedPlatforms(db: db))
    }
    
    private let timeRanges = [
        (label: "allTime", days: 0),
        (label: "days3", days: 3),
        (label: "month1", days: 30),
        (label: "months3", days: 90),
        (label: "months6", days: 180)
    ]
    
    private var canLoadMore: Bool {
        displayedCount < min(cachedFilteredItems.count, 100)
    }

    private var remainingLoadMoreCount: Int {
        max(min(cachedFilteredItems.count, 100) - displayedCount, 0)
    }

    private func makeFilteredItems() -> [FeedItem] {
        Self.makeFilteredItems(
            db: db,
            keyword: selectedKeyword,
            platform: selectedPlatform,
            mediaFilter: mediaFilter,
            days: daysFilter
        )
    }

    static func makeFilteredItems(
        db: LocalDB,
        keyword: String?,
        platform: String?,
        mediaFilter: String,
        days: Int
    ) -> [FeedItem] {
        var result = db.queryFeed(keyword: keyword, days: days)
        if let platform {
            result = result.filter { Self.matchesPlatform($0, platformId: platform) }
        }
        if mediaFilter == "media_only" {
            let mediaPlatforms: Set<String> = ["youtube", "niconico", "tver"]
            result = result.filter {
                $0.media_type == "video" ||
                    $0.media_type == "image" ||
                    mediaPlatforms.contains(PlatformRegistry.normalizeID($0.platform))
            }
        }
        return result
    }
    
    var orderedPlatforms: [String] { cachedOrderedPlatforms }

    static func makeOrderedPlatforms(db: LocalDB) -> [String] {
        let subs = db.subscribedPlatforms
        guard let order = db.sourcesOrder else { return subs }
        let orderSet = Set(order)
        let ordered = order.filter { subs.contains($0) }
        let unordered = subs.filter { !orderSet.contains($0) }
        return ordered + unordered
    }
    
    var body: some View {
        ZStack {
            theme.colors.bg.ignoresSafeArea()
            
            // Custom Wallpaper (from localDB) — remote URL or a locally-rendered
            // "My Oshi" composition file (stored by bare filename, see WallpaperRenderer).
            if let wallpaper = db.wallpaper {
                WallpaperBackground(spec: wallpaper)
            }
            
            if horizontalSizeClass == .regular {
                HStack(spacing: 0) {
                    NavigationStack {
                        mainContentColumn
                    }
                    .frame(width: 380)
                    
                    Divider()
                        .background(theme.colors.divider)
                    
                    NavigationStack {
                        if let item = selectedItem {
                            ReaderView(feedItem: item, siblingItems: cachedVisibleItems, onNavigate: { selectedItem = $0 })
                        } else {
                            VStack(spacing: 16) {
                                Text("📖")
                                    .font(.system(size: 64))
                                Text(i18n.t("feedSelectArticle"))
                                    .font(.headline)
                                    .foregroundColor(theme.colors.textSub)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(theme.colors.bg)
                        }
                    }
                }
            } else {
                NavigationStack {
                    mainContentColumn
                        .navigationDestination(for: FeedItem.self) { item in
                            ReaderView(feedItem: item, siblingItems: cachedVisibleItems)
                                .onAppear { markRecentUse(for: item) }
                        }
                }
            }
        }
    }
    
    private var mainContentColumn: some View {
        ZStack(alignment: .bottomTrailing) {
            feedContentStack
            
            // Floating Action Button
            floatingAddButton
        }
        .navigationTitle(i18n.t("appTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                refreshToolbarContent
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterPanel(selectedKeyword: $selectedKeyword, mediaFilter: $mediaFilter, daysFilter: $daysFilter, db: db, theme: theme, i18n: i18n, timeRanges: timeRanges)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showAddUrlSheet) {
            AddUrlSheet(customUrlString: $customUrlString, customUrlTitle: $customUrlTitle, theme: theme, i18n: i18n) {
                let result = db.addCustomUrl(url: customUrlString, title: customUrlTitle)
                guard result == .added else {
                    // Dismiss the sheet before presenting the alert — SwiftUI
                    // won't reliably show an alert on a view whose sheet is
                    // still active (same class of issue worked around in
                    // SettingsView.submitEncryptedBackupPrompt).
                    showAddUrlSheet = false
                    DispatchQueue.main.async {
                        customUrlAddFailure = result
                    }
                    return
                }
                let sourceRevision = db.dataRevision
                Task {
                    let customItems = await NetworkManager.shared.scrapeCustomUrls(db.customUrls)
                    let currentItems = db.currentCustomFeedItems(customItems)
                    if !currentItems.isEmpty {
                        _ = db.mergeItems(newItems: currentItems, sourceRevision: sourceRevision)
                    }
                }
                customUrlString = ""
                customUrlTitle = ""
                showAddUrlSheet = false
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showReorderSheet) {
            ReorderSourcesSheet(theme: theme, i18n: i18n)
        }
        .alert(
            i18n.tFormat("hidePostTitleFmt", pendingHiddenFeedItem?.title ?? pendingHiddenFeedItem?.watch_term_keyword ?? ""),
            isPresented: Binding(
                get: { pendingHiddenFeedItem != nil },
                set: { if !$0 { pendingHiddenFeedItem = nil } }
            )
        ) {
            Button(i18n.t("cancel"), role: .cancel) {
                pendingHiddenFeedItem = nil
            }
            Button(i18n.t("hidePostConfirm"), role: .destructive) {
                confirmHidePost()
            }
        } message: {
            Text(i18n.t("hidePostMessage"))
        }
        .alert(
            i18n.tFormat("stopFollowingTitleFmt", pendingUnfollowTerm?.keyword ?? ""),
            isPresented: Binding(
                get: { pendingUnfollowTerm != nil },
                set: { if !$0 { pendingUnfollowTerm = nil } }
            )
        ) {
            Button(i18n.t("cancel"), role: .cancel) {
                pendingUnfollowTerm = nil
            }
            Button(i18n.t("stopFollowing"), role: .destructive) {
                confirmStopFollowing()
            }
        } message: {
            Text(i18n.t("stopFollowingMessage"))
        }
        .alert(
            i18n.t("addCustomFeed"),
            isPresented: Binding(
                get: { customUrlAddFailure != nil },
                set: { if !$0 { customUrlAddFailure = nil } }
            )
        ) {
            Button(i18n.t("ok"), role: .cancel) {}
        } message: {
            Text(customUrlAddFailureMessage)
        }
        .onChange(of: selectedKeyword) { _, keyword in handleSelectedKeywordChange(keyword) }
        .onChange(of: selectedPlatform) { _, _ in rebuildFeedCache(resetDisplayedCount: true) }
        .onChange(of: daysFilter) { _, newDays in handleDaysFilterChange(newDays) }
        .onChange(of: mediaFilter) { _, _ in rebuildFeedCache(resetDisplayedCount: true) }
        .onChange(of: db.feedItems) { _, _ in rebuildFeedCache() }
        .onChange(of: db.subscribedPlatforms) { _, _ in
            rebuildFeedCache(resetDisplayedCount: true)
            cachedOrderedPlatforms = Self.makeOrderedPlatforms(db: db)
        }
        .onChange(of: db.sourcesOrder) { _, _ in cachedOrderedPlatforms = Self.makeOrderedPlatforms(db: db) }
        .onChange(of: db.terms) { _, _ in rebuildFeedCache(resetDisplayedCount: true) }
        .onChange(of: db.hiddenItems) { _, _ in rebuildFeedCache(resetDisplayedCount: true) }
        .onChange(of: db.savedPages) { _, newValue in savedItemIds = Set(newValue.map(\.id)) }
        .onAppear {
            rebuildFeedCache()
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true
            Task {
                // First launch with terms but no cached items → pull an initial feed.
                if db.feedItems.isEmpty, !db.terms.isEmpty {
                    await refreshFeed()
                }
            }
        }
    }

    private var feedContentStack: some View {
        VStack(spacing: 0) {
            filterSummaryBar
            platformStrip
            feedMainState
        }
    }

    @ViewBuilder
    private var platformStrip: some View {
        if !orderedPlatforms.isEmpty {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        allPlatformFilterButton()
                        ForEach(orderedPlatforms, id: \.self) { platformId in
                            platformFilterButton(for: platformId)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }

                Button(action: { showReorderSheet.toggle() }) {
                    ReorderSourcesButtonLabel(color: theme.colors.textMuted, background: theme.colors.divider)
                }
                .accessibilityIdentifier("feed.reorderSourcesButton")
                .accessibilityLabel(i18n.t("reorderSources"))
            }
            .background(theme.colors.card)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(theme.colors.divider),
                alignment: .bottom
            )
        }
    }

    @ViewBuilder
    private var feedMainState: some View {
        if refreshCoordinator.isRefreshing && cachedFilteredItems.isEmpty {
            feedLoadingState
        } else if cachedVisibleItems.isEmpty {
            emptyFeedState
        } else {
            feedList
        }
    }

    private var floatingAddButton: some View {
        Button(action: { showAddUrlSheet.toggle() }) {
            AddFeedButtonLabel(background: theme.colors.primary)
        }
        .accessibilityLabel(i18n.t("addCustomFeed"))
        .accessibilityIdentifier("feed.addCustomUrlButton")
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    private var filterSummaryBar: some View {
        Button(action: { showFilterSheet.toggle() }) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(filterCount > 0 ? theme.colors.primary : theme.colors.textMuted)
                Text(i18n.t("filter"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(filterCount > 0 ? theme.colors.primary : theme.colors.textSub)

                if filterCount > 0 {
                    Text("\(filterCount)")
                        .font(.caption2)
                        .bold()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.colors.primary)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }

                activeFilterPills

                Spacer()
                Image(systemName: showFilterSheet ? "chevron.up" : "chevron.down")
                    .foregroundColor(theme.colors.textMuted)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.colors.card)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(theme.colors.divider),
                alignment: .bottom
            )
        }
        .accessibilityIdentifier("feed.filterButton")
    }

    @ViewBuilder
    private var refreshToolbarContent: some View {
        if refreshCoordinator.isRefreshing {
            ProgressView()
                .tint(theme.colors.primary)
        } else {
            Button(action: {
                Task {
                    await refreshFeed()
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(theme.colors.primary)
            }
            .accessibilityLabel(i18n.t("refresh"))
            .accessibilityIdentifier("feed.refreshButton")
        }
    }

    @ViewBuilder
    private var activeFilterPills: some View {
        if let keyword = selectedKeyword {
            PillView(text: keyword, theme: theme)
        }
        if let platform = selectedPlatform {
            let metadata = theme.metadata(for: platform)
            PillView(text: "\(metadata.icon) \(metadata.name)", bgColor: metadata.bg, fgColor: metadata.fg)
        }
        if mediaFilter == "media_only" {
            PillView(text: "📹 " + i18n.t("mediaOnly"), theme: theme)
        }
        if daysFilter != 30, let range = timeRanges.first(where: { $0.days == daysFilter }) {
            PillView(text: i18n.t(range.label), theme: theme)
        }
    }

    private var feedLoadingState: some View {
        Group {
            Spacer()
            ProgressView()
                .tint(theme.colors.primary)
            Spacer()
        }
    }

    private var emptyFeedState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Text("≽՞•ﻌ•՞≼")
                    .font(.system(size: 40))
                    .accessibilityHidden(true)
                Text(isFilteredEmptyState ? i18n.t("feedFilteredEmpty") : i18n.t("feedEmpty"))
                    .font(.headline)
                    .foregroundColor(theme.colors.primary)
                Text(isFilteredEmptyState ? i18n.t("feedFilteredEmptyBody") : i18n.t("feedEmptyBody"))
                    .font(.subheadline)
                    .foregroundColor(theme.colors.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if isFilteredEmptyState {
                    Button {
                        clearFeedFilters()
                    } label: {
                        Text(i18n.t("clearFilters"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(theme.colors.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(theme.colors.primaryBg)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feed.clearFiltersButton")
                }
            }
            Spacer()
        }
    }

    private var feedList: some View {
        List {
            ForEach(cachedVisibleItems) { item in
                feedListRow(for: item)
            }

            if canLoadMore {
                Button {
                    loadMoreFeedItems()
                } label: {
                    HStack {
                        Spacer()
                        Text(i18n.tFormat("feedLoadMoreFmt", remainingLoadMoreCount))
                            .font(.subheadline)
                            .foregroundColor(theme.colors.primary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("feed.loadMoreButton")
            }
        }
        .listStyle(.plain)
        .refreshable {
            await refreshFeed()
        }
    }
    
    private var filterCount: Int {
        var count = 0
        if selectedKeyword != nil { count += 1 }
        if selectedPlatform != nil { count += 1 }
        if mediaFilter == "media_only" { count += 1 }
        if daysFilter != 30 { count += 1 }
        return count
    }

    private var customUrlAddFailureMessage: String {
        switch customUrlAddFailure {
        case .limitReached: return i18n.t("customUrlLimitReached")
        case .duplicate: return i18n.t("customUrlDuplicate")
        case .invalidURL, .added, nil: return i18n.t("invalidUrl")
        }
    }

    private var isFilteredEmptyState: Bool {
        let unfiltered = Self.makeFilteredItems(db: db, keyword: nil, platform: nil, mediaFilter: "all", days: 30)
        guard !unfiltered.isEmpty else { return false }
        return cachedFilteredItems.isEmpty
    }

    private func clearFeedFilters() {
        selectedKeyword = nil
        selectedPlatform = nil
        mediaFilter = "all"
        daysFilter = 30
    }

    private func handleSelectedKeywordChange(_ keyword: String?) {
        rebuildFeedCache(resetDisplayedCount: true)
        if let keyword {
            recentTermUsage.markUsed(keyword: keyword, terms: db.terms)
        }
    }

    private func handleDaysFilterChange(_ newDays: Int) {
        rebuildFeedCache(resetDisplayedCount: true)
        if newDays == 0 {
            Task { await refreshFeed() }
        }
    }

    private func rebuildFeedCache(resetDisplayedCount: Bool = false) {
        let effectiveDisplayedCount = resetDisplayedCount ? 20 : displayedCount
        if displayedCount != effectiveDisplayedCount {
            displayedCount = effectiveDisplayedCount
        }

        let filtered = makeFilteredItems()
        if cachedFilteredItems != filtered {
            cachedFilteredItems = filtered
        }
        updateVisibleFeedCache(displayedCount: effectiveDisplayedCount, filteredItems: filtered)
    }

    private func updateVisibleFeedCache(displayedCount: Int, filteredItems: [FeedItem]? = nil) {
        let sourceItems = filteredItems ?? cachedFilteredItems
        let visible = Array(sourceItems.prefix(displayedCount))
        if cachedVisibleItems != visible {
            cachedVisibleItems = visible
        }
    }

    private func loadMoreFeedItems() {
        let nextCount = min(displayedCount + 20, 100)
        guard nextCount != displayedCount else { return }
        displayedCount = nextCount
        updateVisibleFeedCache(displayedCount: nextCount)
    }
    
    private func refreshFeed() async {
        guard !refreshCoordinator.isRefreshing else { return }

        // Skip live network during UI tests (fixtures are seeded in LocalDB).
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            if ProcessInfo.processInfo.arguments.contains("--uitesting-source-status") {
                refreshDiagnostics.resetSourceStatuses()
                refreshDiagnostics.recordSourceStatuses([
                    SourceRefreshStatus(id: "news", outcome: .received, itemCount: 1, queryCount: 1),
                    SourceRefreshStatus(id: "barks", outcome: .noResults, itemCount: 0, queryCount: 1),
                ])
                refreshDiagnostics.recordCompletedSourceStatuses(refreshDiagnostics.sourceStatuses)
            }
            refreshDiagnostics.finish(succeeded: true, partial: false)
            return
        }

        _ = await refreshCoordinator.refresh(.foreground)
    }

    /// On-demand ingest of a single source (used when a platform chip is tapped
    /// and we have no cached items for it yet).
    private func ingestPlatform(_ platformId: String) async {
        if ProcessInfo.processInfo.arguments.contains("--uitesting") { return }
        _ = await refreshCoordinator.refresh(.platform(platformId))
    }

    private func markRecentUse(for item: FeedItem) {
        recentTermUsage.markUsed(keyword: item.watch_term_keyword, terms: db.terms)
    }

    private func openFeedItem(_ item: FeedItem) {
        markRecentUse(for: item)
        selectedItem = item
    }

    private func platformButtonBackground(isSelected: Bool, metadata: PlatformMetadata) -> Color {
        if theme.style == .standard {
            return isSelected ? theme.colors.primary : theme.standardBadgeBg
        }
        return isSelected ? metadata.accent : metadata.bg
    }

    private func platformButtonForeground(isSelected: Bool, metadata: PlatformMetadata) -> Color {
        if theme.style == .standard {
            return isSelected ? Color.white : theme.standardBadgeFg
        }
        return isSelected ? Color.white : metadata.fg
    }

    private func allPlatformFilterButton() -> some View {
        let isSelected = selectedPlatform == nil
        let background = isSelected ? theme.colors.primary : theme.colors.divider
        let foreground = isSelected ? Color.white : theme.colors.textMuted

        return Button(action: { selectedPlatform = nil }) {
            PlatformFilterButtonLabel(
                icon: "🌐",
                name: i18n.t("all"),
                isSelected: isSelected,
                background: background,
                foreground: foreground
            )
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("feed.platform.all")
    }

    private func platformFilterButton(for platformId: String) -> some View {
        let metadata = theme.metadata(for: platformId)
        let isSelected = selectedPlatform == platformId
        let background = platformButtonBackground(isSelected: isSelected, metadata: metadata)
        let foreground = platformButtonForeground(isSelected: isSelected, metadata: metadata)

        return Button(action: {
            selectedPlatform = isSelected ? nil : platformId
            if !isSelected && !hasItems(for: platformId) {
                Task {
                    await ingestPlatform(platformId)
                }
            }
        }) {
            PlatformFilterButtonLabel(
                icon: metadata.icon,
                name: metadata.name,
                isSelected: isSelected,
                background: background,
                foreground: foreground
            )
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("feed.platform.\(platformId)")
    }

    @ViewBuilder
    private func feedListRow(for item: FeedItem) -> some View {
        if horizontalSizeClass == .regular {
            Button(action: { openFeedItem(item) }) {
                FeedCard(item: item, isSaved: savedItemIds.contains(item.id), theme: theme)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.colors.primary, lineWidth: selectedItem?.id == item.id ? 2 : 0)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityIdentifier("feed.card")
            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                stopFollowingButton(for: item)
                hidePostButton(for: item)
                Button(role: .destructive) {
                    deleteFeedItem(item, clearSelection: true)
                } label: {
                    Label(i18n.t("delete"), systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                saveToggleButton(for: item)
                shareButton(for: item)
            }
            .contextMenu {
                saveToggleButton(for: item)
                shareButton(for: item)
                stopFollowingButton(for: item)
                hidePostButton(for: item)
            }
        } else {
            NavigationLink(value: item) {
                FeedCard(item: item, isSaved: savedItemIds.contains(item.id), theme: theme)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityIdentifier("feed.card")
            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                stopFollowingButton(for: item)
                hidePostButton(for: item)
                Button(role: .destructive) {
                    deleteFeedItem(item, clearSelection: false)
                } label: {
                    Label(i18n.t("delete"), systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                saveToggleButton(for: item)
                shareButton(for: item)
            }
            .contextMenu {
                saveToggleButton(for: item)
                shareButton(for: item)
                stopFollowingButton(for: item)
                hidePostButton(for: item)
            }
        }
    }

    @ViewBuilder
    private func saveToggleButton(for item: FeedItem) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            _ = db.toggleSaved(item: item)
        } label: {
            Label(savedItemIds.contains(item.id) ? i18n.t("unsave") : i18n.t("save"),
                  systemImage: savedItemIds.contains(item.id) ? "bookmark.slash" : "bookmark")
        }
        .tint(theme.colors.primary)
    }

    @ViewBuilder
    private func shareButton(for item: FeedItem) -> some View {
        if let url = URL(string: item.url) {
            ShareLink(item: url) {
                Label(i18n.t("share"), systemImage: "square.and.arrow.up")
            }
            .tint(theme.colors.primary)
        }
    }

    @ViewBuilder
    private func hidePostButton(for item: FeedItem) -> some View {
        Button(role: .destructive) {
            pendingHiddenFeedItem = item
        } label: {
            Label(i18n.t("hidePost"), systemImage: "eye.slash")
        }
        .tint(.red)
    }

    @ViewBuilder
    private func stopFollowingButton(for item: FeedItem) -> some View {
        if let term = db.term(matchingKeyword: item.watch_term_keyword) {
            Button(role: .destructive) {
                pendingUnfollowTerm = term
            } label: {
                Label(i18n.t("stopFollowing"), systemImage: "person.crop.circle.badge.xmark")
            }
            .tint(.red)
        }
    }

    private func deleteFeedItem(_ item: FeedItem, clearSelection: Bool) {
        db.deleteFeedItem(id: item.id, watchTermKeyword: item.watch_term_keyword)
        if clearSelection, selectedItem?.id == item.id {
            selectedItem = nil
        }
    }

    private func confirmHidePost() {
        guard let item = pendingHiddenFeedItem else { return }
        pendingHiddenFeedItem = nil
        deleteFeedItem(item, clearSelection: true)
    }

    private func confirmStopFollowing() {
        guard let term = pendingUnfollowTerm else { return }
        pendingUnfollowTerm = nil
        if selectedKeyword == term.keyword {
            selectedKeyword = nil
        }
        if selectedItem?.watch_term_keyword == term.keyword {
            selectedItem = nil
        }
        db.deleteTerm(id: term.id)
    }

    private func hasItems(for platformId: String) -> Bool {
        db.feedItems.contains { Self.matchesPlatform($0, platformId: platformId) }
    }

    private static func matchesPlatform(_ item: FeedItem, platformId: String) -> Bool {
        PlatformRegistry.normalizeID(item.platform) == platformId
    }

}

// MARK: - Subviews

struct PillView: View {
    let text: String
    var bgColor: Color? = nil
    var fgColor: Color? = nil
    var theme: ThemeManager? = nil
    @StateObject private var appearance = AppearanceManager.shared
    
    var body: some View {
        Text(text)
            .font(appearance.font(size: 11))
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bgColor ?? theme?.colors.divider ?? Color.gray.opacity(0.2))
            .foregroundColor(fgColor ?? theme?.colors.textSub ?? Color.primary)
            .clipShape(Capsule())
    }
}

private struct PlatformFilterButtonLabel: View {
    let icon: String
    let name: String
    let isSelected: Bool
    let background: Color
    let foreground: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(icon)
                .font(.system(size: 18))
            Text(name)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundColor(foreground)
                .lineLimit(1)
        }
        .frame(width: 58)
        .frame(minHeight: 58)
        .background(background)
        .cornerRadius(10)
    }
}

private struct ReorderSourcesButtonLabel: View {
    let color: Color
    let background: Color

    var body: some View {
        Text("≡")
            .font(.title3)
            .foregroundColor(color)
            .frame(width: 44)
            .frame(minHeight: 58)
            .background(background)
            .cornerRadius(10)
            .padding(.trailing, 10)
    }
}

private struct AddFeedButtonLabel: View {
    let background: Color

    var body: some View {
        Image(systemName: "plus")
            .font(.title2)
            .foregroundColor(.white)
            .frame(width: 52, height: 52)
            .background(background)
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
    }
}

struct FeedCard: View {
    let item: FeedItem
    let isSaved: Bool
    let theme: ThemeManager
    @StateObject private var appearance = AppearanceManager.shared
    @StateObject private var i18n = I18nManager.shared

    private var accessibilitySummary: String {
        let meta = theme.metadata(for: item.platform)
        let parts: [String?] = [
            cleanDisplayText(item.title),
            cleanDisplayText(item.author),
            item.watch_term_keyword.isEmpty ? nil : item.watch_term_keyword,
            meta.name,
            isSaved ? i18n.t("tabSaved") : nil,
            relativeTime(from: item.published_at)
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        let meta = theme.metadata(for: item.platform)
        let badgeBg = theme.style == .standard ? theme.standardBadgeBg : meta.bg
        let badgeFg = theme.style == .standard ? theme.standardBadgeFg : meta.fg
        let titleColor = theme.style == .standard ? theme.colors.text : meta.fg
        
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                // Platform tag badge
                HStack(spacing: 3) {
                    Text(meta.icon)
                        .font(appearance.font(size: 12))
                    Text(meta.name)
                        .font(appearance.font(size: 11))
                        .fontWeight(.bold)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(badgeBg)
                .foregroundColor(badgeFg)
                .cornerRadius(6)
                
                if !item.watch_term_keyword.isEmpty {
                    Text(item.watch_term_keyword)
                        .font(appearance.font(size: 11))
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.colors.divider)
                        .foregroundColor(theme.colors.textSub)
                        .cornerRadius(6)
                }
                
                Spacer()
                
                if isSaved {
                    Image(systemName: "bookmark.fill")
                        .foregroundColor(theme.colors.primary)
                        .font(.caption)
                }
                
                Text(relativeTime(from: item.published_at))
                    .font(appearance.font(size: 11))
                    .foregroundColor(theme.colors.textMuted)
            }
            
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = cleanDisplayText(item.title) {
                        Text(title)
                            .font(appearance.font(size: 15))
                            .fontWeight(.bold)
                            .foregroundColor(titleColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    
                    if let author = cleanDisplayText(item.author) {
                        Text(author)
                            .font(appearance.font(size: 12))
                            .fontWeight(.medium)
                            .foregroundColor(theme.colors.textMuted)
                            .lineLimit(1)
                    }
                    
                    if let content = cleanDisplayText(item.content_text) {
                        Text(content)
                            .font(appearance.font(size: 12))
                            .foregroundColor(theme.colors.textSub)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 2)
                    }
                }
                
                Spacer()
                
                // Optional Thumbnail URL
                if let thumb = item.thumbnail_url, let url = URL(string: thumb) {
                    FeedThumbnailView(url: url)
                }
            }
        }
        .padding(12)
        .background(theme.colors.card)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(theme.mode == .dark ? 0.2 : 0.04), radius: 5, x: 0, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("feed.card.\(item.id)")
    }
    
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func relativeTime(from isoDate: String) -> String {
        guard let date = parseISO8601Date(isoDate) else { return "" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Sheet Components

struct FilterPanel: View {
    @Binding var selectedKeyword: String?
    @Binding var mediaFilter: String
    @Binding var daysFilter: Int
    @ObservedObject var db: LocalDB
    let theme: ThemeManager
    let i18n: I18nManager
    let timeRanges: [(label: String, days: Int)]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(i18n.t("filter"))
                    .font(.headline)
                    .foregroundColor(theme.colors.text)
                    .padding(.top, 8)
                
                // All / Media Only
                VStack(alignment: .leading, spacing: 8) {
                    Text(i18n.t("allInfo") + " / " + i18n.t("mediaOnly"))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(theme.colors.textMuted)
                        .textCase(.uppercase)
                    
                    HStack(spacing: 8) {
                        FilterButton(
                            text: "📄 " + i18n.t("allInfo"),
                            isSelected: mediaFilter == "all",
                            theme: theme,
                            accessibilityId: "filter.allInfoButton"
                        ) {
                            mediaFilter = "all"
                        }
                        FilterButton(
                            text: "📹 " + i18n.t("mediaOnly"),
                            isSelected: mediaFilter == "media_only",
                            theme: theme,
                            accessibilityId: "filter.mediaOnlyButton"
                        ) {
                            mediaFilter = "media_only"
                        }
                    }
                }
                
                // Period
                VStack(alignment: .leading, spacing: 8) {
                    Text(i18n.t("period"))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(theme.colors.textMuted)
                        .textCase(.uppercase)
                    
                    FlowLayout(spacing: 6) {
                        ForEach(timeRanges, id: \.days) { range in
                            FilterButton(text: i18n.t(range.label), isSelected: daysFilter == range.days, theme: theme) {
                                daysFilter = range.days
                            }
                        }
                    }
                }
                
                // Keywords (Watch terms)
                VStack(alignment: .leading, spacing: 8) {
                    Text(i18n.t("keyword"))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(theme.colors.textMuted)
                        .textCase(.uppercase)
                    
                    FlowLayout(spacing: 6) {
                        FilterButton(text: i18n.t("all"), isSelected: selectedKeyword == nil, theme: theme) {
                            selectedKeyword = nil
                        }
                        ForEach(db.terms) { term in
                            FilterButton(text: term.keyword, isSelected: selectedKeyword == term.keyword, theme: theme) {
                                selectedKeyword = term.keyword
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .accessibilityIdentifier("filter.sheet")
        .background(theme.colors.bg)
    }
}

struct FilterButton: View {
    let text: String
    let isSelected: Bool
    let theme: ThemeManager
    var accessibilityId: String? = nil
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? theme.colors.primary : theme.colors.divider)
                .foregroundColor(isSelected ? .white : theme.colors.textSub)
                .cornerRadius(999)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier(accessibilityId ?? "filter.option.\(text)")
    }
}

// MARK: - FlowLayout helper for Wrapping Chips
struct FlowLayout: Layout {
    var spacing: CGFloat
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var width: CGFloat = 0
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxRowHeight: CGFloat = 0
        
        let maxW = proposal.width ?? 300
        
        for size in sizes {
            if currentX + size.width > maxW {
                currentX = 0
                currentY += maxRowHeight + spacing
                maxRowHeight = 0
            }
            currentX += size.width + spacing
            width = max(width, currentX)
            maxRowHeight = max(maxRowHeight, size.height)
            height = max(height, currentY + size.height)
        }
        return CGSize(width: width, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var maxRowHeight: CGFloat = 0
        
        let maxW = bounds.width
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.minX + maxW {
                currentX = bounds.minX
                currentY += maxRowHeight + spacing
                maxRowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            maxRowHeight = max(maxRowHeight, size.height)
        }
    }
}

struct AddUrlSheet: View {
    @Binding var customUrlString: String
    @Binding var customUrlTitle: String
    let theme: ThemeManager
    let i18n: I18nManager
    let onSave: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(i18n.t("addCustomFeed"))
                .font(.headline)
                .foregroundColor(theme.colors.text)
                .padding(.top, 10)
            
            TextField(i18n.t("feedTitlePlaceholder"), text: $customUrlTitle)
                .padding()
                .background(theme.colors.card)
                .cornerRadius(8)
                .foregroundColor(theme.colors.text)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.colors.border, lineWidth: 1))
                .accessibilityIdentifier("customUrl.titleField")
            
            TextField(i18n.t("urlPlaceholder"), text: $customUrlString)
                .padding()
                .background(theme.colors.card)
                .cornerRadius(8)
                .foregroundColor(theme.colors.text)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.colors.border, lineWidth: 1))
                .keyboardType(.URL)
                .autocapitalization(.none)
                .accessibilityIdentifier("customUrl.urlField")
            
            Button(action: onSave) {
                Text(i18n.t("save"))
                    .bold()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(theme.colors.primary)
                    .cornerRadius(10)
            }
            .accessibilityIdentifier("customUrl.saveButton")
            .disabled(customUrlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(customUrlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)
            
            Spacer()
        }
        .padding(18)
        .background(theme.colors.bg)
    }
}

struct ReorderSourcesSheet: View {
    @StateObject private var db = LocalDB.shared
    let theme: ThemeManager
    let i18n: I18nManager
    
    @Environment(\.dismiss) private var dismiss
    @State private var platforms: [String] = []
    
    var body: some View {
        NavigationStack {
            VStack {
                List {
                    ForEach(platforms, id: \.self) { pId in
                        let meta = theme.metadata(for: pId)
                        HStack(spacing: 8) {
                            Text(meta.icon)
                                .font(.system(size: 16))
                            Text(meta.name)
                                .font(.subheadline)
                                .foregroundColor(theme.colors.text)
                            Spacer()
                            Image(systemName: "line.3.horizontal")
                                .font(.subheadline)
                                .foregroundColor(theme.colors.textMuted)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    .onMove { indices, newOffset in
                        platforms.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 36)
                
                Button(action: {
                    db.setSourcesOrder(order: platforms)
                    dismiss()
                }) {
                    Text(i18n.t("save"))
                        .bold()
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.colors.primary)
                        .cornerRadius(10)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle(i18n.t("reorderSources"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(i18n.t("cancel")) { dismiss() }
                }
            }
            .onAppear {
                platforms = db.subscribedPlatforms
                if let order = db.sourcesOrder {
                    let orderSet = Set(order)
                    let ordered = order.filter { platforms.contains($0) }
                    let unordered = platforms.filter { !orderSet.contains($0) }
                    platforms = ordered + unordered
                }
            }
            .background(theme.colors.bg)
        }
    }
}
