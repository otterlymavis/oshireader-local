import Foundation
import Combine
import WidgetKit

/// Coalesces rapid mutations of a single JSON-backed store into one
/// debounced disk write (e.g. hiding several items in a row produces one
/// write instead of N full re-encodes), while still allowing an immediate
/// synchronous flush for lifecycle transitions like app backgrounding.
private final class DebouncedFileSaver {
    private let lock = NSLock()
    private var generation = 0
    private var pendingWorkItem: DispatchWorkItem?

    func scheduleSave(on queue: DispatchQueue, delay: DispatchTimeInterval = .milliseconds(250), write: @escaping () -> Void) {
        lock.lock()
        pendingWorkItem?.cancel()
        generation &+= 1
        let currentGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.generation == currentGeneration
            self.lock.unlock()
            guard isCurrent else { return }
            write()
        }
        pendingWorkItem = workItem
        lock.unlock()
        // Scheduled for later execution on `queue`, not run inline, so this
        // can't reenter the lock we're about to release.
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Cancels any pending debounced write and performs `write` synchronously
    /// on `queue` right now.
    func flush(on queue: DispatchQueue, write: @escaping () -> Void) {
        lock.lock()
        generation &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        lock.unlock()
        queue.sync(execute: write)
    }
}

private struct LocalRestoreManifest: Codable {
    let stagingDirectory: String
    let files: [String]
    let wallpaper: String?
    let sourcesOrder: [String]?
}

/// What `LocalDB.processPendingShares()` did with a drained batch, so the UI
/// can tell the user when a share silently didn't make it in (duplicate,
/// invalid, or the custom-URL limit was hit) instead of just going quiet —
/// the same failures `AddUrlSheet`'s in-app flow already surfaces.
struct PendingShareDrainSummary: Equatable {
    let addedCount: Int
    let failures: [CustomUrlAddResult]
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
    /// Shared by the interactive-add cap and `importBackupData`'s validation
    /// guard, so a device can never accumulate more custom URLs than a
    /// backup could restore.
    private static let maximumCustomUrls = 200
    /// Shared by the interactive-add cap and `importBackupData`'s validation
    /// guard. Saved pages are deliberate user bookmarks, not auto-ingested
    /// feed content, so this is far higher than `maxFeedItems`.
    private static let maximumSavedPages = 2_000
    private static let minFeedItemsPerSubscribedPlatform = 8
    private static let minFeedItemsPerDiscussionPlatform = 25
    private static let discussionActivityPlatforms: Set<String> = ["5ch", "girlschannel"]
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
    private let feedItemsSaver = DebouncedFileSaver()
    private let hiddenItemsSaver = DebouncedFileSaver()
    private let termsSaver = DebouncedFileSaver()
    private let widgetSnapshotSaver = DebouncedFileSaver()
    private static let widgetItemsPerTerm = 10
    private var contentCacheGenerationValue = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let profileStore: LocalProfileStore

    // `queryFeed` is called on nearly every re-render of the feed view, but
    // its filter/sort/dedup pass is expensive. `objectWillChange` fires on
    // every `@Published` mutation (feedItems, hiddenItems, terms,
    // subscribedPlatforms, and others queryFeed doesn't use), so bumping a
    // generation counter from it over-invalidates on unrelated changes
    // (e.g. an avatar edit) but never under-invalidates — unlike hand-picking
    // call sites to bump a counter, which is exactly the kind of thing that's
    // easy to miss one of and silently serve stale query results.
    private var queryFeedGeneration = 0
    private var queryFeedInvalidationSubscription: AnyCancellable?
    private var queryFeedCache: (keyword: String?, days: Int, generation: Int, hourBucket: Int, result: [FeedItem])?

    private init() {
        self.profileStore = LocalProfileStore.shared
        recoverPendingRestoreIfNeeded()
        loadAll()
        queryFeedInvalidationSubscription = objectWillChange.sink { [weak self] _ in
            self?.queryFeedGeneration &+= 1
            self?.scheduleWidgetSnapshotRefresh()
        }
    }

    // MARK: - Widget snapshot
    //
    // The widget extension can't reach LocalDB's Documents-directory JSON
    // files, so on every data change we publish a small per-term snapshot
    // into the shared App Group container instead. Debounced the same way
    // as `scheduleSave` (`objectWillChange` fires on every `@Published`
    // mutation, including unrelated ones like an avatar edit — cheap to
    // over-trigger, and simpler than hand-picking call sites and risking
    // missing one). The actual `queryFeed` recompute happens once the
    // debounce settles, on the main queue where `@Published` reads are safe.
    private func scheduleWidgetSnapshotRefresh() {
        widgetSnapshotSaver.scheduleSave(on: DispatchQueue.main, delay: .milliseconds(400)) { [weak self] in
            self?.writeWidgetSnapshotNow()
        }
    }

    private func writeWidgetSnapshotNow() {
        let termOptions = terms.map { WidgetTermOption(id: $0.id, keyword: $0.keyword) }
        var itemsByTermID: [String: [FeedItem]] = [:]
        for term in terms {
            // Deliberately bypasses `queryFeed`'s single-slot cache: looping
            // over every term here would thrash that cache (each term's
            // lookup evicts the last), leaving it cold for the next real
            // FeedView render right after. This recompute is already
            // debounced to once per data-change burst, so there's no
            // caching win to give up.
            itemsByTermID[term.id] = Array(computeQueryFeed(keyword: term.keyword, days: 0).prefix(Self.widgetItemsPerTerm))
        }
        let snapshot = WidgetSnapshot(terms: termOptions, itemsByTermID: itemsByTermID, updatedAt: Date())
        queue.async {
            WidgetSnapshotStore.write(snapshot)
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
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
        if PlusStore.shouldSyncBackend {
            Task { await PushSyncCoordinator.shared.reconcile() }
        }
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
        PushSyncCoordinator.shared.scheduleProfileDeletion(profileID: id)
        try profileStore.deleteProfile(id: id)
    }

    @MainActor
    private func clearNotificationsForProfile(_ profileID: UUID) {
        let termsURL = profileStore.fileURL(for: "terms", profileID: profileID)
        guard let data = try? Data(contentsOf: termsURL),
              let terms = try? decoder.decode([WatchTerm].self, from: data) else { return }
        for term in terms {
            Task { @MainActor in
                await NotificationManager.shared.clearNotification(forTermID: term.id)
            }
        }
    }
    
    // MARK: - Load and Save Helpers
    private func loadAll() {
        // The 9 reads below are independent files with no shared mutable
        // state (the JSONDecoder instance they share is never reconfigured
        // per-call, so concurrent `decode` calls on it are safe). Loading
        // them in parallel instead of one after another cuts the time this
        // blocks the caller — app launch and every profile switch — down
        // from the sum of each file's I/O+decode time to roughly the slowest
        // one, instead of all of them back-to-back.
        let loadQueue = DispatchQueue(label: "com.otterlymavis.oshireader.db.load", attributes: .concurrent)
        let group = DispatchGroup()
        func loadConcurrently(_ work: @escaping () -> Void) {
            group.enter()
            loadQueue.async {
                work()
                group.leave()
            }
        }

        var loadedTerms: [WatchTerm] = []
        var loadedFeedItems: [FeedItem] = []
        var loadedCustomUrls: [CustomUrl] = []
        var loadedSavedPages: [SavedPage] = []
        var loadedAmebloBlogs: [AmebloBlog] = []
        var loadedSubscribedPlatforms: [String] = []
        var hasSavedSubscribedPlatforms = false
        var loadedOshiAvatars: [String: String] = [:]
        var loadedCompositions: [String: [AvatarLayer]] = [:]
        var hiddenArray: [String] = []

        loadConcurrently { loadedTerms = self.loadArrayFromFile(name: "terms") }
        loadConcurrently { loadedFeedItems = self.loadArrayFromFile(name: "feed_items") }
        loadConcurrently { loadedCustomUrls = self.loadArrayFromFile(name: "custom_urls") }
        loadConcurrently { loadedSavedPages = self.loadArrayFromFile(name: "saved_pages") }
        loadConcurrently { loadedAmebloBlogs = self.loadArrayFromFile(name: "ameblo_blogs") }
        loadConcurrently {
            let subscribedPlatformsURL = self.fileURL(for: "subscribed_platforms")
            hasSavedSubscribedPlatforms = FileManager.default.fileExists(atPath: subscribedPlatformsURL.path)
            loadedSubscribedPlatforms = self.loadFromFile(
                name: "subscribed_platforms",
                defaultValue: PlatformRegistry.defaultSubscribedIDs
            )
        }
        loadConcurrently { loadedOshiAvatars = self.loadFromFile(name: "oshi_avatars", defaultValue: [:]) }
        loadConcurrently { loadedCompositions = self.loadFromFile(name: "oshi_compositions", defaultValue: [:]) }
        loadConcurrently { hiddenArray = self.loadFromFile(name: "hidden_items", defaultValue: []) }
        group.wait()

        self.terms = loadedTerms.map(Self.normalizedTerm)
        if self.terms != loadedTerms {
            saveToFile(name: "terms", value: self.terms)
        }
        let loadedCustomURLImport = Self.normalizedCustomUrlImport(loadedCustomUrls)
        self.customUrls = loadedCustomURLImport.urls
        let normalizedLoadedCustomUrls = self.customUrls != loadedCustomUrls
        if normalizedLoadedCustomUrls {
            saveToFile(name: "custom_urls", value: self.customUrls)
        }
        self.savedPages = Self.normalizedImportedSavedPages(loadedSavedPages, customURLImport: loadedCustomURLImport)
        let normalizedLoadedSavedPages = self.savedPages != loadedSavedPages
        if normalizedLoadedSavedPages {
            saveToFile(name: "saved_pages", value: self.savedPages)
        }
        self.feedItems = Self.normalizedImportedFeedItems(loadedFeedItems, customURLImport: loadedCustomURLImport)
        let normalizedLoadedFeedItems = self.feedItems != loadedFeedItems
        let prunedLegacyYouTubeItemKeys = pruneLegacyYouTubeItems()
        self.amebloBlogs = loadedAmebloBlogs
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
        self.oshiAvatars = loadedOshiAvatars
        self.compositions = loadedCompositions
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

    /// Wraps a single array element so one malformed entry doesn't fail the
    /// whole array decode — `decode()` swallows the per-element error and
    /// leaves `value` nil instead of throwing.
    private struct FailableDecodable<Wrapped: Decodable>: Decodable {
        let value: Wrapped?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(Wrapped.self)
        }
    }

    /// Like `loadFromFile`, but for array-backed stores: a single corrupt
    /// element is skipped and logged instead of discarding the entire store
    /// (which previously meant one bad entry could wipe out everything else
    /// in the file on the next unrelated write).
    private func loadArrayFromFile<T: Decodable>(name: String, defaultValue: [T] = []) -> [T] {
        let url = fileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        do {
            let data = try Data(contentsOf: url)
            let wrapped = try decoder.decode([FailableDecodable<T>].self, from: data)
            let decoded = wrapped.compactMap(\.value)
            let skippedCount = wrapped.count - decoded.count
            if skippedCount > 0 {
                AppLogger.persistence.error("Skipped \(skippedCount) malformed entr\(skippedCount == 1 ? "y" : "ies") while loading \(name)")
            }
            return decoded
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
        flushPendingHiddenItemsSave()
        flushPendingTermsSave()
        queue.sync {}
    }

    private func writeEncoded<T: Encodable>(_ value: T, to name: String) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: fileURL(for: name), options: [.atomic])
        } catch {
            AppLogger.persistence.error("Failed to save \(name): \(error.localizedDescription)")
        }
    }

    /// Coalesces rapid feed merges into one serialized disk write while keeping
    /// the in-memory feed immediately available to SwiftUI.
    func flushPendingFeedItemsSave() {
        let snapshot = feedItems
        feedItemsSaver.flush(on: queue) { [weak self] in self?.writeEncoded(snapshot, to: "feed_items") }
    }

    private func saveFeedItemsSoon() {
        let snapshot = feedItems
        feedItemsSaver.scheduleSave(on: queue) { [weak self] in self?.writeEncoded(snapshot, to: "feed_items") }
    }

    private func flushPendingHiddenItemsSave() {
        let snapshot = Array(hiddenItems)
        hiddenItemsSaver.flush(on: queue) { [weak self] in self?.writeEncoded(snapshot, to: "hidden_items") }
    }

    /// Coalesces rapid hide/unhide actions the same way `saveFeedItemsSoon`
    /// coalesces feed merges, instead of a full re-encode+write per action.
    private func saveHiddenItemsSoon() {
        let snapshot = Array(hiddenItems)
        hiddenItemsSaver.scheduleSave(on: queue) { [weak self] in self?.writeEncoded(snapshot, to: "hidden_items") }
    }

    private func flushPendingTermsSave() {
        let snapshot = terms
        termsSaver.flush(on: queue) { [weak self] in self?.writeEncoded(snapshot, to: "terms") }
    }

    /// Coalesces rapid term edits the same way `saveFeedItemsSoon` coalesces
    /// feed merges, instead of a full re-encode+write per action.
    private func saveTermsSoon() {
        let snapshot = terms
        termsSaver.scheduleSave(on: queue) { [weak self] in self?.writeEncoded(snapshot, to: "terms") }
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
            self.saveTermsSoon()
        }
        return term
    }
    
    func updateTerm(id: String, isActive: Bool? = nil, collectionMode: String? = nil, sourceMode: SourceMode? = nil, selectedPlatforms: [String]? = nil, notifyOnNew: Bool? = nil, backendTermID: Int?? = nil, aliases: [String]? = nil) {
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
                            await NotificationManager.shared.clearNotification(forTermID: id)
                        }
                    }
                }
                if let backendTermID { term.backendTermID = backendTermID }
                if let aliases = aliases { term.aliases = aliases }
                self.terms[idx] = term
                self.saveTermsSoon()
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
                let backendTermID = self.terms[term].backendTermID
                self.advanceDataRevision()
                self.terms.remove(at: term)
                let profileID = self.profileStore.activeProfileID
                Task { @MainActor in
                    PushSyncCoordinator.shared.removeLocalTerm(
                        profileID: profileID,
                        localTermID: id,
                        backendTermID: backendTermID
                    )
                }
                Task { @MainActor in
                    RecentTermUsageStore.shared.remove(termID: id)
                    await NotificationManager.shared.clearNotification(forTermID: id)
                }
                self.saveTermsSoon()
                
                // Also clean up items containing that watch term keyword
                self.feedItems.removeAll(where: { $0.watch_term_keyword == keyword })
                let hiddenSuffix = "::\(keyword)"
                let remainingHiddenSuffixes = Set(self.terms.map { "::\($0.keyword)" })
                self.hiddenItems = self.hiddenItems.filter { hiddenKey in
                    if remainingHiddenSuffixes.contains(where: { hiddenKey.hasSuffix($0) }) { return true }
                    return !hiddenKey.hasSuffix(hiddenSuffix)
                }
                self.saveHiddenItemsSoon()
                self.saveFeedItemsSoon()
            }
        }
    }
    
    // MARK: - Feed Items & Merging
    struct FeedMergeResult: Equatable {
        let addedCount: Int
        let didMutate: Bool
    }

    // Items older than this never trigger a notification, even when they're
    // new to local storage — e.g. a freshly created watch term, a newly
    // enabled platform, or an item that re-surfaces after being evicted by
    // the feed cap all look "new" to the merge but can carry a publish date
    // from long before this device ever saw them.
    private static let maxNotifiableItemAge: TimeInterval = 3 * 24 * 60 * 60

    @MainActor
    func mergeItems(
        newItems: [FeedItem],
        sourceRevision: Int? = nil,
        notificationHandler: (([FeedItem], [WatchTerm]) -> Void)? = nil
    ) -> Int {
        mergeItemsResult(
            newItems: newItems,
            sourceRevision: sourceRevision,
            notificationHandler: notificationHandler
        ).addedCount
    }

    @MainActor
    func mergeItemsResult(
        newItems: [FeedItem],
        sourceRevision: Int? = nil,
        notificationHandler: (([FeedItem], [WatchTerm]) -> Void)? = nil
    ) -> FeedMergeResult {
        mergeItemsBatchedResult(
            newItemsBatches: [newItems],
            sourceRevision: sourceRevision,
            notificationHandler: notificationHandler
        )
    }

    @MainActor
    func mergeItemsBatched(
        newItemsBatches: [[FeedItem]],
        sourceRevision: Int? = nil,
        notificationHandler: (([FeedItem], [WatchTerm]) -> Void)? = nil
    ) -> Int {
        mergeItemsBatchedResult(
            newItemsBatches: newItemsBatches,
            sourceRevision: sourceRevision,
            notificationHandler: notificationHandler
        ).addedCount
    }

    @MainActor
    func mergeItemsBatchedResult(
        newItemsBatches: [[FeedItem]],
        sourceRevision: Int? = nil,
        notificationHandler: (([FeedItem], [WatchTerm]) -> Void)? = nil
    ) -> FeedMergeResult {
        guard sourceRevision == nil || sourceRevision == dataRevision else {
            return FeedMergeResult(addedCount: 0, didMutate: false)
        }
        var addedCount = 0
        var addedItems: [FeedItem] = []
        var addedKeys: [String] = []

        // Compute each incoming item's key once (it's a string interpolation,
        // not free) instead of recomputing it here and again in the merge
        // loop below.
        var newKeyed: [(item: FeedItem, key: String)] = []
        newKeyed.reserveCapacity(newItemsBatches.reduce(0) { $0 + $1.count })
        for item in newItemsBatches.lazy.flatMap({ $0 }) {
            let key = Self.feedItemKey(item)
            let isHidden = self.hiddenItems.contains(key)
            let isSearchFallback = Self.isSearchFallbackItem(item)
            guard !isHidden, !isSearchFallback, !FeedItemPolicy.shouldPruneLegacyYouTubeItem(item) else { continue }
            newKeyed.append((item, key))
        }

        var currentMap = [String: FeedItem]()
        for item in self.feedItems {
            if FeedItemPolicy.shouldPruneLegacyYouTubeItem(item) { continue }
            currentMap[Self.feedItemKey(item)] = item
        }
        let wasFirstLoad = currentMap.isEmpty

        for (item, key) in newKeyed {
            if currentMap[key] == nil {
                currentMap[key] = item
                addedCount += 1
                addedItems.append(item)
                addedKeys.append(key)
            } else {
                // Merge/update fields if needed (like title length, content, published date)
                let existing = currentMap[key]!
                let shouldReplaceTitle = (item.title?.isEmpty == false) &&
                    (existing.title == nil ||
                     existing.title?.contains("...") == true ||
                     (item.title?.count ?? 0) > (existing.title?.count ?? 0) + 8)

                let merged = existing.with(
                    title: shouldReplaceTitle ? item.title : existing.title,
                    content_text: item.content_text ?? existing.content_text,
                    author: item.author ?? existing.author,
                    thumbnail_url: item.thumbnail_url ?? existing.thumbnail_url,
                    published_at: Self.mergedPublishedAt(existing: existing, incoming: item),
                    fetched_at: item.fetched_at,
                    source: item.source ?? existing.source
                )
                currentMap[key] = merged
            }
        }
        
        // Precompute each item's sort date once instead of letting the
        // comparator re-derive it on every comparison — sorted(by:) makes
        // O(n log n) comparator calls, each parsing both sides, which was
        // the dominant cost of a full-refresh merge. Tie-break order below
        // must stay in sync with feedItemSortPrecedes.
        let sorted = currentMap.values
            .map { ($0, parseISO8601Date($0.published_at) ?? .distantPast) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.id != rhs.0.id { return lhs.0.id < rhs.0.id }
                if lhs.0.watch_term_keyword != rhs.0.watch_term_keyword { return lhs.0.watch_term_keyword < rhs.0.watch_term_keyword }
                return lhs.0.url < rhs.0.url
            }
            .map(\.0)
        let preserveAddedItems = !self.feedItems.isEmpty
        let preservedKeys = preserveAddedItems ? Set(addedKeys) : []
        let finalItems = Self.cappedFeedItems(
            sorted,
            preserving: preservedKeys,
            subscribedPlatforms: subscribedPlatforms
        )

        // Only notify for items that survived the cap — avoids pinging for articles
        // that were immediately evicted as too old.
        if !addedItems.isEmpty && !wasFirstLoad {
            let survivedKeys = Set(finalItems.map(Self.feedItemKey))
            let now = Date()
            let notifyItems = zip(addedItems, addedKeys)
                .filter { survivedKeys.contains($0.1) }
                .map(\.0)
                .filter {
                    // 5ch/girlschannel published_at reflects thread creation, not the
                    // latest bump, so it's not a useful staleness signal there — same
                    // exemption computeQueryFeed's cutoff check makes.
                    if Self.discussionActivityPlatforms.contains(normalizedPlatformKey($0.platform)) {
                        return true
                    }
                    // An unparseable date means we can't tell whether the item is
                    // stale; fail open rather than silently swallow the notification.
                    guard let published = parseISO8601Date($0.published_at) else { return true }
                    return now.timeIntervalSince(published) <= Self.maxNotifiableItemAge
                }
            if !notifyItems.isEmpty {
                let terms = self.terms
                if let notificationHandler {
                    notificationHandler(notifyItems, terms)
                } else {
                    Task {
                        await NotificationManager.shared.notifyForNewItems(notifyItems, terms: terms)
                    }
                }
            }
        }

        let didMutate = finalItems != self.feedItems
        self.feedItems = finalItems
        if didMutate {
            self.saveFeedItemsSoon()
        }
        return FeedMergeResult(addedCount: addedCount, didMutate: didMutate)
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

        return incomingDate >= existingDate ? incoming.published_at : existing.published_at
    }


    private struct FeedQueryCandidate {
        let item: FeedItem
        let platformKey: String
        let date: Date
    }

    private static func cappedFeedItems(
        _ sortedItems: [FeedItem],
        preserving preservedKeys: Set<String>,
        subscribedPlatforms: [String]
    ) -> [FeedItem] {
        guard sortedItems.count > maxFeedItems else { return sortedItems }

        // Each item's key and normalized platform are needed repeatedly below
        // (feedItemKey allocates a string, normalizeID trims+lowercases) —
        // compute both once per item instead of recomputing them on every
        // pass, and instead of rescanning the full list once per subscribed
        // platform.
        let keys = sortedItems.map(feedItemKey)
        let normalizedPlatforms = sortedItems.map { PlatformRegistry.normalizeID($0.platform) }

        // Each pass below only decides which keys survive the cap; membership
        // is tracked in `selectedKeys` and the result is reassembled with a
        // single filter at the end, preserving `sortedItems`' existing order
        // instead of re-sorting the selection after every pass.
        var selectedKeys = Set<String>()

        preservedPass: for index in sortedItems.indices where preservedKeys.contains(keys[index]) {
            guard selectedKeys.insert(keys[index]).inserted else { continue }
            if selectedKeys.count >= maxFeedItems { break preservedPass }
        }

        if selectedKeys.count < maxFeedItems {
            let subscribed = Set(subscribedPlatforms.filter { $0 != "custom" }.map(PlatformRegistry.normalizeID))
            var indicesByPlatform: [String: [Int]] = [:]
            for index in sortedItems.indices where subscribed.contains(normalizedPlatforms[index]) {
                indicesByPlatform[normalizedPlatforms[index], default: []].append(index)
            }
            platformPass: for platformId in subscribed.sorted() {
                var keptForPlatform = 0
                let targetCount = minRetainedFeedItems(for: platformId)
                for index in indicesByPlatform[platformId] ?? [] {
                    guard selectedKeys.insert(keys[index]).inserted else { continue }
                    keptForPlatform += 1
                    if selectedKeys.count >= maxFeedItems { break platformPass }
                    if keptForPlatform >= targetCount { break }
                }
            }
        }

        if selectedKeys.count < maxFeedItems {
            for key in keys {
                guard selectedKeys.count < maxFeedItems else { break }
                selectedKeys.insert(key)
            }
        }

        return sortedItems.indices.filter { selectedKeys.contains(keys[$0]) }.map { sortedItems[$0] }
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
            self.saveHiddenItemsSoon()
            
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
        // Bucketed by hour so a long-lived cache entry can't drift more than
        // an hour stale against the days-based cutoff in computeQueryFeed —
        // the generation counter alone only invalidates on data mutations,
        // not on the passage of real time.
        let hourBucket = Int(Date().timeIntervalSince1970 / 3600)
        if let cache = queryFeedCache,
           cache.keyword == keyword, cache.days == days,
           cache.generation == queryFeedGeneration, cache.hourBucket == hourBucket {
            return cache.result
        }
        let result = computeQueryFeed(keyword: keyword, days: days)
        queryFeedCache = (keyword: keyword, days: days, generation: queryFeedGeneration, hourBucket: hourBucket, result: result)
        return result
    }

    private func computeQueryFeed(keyword: String?, days: Int) -> [FeedItem] {
        let now = Date()
        // days == 0 means "All Time" — no cutoff applied
        let cutoffDate = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: now) : nil
        
        let strictKeywordPlatforms = PlatformRegistry.strictKeywordPlatformIDs
            .union(["news", "tver"])
        let termsByKeyword = Dictionary(self.terms.map { ($0.keyword, $0) }, uniquingKeysWith: { first, _ in first })

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
            
            // Cutoff check (skip limit check for 5ch, girlschannel)
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
                let aliases = termsByKeyword[item.watch_term_keyword]?.aliases ?? []
                let matchingKeywords = [item.watch_term_keyword] + aliases
                if !matchingKeywords.contains(where: { matchesKeyword(item: item, kw: $0) }) {
                    return nil
                }
            }
            
            // Subscribed platforms
            if !subscribedPlatforms.contains(platformKey) {
                return nil
            }
            
            // Parsed once here and reused by the sort below instead of
            // letting the comparator re-derive it on every comparison.
            let date = parseISO8601Date(item.published_at) ?? .distantPast
            return FeedQueryCandidate(item: item, platformKey: platformKey, date: date)
        }
        .sorted { lhs, rhs in
            // Tie-break order must stay in sync with feedItemSortPrecedes.
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            if lhs.item.id != rhs.item.id { return lhs.item.id < rhs.item.id }
            if lhs.item.watch_term_keyword != rhs.item.watch_term_keyword { return lhs.item.watch_term_keyword < rhs.item.watch_term_keyword }
            return lhs.item.url < rhs.item.url
        }

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
                if self.savedPages.count > Self.maximumSavedPages {
                    self.savedPages.removeLast(self.savedPages.count - Self.maximumSavedPages)
                }
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
                self.saveTermsSoon()
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
            return item.with(
                id: entry.id,
                platform: "custom",
                url: entry.url,
                source: item.source ?? "custom_url"
            )
        }
    }

    private static func normalizedImportedSavedPages(
        _ pages: [SavedPage],
        customURLImport: NormalizedCustomUrlImport
    ) -> [SavedPage] {
        var seenIDs = Set<String>()
        return pages.compactMap { page in
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
        }.filter { page in
            seenIDs.insert(page.id).inserted
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

    @discardableResult
    /// Must be called on the main thread — unlike most other mutators here,
    /// it returns a result synchronously (to let the caller show a
    /// limit-reached message) so it can't dispatch through `runOnMain` the
    /// way `removeCustomUrl` does.
    func addCustomUrl(url: String, title: String) -> CustomUrlAddResult {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let entry = Self.normalizedCustomUrlEntry(url: url, title: title, addedAt: Self.iso8601.string(from: Date())) else { return .invalidURL }
        guard !customUrls.contains(where: { $0.id == entry.id }) else { return .duplicate }
        guard customUrls.count < Self.maximumCustomUrls else { return .limitReached }
        advanceDataRevision()
        customUrls.insert(entry, at: 0)
        saveToFile(name: "custom_urls", value: customUrls)
        return .added
    }

    /// Drains whatever the Share Extension queued (see `PendingShareStore`)
    /// into `customUrls` via the normal `addCustomUrl` path, then scrapes and
    /// merges them the same way the in-app "Add custom feed" sheet does.
    /// Safe to call repeatedly — the queue is empty after the first drain.
    @discardableResult
    func processPendingShares() -> PendingShareDrainSummary {
        dispatchPrecondition(condition: .onQueue(.main))
        let pending = PendingShareStore.drain()
        guard !pending.isEmpty else { return PendingShareDrainSummary(addedCount: 0, failures: []) }
        var addedCount = 0
        var failures: [CustomUrlAddResult] = []
        for share in pending {
            let result = addCustomUrl(url: share.url, title: share.title ?? "")
            if result == .added {
                addedCount += 1
            } else {
                failures.append(result)
            }
        }
        guard addedCount > 0 else { return PendingShareDrainSummary(addedCount: 0, failures: failures) }
        let sourceRevision = dataRevision
        Task { @MainActor in
            let customItems = await NetworkManager.shared.scrapeCustomUrls(self.customUrls)
            let currentItems = self.currentCustomFeedItems(customItems)
            if !currentItems.isEmpty {
                _ = self.mergeItems(newItems: currentItems, sourceRevision: sourceRevision)
            }
        }
        return PendingShareDrainSummary(addedCount: addedCount, failures: failures)
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
            self.savedPages.removeAll { page in
                PlatformRegistry.normalizeID(page.platform) == "custom" &&
                    (page.id == id || removedUrls.contains(page.url))
            }
            self.hiddenItems = self.hiddenItems
                .filter { hiddenKey in
                    if remainingCustomHiddenPrefixes.contains(where: { hiddenKey.hasPrefix($0) }) { return true }
                    return !hiddenKey.hasPrefix(removedHiddenKeyPrefix)
                }
                .subtracting(removedHiddenKeys)
            self.saveToFile(name: "custom_urls", value: self.customUrls)
            self.saveToFile(name: "saved_pages", value: self.savedPages)
            self.saveHiddenItemsSoon()
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
        flushPendingHiddenItemsSave()
        flushPendingTermsSave()
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

    /// PBKDF2 at 600k iterations is deliberately slow (that's the point —
    /// see EncryptedBackupCodec); running it detached keeps that off the
    /// main thread instead of freezing the UI for the export/import prompt.
    @MainActor
    func exportEncryptedBackupData(password: String) async throws -> Data {
        let plaintext = try exportBackupData()
        return try await Task.detached(priority: .userInitiated) {
            try EncryptedBackupCodec.encrypt(plaintext, password: password)
        }.value
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
              backup.saved_pages.count <= Self.maximumSavedPages,
              backup.custom_urls.count <= Self.maximumCustomUrls,
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
                .sorted(by: feedItemSortPrecedes),
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

    /// See exportEncryptedBackupData — PBKDF2 runs detached to keep the
    /// deliberately-slow key derivation off the main thread.
    @MainActor
    func importEncryptedBackupData(_ data: Data, password: String) async throws {
        let plaintext = try await Task.detached(priority: .userInitiated) {
            try EncryptedBackupCodec.decrypt(data, password: password)
        }.value
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
    
    /// Reads off `queue` (a background queue) so callers on the main thread —
    /// e.g. a `WKNavigationDelegate` callback — never block on disk I/O.
    func getContentCache(id: String, completion: @escaping (String?) -> Void) {
        let name = "cache_\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)"
        queue.async { [weak self] in
            let result: String? = self?.loadFromFile(name: name, defaultValue: nil)
            DispatchQueue.main.async { completion(result) }
        }
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
