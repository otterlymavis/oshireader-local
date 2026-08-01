import Foundation
import Combine

private struct LocalRestoreManifest: Codable {
    let stagingDirectory: String
    let files: [String]
    let wallpaper: String?
    let sourcesOrder: [String]?
}

class LocalDB: ObservableObject {
    static let shared = LocalDB()
    static let maximumBackupBytes = 20 * 1024 * 1024
    
    // Published states for views
    @Published var terms: [WatchTerm] = []
    @Published var feedItems: [FeedItem] = []
    @Published var savedPages: [SavedPage] = []
    @Published var customUrls: [CustomUrl] = []
    @Published var subscribedPlatforms: [String] = []
    @Published var wallpaper: String? = nil
    @Published var sourcesOrder: [String]? = nil
    @Published var oshiAvatars: [String: String] = [:]
    @Published var compositions: [String: [AvatarLayer]] = [:]
    @Published var hiddenItems: Set<String> = []
    @Published private(set) var contentCacheGeneration: Int = UserDefaults.standard.integer(forKey: "content_cache_generation")
    @Published private(set) var dataRevision: Int = UserDefaults.standard.integer(forKey: "local_data_revision")
    
    private let queue = DispatchQueue(label: "com.otterlymavis.oshireader.db", qos: .userInitiated)
    private let pendingWritesLock = NSLock()
    private let contentCacheGenerationLock = NSLock()
    private var pendingWrites = 0
    private var contentCacheGenerationValue = UserDefaults.standard.integer(forKey: "content_cache_generation")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {
        recoverPendingRestoreIfNeeded()
        loadAll()
    }
    
    // MARK: - File Paths
    private func fileURL(for name: String) -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("\(name).json")
    }
    
    // MARK: - Load and Save Helpers
    private func loadAll() {
        self.terms = loadFromFile(name: "terms", defaultValue: [])
        self.feedItems = loadFromFile(name: "feed_items", defaultValue: [])
        self.savedPages = loadFromFile(name: "saved_pages", defaultValue: [])
        self.customUrls = loadFromFile(name: "custom_urls", defaultValue: [])
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
        self.wallpaper = UserDefaults.standard.string(forKey: "wallpaper_url")
        self.sourcesOrder = UserDefaults.standard.stringArray(forKey: "sources_order")
        self.oshiAvatars = loadFromFile(name: "oshi_avatars", defaultValue: [:])
        self.compositions = loadFromFile(name: "oshi_compositions", defaultValue: [:])
        let hiddenArray: [String] = loadFromFile(name: "hidden_items", defaultValue: [])
        self.hiddenItems = Set(hiddenArray)
    }
    
    private func loadFromFile<T: Decodable>(name: String, defaultValue: T) -> T {
        let url = fileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("Error loading \(name): \(error)")
            #endif

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
                #if DEBUG
                print("Error saving \(name): \(error)")
                #endif

            }
        }
    }

    /// Blocks until all ordinary asynchronous local writes submitted so far
    /// have reached disk. Intended for lifecycle transitions, not UI actions.
    func flushPendingWrites() {
        queue.sync {}
    }

    private func saveEncodedFilesSynchronously(
        _ files: [(String, Data)],
        wallpaper: String?,
        sourcesOrder: [String]?
    ) throws {
        let docsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
            #if DEBUG
            print("Pending local restore could not be completed: \(error)")
            #endif
        }
    }

    private func applyPendingRestore() throws {
        let docsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let manifestURL = docsDirectory.appendingPathComponent("restore_manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let manifest = try JSONDecoder().decode(LocalRestoreManifest.self, from: Data(contentsOf: manifestURL))
        let expectedFiles: Set<String> = [
            "terms", "feed_items", "saved_pages", "custom_urls",
            "subscribed_platforms", "oshi_avatars", "oshi_compositions", "hidden_items"
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

        if let wallpaper = manifest.wallpaper { UserDefaults.standard.set(wallpaper, forKey: "wallpaper_url") }
        else { UserDefaults.standard.removeObject(forKey: "wallpaper_url") }
        if let sourcesOrder = manifest.sourcesOrder { UserDefaults.standard.set(sourcesOrder, forKey: "sources_order") }
        else { UserDefaults.standard.removeObject(forKey: "sources_order") }

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
        UserDefaults.standard.set(dataRevision, forKey: "local_data_revision")
    }
    
    // MARK: - Watch Terms
    func saveTerm(keyword: String, collectionMode: String = "all_info") -> WatchTerm {
        let term = WatchTerm(keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines), collection_mode: collectionMode)
        runOnMain {
            self.advanceDataRevision()
            self.terms.insert(term, at: 0)
            self.saveToFile(name: "terms", value: self.terms)
        }
        return term
    }
    
    func updateTerm(id: String, isActive: Bool? = nil, collectionMode: String? = nil, notifyOnNew: Bool? = nil, aliases: [String]? = nil) {
        runOnMain {
            if let idx = self.terms.firstIndex(where: { $0.id == id }) {
                var term = self.terms[idx]
                let changesIngestionScope =
                    isActive.map { $0 != term.is_active } ?? false ||
                    collectionMode.map { $0 != term.collection_mode } ?? false ||
                    aliases.map { $0 != term.aliases } ?? false
                if changesIngestionScope {
                    self.advanceDataRevision()
                }
                if let isActive = isActive { term.is_active = isActive }
                if let collectionMode = collectionMode { term.collection_mode = collectionMode }
                if let notifyOnNew = notifyOnNew { term.notify_on_new = notifyOnNew }
                if let aliases = aliases { term.aliases = aliases }
                self.terms[idx] = term
                self.saveToFile(name: "terms", value: self.terms)
            }
        }
    }

    func deleteTerm(id: String) {
        runOnMain {
            if let term = self.terms.firstIndex(where: { $0.id == id }) {
                let keyword = self.terms[term].keyword
                self.advanceDataRevision()
                self.terms.remove(at: term)
                self.saveToFile(name: "terms", value: self.terms)
                
                // Also clean up items containing that watch term keyword
                self.feedItems.removeAll(where: { $0.watch_term_keyword == keyword })
                self.saveToFile(name: "feed_items", value: self.feedItems)
            }
        }
    }
    
    // MARK: - Feed Items & Merging
    @MainActor
    func mergeItems(newItems: [FeedItem], sourceRevision: Int? = nil) -> Int {
        guard sourceRevision == nil || sourceRevision == dataRevision else { return 0 }
        var addedCount = 0
        var addedItems: [FeedItem] = []
        let itemKey = { (i: FeedItem) -> String in "\(i.id)::\(i.watch_term_keyword)" }
        
        let filteredNew = newItems.filter { item in
            let key = itemKey(item)
            let isHidden = self.hiddenItems.contains(key)
            let isSearchFallback = item.id.contains("search:") || item.title?.lowercased().contains("search:") == true
            return !isHidden && !isSearchFallback
        }
        
        var currentMap = [String: FeedItem]()
        for item in self.feedItems {
            currentMap[itemKey(item)] = item
        }
        
        for item in filteredNew {
            let key = itemKey(item)
            if currentMap[key] == nil {
                currentMap[key] = item
                addedCount += 1
                addedItems.append(item)
            } else {
                // Merge/update fields if needed (like title length, content, published date)
                let existing = currentMap[key]!
                let shouldReplaceTitle = (item.title?.isEmpty == false) &&
                    (existing.title == nil || existing.title!.contains("...") || item.title!.count > existing.title!.count + 8)
                
                let merged = FeedItem(
                    id: existing.id,
                    platform: existing.platform,
                    url: existing.url,
                    title: shouldReplaceTitle ? item.title : existing.title,
                    content_text: item.content_text ?? existing.content_text,
                    author: item.author ?? existing.author,
                    thumbnail_url: item.thumbnail_url ?? existing.thumbnail_url,
                    media_type: existing.media_type,
                    published_at: min(existing.published_at, item.published_at),
                    watch_term_keyword: existing.watch_term_keyword,
                    fetched_at: item.fetched_at
                )
                currentMap[key] = merged
            }
        }
        
        let sorted = currentMap.values.sorted(by: { $0.published_at > $1.published_at })
        let finalItems = Array(sorted.prefix(600)) // Replicate MAX_ITEMS = 600

        // Only notify for items that survived the cap — avoids pinging for articles
        // that were immediately evicted as too old.
        if !addedItems.isEmpty {
            let survivedKeys = Set(finalItems.map { itemKey($0) })
            let notifyItems = addedItems.filter { survivedKeys.contains(itemKey($0)) }
            if !notifyItems.isEmpty {
                let terms = self.terms
                Task {
                    await NotificationManager.shared.notifyForNewItems(notifyItems, terms: terms)
                }
            }
        }

        self.feedItems = finalItems
        self.saveToFile(name: "feed_items", value: self.feedItems)
        return addedCount
    }
    
    func deleteFeedItem(id: String, watchTermKeyword: String) {
        let key = "\(id)::\(watchTermKeyword)"
        runOnMain {
            self.hiddenItems.insert(key)
            self.saveToFile(name: "hidden_items", value: Array(self.hiddenItems))
            
            self.feedItems.removeAll(where: { $0.id == id && $0.watch_term_keyword == watchTermKeyword })
            self.saveToFile(name: "feed_items", value: self.feedItems)
        }
    }
    
    // MARK: - Query Feed (Filtering)
    func queryFeed(keyword: String?, days: Int) -> [FeedItem] {
        let now = Date()
        // days == 0 means "All Time" — no cutoff applied
        let cutoffDate = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: now) : nil
        let formatter = ISO8601DateFormatter()
        let cutoffString = cutoffDate.map { formatter.string(from: $0) }
        
        let strictKeywordPlatforms = PlatformRegistry.strictKeywordPlatformIDs
            .union(["news", "tver"])
        
        return feedItems.filter { item in
            let key = "\(item.id)::\(item.watch_term_keyword)"
            if hiddenItems.contains(key) { return false }
            
            // Search pages fallbacks
            if item.id.contains("search:") || item.title?.lowercased().contains("search:") == true { return false }
            
            // Bare address item (Yahoo News fallback checking)
            if item.platform == "yahoonews" && (item.title?.contains("https://") == true || item.content_text?.contains("https://") == true) {
                return false
            }
            
            // Cutoff check (skip limit check for 5ch, girlschannel, togetter)
            let skipCutoff = item.platform == "5ch" || item.platform == "girlschannel" || item.platform == "togetter"
            if let cutoff = cutoffString, item.published_at < cutoff && !skipCutoff {
                return false
            }
            
            // Keyword filter
            if let kw = keyword, !kw.isEmpty {
                if item.platform == "custom" {
                    // Let custom pages pass if custom matches
                } else if item.watch_term_keyword != kw {
                    return false
                }
            }
            
            // Strict keyword matching logic
            if strictKeywordPlatforms.contains(item.platform), !item.watch_term_keyword.isEmpty {
                let aliases = self.terms
                    .first { $0.keyword == item.watch_term_keyword }?
                    .aliases ?? []
                let matchingKeywords = [item.watch_term_keyword] + aliases
                if !matchingKeywords.contains(where: { matchesKeyword(item: item, kw: $0) }) {
                    return false
                }
            }
            
            // Subscribed platforms
            let platformKey = normalizedPlatformKey(item.platform)
            if !subscribedPlatforms.contains(platformKey) {
                return false
            }
            
            return true
        }
        .sorted(by: { $0.published_at > $1.published_at })
        .reduce(into: ([FeedItem](), Set<String>())) { acc, item in
            // When no keyword filter, deduplicate by URL — the same article can be
            // stored once per matching watch term; only the first (most recent) copy
            // is shown. When filtering by a specific keyword, all matches are shown.
            guard keyword == nil else { acc.0.append(item); return }
            if acc.1.insert(item.url).inserted { acc.0.append(item) }
        }.0
    }
    
    private func matchesKeyword(item: FeedItem, kw: String) -> Bool {
        let haystack = "\(item.title ?? "") \(item.content_text ?? "")".lowercased()
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
                    saved_at: ISO8601DateFormatter().string(from: Date())
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
            guard self.subscribedPlatforms != platforms else { return }
            self.advanceDataRevision()
            self.subscribedPlatforms = platforms
            self.saveToFile(name: "subscribed_platforms", value: self.subscribedPlatforms)
        }
    }
    
    // MARK: - Custom URLs
    func addCustomUrl(url: String, title: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        let id = "custom:\(normalized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.prefix(60) ?? "")"
        runOnMain {
            if self.customUrls.contains(where: { $0.id == id }) { return }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = CustomUrl(id: id, url: normalized, title: trimmedTitle.isEmpty ? nil : trimmedTitle, added_at: ISO8601DateFormatter().string(from: Date()))
            self.advanceDataRevision()
            self.customUrls.insert(entry, at: 0)
            self.saveToFile(name: "custom_urls", value: self.customUrls)
        }
    }
    
    func removeCustomUrl(id: String) {
        runOnMain {
            guard self.customUrls.contains(where: { $0.id == id }) else { return }
            self.advanceDataRevision()
            self.customUrls.removeAll(where: { $0.id == id })
            self.saveToFile(name: "custom_urls", value: self.customUrls)
        }
    }

    // MARK: - Data Reset
    @MainActor
    func clearAllData() {
        let fileNames = [
            "terms",
            "feed_items",
            "saved_pages",
            "custom_urls",
            "subscribed_platforms",
            "oshi_avatars",
            "oshi_compositions",
            "hidden_items"
        ]

        flushPendingWrites()
        dataRevision += 1
        UserDefaults.standard.set(dataRevision, forKey: "local_data_revision")
        invalidateContentCaches()
        NotificationManager.shared.clearLocalNotifications()
        terms = []
        feedItems = []
        savedPages = []
        customUrls = []
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
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: docsDir, includingPropertiesForKeys: nil
        ) {
            for cacheUrl in contents where cacheUrl.lastPathComponent.hasPrefix("oshi_wallpaper") {
                try? FileManager.default.removeItem(at: cacheUrl)
            }
        }
        UserDefaults.standard.removeObject(forKey: "wallpaper_url")
        UserDefaults.standard.removeObject(forKey: "sources_order")
        saveToFile(name: "subscribed_platforms", value: subscribedPlatforms)
    }
    
    // MARK: - Wallpaper & Custom Order (UserDefaults)
    func setWallpaper(url: String?) {
        runOnMain {
            self.wallpaper = url
            if let url = url {
                UserDefaults.standard.set(url, forKey: "wallpaper_url")
            } else {
                UserDefaults.standard.removeObject(forKey: "wallpaper_url")
            }
        }
    }
    
    func setSourcesOrder(order: [String]) {
        runOnMain {
            self.sourcesOrder = order
            UserDefaults.standard.set(order, forKey: "sources_order")
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
        let backup = LocalBackup(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            terms: terms,
            feedItems: feedItems,
            savedPages: savedPages,
            customUrls: customUrls,
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
    func importBackupData(_ data: Data) throws {
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
              backup.oshi_avatars.count <= 200,
              backup.compositions.count <= 200,
              backup.compositions.values.allSatisfy({ $0.count <= 100 }),
              backup.hidden_items.count <= 5_000 else {
            throw NSError(domain: "OshiReaderBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "Backup contains too much data"])
        }

        let normalizedTerms = backup.terms.map { term -> WatchTerm in
            var normalized = term
            normalized.aliases = Array(IngestionService.searchKeywords(for: term).dropFirst())
            return normalized
        }
        let normalizedSubscribedPlatforms = Self.normalizePlatformIDs(backup.subscribed_platforms)
        let normalizedSourcesOrder = backup.sources_order.map(Self.normalizePlatformIDs)

        let encodedFiles: [(String, Data)] = try [
            ("terms", encoder.encode(normalizedTerms)),
            ("feed_items", encoder.encode(Array(backup.feed_items.sorted { $0.published_at > $1.published_at }.prefix(600)))),
            ("saved_pages", encoder.encode(backup.saved_pages)),
            ("custom_urls", encoder.encode(backup.custom_urls)),
            ("subscribed_platforms", encoder.encode(normalizedSubscribedPlatforms)),
            ("oshi_avatars", encoder.encode(backup.oshi_avatars)),
            ("oshi_compositions", encoder.encode(backup.compositions)),
            ("hidden_items", encoder.encode(backup.hidden_items))
        ]
        try saveEncodedFilesSynchronously(
            encodedFiles,
            wallpaper: backup.wallpaper,
            sourcesOrder: normalizedSourcesOrder
        )

        dataRevision += 1
        UserDefaults.standard.set(dataRevision, forKey: "local_data_revision")
        invalidateContentCaches()
        NotificationManager.shared.clearLocalNotifications()

        terms = normalizedTerms
        feedItems = Array(backup.feed_items.sorted { $0.published_at > $1.published_at }.prefix(600))
        savedPages = backup.saved_pages
        customUrls = backup.custom_urls
        subscribedPlatforms = normalizedSubscribedPlatforms
        wallpaper = backup.wallpaper
        sourcesOrder = normalizedSourcesOrder
        oshiAvatars = backup.oshi_avatars
        compositions = backup.compositions
        hiddenItems = Set(backup.hidden_items)

    }

    static func subscribedPlatformsForLoadedValue(_ ids: [String], hasSavedFile: Bool) -> [String] {
        hasSavedFile ? normalizePlatformIDs(ids) : PlatformRegistry.defaultSubscribedIDs
    }

    static func normalizePlatformIDs(_ ids: [String]) -> [String] {
        let knownIDs = Set(PlatformRegistry.all.map(\.id))
        var seen = Set<String>()
        return ids.compactMap { rawID in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownIDs.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    private func invalidateContentCaches() {
        contentCacheGenerationLock.lock()
        contentCacheGenerationValue += 1
        let nextGeneration = contentCacheGenerationValue
        contentCacheGeneration = nextGeneration
        UserDefaults.standard.set(nextGeneration, forKey: "content_cache_generation")
        contentCacheGenerationLock.unlock()

        queue.sync {
            let docsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

        let now = ISO8601DateFormatter().string(from: Date())
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

        runOnMain {
            self.terms = [term]
            self.feedItems = [feedItem]
            self.savedPages = [savedPage]
            self.customUrls = [customUrl]
            self.subscribedPlatforms = ["news", "youtube", "tver", "custom"]
            self.wallpaper = nil
            self.sourcesOrder = nil
            self.oshiAvatars = [:]
            self.compositions = [term.keyword: [layer]]
            self.hiddenItems = []
            // Do NOT persist fixture data — only seed in-memory so nothing stains the
            // container after the test process exits.
            UserDefaults.standard.removeObject(forKey: "wallpaper_url")
            UserDefaults.standard.removeObject(forKey: "sources_order")
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
        if platform == "news:mdpr" { return "mdpr" }
        if platform == "news:yahoo_ent" { return "yahoonews" }
        if platform == "news" || platform.hasPrefix("news:") { return "news" }
        return platform
    }
}
