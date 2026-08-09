import Foundation
import Combine

private struct LocalRestoreManifest: Codable {
    let stagingDirectory: String
    let files: [String]
    let wallpaper: String?
    let sourcesOrder: [String]?
}

enum FeedItemPolicy {
    static func isLegacyYouTubeGoogleNewsFallback(_ item: FeedItem) -> Bool {
        guard PlatformRegistry.normalizeID(item.platform) == "youtube" else { return false }
        if item.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "google_news" { return true }
        if item.id.contains(":gnews:") { return true }
        guard let host = URL(string: item.url)?.host?.lowercased() else { return false }
        return host == "news.google.com" || host.hasSuffix(".news.google.com")
    }

    static func isLegacyUnmarkedYouTubeEstimate(_ item: FeedItem) -> Bool {
        guard PlatformRegistry.normalizeID(item.platform) == "youtube" else { return false }
        return item.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    static func shouldPruneLegacyYouTubeItem(_ item: FeedItem) -> Bool {
        isLegacyYouTubeGoogleNewsFallback(item) || isLegacyUnmarkedYouTubeEstimate(item)
    }
}

class LocalDB: ObservableObject {
    static let shared = LocalDB()
    static let maximumBackupBytes = 20 * 1024 * 1024
    static let maximumProfileTransferBytes = 22 * 1024 * 1024
    private static let maxFeedItems = 600
    private static let minFeedItemsPerSubscribedPlatform = 8
    private static let minFeedItemsPerDiscussionPlatform = 25
    private static let discussionActivityPlatforms: Set<String> = ["5ch", "girlschannel", "togetter"]
    private static let iso8601 = ISO8601DateFormatter()
    
    // Published states for views
    @Published var terms: [WatchTerm] = []
    @Published var feedItems: [FeedItem] = []
    @Published var savedPages: [SavedPage] = []
    @Published var customUrls: [CustomUrl] = []
    @Published var amebloBlogs: [AmebloBlog] = []
    @Published var subscribedPlatforms: [String] = []
    @Published var wallpaper: String? = nil
    @Published var sourcesOrder: [String]? = nil
    @Published var oshiAvatars: [String: String] = [:]
    @Published var compositions: [String: [AvatarLayer]] = [:]
    @Published var hiddenItems: Set<String> = []
    @Published private(set) var contentCacheGeneration: Int = 0
    @Published private(set) var dataRevision: Int = 0
    
    private let queue = DispatchQueue(label: "com.otterlymavis.oshireader.db", qos: .userInitiated)
    private let pendingWritesLock = NSLock()
    private let contentCacheGenerationLock = NSLock()
    private var pendingWrites = 0
    private var feedItemsSaveGeneration = 0
    private var pendingFeedItemsSaveWorkItem: DispatchWorkItem?
    private var contentCacheGenerationValue = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let profileStore: LocalProfileStore
    
    private init() {
        self.profileStore = LocalProfileStore.shared
        recoverPendingRestoreIfNeeded()
        loadAll()
    }
    
    // MARK: - File Paths
    private func fileURL(for name: String) -> URL {
        return profileStore.fileURL(for: name)
    }

    var activeProfile: LocalProfile { profileStore.activeProfile }
    var profiles: [LocalProfile] { profileStore.profiles }

    @MainActor
    func switchProfile(to profileID: UUID) throws {
        guard profileID != profileStore.activeProfileID else { return }
        LocalRefreshCoordinator.shared.cancel()
        flushPendingWrites()
        NotificationManager.shared.clearLocalNotifications()
        try profileStore.activateProfile(id: profileID)
        loadAll()
        RecentTermUsageStore.shared.configure(profileID: profileID)
        RefreshDiagnostics.shared.configure(profileID: profileID)
        ThemeManager.shared.configure(profileID: profileID)
        AppearanceManager.shared.configure(profileID: profileID)
        I18nManager.shared.configure(profileID: profileID)
    }

    @MainActor
    func createProfile(name: String) throws -> LocalProfile {
        try profileStore.createProfile(name: name)
    }

    @MainActor
    func renameProfile(id: UUID, name: String) throws {
        try profileStore.renameProfile(id: id, name: name)
    }

    @MainActor
    func deleteProfile(id: UUID) throws {
        let wasActive = id == profileStore.activeProfileID
        if wasActive {
            guard profileStore.profiles.count > 1 else { throw LocalProfileError.cannotDeleteLastProfile }
            let replacement = profileStore.profiles.first { $0.id != id }!
            try switchProfile(to: replacement.id)
        } else {
            clearNotificationsForProfile(id)
        }
        try profileStore.deleteProfile(id: id)
    }

    @MainActor
    private func clearNotificationsForProfile(_ profileID: UUID) {
        let termsURL = profileStore.fileURL(for: "terms", profileID: profileID)
        guard let data = try? Data(contentsOf: termsURL),
              let terms = try? decoder.decode([WatchTerm].self, from: data) else { return }
        for term in terms {
            NotificationManager.shared.clearNotification(forTermID: term.id)
        }
    }
    
    // MARK: - Load and Save Helpers
    private func loadAll() {
        let loadedTerms: [WatchTerm] = loadFromFile(name: "terms", defaultValue: [])
        self.terms = loadedTerms.map(Self.normalizedTerm)
        if self.terms != loadedTerms {
            saveToFile(name: "terms", value: self.terms)
        }
        let loadedFeedItems: [FeedItem] = loadFromFile(name: "feed_items", defaultValue: [])
        let loadedCustomUrls: [CustomUrl] = loadFromFile(name: "custom_urls", defaultValue: [])
        let loadedCustomURLImport = Self.normalizedCustomUrlImport(loadedCustomUrls)
        self.customUrls = loadedCustomURLImport.urls
        let normalizedLoadedCustomUrls = self.customUrls != loadedCustomUrls
        if normalizedLoadedCustomUrls {
            saveToFile(name: "custom_urls", value: self.customUrls)
        }
        let loadedSavedPages: [SavedPage] = loadFromFile(name: "saved_pages", defaultValue: [])
        self.savedPages = Self.normalizedImportedSavedPages(loadedSavedPages, customURLImport: loadedCustomURLImport)
        let normalizedLoadedSavedPages = self.savedPages != loadedSavedPages
        if normalizedLoadedSavedPages {
            saveToFile(name: "saved_pages", value: self.savedPages)
        }
        self.feedItems = Self.normalizedImportedFeedItems(loadedFeedItems, customURLImport: loadedCustomURLImport)
        let normalizedLoadedFeedItems = self.feedItems != loadedFeedItems
        let prunedLegacyYouTubeItemKeys = pruneLegacyYouTubeItems()
        self.amebloBlogs = loadFromFile(name: "ameblo_blogs", defaultValue: [])
        let subscribedPlatformsURL = fileURL(for: "subscribed_platforms")
        let hasSavedSubscribedPlatforms = FileManager.default.fileExists(atPath: subscribedPlatformsURL.path)
        let loadedSubscribedPlatforms: [String] = loadFromFile(
            name: "subscribed_platforms",
            defaultValue: PlatformRegistry.defaultSubscribedIDs
        )
        self.subscribedPlatforms = Self.subscribedPlatformsForLoadedValue(
            loadedSubscribedPlatforms,
            hasSavedFile: hasSavedSubscribedPlatforms
        )
        if hasSavedSubscribedPlatforms, self.subscribedPlatforms != loadedSubscribedPlatforms {
            saveToFile(name: "subscribed_platforms", value: self.subscribedPlatforms)
        }
        self.wallpaper = UserDefaults.standard.string(forKey: profileKey("wallpaper_url"))
        let loadedSourcesOrder = UserDefaults.standard.stringArray(forKey: profileKey("sources_order"))
        self.sourcesOrder = Self.normalizedSourcesOrder(loadedSourcesOrder)
        if loadedSourcesOrder != self.sourcesOrder {
            if let sourcesOrder = self.sourcesOrder {
                UserDefaults.standard.set(sourcesOrder, forKey: profileKey("sources_order"))
            } else {
                UserDefaults.standard.removeObject(forKey: profileKey("sources_order"))
            }
        }
        self.oshiAvatars = loadFromFile(name: "oshi_avatars", defaultValue: [:])
        self.compositions = loadFromFile(name: "oshi_compositions", defaultValue: [:])
        let hiddenArray: [String] = loadFromFile(name: "hidden_items", defaultValue: [])
        let normalizedHiddenArray = hiddenArray.compactMap {
            Self.normalizedImportedHiddenItem($0, customURLImport: loadedCustomURLImport)
        }.filter {
            !prunedLegacyYouTubeItemKeys.contains($0)
        }
        self.hiddenItems = Set(normalizedHiddenArray)
        let normalizedLoadedHiddenItems = normalizedHiddenArray != hiddenArray
        if normalizedLoadedHiddenItems {
            saveToFile(name: "hidden_items", value: Array(self.hiddenItems))
        }
        contentCacheGenerationValue = UserDefaults.standard.integer(forKey: profileKey("content_cache_generation"))
        contentCacheGeneration = contentCacheGenerationValue
        dataRevision = UserDefaults.standard.integer(forKey: profileKey("local_data_revision"))
        if normalizedLoadedFeedItems {
            saveToFile(name: "feed_items", value: self.feedItems)
        }
        if normalizedLoadedCustomUrls || normalizedLoadedSavedPages || normalizedLoadedFeedItems || normalizedLoadedHiddenItems || !prunedLegacyYouTubeItemKeys.isEmpty {
            dataRevision &+= 1
            UserDefaults.standard.set(dataRevision, forKey: profileKey("local_data_revision"))
        }
    }

    private func profileKey(_ key: String) -> String {
        LocalProfileStore.defaultsKey(key, profileID: profileStore.activeProfileID)
    }
    
    private func loadFromFile<T: Decodable>(name: String, defaultValue: T) -> T {
        let url = fileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLogger.persistence.error("Failed to load \(name): \(error.localizedDescription)")
            return defaultValue
        }
    }
    
    private func saveToFile<T: Encodable>(name: String, value: T) {
        saveToFile(name: name, value: value, shouldWrite: nil)
    }

    private func saveToFile<T: Encodable>(name: String, value: T, shouldWrite: (() -> Bool)?) {
        let url = fileURL(for: name)
        pendingWritesLock.lock()
        pendingWrites += 1
        pendingWritesLock.unlock()
        queue.async {
            defer {
                self.pendingWritesLock.lock()
                self.pendingWrites -= 1
                self.pendingWritesLock.unlock()
            }
            if let shouldWrite, !shouldWrite() { return }
            do {
                let data = try self.encoder.encode(value)
                try data.write(to: url, options: [.atomic])
            } catch {
                AppLogger.persistence.error("Failed to save \(name): \(error.localizedDescription)")
            }
        }
    }

    private func pruneLegacyYouTubeItems() -> Set<String> {
        let prunedKeys = Set(feedItems
            .filter { FeedItemPolicy.shouldPruneLegacyYouTubeItem($0) }
            .map(Self.feedItemKey))
        guard !prunedKeys.isEmpty else { return [] }
        feedItems.removeAll { FeedItemPolicy.shouldPruneLegacyYouTubeItem($0) }
        saveToFile(name: "feed_items", value: feedItems)
        AppLogger.persistence.info("Pruned \(prunedKeys.count) legacy YouTube feed items")
        return prunedKeys
    }

    /// Blocks until all ordinary asynchronous local writes submitted so far
    /// have reached disk. Intended for lifecycle transitions, not UI actions.
    func flushPendingWrites() {
        flushPendingFeedItemsSave()
        queue.sync {}
    }

    /// Coalesces rapid feed merges into one serialized disk write while keeping
    /// the in-memory feed immediately available to SwiftUI.
    func flushPendingFeedItemsSave() {
        let snapshot = feedItems
        pendingWritesLock.lock()
        feedItemsSaveGeneration &+= 1
        pendingWritesLock.unlock()
        pendingFeedItemsSaveWorkItem?.cancel()
        pendingFeedItemsSaveWorkItem = nil
        queue.sync {
            do {
                let data = try self.encoder.encode(snapshot)
                try data.write(to: self.fileURL(for: "feed_items"), options: [.atomic])
            } catch {
                AppLogger.persistence.error("Failed to save feed_items: \(error.localizedDescription)")
            }
        }
    }

    private func saveFeedItemsSoon() {
        pendingFeedItemsSaveWorkItem?.cancel()
        let snapshot = feedItems
        pendingWritesLock.lock()
        feedItemsSaveGeneration &+= 1
        let generation = feedItemsSaveGeneration
        pendingWritesLock.unlock()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWritesLock.lock()
            let isCurrent = self.feedItemsSaveGeneration == generation
            self.pendingWritesLock.unlock()
            guard isCurrent else { return }
            do {
                let data = try self.encoder.encode(snapshot)
                try data.write(to: self.fileURL(for: "feed_items"), options: [.atomic])
            } catch {
                AppLogger.persistence.error("Failed to save feed_items: \(error.localizedDescription)")
            }
        }
        pendingFeedItemsSaveWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
    }

    private func saveEncodedFilesSynchronously(
        _ files: [(String, Data)],
        wallpaper: String?,
        sourcesOrder: [String]?
    ) throws {
        let docsDirectory = profileStore.directoryURL(for: profileStore.activeProfileID)
        let stagingName = ".oshireader-restore-\(UUID().uuidString)"
        let stagingDirectory = docsDirectory.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        do {
            try queue.sync {
                for (name, data) in files {
                    try data.write(to: stagingDirectory.appendingPathComponent("\(name).json"), options: [.atomic])
                }
            }
            let manifest = LocalRestoreManifest(
                stagingDirectory: stagingName,
                files: files.map { $0.0 },
                wallpaper: wallpaper,
                sourcesOrder: sourcesOrder
            )
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: docsDirectory.appendingPathComponent("restore_manifest.json"), options: [.atomic])
            try applyPendingRestore()
        } catch {
            // Keep a fully written manifest/staging directory only when the
            // replacement phase has started; the next launch can recover it.
            if !FileManager.default.fileExists(atPath: docsDirectory.appendingPathComponent("restore_manifest.json").path) {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
            throw error
        }
    }

    private func recoverPendingRestoreIfNeeded() {
        do { try applyPendingRestore() } catch {
            AppLogger.persistence.error("Pending local restore could not be completed: \(error.localizedDescription)")
        }
    }

    private func applyPendingRestore() throws {
        let docsDirectory = profileStore.directoryURL(for: profileStore.activeProfileID)
        let manifestURL = docsDirectory.appendingPathComponent("restore_manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let manifest = try JSONDecoder().decode(LocalRestoreManifest.self, from: Data(contentsOf: manifestURL))
        let expectedFiles: Set<String> = [
            "terms", "feed_items", "saved_pages", "custom_urls",
            "subscribed_platforms", "oshi_avatars", "oshi_compositions", "hidden_items",
            "ameblo_blogs"
        ]
        guard Set(manifest.files) == expectedFiles,
              manifest.stagingDirectory.hasPrefix(".oshireader-restore-"),
              !manifest.stagingDirectory.contains("/") else {
            throw NSError(domain: "OshiReaderBackup", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid restore manifest"])
        }
        let stagingDirectory = docsDirectory.appendingPathComponent(manifest.stagingDirectory, isDirectory: true)
        guard stagingDirectory.deletingLastPathComponent().standardizedFileURL.path == docsDirectory.standardizedFileURL.path else {
            throw NSError(domain: "OshiReaderBackup", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid restore staging path"])
        }

        for name in manifest.files {
            let stagedURL = stagingDirectory.appendingPathComponent("\(name).json")
            let destinationURL = fileURL(for: name)
            if FileManager.default.fileExists(atPath: destinationURL.path),
               FileManager.default.fileExists(atPath: stagedURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
            } else if FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
            } else if !FileManager.default.fileExists(atPath: destinationURL.path) {
                throw NSError(domain: "OshiReaderBackup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Restore staging data is incomplete"])
            }
        }

        if let wallpaper = manifest.wallpaper { UserDefaults.standard.set(wallpaper, forKey: profileKey("wallpaper_url")) }
        else { UserDefaults.standard.removeObject(forKey: profileKey("wallpaper_url")) }
        if let sourcesOrder = Self.normalizedSourcesOrder(manifest.sourcesOrder) { UserDefaults.standard.set(sourcesOrder, forKey: profileKey("sources_order")) }
        else { UserDefaults.standard.removeObject(forKey: profileKey("sources_order")) }

        try? FileManager.default.removeItem(at: stagingDirectory)
        try FileManager.default.removeItem(at: manifestURL)
    }
    
    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async {
                block()
            }
        }
    }

    private func advanceDataRevision() {
        dataRevision &+= 1
        UserDefaults.standard.set(dataRevision, forKey: profileKey("local_data_revision"))
    }

    private static func normalizedTerm(_ term: WatchTerm) -> WatchTerm {
        var normalized = term
        let platforms = normalizePlatformIDs(term.selected_platforms)
        normalized.source_mode = term.source_mode == .selected && !platforms.isEmpty ? .selected : .all
        normalized.selected_platforms = normalized.source_mode == .selected ? platforms : []
        return normalized
    }
    
    // MARK: - Watch Terms
    func saveTerm(keyword: String, collectionMode: String = "all_info", sourceMode: SourceMode = .all, selectedPlatforms: [String] = []) -> WatchTerm {
        let normalizedPlatforms = Self.normalizePlatformIDs(selectedPlatforms)
        let effectiveMode: SourceMode = sourceMode == .selected && !normalizedPlatforms.isEmpty ? .selected : .all
        let term = WatchTerm(
            keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            collection_mode: collectionMode,
            source_mode: effectiveMode,
            selected_platforms: effectiveMode == .selected ? normalizedPlatforms : []
        )
        runOnMain {
            self.advanceDataRevision()
            self.terms.insert(term, at: 0)
            self.saveToFile(name: "terms", value: self.terms)
        }
        return term
    }
    
    func updateTerm(id: String, isActive: Bool? = nil, collectionMode: String? = nil, sourceMode: SourceMode? = nil, selectedPlatforms: [String]? = nil, notifyOnNew: Bool? = nil, aliases: [String]? = nil) {
        runOnMain {
            if let idx = self.terms.firstIndex(where: { $0.id == id }) {
                var term = self.terms[idx]
                let changesIngestionScope =
                    isActive.map { $0 != term.is_active } ?? false ||
                    collectionMode.map { $0 != term.collection_mode } ?? false ||
                    sourceMode.map { $0 != term.source_mode } ?? false ||
                    selectedPlatforms.map { Self.normalizePlatformIDs($0) != term.selected_platforms } ?? false ||
                    aliases.map { $0 != term.aliases } ?? false
                if changesIngestionScope {
                    self.advanceDataRevision()
                }
                if let isActive = isActive { term.is_active = isActive }
                if let collectionMode = collectionMode { term.collection_mode = collectionMode }
                if let sourceMode = sourceMode {
                    let normalized = Self.normalizePlatformIDs(selectedPlatforms ?? term.selected_platforms)
                    term.source_mode = sourceMode == .selected && !normalized.isEmpty ? .selected : .all
                    term.selected_platforms = term.source_mode == .selected ? normalized : []
                } else if let selectedPlatforms = selectedPlatforms {
                    let normalized = Self.normalizePlatformIDs(selectedPlatforms)
                    term.source_mode = term.source_mode == .selected && !normalized.isEmpty ? .selected : .all
                    term.selected_platforms = term.source_mode == .selected ? normalized : []
                }
                if let notifyOnNew = notifyOnNew {
                    term.notify_on_new = notifyOnNew
                    if !notifyOnNew {
                        Task { @MainActor in
                            NotificationManager.shared.clearNotification(forTermID: id)
                        }
                    }
                }
                if let aliases = aliases { term.aliases = aliases }
                self.terms[idx] = term
                self.saveToFile(name: "terms", value: self.terms)
            }
        }
    }

    func term(matchingKeyword keyword: String) -> WatchTerm? {
        terms.first { $0.keyword == keyword }
    }

    func deleteTerm(id: String) {
        runOnMain {
            if let term = self.terms.firstIndex(where: { $0.id == id }) {
                let keyword = self.terms[term].keyword
                self.advanceDataRevision()
                self.terms.remove(at: term)
                Task { @MainActor in
                    RecentTermUsageStore.shared.remove(termID: id)
                    NotificationManager.shared.clearNotification(forTermID: id)
                }
                self.saveToFile(name: "terms", value: self.terms)
                
                // Also clean up items containing that watch term keyword
                self.feedItems.removeAll(where: { $0.watch_term_keyword == keyword })
                let hiddenSuffix = "::\(keyword)"
                let remainingHiddenSuffixes = Set(self.terms.map { "::\($0.keyword)" })
                self.hiddenItems = self.hiddenItems.filter { hiddenKey in
                    if remainingHiddenSuffixes.contains(where: { hiddenKey.hasSuffix($0) }) { return true }
                    return !hiddenKey.hasSuffix(hiddenSuffix)
                }
                self.saveToFile(name: "hidden_items", value: Array(self.hiddenItems))
                self.saveFeedItemsSoon()
            }
        }
    }
    
    // MARK: - Feed Items & Merging
    @MainActor
    func mergeItems(newItems: [FeedItem], sourceRevision: Int? = nil) -> Int {
        mergeItemsBatched(newItemsBatches: [newItems], sourceRevision: sourceRevision)
    }

    @MainActor
    func mergeItemsBatched(newItemsBatches: [[FeedItem]], sourceRevision: Int? = nil) -> Int {
        guard sourceRevision == nil || sourceRevision == dataRevision else { return 0 }
        var addedCount = 0
        var addedItems: [FeedItem] = []
        
        let filteredNew = newItemsBatches.flatMap { $0 }.filter { item in
            let key = Self.feedItemKey(item)
            let isHidden = self.hiddenItems.contains(key)
            let isSearchFallback = Self.isSearchFallbackItem(item)
            return !isHidden && !isSearchFallback && !FeedItemPolicy.shouldPruneLegacyYouTubeItem(item)
        }
        
        var currentMap = [String: FeedItem]()
        for item in self.feedItems {
            if FeedItemPolicy.shouldPruneLegacyYouTubeItem(item) { continue }
            currentMap[Self.feedItemKey(item)] = item
        }
        let wasFirstLoad = currentMap.isEmpty
        
        for item in filteredNew {
            let key = Self.feedItemKey(item)
            if currentMap[key] == nil {
                currentMap[key] = item
                addedCount += 1
                addedItems.append(item)
            } else {
                // Merge/update fields if needed (like title length, content, published date)
                let existing = currentMap[key]!
                let shouldReplaceTitle = (item.title?.isEmpty == false) &&
                    (existing.title == nil ||
                     existing.title?.contains("...") == true ||
                     (item.title?.count ?? 0) > (existing.title?.count ?? 0) + 8)

                let merged = FeedItem(
                    id: existing.id,
                    platform: existing.platform,
                    url: existing.url,
                    title: shouldReplaceTitle ? item.title : existing.title,
                    content_text: item.content_text ?? existing.content_text,
                    author: item.author ?? existing.author,
                    thumbnail_url: item.thumbnail_url ?? existing.thumbnail_url,
                    media_type: existing.media_type,
                    published_at: Self.mergedPublishedAt(existing: existing, incoming: item),
                    watch_term_keyword: existing.watch_term_keyword,
                    fetched_at: item.fetched_at,
                    source: item.source ?? existing.source
                )
                currentMap[key] = merged
            }
        }
        
        let sorted = currentMap.values.sorted(by: Self.feedItemSortPrecedes)
        let preserveAddedItems = !self.feedItems.isEmpty
        let preservedKeys = preserveAddedItems ? Set(addedItems.map(Self.feedItemKey)) : []
        let finalItems = Self.cappedFeedItems(
            sorted,
            preserving: preservedKeys,
            subscribedPlatforms: subscribedPlatforms
        )

        // Only notify for items that survived the cap — avoids pinging for articles
        // that were immediately evicted as too old.
        if !addedItems.isEmpty && !wasFirstLoad {
            let survivedKeys = Set(finalItems.map(Self.feedItemKey))
            let notifyItems = addedItems.filter { survivedKeys.contains(Self.feedItemKey($0)) }
            if !notifyItems.isEmpty {
                let terms = self.terms
                Task {
                    await NotificationManager.shared.notifyForNewItems(notifyItems, terms: terms)
                }
            }
        }

        self.feedItems = finalItems
        self.saveFeedItemsSoon()
        return addedCount
    }

    private static func feedItemKey(_ item: FeedItem) -> String {
        "\(item.id)::\(item.watch_term_keyword)"
    }

    private static func isSearchFallbackItem(_ item: FeedItem) -> Bool {
        item.id.lowercased().hasPrefix("search:") ||
            item.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("search:") == true
    }

    private static func mergedPublishedAt(existing: FeedItem, incoming: FeedItem) -> String {
        let existingDate = parseISO8601Date(existing.published_at)
        let incomingDate = parseISO8601Date(incoming.published_at)
        guard let existingDate, let incomingDate else {
            return existingDate == nil ? incoming.published_at : existing.published_at
        }

        if discussionActivityPlatforms.contains(PlatformRegistry.normalizeID(incoming.platform)) {
            return incomingDate >= existingDate ? incoming.published_at : existing.published_at
        }
        return existingDate <= incomingDate ? existing.published_at : incoming.published_at
    }

    private static func feedItemSortPrecedes(_ lhs: FeedItem, _ rhs: FeedItem) -> Bool {
        let lhsDate = parseISO8601Date(lhs.published_at) ?? .distantPast
        let rhsDate = parseISO8601Date(rhs.published_at) ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }

        let lhsKey = feedItemKey(lhs)
        let rhsKey = feedItemKey(rhs)
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return lhs.url < rhs.url
    }

    private struct FeedQueryCandidate {
        let item: FeedItem
        let platformKey: String
    }

    private static func cappedFeedItems(
        _ sortedItems: [FeedItem],
        preserving preservedKeys: Set<String>,
        subscribedPlatforms: [String]
    ) -> [FeedItem] {
        guard sortedItems.count > maxFeedItems else { return sortedItems }

        var selected: [FeedItem] = []
        var selectedKeys = Set<String>()

        for item in sortedItems where preservedKeys.contains(feedItemKey(item)) {
            let key = feedItemKey(item)
            guard selectedKeys.insert(key).inserted else { continue }
            selected.append(item)
            if selected.count >= maxFeedItems { return selected.sorted(by: feedItemSortPrecedes) }
        }

        let subscribed = Set(subscribedPlatforms.filter { $0 != "custom" }.map(PlatformRegistry.normalizeID))
        for platformId in subscribed.sorted() {
            var keptForPlatform = 0
            let targetCount = minRetainedFeedItems(for: platformId)
            for item in sortedItems where PlatformRegistry.normalizeID(item.platform) == platformId {
                let key = feedItemKey(item)
                guard selectedKeys.insert(key).inserted else { continue }
                selected.append(item)
                keptForPlatform += 1
                if selected.count >= maxFeedItems { return selected.sorted(by: feedItemSortPrecedes) }
                if keptForPlatform >= targetCount { break }
            }
        }

        for item in sortedItems {
            guard selected.count < maxFeedItems else { break }
            let key = feedItemKey(item)
            guard selectedKeys.insert(key).inserted else { continue }
            selected.append(item)
        }

        return selected.sorted(by: feedItemSortPrecedes)
    }

    private static func minRetainedFeedItems(for platformId: String) -> Int {
        discussionActivityPlatforms.contains(platformId)
            ? minFeedItemsPerDiscussionPlatform
            : minFeedItemsPerSubscribedPlatform
    }
    
    func deleteFeedItem(id: String, watchTermKeyword: String) {
        let key = "\(id)::\(watchTermKeyword)"
        runOnMain {
            self.hiddenItems.insert(key)
            self.saveToFile(name: "hidden_items", value: Array(self.hiddenItems))
            
            self.feedItems.removeAll(where: { $0.id == id && $0.watch_term_keyword == watchTermKeyword })
            self.saveFeedItemsSoon()
        }
    }

    func currentCustomFeedItems(_ items: [FeedItem]) -> [FeedItem] {
        let currentIds = Set(customUrls.map(\.id))
        let currentUrls = Set(customUrls.map(\.url))
        return items.filter { item in
            PlatformRegistry.normalizeID(item.platform) != "custom" ||
                currentIds.contains(item.id) ||
                currentUrls.contains(item.url)
        }
    }
    
    // MARK: - Query Feed (Filtering)
    func queryFeed(keyword: String?, days: Int) -> [FeedItem] {
        let now = Date()
        // days == 0 means "All Time" — no cutoff applied
        let cutoffDate = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: now) : nil
        
        let strictKeywordPlatforms = PlatformRegistry.strictKeywordPlatformIDs
            .union(["news", "tver"])
        
        let candidates = feedItems.compactMap { item -> FeedQueryCandidate? in
            let key = "\(item.id)::\(item.watch_term_keyword)"
            if hiddenItems.contains(key) { return nil }
            
            // Search pages fallbacks
            if Self.isSearchFallbackItem(item) { return nil }
            if FeedItemPolicy.shouldPruneLegacyYouTubeItem(item) { return nil }
            let platformKey = normalizedPlatformKey(item.platform)
            
            // Bare address item (Yahoo News fallback checking)
            if platformKey == "yahoonews" && (item.title?.contains("https://") == true || item.content_text?.contains("https://") == true) {
                return nil
            }
            
            // Cutoff check (skip limit check for 5ch, girlschannel, togetter)
            let skipCutoff = Self.discussionActivityPlatforms.contains(platformKey)
            if let cutoff = cutoffDate, !skipCutoff {
                guard let itemDate = parseISO8601Date(item.published_at), itemDate >= cutoff else {
                    return nil
                }
            }
            
            // Keyword filter
            if let kw = keyword, !kw.isEmpty {
                if platformKey == "custom" {
                    // Let custom pages pass if custom matches
                } else if item.watch_term_keyword != kw {
                    return nil
                }
            }
            
            // Strict keyword matching logic
            if strictKeywordPlatforms.contains(PlatformRegistry.normalizeID(item.platform)), !item.watch_term_keyword.isEmpty {
                let aliases = self.terms
                    .first { $0.keyword == item.watch_term_keyword }?
                    .aliases ?? []
                let matchingKeywords = [item.watch_term_keyword] + aliases
                if !matchingKeywords.contains(where: { matchesKeyword(item: item, kw: $0) }) {
                    return nil
                }
            }
            
            // Subscribed platforms
            if !subscribedPlatforms.contains(platformKey) {
                return nil
            }
            
            return FeedQueryCandidate(item: item, platformKey: platformKey)
        }
        .sorted { Self.feedItemSortPrecedes($0.item, $1.item) }

        if keyword?.isEmpty == false {
            return candidates.map(\.item)
        }

        return candidates
        .reduce(into: (items: [FeedItem](), urls: Set<String>(), platformTitles: Set<String>(), articleTitles: Set<String>())) { acc, candidate in
            let item = candidate.item
            let urlKey = Self.normalizedURLKey(item.url)
            guard urlKey.isEmpty || acc.urls.insert(urlKey).inserted else { return }

            let titleKey = Self.normalizedTitleKey(item.title)
            let platformTitleKey = titleKey.isEmpty ? "" : "\(candidate.platformKey)|\(titleKey)"
            guard platformTitleKey.isEmpty || acc.platformTitles.insert(platformTitleKey).inserted else { return }

            let articleTitleKey = Self.normalizedArticleTitleKey(item.title)
            if Self.shouldDeduplicateArticleTitle(item), articleTitleKey.count >= 10 {
                guard acc.articleTitles.insert(articleTitleKey).inserted else { return }
            }

            acc.items.append(item)
        }.items
    }

    static func normalizedURLKey(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return trimmed.lowercased()
        }

        let host = (components.host ?? "").lowercased()
        guard !host.isEmpty,
              host.contains(".") || host == "localhost" || host.allSatisfy(\.isNumber) else {
            return ""
        }
        if host == "youtu.be" {
            let videoID = components.path.split(separator: "/").first.map(String.init) ?? ""
            if !videoID.isEmpty { return "https://youtube.com/watch?v=\(videoID)" }
        }
        if host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" {
            let queryItems = components.queryItems ?? []
            if components.path == "/watch",
               let videoID = queryItems.first(where: { $0.name == "v" })?.value,
               !videoID.isEmpty {
                return "https://youtube.com/watch?v=\(videoID)"
            }
        }

        components.scheme = "https"
        components.host = normalizedHost(host)
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path

        let queryItems = (components.queryItems ?? [])
            .filter { !isIgnoredURLQueryItem($0.name) }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.value ?? "") < ($1.value ?? "")
            }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        return components.url?.absoluteString ?? trimmed
    }

    static func normalizedTitleKey(_ title: String?) -> String {
        guard let title = title?.lowercased(), !title.isEmpty else { return "" }
        return String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func normalizedArticleTitleKey(_ title: String?) -> String {
        guard var text = cleanDisplayText(title)?.lowercased(), !text.isEmpty else { return "" }

        for separator in [" - ", " | ", "｜"] {
            guard let range = text.range(of: separator, options: .backwards) else { continue }
            let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count >= 8, suffix.count <= 40, publisherSuffixLooksLikely(suffix) {
                text = prefix
                break
            }
        }

        text = strippingTrailingPublisherParenthetical(text)
        return normalizedTitleKey(text)
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host
        if value.hasPrefix("www.") { value.removeFirst(4) }
        if value.hasPrefix("m.") { value.removeFirst(2) }
        return value
    }

    private static func isIgnoredURLQueryItem(_ rawName: String) -> Bool {
        let name = rawName.lowercased()
        return name.hasPrefix("utm_") || [
            "fbclid", "gclid", "yclid", "igshid", "mc_cid", "mc_eid",
            "ref", "ref_src", "spm", "oc", "hl", "gl", "ceid"
        ].contains(name)
    }

    private static func shouldDeduplicateArticleTitle(_ item: FeedItem) -> Bool {
        if item.media_type == "article" || item.media_type == "text" { return true }
        return PlatformRegistry.strictKeywordPlatformIDs.contains(PlatformRegistry.normalizeID(item.platform))
    }

    private static func publisherSuffixLooksLikely(_ suffix: String) -> Bool {
        if suffix.isEmpty { return false }
        let knownWords = [
            "news", "ニュース", "新聞", "online", "web", "press", "times",
            "ナタリー", "モデルプレス", "oricon", "mdpr", "modelpress", "yahoo", "google"
        ]
        if knownWords.contains(where: { suffix.contains($0) }) { return true }
        return suffix.count <= 14 && !suffix.contains(" ")
    }

    private static func strippingTrailingPublisherParenthetical(_ text: String) -> String {
        let pairs: [(Character, Character)] = [(")", "("), ("）", "（")]
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (closing, opening) in pairs where current.last == closing {
            guard let openIndex = current.lastIndex(of: opening) else { continue }
            let prefix = String(current[..<openIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(current[current.index(after: openIndex)..<current.index(before: current.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count >= 8, suffix.count <= 40, publisherSuffixLooksLikely(suffix) {
                current = prefix
            }
        }
        return current
    }
    
    private func matchesKeyword(item: FeedItem, kw: String) -> Bool {
        let primaryText = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let haystack = ((primaryText?.isEmpty == false ? primaryText : item.content_text) ?? "").lowercased()
        let needle = kw.lowercased()
        if needle.isEmpty { return true }
        if haystack.contains(needle) { return true }
        
        let parts = kw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if parts.count > 1 {
            return parts.allSatisfy { haystack.contains($0.lowercased()) }
        }
        return false
    }
    
    // MARK: - Bookmarks (Saved)
    func getSaved() -> [SavedPage] {
        return savedPages
    }
    
    func toggleSaved(item: FeedItem) -> Bool {
        var isSaved = false
        runOnMain {
            if let idx = self.savedPages.firstIndex(where: { $0.id == item.id }) {
                self.savedPages.remove(at: idx)
            } else {
                let page = SavedPage(
                    id: item.id,
                    url: item.url,
                    title: item.title,
                    platform: item.platform,
                    saved_at: Self.iso8601.string(from: Date()),
                    source: item.source
                )
                self.savedPages.insert(page, at: 0)
                isSaved = true
            }
            self.saveToFile(name: "saved_pages", value: self.savedPages)
        }
        return isSaved
    }
    
    func removeSaved(id: String) {
        runOnMain {
            self.savedPages.removeAll(where: { $0.id == id })
            self.saveToFile(name: "saved_pages", value: self.savedPages)
        }
    }
    
    // MARK: - Subscribed Platforms
    func setSubscribedPlatforms(platforms: [String]) {
        runOnMain {
            let normalizedPlatforms = Self.normalizePlatformIDs(platforms)
            let subscribedSourceIDs = Set(normalizedPlatforms.filter { $0 != "custom" })
            var termsChanged = false
            for index in self.terms.indices where self.terms[index].source_mode == .selected {
                let validSelection = Self.normalizePlatformIDs(self.terms[index].selected_platforms)
                    .filter { subscribedSourceIDs.contains($0) }
                let nextMode: SourceMode = validSelection.isEmpty ? .all : .selected
                let nextSelection = nextMode == .selected ? validSelection : []
                if self.terms[index].source_mode != nextMode || self.terms[index].selected_platforms != nextSelection {
                    self.terms[index].source_mode = nextMode
                    self.terms[index].selected_platforms = nextSelection
                    termsChanged = true
                }
            }
            guard self.subscribedPlatforms != normalizedPlatforms || termsChanged else { return }
            self.advanceDataRevision()
            self.subscribedPlatforms = normalizedPlatforms
            self.saveToFile(name: "subscribed_platforms", value: self.subscribedPlatforms)
            if termsChanged {
                self.saveToFile(name: "terms", value: self.terms)
            }
        }
    }
    
    // MARK: - Custom URLs
    private static func normalizedCustomUrlEntry(url: String, title: String?, addedAt: String) -> CustomUrl? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+\-.]*:"#,
                                      options: .regularExpression) != nil
        let hasHTTPSScheme = trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
        let looksLikeHostPort = trimmed.range(of: #"^[A-Za-z0-9.-]+:\d+([/?#].*)?$"#,
                                              options: .regularExpression) != nil
        guard !hasScheme || hasHTTPSScheme || looksLikeHostPort else { return nil }
        let candidate = hasHTTPSScheme ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              host.contains(".") || host == "localhost" || host.allSatisfy(\.isNumber) else { return nil }
        components.scheme = scheme
        components.host = Self.normalizedHost(host)
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        let queryItems = (components.queryItems ?? [])
            .filter { !Self.isIgnoredURLQueryItem($0.name) }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.value ?? "") < ($1.value ?? "")
            }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let normalized = components.url?.absoluteString else { return nil }
        let id = "custom:\(normalized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? normalized)"
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomUrl(id: id, url: normalized, title: trimmedTitle?.isEmpty == false ? trimmedTitle : nil, added_at: addedAt)
    }

    private static func normalizedCustomUrls(_ urls: [CustomUrl]) -> [CustomUrl] {
        normalizedCustomUrlImport(urls).urls
    }

    private struct NormalizedCustomUrlImport {
        let urls: [CustomUrl]
        let entriesByLegacyID: [String: CustomUrl]
        let entriesByLegacyURL: [String: CustomUrl]
        let droppedLegacyIDs: Set<String>
    }

    private static func normalizedCustomUrlImport(_ urls: [CustomUrl]) -> NormalizedCustomUrlImport {
        var normalizedUrls: [CustomUrl] = []
        var entriesByID: [String: CustomUrl] = [:]
        var entriesByURL: [String: CustomUrl] = [:]
        var canonicalByNormalizedID: [String: CustomUrl] = [:]
        var droppedIDs = Set<String>()

        for entry in urls {
            guard let normalized = normalizedCustomUrlEntry(url: entry.url, title: entry.title, addedAt: entry.added_at) else {
                droppedIDs.insert(entry.id)
                continue
            }

            let canonical: CustomUrl
            if let existing = canonicalByNormalizedID[normalized.id] {
                canonical = existing
            } else {
                canonicalByNormalizedID[normalized.id] = normalized
                normalizedUrls.append(normalized)
                canonical = normalized
            }

            entriesByID[entry.id] = canonical
            entriesByID[canonical.id] = canonical
            entriesByURL[entry.url] = canonical
            entriesByURL[canonical.url] = canonical
        }

        return NormalizedCustomUrlImport(
            urls: normalizedUrls,
            entriesByLegacyID: entriesByID,
            entriesByLegacyURL: entriesByURL,
            droppedLegacyIDs: droppedIDs
        )
    }

    private static func normalizedImportedFeedItems(
        _ items: [FeedItem],
        customURLImport: NormalizedCustomUrlImport
    ) -> [FeedItem] {
        items.compactMap { item in
            guard PlatformRegistry.normalizeID(item.platform) == "custom" else { return item }
            let normalizedItemURL = normalizedCustomUrlEntry(url: item.url, title: nil, addedAt: "")?.url
            guard let entry = customURLImport.entriesByLegacyID[item.id] ??
                    customURLImport.entriesByLegacyURL[item.url] ??
                    normalizedItemURL.flatMap({ customURLImport.entriesByLegacyURL[$0] }) else {
                return nil
            }
            return FeedItem(
                id: entry.id,
                platform: "custom",
                url: entry.url,
                title: item.title,
                content_text: item.content_text,
                author: item.author,
                thumbnail_url: item.thumbnail_url,
                media_type: item.media_type,
                published_at: item.published_at,
                watch_term_keyword: item.watch_term_keyword,
                fetched_at: item.fetched_at,
                source: item.source ?? "custom_url"
            )
        }
    }

    private static func normalizedImportedSavedPages(
        _ pages: [SavedPage],
        customURLImport: NormalizedCustomUrlImport
    ) -> [SavedPage] {
        pages.compactMap { page in
            guard PlatformRegistry.normalizeID(page.platform) == "custom" else { return page }
            let normalizedPageURL = normalizedCustomUrlEntry(url: page.url, title: nil, addedAt: "")?.url
            guard let entry = customURLImport.entriesByLegacyID[page.id] ??
                    customURLImport.entriesByLegacyURL[page.url] ??
                    normalizedPageURL.flatMap({ customURLImport.entriesByLegacyURL[$0] }) else {
                return nil
            }
            return SavedPage(
                id: entry.id,
                url: entry.url,
                title: page.title,
                platform: "custom",
                saved_at: page.saved_at,
                source: page.source ?? "custom_url"
            )
        }
    }

    private static func normalizedImportedHiddenItem(
        _ key: String,
        customURLImport: NormalizedCustomUrlImport
    ) -> String? {
        let legacyID = key.split(separator: "::", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? key
        if customURLImport.droppedLegacyIDs.contains(legacyID) { return nil }
        guard let entry = customURLImport.entriesByLegacyID[legacyID] else { return key }
        return entry.id + key.dropFirst(legacyID.count)
    }

    func addCustomUrl(url: String, title: String) {
        guard let entry = Self.normalizedCustomUrlEntry(url: url, title: title, addedAt: Self.iso8601.string(from: Date())) else { return }
        runOnMain {
            if self.customUrls.contains(where: { $0.id == entry.id }) { return }
            self.advanceDataRevision()
            self.customUrls.insert(entry, at: 0)
            self.saveToFile(name: "custom_urls", value: self.customUrls)
        }
    }
    
    func removeCustomUrl(id: String) {
        runOnMain {
            let removedUrls = self.customUrls
                .filter { $0.id == id }
                .map(\.url)
            guard !removedUrls.isEmpty else { return }
            let removedHiddenKeyPrefix = "\(id)::"
            let remainingCustomHiddenPrefixes = Set(self.customUrls
                .filter { $0.id != id }
                .map { "\($0.id)::" })
            var removedHiddenKeys = Set([removedHiddenKeyPrefix])
            for item in self.feedItems where PlatformRegistry.normalizeID(item.platform) == "custom" && (item.id == id || removedUrls.contains(item.url)) {
                removedHiddenKeys.insert(Self.feedItemKey(item))
            }
            self.advanceDataRevision()
            self.customUrls.removeAll(where: { $0.id == id })
            self.feedItems.removeAll { item in
                PlatformRegistry.normalizeID(item.platform) == "custom" &&
                    (item.id == id || removedUrls.contains(item.url))
            }
            self.hiddenItems = self.hiddenItems
                .filter { hiddenKey in
                    if remainingCustomHiddenPrefixes.contains(where: { hiddenKey.hasPrefix($0) }) { return true }
                    return !hiddenKey.hasPrefix(removedHiddenKeyPrefix)
                }
                .subtracting(removedHiddenKeys)
            self.saveToFile(name: "custom_urls", value: self.customUrls)
            self.saveToFile(name: "hidden_items", value: Array(self.hiddenItems))
            self.saveFeedItemsSoon()
        }
    }

    // MARK: - Ameblo blogs
    func addAmebloBlog(url: String, title: String) -> AmebloBlogAddResult {
        guard let blog = AmebloBlog(url: url, title: title) else { return .invalidURL }
        guard !amebloBlogs.contains(where: { $0.id == blog.id }) else { return .duplicate }
        guard amebloBlogs.count < AmebloBlog.maximumCount else { return .limitReached }

        amebloBlogs.insert(blog, at: 0)
        saveToFile(name: "ameblo_blogs", value: amebloBlogs)
        if !subscribedPlatforms.contains("ameblo") {
            subscribedPlatforms.append("ameblo")
            saveToFile(name: "subscribed_platforms", value: subscribedPlatforms)
        }
        advanceDataRevision()
        return .added
    }

    func removeAmebloBlog(id: String) {
        guard amebloBlogs.contains(where: { $0.id == id }) else { return }
        amebloBlogs.removeAll { $0.id == id }
        saveToFile(name: "ameblo_blogs", value: amebloBlogs)
        advanceDataRevision()
    }

    // MARK: - Data Reset
    @MainActor
    func clearAllData() {
        let fileNames = [
            "terms",
            "feed_items",
            "saved_pages",
            "custom_urls",
            "ameblo_blogs",
            "subscribed_platforms",
            "oshi_avatars",
            "oshi_compositions",
            "hidden_items"
        ]

        flushPendingWrites()
        dataRevision += 1
        UserDefaults.standard.set(dataRevision, forKey: profileKey("local_data_revision"))
        invalidateContentCaches()
        NotificationManager.shared.clearLocalNotifications()
        terms = []
        RecentTermUsageStore.shared.removeAll()
        feedItems = []
        savedPages = []
        customUrls = []
        amebloBlogs = []
        subscribedPlatforms = PlatformRegistry.defaultSubscribedIDs
        wallpaper = nil
        sourcesOrder = nil
        oshiAvatars = [:]
        compositions = [:]
        hiddenItems = []

        for name in fileNames {
            let url = fileURL(for: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // Delete wallpaper files separately from content caches.
        let docsDir = profileStore.directoryURL(for: profileStore.activeProfileID)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: docsDir, includingPropertiesForKeys: nil
        ) {
            for cacheUrl in contents where cacheUrl.lastPathComponent.hasPrefix("oshi_wallpaper") {
                try? FileManager.default.removeItem(at: cacheUrl)
            }
        }
        UserDefaults.standard.removeObject(forKey: profileKey("wallpaper_url"))
        UserDefaults.standard.removeObject(forKey: profileKey("sources_order"))
        saveToFile(name: "subscribed_platforms", value: subscribedPlatforms)
    }
    
    // MARK: - Wallpaper & Custom Order (UserDefaults)
    func setWallpaper(url: String?) {
        runOnMain {
            self.wallpaper = url
            if let url = url {
                UserDefaults.standard.set(url, forKey: self.profileKey("wallpaper_url"))
            } else {
                UserDefaults.standard.removeObject(forKey: self.profileKey("wallpaper_url"))
            }
        }
    }
    
    func setSourcesOrder(order: [String]) {
        runOnMain {
            let normalizedOrder = Self.normalizedSourcesOrder(order) ?? []
            self.sourcesOrder = normalizedOrder
            UserDefaults.standard.set(normalizedOrder, forKey: self.profileKey("sources_order"))
        }
    }
    
    // MARK: - Oshi Avatars & Compositions
    func setOshiAvatar(keyword: String, imageUrl: String) {
        runOnMain {
            self.oshiAvatars[keyword] = imageUrl
            self.saveToFile(name: "oshi_avatars", value: self.oshiAvatars)
        }
    }
    
    func setOshiComposition(keyword: String, layers: [AvatarLayer]) {
        runOnMain {
            self.compositions[keyword] = layers
            self.saveToFile(name: "oshi_compositions", value: self.compositions)
        }
    }

    // MARK: - Portable local backup
    @MainActor
    func exportBackupData() throws -> Data {
        flushPendingFeedItemsSave()
        let backup = LocalBackup(
            exportedAt: Self.iso8601.string(from: Date()),
            terms: terms,
            feedItems: feedItems,
            savedPages: savedPages,
            customUrls: customUrls,
            amebloBlogs: amebloBlogs,
            subscribedPlatforms: subscribedPlatforms,
            wallpaper: wallpaper,
            sourcesOrder: sourcesOrder,
            oshiAvatars: oshiAvatars,
            compositions: compositions,
            hiddenItems: Array(hiddenItems)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    @MainActor
    func exportEncryptedBackupData(password: String) throws -> Data {
        try EncryptedBackupCodec.encrypt(exportBackupData(), password: password)
    }

    @MainActor
    func importBackupData(_ data: Data) throws {
        flushPendingFeedItemsSave()
        guard data.count <= Self.maximumBackupBytes else {
            throw NSError(domain: "OshiReaderBackup", code: 5, userInfo: [NSLocalizedDescriptionKey: "Backup file is too large"])
        }
        let backup = try JSONDecoder().decode(LocalBackup.self, from: data)
        guard backup.subscribed_platforms.count <= 100 else {
            throw NSError(domain: "OshiReaderBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "Backup contains too many platforms"])
        }
        guard backup.terms.count <= 200,
              backup.feed_items.count <= 2_000,
              backup.saved_pages.count <= 2_000,
              backup.custom_urls.count <= 200,
              backup.ameblo_blogs.count <= AmebloBlog.maximumCount,
              backup.oshi_avatars.count <= 200,
              backup.compositions.count <= 200,
              backup.compositions.values.allSatisfy({ $0.count <= 100 }),
              backup.hidden_items.count <= 5_000 else {
            throw NSError(domain: "OshiReaderBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "Backup contains too much data"])
        }

        let normalizedTerms = backup.terms.map { term -> WatchTerm in
            var normalized = Self.normalizedTerm(term)
            normalized.aliases = Array(IngestionService.searchKeywords(for: term).dropFirst())
            return normalized
        }
        let normalizedAmebloBlogs = Array(backup.ameblo_blogs.compactMap {
            AmebloBlog(url: $0.url, title: $0.title, addedAt: $0.added_at)
        }.prefix(AmebloBlog.maximumCount))
        var normalizedSubscribedPlatforms = Self.normalizePlatformIDs(backup.subscribed_platforms)
        if !normalizedAmebloBlogs.isEmpty && !normalizedSubscribedPlatforms.contains("ameblo") {
            normalizedSubscribedPlatforms.append("ameblo")
        }
        let normalizedSourcesOrder = Self.normalizedSourcesOrder(backup.sources_order)
        let customURLImport = Self.normalizedCustomUrlImport(backup.custom_urls)
        let normalizedSavedPages = Self.normalizedImportedSavedPages(backup.saved_pages, customURLImport: customURLImport)
        let importedFeedItems = Self.normalizedImportedFeedItems(backup.feed_items, customURLImport: customURLImport)
        let prunedFeedItemKeys = Set(importedFeedItems
            .filter { FeedItemPolicy.shouldPruneLegacyYouTubeItem($0) }
            .map(Self.feedItemKey))
        let normalizedFeedItems = Self.cappedFeedItems(
            importedFeedItems
                .filter { !FeedItemPolicy.shouldPruneLegacyYouTubeItem($0) }
                .sorted(by: Self.feedItemSortPrecedes),
            preserving: [],
            subscribedPlatforms: normalizedSubscribedPlatforms
        )
        let normalizedHiddenItems = backup.hidden_items.compactMap { hiddenKey -> String? in
            guard !prunedFeedItemKeys.contains(hiddenKey) else { return nil }
            return Self.normalizedImportedHiddenItem(hiddenKey, customURLImport: customURLImport)
        }
        let normalizedCustomUrls = customURLImport.urls

        let encodedFiles: [(String, Data)] = try [
            ("terms", encoder.encode(normalizedTerms)),
            ("feed_items", encoder.encode(normalizedFeedItems)),
            ("saved_pages", encoder.encode(normalizedSavedPages)),
            ("custom_urls", encoder.encode(normalizedCustomUrls)),
            ("ameblo_blogs", encoder.encode(normalizedAmebloBlogs)),
            ("subscribed_platforms", encoder.encode(normalizedSubscribedPlatforms)),
            ("oshi_avatars", encoder.encode(backup.oshi_avatars)),
            ("oshi_compositions", encoder.encode(backup.compositions)),
            ("hidden_items", encoder.encode(normalizedHiddenItems))
        ]
        try saveEncodedFilesSynchronously(
            encodedFiles,
            wallpaper: backup.wallpaper,
            sourcesOrder: normalizedSourcesOrder
        )

        dataRevision += 1
        UserDefaults.standard.set(dataRevision, forKey: profileKey("local_data_revision"))
        invalidateContentCaches()
        NotificationManager.shared.clearLocalNotifications()

        terms = normalizedTerms
        feedItems = normalizedFeedItems
        savedPages = normalizedSavedPages
        customUrls = normalizedCustomUrls
        amebloBlogs = normalizedAmebloBlogs
        subscribedPlatforms = normalizedSubscribedPlatforms
        wallpaper = backup.wallpaper
        sourcesOrder = normalizedSourcesOrder
        oshiAvatars = backup.oshi_avatars
        compositions = backup.compositions
        hiddenItems = Set(normalizedHiddenItems)

    }

    @MainActor
    func importEncryptedBackupData(_ data: Data, password: String) throws {
        let plaintext = try EncryptedBackupCodec.decrypt(data, password: password)
        try importBackupData(plaintext)
    }

    @MainActor
    func exportProfileTransferData() throws -> Data {
        let backupData = try exportBackupData()
        let backup = try JSONDecoder().decode(LocalBackup.self, from: backupData)
        let transfer = LocalProfileTransfer(
            profile: activeProfile,
            backup: backup,
            settings: LocalProfileSettings.load(profileID: profileStore.activeProfileID)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(transfer)
        guard data.count <= Self.maximumProfileTransferBytes else {
            throw NSError(domain: "OshiReaderProfile", code: 5, userInfo: [NSLocalizedDescriptionKey: "Profile package is too large"])
        }
        return data
    }

    @MainActor
    @discardableResult
    func importProfileTransferData(_ data: Data) throws -> LocalProfile {
        guard data.count <= Self.maximumProfileTransferBytes else { throw LocalProfileError.invalidPackage }
        guard let packageObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packageVersion = packageObject["version"] as? Int else {
            throw LocalProfileError.invalidPackage
        }
        if packageVersion < 1 || packageVersion > LocalProfileTransfer.currentVersion {
            throw LocalProfileError.unsupportedPackageVersion
        }
        let transfer: LocalProfileTransfer
        do {
            transfer = try JSONDecoder().decode(LocalProfileTransfer.self, from: data)
        } catch {
            throw LocalProfileError.invalidPackage
        }
        guard !transfer.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalProfileError.invalidPackage
        }

        let originalProfileID = profileStore.activeProfileID
        let importedName = uniqueImportedProfileName(transfer.profile.name)
        let imported = try profileStore.createProfile(name: importedName)
        do {
            try switchProfile(to: imported.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try importBackupData(encoder.encode(transfer.backup))
            if let settings = transfer.settings {
                settings.apply(to: imported.id)
                ThemeManager.shared.configure(profileID: imported.id)
                AppearanceManager.shared.configure(profileID: imported.id)
                I18nManager.shared.configure(profileID: imported.id)
            }
            try switchProfile(to: originalProfileID)
            return imported
        } catch {
            if profileStore.activeProfileID != originalProfileID {
                try? switchProfile(to: originalProfileID)
            }
            try? profileStore.deleteProfile(id: imported.id)
            throw error
        }
    }

    private func uniqueImportedProfileName(_ requested: String) -> String {
        let base = requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported profile" : requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profileStore.profile(named: base) != nil else { return base }
        var index = 2
        while profileStore.profile(named: "\(base) \(index)") != nil { index += 1 }
        return "\(base) \(index)"
    }

    static func subscribedPlatformsForLoadedValue(_ ids: [String], hasSavedFile: Bool) -> [String] {
        hasSavedFile ? normalizePlatformIDs(ids) : PlatformRegistry.defaultSubscribedIDs
    }

    static func normalizePlatformIDs(_ ids: [String]) -> [String] {
        PlatformRegistry.normalizeIDs(ids)
    }

    static func normalizedSourcesOrder(_ ids: [String]?) -> [String]? {
        ids.map(normalizePlatformIDs)
    }

    private func invalidateContentCaches() {
        contentCacheGenerationLock.lock()
        contentCacheGenerationValue += 1
        let nextGeneration = contentCacheGenerationValue
        contentCacheGeneration = nextGeneration
        UserDefaults.standard.set(nextGeneration, forKey: profileKey("content_cache_generation"))
        contentCacheGenerationLock.unlock()

        queue.sync {
            let docsDirectory = profileStore.directoryURL(for: profileStore.activeProfileID)
            if let contents = try? FileManager.default.contentsOfDirectory(at: docsDirectory, includingPropertiesForKeys: nil) {
                for url in contents where url.lastPathComponent.hasPrefix("cache_") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - UI Test Fixture
    func resetForUITesting() {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }

        profileStore.resetForUITesting()

        let now = Self.iso8601.string(from: Date())
        let term = WatchTerm(id: "ui-term-oshitest", keyword: "UITest Oshi", collection_mode: "all_info", is_active: true, created_at: now)
        let feedItem = FeedItem(
            id: "ui-feed-reader",
            platform: "news",
            url: "https://example.com/oshireader-ui-test",
            title: "UITest Oshi headline",
            content_text: "A seeded article used by OshiReader UI tests.",
            author: "UI Test Desk",
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: term.keyword,
            fetched_at: now
        )
        let savedPage = SavedPage(
            id: "ui-saved-reader",
            url: "https://example.com/oshireader-saved",
            title: "UITest saved article",
            platform: "news",
            saved_at: now
        )
        let customUrl = CustomUrl(
            id: "custom:https%3A%2F%2Fexample.com%2Ffeed.xml",
            url: "https://example.com/feed.xml",
            title: "UITest custom feed",
            added_at: now
        )
        let layer = AvatarLayer(
            id: "ui-avatar-layer",
            imageUrl: "https://example.com/avatar.png",
            x: 105,
            y: 105,
            scale: 1.0,
            zIndex: 1
        )
        let platformFixtureID: String? = {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--uitesting-single-platform-feed"),
                  args.indices.contains(index + 1) else {
                return nil
            }
            return PlatformRegistry.normalizeID(args[index + 1])
        }()
        let usesAllPlatformSortFixture = ProcessInfo.processInfo.arguments.contains("--uitesting-all-platform-sort-feed")
        let mediaPlatformIDs: Set<String> = ["youtube", "niconico", "tver", "twitter"]
        let allPlatformFeedItems = PlatformRegistry.all.enumerated().map { index, platform in
            let publishedAt = usesAllPlatformSortFixture
                ? Self.iso8601.string(from: Date().addingTimeInterval(TimeInterval(-index * 60)))
                : now
            return FeedItem(
                id: platform.id == "youtube" ? "youtube:ui-platform-youtube" : "ui-platform-\(platform.id)",
                platform: platform.id,
                url: platform.id == "youtube"
                    ? "https://www.youtube.com/watch?v=oshireaderui1"
                    : "https://example.com/oshireader-ui-test/\(platform.id)",
                title: "UITest Oshi \(platform.name) item",
                content_text: "A seeded \(platform.name) item for UITest Oshi used by OshiReader UI tests.",
                author: "UI Test Desk",
                thumbnail_url: nil,
                media_type: mediaPlatformIDs.contains(platform.id) ? "video" : "article",
                published_at: publishedAt,
                watch_term_keyword: term.keyword,
                fetched_at: now,
                source: platform.id == "youtube" ? "youtube_scrape" : nil
            )
        }

        runOnMain {
            self.terms = [term]
            if let platformFixtureID {
                self.feedItems = allPlatformFeedItems.filter { PlatformRegistry.normalizeID($0.platform) == platformFixtureID }
            } else if usesAllPlatformSortFixture {
                self.feedItems = Array(allPlatformFeedItems.reversed())
            } else {
                self.feedItems = [feedItem]
            }
            self.savedPages = [savedPage]
            self.customUrls = [customUrl]
            self.amebloBlogs = []
            if let platformFixtureID {
                self.subscribedPlatforms = [platformFixtureID]
            } else if usesAllPlatformSortFixture {
                self.subscribedPlatforms = PlatformRegistry.all.map(\.id)
            } else {
                self.subscribedPlatforms = ["news", "youtube", "tver", "custom"]
            }
            self.wallpaper = nil
            self.sourcesOrder = nil
            self.oshiAvatars = [:]
            self.compositions = [term.keyword: [layer]]
            self.hiddenItems = []
            // Do NOT persist fixture data — only seed in-memory so nothing stains the
            // container after the test process exits.
            UserDefaults.standard.removeObject(forKey: self.profileKey("wallpaper_url"))
            UserDefaults.standard.removeObject(forKey: self.profileKey("sources_order"))
        }
    }
    
    // MARK: - Content Cache (Offline Pages)
    func saveContentCache(id: String, html: String, sourceGeneration: Int? = nil) {
        let name = "cache_\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)"
        saveToFile(name: name, value: html) { [weak self] in
            guard let self else { return false }
            guard let sourceGeneration else { return true }
            self.contentCacheGenerationLock.lock()
            defer { self.contentCacheGenerationLock.unlock() }
            return sourceGeneration == self.contentCacheGenerationValue
        }
    }
    
    func getContentCache(id: String) -> String? {
        let name = "cache_\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)"
        let result: String? = loadFromFile(name: name, defaultValue: nil)
        return result
    }
    
    func removeContentCache(id: String) {
        let name = "cache_\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)"
        let url = fileURL(for: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    // MARK: - Stats
    func getStats() -> (total: Int, byPlatform: [String: Int]) {
        var counts = [String: Int]()
        for item in feedItems {
            let key = normalizedPlatformKey(item.platform)
            counts[key] = (counts[key] ?? 0) + 1
        }
        return (feedItems.count, counts)
    }

    private func normalizedPlatformKey(_ platform: String) -> String {
        PlatformRegistry.normalizeID(platform)
    }
}
