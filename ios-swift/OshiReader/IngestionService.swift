import Foundation

enum SourceRefreshFailure: String, Codable, Equatable, CaseIterable, Error {
    case timeout
    case networkUnavailable
    case authenticationRequired
    case rateLimited
    case httpFailure
    case invalidResponse
    case invalidPayload
    case missingCredential

    var displayName: String {
        switch self {
        case .timeout: return "Timed out"
        case .networkUnavailable: return "Network unavailable"
        case .authenticationRequired: return "Authentication required"
        case .rateLimited: return "Rate limited"
        case .httpFailure: return "HTTP failure"
        case .invalidResponse: return "Invalid response"
        case .invalidPayload: return "Invalid data"
        case .missingCredential: return "Credential missing"
        }
    }
}

enum SourceRefreshOutcome: Equatable {
    case received
    case stale
    case noResults
    case failed(SourceRefreshFailure)
}

struct SourceRefreshStatus: Identifiable, Equatable {
    let id: String
    var outcome: SourceRefreshOutcome
    var itemCount: Int
    var queryCount: Int
}

extension Sequence where Element == SourceRefreshStatus {
    var hasFailures: Bool {
        contains {
            switch $0.outcome {
            case .stale, .failed: return true
            case .received, .noResults: return false
            }
        }
    }
}

struct IngestionReport {
    let items: [FeedItem]
    let sourceStatuses: [SourceRefreshStatus]
}

private enum TransportResult {
    case success(Data, HTTPURLResponse)
    case failure(SourceRefreshFailure)
}

private actor SourceFailureRecorder {
    private var failures: [String: SourceRefreshFailure] = [:]

    func record(_ failure: SourceRefreshFailure, for sourceID: String) {
        if failures[sourceID] == nil {
            failures[sourceID] = failure
        }
    }

    func failure(for sourceID: String) -> SourceRefreshFailure? {
        failures[sourceID]
    }
}

/// On-device ingestion for public RSS feeds, JSON APIs, and pages.
///
/// Each `fetch*` method reads directly from the phone.
/// `ingest(term:platforms:)` fans them out for a single watch term and returns
/// flat `FeedItem`s ready for `LocalDB.mergeItems`.
final class IngestionService {
    static let freshnessWindow: TimeInterval = 10 * 24 * 60 * 60
    static let googleNewsLookbackDays = 10
    static let shared = IngestionService(classifyFreshness: true)
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias RetrySleeper = @Sendable (UInt64) async -> Void

    private let requestExecutor: RequestExecutor
    private let retrySleeper: RetrySleeper
    private let classifyFreshness: Bool
    private let now: @Sendable () -> Date
    private static let maximumTransportAttempts = 2
    private static let retryDelayNanoseconds: UInt64 = 100_000_000
    private static let outputISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let titleCleanupRegexLock = NSLock()
    private static var titleCleanupRegexes: [String: NSRegularExpression] = [:]
    private static let defaultTitleCleanupPatterns = [
        #"\s*\([^)]*ニュース\)\s*[-|]\s*Yahoo!ニュース\s*$"#,
        #"\s*[-|]\s*Yahoo!ニュース\s*$"#,
        #"\s*[-|]\s*(?:Bing|Google)\s*$"#
    ]
    private static let generalRegexLock = NSLock()
    private static var generalRegexes: [String: NSRegularExpression] = [:]
    private static let youtubeInitialDataObjectRegex = try? NSRegularExpression(
        pattern: #"ytInitialData\s*=\s*(\{.+?\});"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let youtubeInitialDataStringRegex = try? NSRegularExpression(
        pattern: #"ytInitialData\s*=\s*'((?:\\'|[^'])*)';"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let videoIdCharacterClass = "[A-Za-z0-9_-]{11}"
    private static let escapedYouTubeVideoIDRegexes: [NSRegularExpression] = [
        #""videoId":"(\#(videoIdCharacterClass))""#,
        #"/(?:watch\?v=|shorts/)(\#(videoIdCharacterClass))"#,
        #"\\\\x22videoId\\\\x22:\\\\x22(\#(videoIdCharacterClass))\\\\x22"#,
        #"/(?:watch\?v\\\\x3d|shorts/)(\#(videoIdCharacterClass))"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let youTubeUploadDateSearchParam = "CAI%3D"

    init(
        requestExecutor: @escaping RequestExecutor = { request in
            try await URLSession.shared.data(for: request)
        },
        retrySleeper: @escaping RetrySleeper = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        classifyFreshness: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.requestExecutor = requestExecutor
        self.retrySleeper = retrySleeper
        self.classifyFreshness = classifyFreshness
        self.now = now
    }

    @TaskLocal private static var sourceFailureRecorder: SourceFailureRecorder?
    @TaskLocal private static var sourceID: String?

    private let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private let rssUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Caps concurrent news.google.com requests across all in-flight terms.
    private static let googleNewsLimiter = RequestLimiter(limit: 3)
    /// Caps all source requests across foreground and background ingestion.
    private static let sourceRequestLimiter = RequestLimiter(limit: 4)
    static let maximumAliasesPerTerm = 5

    /// Removes common analytics parameters only for deduplication. The
    /// original URL remains untouched in FeedItem so reader navigation keeps
    /// the source-provided link.
    static func canonicalURLForDedup(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            return raw
        }

        let trackingKeys = Set([
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "fbclid", "gclid", "dclid", "mc_cid", "mc_eid", "igshid"
        ])
        components.queryItems = components.queryItems?.filter {
            !trackingKeys.contains($0.name.lowercased())
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1 {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .isEmpty ? "/" : components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        }
        return components.string ?? raw
    }

    // MARK: - Orchestration

    static func searchKeywords(for term: WatchTerm, maximumAliases: Int? = nil) -> [String] {
        var result = [String]()
        var seen = Set<String>()
        let aliasLimit = maximumAliases.map { max(0, min($0, Self.maximumAliasesPerTerm)) }
        for value in [term.keyword] + term.aliases {
            let keyword = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty, seen.insert(keyword).inserted else { continue }
            result.append(keyword)
            if result.count >= 1 + (aliasLimit ?? Self.maximumAliasesPerTerm) { break }
        }
        return result
    }

    static func effectivePlatforms(for term: WatchTerm, available: Set<String>) -> Set<String> {
        let normalizedAvailable = Set(PlatformRegistry.normalizeIDs(Array(available)))
        guard term.source_mode == .selected else { return normalizedAvailable }
        let selected = Set(PlatformRegistry.normalizeIDs(term.selected_platforms))
        return selected.isEmpty ? normalizedAvailable : normalizedAvailable.intersection(selected)
    }

    /// Fetch every subscribed source for one watch term. Network errors in any
    /// single source are swallowed (that source just contributes no items).
    func ingest(term: WatchTerm, platforms: Set<String>, maximumAliases: Int? = nil) async -> [FeedItem] {
        await ingestReport(term: term, platforms: platforms, maximumAliases: maximumAliases).items
    }

    func ingestReport(term: WatchTerm, platforms: Set<String>, maximumAliases: Int? = nil) async -> IngestionReport {
        let primaryKeyword = term.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchKeywords = Self.searchKeywords(for: term, maximumAliases: maximumAliases)
        guard !primaryKeyword.isEmpty, !searchKeywords.isEmpty else {
            return IngestionReport(items: [], sourceStatuses: [])
        }
        let mediaOnly = term.collection_mode == "media_only"
        let effectivePlatforms = Self.effectivePlatforms(for: term, available: platforms)
        guard !effectivePlatforms.isEmpty else {
            return IngestionReport(items: [], sourceStatuses: [])
        }

        let recorder = SourceFailureRecorder()
        return await withTaskGroup(of: (String, [FeedItem]).self) { group in
            func add(_ id: String, _ work: @escaping (String) async -> [FeedItem]) {
                guard effectivePlatforms.contains(id) else { return }
                for searchKeyword in searchKeywords {
                    group.addTask {
                        guard await Self.sourceRequestLimiter.acquire() else { return (id, []) }
                        guard !Task.isCancelled else {
                            await Self.sourceRequestLimiter.release()
                            return (id, [])
                        }
                        let items = await Self.$sourceFailureRecorder.withValue(recorder) {
                            await Self.$sourceID.withValue(id) {
                                await work(searchKeyword)
                            }
                        }
                        await Self.sourceRequestLimiter.release()
                        return (id, items.map { self.withWatchTermKeyword($0, keyword: primaryKeyword) })
                    }
                }
            }

            add("news")        { await self.fetchCuratedNews(keyword: $0, mediaOnly: mediaOnly) }
            add("5ch")         { await self.fetchGoogleNews(keyword: $0, query: "\($0) site:5ch.net", platform: "5ch", mediaType: "text", mediaOnly: mediaOnly) }
            add("girlschannel") { await self.fetchGoogleNews(keyword: $0, query: "\($0) site:girlschannel.net", platform: "girlschannel", mediaType: "text", mediaOnly: mediaOnly) }
            add("mdpr")        { await self.fetchModelPress(keyword: $0, mediaOnly: mediaOnly) }
            add("oricon")      { await self.fetchGoogleNews(keyword: $0, query: "\($0) site:oricon.co.jp", platform: "oricon", mediaType: "article", mediaOnly: mediaOnly, author: "ORICON NEWS", limit: 20, titlePatterns: [#"\s*[-|]\s*(ORICON NEWS|オリコンニュース|オリコン)\s*$"#]) }
            add("yahoonews")   { await self.fetchYahooNews(keyword: $0, mediaOnly: mediaOnly) }
            add("niconico")    { await self.fetchNiconico(keyword: $0) }
            add("note")        { await self.fetchNote(keyword: $0, mediaOnly: mediaOnly) }
            add("ameblo")     {
                let blogs = LocalDB.shared.amebloBlogs
                if blogs.isEmpty {
                    return await self.fetchGoogleNews(keyword: $0, query: "\($0) site:ameblo.jp", platform: "ameblo", mediaType: "article", mediaOnly: mediaOnly)
                }
                return await self.fetchAmeblo(keyword: $0, blogs: blogs, mediaOnly: mediaOnly)
            }
            add("natalie")     { await self.fetchDedicatedRSSSource(sourceID: "natalie", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["natalie"] ?? [], mediaOnly: mediaOnly, fallbackSite: "natalie.mu") }
            add("barks")       { await self.fetchDedicatedRSSSource(sourceID: "barks", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["barks"] ?? [], mediaOnly: mediaOnly, fallbackSite: "barks.jp") }
            add("aera")        { await self.fetchDedicatedRSSSource(sourceID: "aera", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["aera"] ?? [], mediaOnly: mediaOnly, fallbackSite: "dot.asahi.com") }
            add("hochi")       { await self.fetchDedicatedRSSSource(sourceID: "hochi", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["hochi"] ?? [], mediaOnly: mediaOnly, fallbackSite: "hochi.news") }
            add("realsound")   { await self.fetchDedicatedRSSSource(sourceID: "realsound", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["realsound"] ?? [], mediaOnly: mediaOnly, fallbackSite: "realsound.jp") }
            add("cinemacafe")  { await self.fetchDedicatedRSSSource(sourceID: "cinemacafe", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["cinemacafe"] ?? [], mediaOnly: mediaOnly, fallbackSite: "cinemacafe.net") }
            add("billboardjapan") { await self.fetchDedicatedRSSSource(sourceID: "billboardjapan", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["billboardjapan"] ?? [], mediaOnly: mediaOnly, fallbackSite: "billboard-japan.com") }
            add("kpopofficial") { await self.fetchDedicatedRSSSource(sourceID: "kpopofficial", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["kpopofficial"] ?? [], mediaOnly: mediaOnly, fallbackSite: "kpopofficial.com", locale: .englishUS) }
            add("tver")        { await self.fetchTVer(keyword: $0) }
            add("youtube")     { await self.fetchYouTube(keyword: $0) }
            add("twitter")     { await self.fetchTwitter(keyword: $0, mediaOnly: mediaOnly) }

            // Keep the source catalog additive: existing dedicated fetchers
            // above win, while the remaining reference sources use dated RSS
            // results from Google News until they warrant a dedicated parser.
            for source in PlatformRegistry.googleNewsSources where
                !["5ch", "girlschannel", "mdpr", "oricon", "yahoonews", "twitter", "ameblo", "natalie", "barks", "aera", "hochi", "realsound", "cinemacafe", "billboardjapan", "kpopofficial"].contains(source.id) {
                add(source.id) {
                    await self.fetchGoogleNews(
                        keyword: $0,
                        query: "\($0) site:\(source.googleNewsSite ?? "")",
                        platform: source.id,
                        mediaType: "article",
                        mediaOnly: mediaOnly,
                        locale: source.newsLocale
                    )
                }
            }

            var all = [FeedItem]()
            var counts: [String: (items: Int, queries: Int, newestPublishedAt: Date?)] = [:]
            var seenItemIDsBySource: [String: Set<String>] = [:]
            for await (sourceID, items) in group {
                var seenItemIDs = seenItemIDsBySource[sourceID] ?? []
                let uniqueItems = items.filter { seenItemIDs.insert($0.id).inserted }
                seenItemIDsBySource[sourceID] = seenItemIDs
                all.append(contentsOf: uniqueItems)
                let batchNewest = uniqueItems.compactMap { parseISO8601Date($0.published_at) }.max()
                let current = counts[sourceID] ?? (items: 0, queries: 0, newestPublishedAt: nil)
                let newestPublishedAt = [current.newestPublishedAt, batchNewest].compactMap { $0 }.max()
                counts[sourceID] = (
                    current.items + uniqueItems.count,
                    current.queries + 1,
                    newestPublishedAt
                )
            }
            var statuses = [SourceRefreshStatus]()
            for sourceID in counts.keys.sorted() {
                let count = counts[sourceID] ?? (items: 0, queries: 0, newestPublishedAt: nil)
                let failure = await recorder.failure(for: sourceID)
                let outcome: SourceRefreshOutcome
                if classifyFreshness,
                   count.items > 0,
                   (count.newestPublishedAt ?? .distantPast) < now().addingTimeInterval(-Self.freshnessWindow) {
                    outcome = failure.map(SourceRefreshOutcome.failed) ?? .stale
                } else if count.items > 0 {
                    outcome = .received
                } else if let failure {
                    outcome = .failed(failure)
                } else {
                    outcome = .noResults
                }
                statuses.append(SourceRefreshStatus(
                    id: sourceID,
                    outcome: outcome,
                    itemCount: count.items,
                    queryCount: count.queries
                ))
            }
            return IngestionReport(items: self.sortedByPublishedDate(all), sourceStatuses: statuses)
        }
    }

    private func withWatchTermKeyword(_ item: FeedItem, keyword: String) -> FeedItem {
        FeedItem(
            id: item.id,
            platform: item.platform,
            url: item.url,
            title: item.title,
            content_text: item.content_text,
            author: item.author,
            thumbnail_url: item.thumbnail_url,
            media_type: item.media_type,
            published_at: item.published_at,
            watch_term_keyword: keyword,
            fetched_at: item.fetched_at,
            source: item.source
        )
    }

    // MARK: - General news
    //
    // Discovery is a keyword-targeted Google News search (reliable, relevant),
    // augmented by a couple of general entertainment feeds filtered client-side.
    // "news" items are also keyword-filtered at display time in LocalDB.queryFeed.
    private static let curatedFeeds = [
        "https://www3.nhk.or.jp/rss/news/cat7.xml",
    ]

    private static let dedicatedRSSFeeds: [String: [String]] = [
        // Publisher-documented RSS feeds verified against the live official
        // domains. Sponichi remains on the Google News fallback until it
        // exposes a stable official RSS endpoint.
        "aera": [
            "https://dot.asahi.com/list/feed/rss4provider-all",
        ],
        "hochi": [
            "https://hochi.news/rss/index.xml",
        ],
        "realsound": [
            "https://realsound.jp/atom.xml",
        ],
        "cinemacafe": [
            "https://www.cinemacafe.net/rss20/index.rdf",
        ],
        "billboardjapan": [
            "https://www.billboard-japan.com/d_news/doc.xml",
        ],
        "natalie": [
            "https://natalie.mu/music/feed/news",
            "https://natalie.mu/tv/feed/news",
        ],
        // Use the current WordPress RSS feed; the old about/?m=rss endpoint
        // now redirects to an HTML page.
        "barks": [
            "https://barks.jp/feed/",
        ],
        "kpopofficial": [
            "https://kpopofficial.com/feed/",
        ],
    ]

    private func fetchCuratedNews(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        if mediaOnly { return [] }
        return await withTaskGroup(of: [FeedItem].self) { group in
            // Keyword-targeted Google News (general, no site filter).
            group.addTask {
                await self.fetchGoogleNews(keyword: keyword, query: keyword, platform: "news", mediaType: "article", mediaOnly: false)
            }
            // General entertainment feeds, filtered to the keyword client-side.
            for feedURL in Self.curatedFeeds {
                group.addTask {
                    guard let url = URL(string: feedURL) else { return [] }
                    guard case .success(let entries) = await self.parseRSS(url) else { return [] }
                    return entries.compactMap { entry -> FeedItem? in
                        guard !entry.link.isEmpty,
                              let publishedAt = self.validPublishedDate(entry.pubDate) else { return nil }
                        guard self.matchesKeyword(title: entry.title, desc: entry.description, kw: keyword) else { return nil }
                        return FeedItem(
                            id: "news:\(self.stableId(entry.link))",
                            platform: "news",
                            url: entry.link,
                            title: self.cleanedOptionalTitle(entry.title),
                            content_text: entry.description.isEmpty ? nil : entry.description,
                            author: nil,
                            thumbnail_url: entry.thumbnailUrl,
                            media_type: "article",
                            published_at: publishedAt,
                            watch_term_keyword: keyword,
                            fetched_at: self.nowISO(),
                            source: "curated_rss"
                        )
                    }
                }
            }
            var all = [FeedItem]()
            for await items in group { all.append(contentsOf: items) }
            return all
        }
    }

    private func fetchDedicatedRSSSource(
        sourceID: String,
        keyword: String,
        feedURLs: [String],
        mediaOnly: Bool,
        fallbackSite: String? = nil,
        locale: PlatformDefinition.NewsLocale = .japan
    ) async -> [FeedItem] {
        guard !mediaOnly, !feedURLs.isEmpty else { return [] }

        let dedicatedResult = await withTaskGroup(of: ([FeedItem], Bool, Bool, Bool).self) { group in
            for feedURL in feedURLs {
                group.addTask {
                    guard let url = URL(string: feedURL) else {
                        return ([], false, true, true)
                    }
                    let entries: [RssItem]
                    switch await self.parseRSS(url) {
                    case .success(let parsed):
                        entries = parsed
                    case .failure(let failure):
                        return ([], false, true, failure != .authenticationRequired)
                    }

                    var seen = Set<String>()
                    let items = entries.compactMap { entry -> FeedItem? in
                        guard !entry.link.isEmpty,
                              let publishedAt = self.validPublishedDate(entry.pubDate),
                              self.matchesKeyword(title: entry.title, desc: entry.description, kw: keyword) else {
                            return nil
                        }
                        let canonical = Self.canonicalURLForDedup(entry.link)
                        guard seen.insert(canonical).inserted else { return nil }
                        return FeedItem(
                            id: "\(sourceID):\(self.stableId(fromCanonical: canonical))",
                            platform: sourceID,
                            url: entry.link,
                            title: self.cleanedOptionalTitle(entry.title),
                            content_text: entry.description.isEmpty ? nil : entry.description,
                            author: nil,
                            thumbnail_url: entry.thumbnailUrl,
                            media_type: "article",
                            published_at: publishedAt,
                            watch_term_keyword: keyword,
                            fetched_at: self.nowISO(),
                            source: "dedicated_rss"
                        )
                    }
                    return (items, true, false, false)
                }
            }

            var all = [FeedItem]()
            var parsedAnyFeed = false
            var failedAnyFeed = false
            var hasFallbackEligibleFailure = false
            for await (items, didParse, didFail, fallbackEligible) in group {
                all.append(contentsOf: items)
                parsedAnyFeed = parsedAnyFeed || didParse
                failedAnyFeed = failedAnyFeed || didFail
                hasFallbackEligibleFailure = hasFallbackEligibleFailure || fallbackEligible
            }

            var seen = Set<String>()
            return (
                sortedByPublishedDate(all.filter { seen.insert($0.id).inserted }).prefix(25).map { $0 },
                parsedAnyFeed,
                failedAnyFeed,
                hasFallbackEligibleFailure
            )
        }

        let dedicatedItems = dedicatedResult.0
        if !dedicatedItems.isEmpty { return dedicatedItems }
        if dedicatedResult.1 && !dedicatedResult.2 { return [] }
        if dedicatedResult.2 && !dedicatedResult.3 { return [] }
        guard let fallbackSite, !fallbackSite.isEmpty else { return [] }
        return await fetchGoogleNews(
            keyword: keyword,
            query: "\(keyword) site:\(fallbackSite)",
            platform: sourceID,
            mediaType: "article",
            mediaOnly: mediaOnly,
            locale: locale
        )
    }

    private func fetchAmeblo(keyword: String, blogs: [AmebloBlog], mediaOnly: Bool) async -> [FeedItem] {
        guard !mediaOnly, !blogs.isEmpty else { return [] }

        let results = await withTaskGroup(of: (Int, [FeedItem], SourceRefreshFailure?).self, returning: [(Int, [FeedItem], SourceRefreshFailure?)].self) { group in
            for (index, blog) in blogs.enumerated() {
                group.addTask {
                    guard let feedURL = blog.rssURL else { return (index, [], .invalidResponse) }
                    let entries: [RssItem]
                    switch await self.parseRSS(feedURL) {
                    case .success(let parsed):
                        entries = parsed
                    case .failure(let failure):
                        return (index, [], failure)
                    }
                    var seen = Set<String>()
                    let items = entries.compactMap { entry -> FeedItem? in
                        guard !entry.link.isEmpty,
                              let publishedAt = self.validPublishedDate(entry.pubDate),
                              self.matchesKeyword(title: entry.title, desc: entry.description, kw: keyword) else { return nil }
                        let canonical = Self.canonicalURLForDedup(entry.link)
                        guard seen.insert(canonical).inserted else { return nil }
                        return FeedItem(
                            id: "ameblo:\(self.stableId(fromCanonical: canonical))",
                            platform: "ameblo",
                            url: entry.link,
                            title: self.cleanedOptionalTitle(entry.title),
                            content_text: entry.description.isEmpty ? nil : entry.description,
                            author: blog.title ?? blog.amebaID,
                            thumbnail_url: entry.thumbnailUrl,
                            media_type: "article",
                            published_at: publishedAt,
                            watch_term_keyword: keyword,
                            fetched_at: self.nowISO(),
                            source: "ameblo_rss"
                        )
                    }
                    return (index, items, nil)
                }
            }

            var results = [(Int, [FeedItem], SourceRefreshFailure?)]()
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        if let firstFailure = results.compactMap({ $0.2 }).first {
            await recordFailure(firstFailure)
        }
        var seen = Set<String>()
        return results
            .flatMap(\.1)
            .filter { seen.insert($0.id).inserted }
            .sorted { self.feedItemSortPrecedes($0, $1) }
            .prefix(25)
            .map { $0 }
    }

    // MARK: - Google News site-filtered RSS (5ch, girlschannel, mdpr, oricon, yahoonews, niconico fallback)

    private func fetchModelPress(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        if mediaOnly { return [] }
        var items = [FeedItem]()
        var seen = Set<String>()
        for page in 1...2 {
            guard let result = await fetchModelPressSearchPage(keyword: keyword, page: page) else {
                break
            }
            for item in result.items where items.count < 25 && seen.insert(item.id).inserted {
                items.append(item)
            }
            if items.count >= 25 || !result.hasNextPage { break }
        }
        if !items.isEmpty { return sortedByPublishedDate(items) }
        return await fetchGoogleNews(
            keyword: keyword,
            query: "\(keyword) site:mdpr.jp",
            platform: "mdpr",
            mediaType: "article",
            mediaOnly: false,
            titlePatterns: [#"\s*[-|]\s*モデルプレス\s*$"#]
        )
    }

    private func fetchModelPressSearchPage(
        keyword: String,
        page: Int
    ) async -> (items: [FeedItem], hasNextPage: Bool)? {
        var components = URLComponents(string: "https://mdpr.jp/search")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "type", value: "article"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components.url,
              case .success(let data, _) = await httpGET(
                url,
                headers: ["User-Agent": browserUA, "Accept-Language": "ja,en;q=0.9"]
              ),
              let html = String(data: data, encoding: .utf8),
              let itemRegex = Self.generalRegex(for: #"<li class="p-articleListItem">([\s\S]*?)</li>"#) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var items = [FeedItem]()
        for match in itemRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let blockRange = Range(match.range(at: 1), in: html) else { continue }
            let block = String(html[blockRange])
            guard let path = regexGroups(block, #"<a href="([^"]+)" class="p-articleListItem__link">"#)?.first,
                  let rawTitle = regexGroups(block, #"<p class="p-articleListItem__title"><span>([\s\S]*?)</span>"#)?.first,
                  let rawDate = regexGroups(block, #"<time datetime="([^"]+)""#)?.first,
                  let publishedDate = formatter.date(from: rawDate),
                  let articleURL = URL(string: path, relativeTo: URL(string: "https://mdpr.jp"))?.absoluteURL else {
                continue
            }
            guard let title = cleanDisplayText(rawTitle),
                  matchesKeyword(title: title, desc: "", kw: keyword) else { continue }
            let thumbnail = regexGroups(block, #"<img[^>]+src="([^"]+)""#)?.first
                .flatMap { cleanDisplayText($0) }
            let absoluteURL = articleURL.absoluteString
            items.append(FeedItem(
                id: "mdpr:\(stableId(absoluteURL))",
                platform: "mdpr",
                url: absoluteURL,
                title: title,
                content_text: nil,
                author: "ModelPress",
                thumbnail_url: thumbnail,
                media_type: "article",
                published_at: isoString(publishedDate),
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "modelpress_search"
            ))
        }
        let nextPageToken = "page=\(page + 1)"
        return (items, html.contains(nextPageToken))
    }

    private func fetchGoogleNews(
        keyword: String,
        query: String,
        platform: String,
        mediaType: String,
        mediaOnly: Bool,
        author: String? = nil,
        limit: Int = 25,
        titlePatterns: [String] = [],
        locale: PlatformDefinition.NewsLocale = .japan
    ) async -> [FeedItem] {
        if mediaOnly { return [] }
        var recentItems = [FeedItem]()
        if classifyFreshness,
           let recentURL = googleNewsURL(query, locale: locale, recentDays: Self.googleNewsLookbackDays),
           let recentEntries = await fetchGoogleNewsEntries(recentURL, locale: locale) {
            recentItems = makeGoogleNewsItems(
                entries: recentEntries,
                keyword: keyword,
                platform: platform,
                mediaType: mediaType,
                author: author,
                limit: limit,
                titlePatterns: titlePatterns
            )
        }
        // The recent-window query already satisfies most refreshes; only pay
        // for the full historical query when it came back close to empty.
        if recentItems.count >= min(limit, 3) { return recentItems }

        guard let url = googleNewsURL(query, locale: locale),
              let entries = await fetchGoogleNewsEntries(url, locale: locale) else { return recentItems }
        let historicalItems = makeGoogleNewsItems(
            entries: entries,
            keyword: keyword,
            platform: platform,
            mediaType: mediaType,
            author: author,
            limit: limit,
            titlePatterns: titlePatterns
        )
        var seen = Set<String>()
        return (recentItems + historicalItems)
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }

    private func fetchGoogleNewsEntries(
        _ url: URL,
        locale: PlatformDefinition.NewsLocale
    ) async -> [RssItem]? {
        // Many sources funnel through news.google.com; throttle so we don't get
        // rate-limited (which previously made sources like 5ch return nothing).
        guard await Self.googleNewsLimiter.acquire() else { return nil }
        guard !Task.isCancelled else {
            await Self.googleNewsLimiter.release()
            return nil
        }
        let entries: [RssItem]?
        switch await parseRSS(url, headers: ["Accept-Language": locale.acceptLanguage]) {
        case .success(let value):
            entries = value
        case .failure:
            entries = nil
        }
        await Self.googleNewsLimiter.release()
        return entries
    }

    private func makeGoogleNewsItems(
        entries: [RssItem],
        keyword: String,
        platform: String,
        mediaType: String,
        author: String?,
        limit: Int,
        titlePatterns: [String]
    ) -> [FeedItem] {
        var seen = Set<String>()
        var items = [FeedItem]()
        for entry in entries {
            if items.count >= limit { break }
            guard !entry.link.isEmpty,
                  let publishedAt = validPublishedDate(entry.pubDate) else { continue }
            let key = entry.link
            if !seen.insert(key).inserted { continue }
            let title = cleanTitle(entry.title, patterns: titlePatterns)
            if title.isEmpty { continue }
            guard matchesKeyword(title: title, desc: "", kw: keyword) else { continue }
            items.append(FeedItem(
                id: "\(platform):\(stableId(entry.link))",
                platform: platform,
                url: entry.link,
                title: title,
                content_text: entry.description.isEmpty ? nil : entry.description,
                author: author,
                thumbnail_url: nil,
                media_type: mediaType,
                published_at: publishedAt,
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "google_news"
            ))
        }
        return items
    }

    // MARK: - Yahoo News (Google News RSS — carries real publish dates)

    private func fetchYahooNews(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        if mediaOnly { return [] }
        // The old r.jina.ai markdown fallback couldn't supply real dates, so it's
        // dropped in favour of the dated RSS path.
        return await fetchGoogleNews(keyword: keyword, query: "\(keyword) site:news.yahoo.co.jp", platform: "yahoonews", mediaType: "article", mediaOnly: false)
    }

    // MARK: - NicoNico (snapshot search JSON API, Google News fallback)

    private func fetchNiconico(keyword: String) async -> [FeedItem] {
        var comps = URLComponents(string: "https://snapshot.search.nicovideo.jp/api/v2/snapshot/video/contents/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "targets", value: "title,description,tags"),
            URLQueryItem(name: "fields", value: "contentId,title,description,userId,channelId,startTime,thumbnailUrl"),
            URLQueryItem(name: "_sort", value: "-startTime"),
            URLQueryItem(name: "_limit", value: "25"),
        ]
        if let url = comps.url {
            if case .success(let data, _) = await httpGET(url, headers: ["Accept": "application/json"], timeout: 10) {
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    await recordFailure(.invalidPayload)
                    return await fetchGoogleNews(keyword: keyword, query: "\(keyword) site:nicovideo.jp", platform: "niconico", mediaType: "video", mediaOnly: false)
                }
                if let rows = json["data"] as? [[String: Any]], !rows.isEmpty {
                    var items = [FeedItem]()
                    for raw in rows {
                        guard let contentId = raw["contentId"] as? String,
                              let published = (raw["startTime"] as? String).flatMap(parseISO8601Date).map(isoString) else {
                            continue
                        }
                        // userId/channelId may be a number, a string, or JSON null — stringify
                        // only real values so we never emit "<null>".
                        let author = [raw["userId"], raw["channelId"]]
                            .compactMap { v -> String? in
                                guard let v, !(v is NSNull) else { return nil }
                                let s = "\(v)"
                                return s.isEmpty ? nil : s
                            }
                            .first
                        items.append(FeedItem(
                            id: "niconico:\(contentId)",
                            platform: "niconico",
                            url: "https://www.nicovideo.jp/watch/\(contentId)",
                            title: raw["title"] as? String,
                            content_text: raw["description"] as? String,
                            author: author,
                            thumbnail_url: raw["thumbnailUrl"] as? String,
                            media_type: "video",
                            published_at: published,
                            watch_term_keyword: keyword,
                            fetched_at: nowISO(),
                            source: "niconico_snapshot"
                        ))
                    }
                    if !items.isEmpty { return items }
                }
            }
        }
        // Fallback: Google News filtered to nicovideo.jp
        return await fetchGoogleNews(keyword: keyword, query: "\(keyword) site:nicovideo.jp", platform: "niconico", mediaType: "video", mediaOnly: false)
    }

    // MARK: - note.com (hashtag RSS)

    private func fetchNote(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        if mediaOnly { return [] }
        // note.com's old /api/v2/searches endpoint now 404s, so we use the
        // hashtag RSS feed (notes tagged with the keyword) directly.
        var tags = [keyword]
        let compacted = keyword.components(separatedBy: .whitespacesAndNewlines).joined()
        if compacted != keyword, !compacted.isEmpty {
            tags.append(compacted)
        }
        var entries = [RssItem]()
        for tag in tags {
            guard let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://note.com/hashtag/\(encoded)/rss") else { continue }
            guard case .success(let parsed) = await parseRSS(url) else { continue }
            entries = parsed
            if !entries.isEmpty { break }
        }
        return entries.prefix(25).compactMap { entry -> FeedItem? in
            guard !entry.link.isEmpty,
                  let publishedAt = validPublishedDate(entry.pubDate) else { return nil }
            let itemId = entry.link.split(separator: "/").last.map(String.init) ?? entry.link
            return FeedItem(
                id: "note:\(itemId)",
                platform: "note",
                url: entry.link,
                title: cleanedOptionalTitle(entry.title),
                content_text: entry.description.isEmpty ? nil : entry.description,
                author: nil,
                thumbnail_url: entry.thumbnailUrl,
                media_type: "article",
                published_at: publishedAt,
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "note_rss"
            )
        }
    }

    // MARK: - TVer (public platform API: create token, then keyword search)

    private func fetchTVer(keyword: String) async -> [FeedItem] {
        let baseHeaders = [
            "User-Agent": browserUA,
            "Origin": "https://tver.jp",
            "Referer": "https://tver.jp/",
        ]
        // 1. Create an anonymous platform token.
        guard let createURL = URL(string: "https://platform-api.tver.jp/v2/api/platform_users/browser/create") else { return [] }
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.timeoutInterval = 15
        for (k, v) in baseHeaders { createReq.setValue(v, forHTTPHeaderField: k) }
        createReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = "device_type=pc".data(using: .utf8)

        guard case .success(let cData, let cResp) = await request(createReq),
              cResp.statusCode == 200,
              let cJson = (try? JSONSerialization.jsonObject(with: cData)) as? [String: Any],
              let result = cJson["result"] as? [String: Any],
              let uid = result["platform_uid"] as? String,
              let token = result["platform_token"] as? String else {
            await recordFailure(.invalidPayload)
            return []
        }

        // 2. Keyword search.
        var comps = URLComponents(string: "https://platform-api.tver.jp/service/api/v1/callKeywordSearch")!
        comps.queryItems = [
            URLQueryItem(name: "platform_uid", value: uid),
            URLQueryItem(name: "platform_token", value: token),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "detail", value: "true"),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "require_talent_data", value: "true"),
            URLQueryItem(name: "page", value: "1"),
        ]
        guard let searchURL = comps.url else { return [] }
        let searchHeaders = baseHeaders.merging([
            "x-tver-platform-type": "web",
            "x-clientplatform": "web",
        ]) { _, new in new }
        guard case .success(let data, _) = await httpGET(searchURL, headers: searchHeaders, timeout: 15),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            await recordFailure(.invalidPayload)
            return []
        }

        let res = json["result"] as? [String: Any] ?? [:]
        var episodes: [[String: Any]] = []
        if let eps = (res["episodes"] as? [String: Any])?["contents"] as? [[String: Any]] {
            episodes = eps
        } else if let sae = res["seriesAndEpisode"] as? [String: Any],
                  let eps = (sae["episodes"] as? [String: Any])?["contents"] as? [[String: Any]] {
            episodes = eps
        } else if let c = res["contents"] as? [[String: Any]] {
            episodes = c
        } else if let r = res["rows"] as? [[String: Any]] {
            episodes = r
        } else {
            episodes = (json["contents"] as? [[String: Any]]) ?? (json["rows"] as? [[String: Any]]) ?? []
        }

        var items = [FeedItem]()
        for ep in episodes.prefix(25) {
            let content = (ep["content"] as? [String: Any]) ?? (ep["episode"] as? [String: Any]) ?? ep
            let epId = (content["id"] as? String) ?? (content["seriesId"] as? String) ?? (ep["id"] as? String)
            guard let epId, !epId.isEmpty else { continue }
            let title = (content["title"] as? String) ?? (content["episodeTitle"] as? String) ?? (content["seriesTitle"] as? String)
            guard let title, !title.isEmpty,
                  let publishedAt = tverDate(content) else { continue }

            let type = ((ep["type"] as? String) ?? (content["type"] as? String) ?? "").lowercased()
            let url: String
            switch type {
            case "series": url = "https://tver.jp/series/\(epId)"
            case "special": url = "https://tver.jp/specials/\(epId)"
            default: url = "https://tver.jp/episodes/\(epId)"
            }

            var thumb = (content["thumbnailUrl"] as? String) ?? (content["thumbnailURL"] as? String) ?? (content["thumbnail_path"] as? String)
            if let t = thumb, t.hasPrefix("/") { thumb = "https://statics.tver.jp\(t)" }

            items.append(FeedItem(
                id: "tver:\(epId)",
                platform: "tver",
                url: url,
                title: title,
                content_text: (content["description"] as? String) ?? (content["episodeDescription"] as? String),
                author: (content["broadcasterName"] as? String) ?? (content["productionProviderName"] as? String),
                thumbnail_url: thumb,
                media_type: "video",
                published_at: publishedAt,
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "tver_api"
            ))
        }
        return items
    }

    private func tverDate(_ content: [String: Any]) -> String? {
        for key in ["publishedAt", "publish_start", "deliveryStartAt", "broadcastDate", "airDate"] {
            if let n = content[key] as? Double, n > 0 {
                return isoString(Date(timeIntervalSince1970: n))
            }
            if let s = content[key] as? String, let d = parseISO8601Date(s) {
                return isoString(d)
            }
        }
        // TVer almost always exposes only a Japanese broadcast label rather than a
        // timestamp: "2025年放送", "6月5日(金)放送分", "5月29日(金) 18:29".
        if let label = content["broadcastDateLabel"] as? String, !label.isEmpty,
           let d = parseBroadcastLabel(label) {
            return isoString(d)
        }
        return nil
    }

    private func parseBroadcastLabel(_ label: String) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let currentDate = now()

        // Year only: "2021年放送" → mid-year placeholder.
        if let g = regexGroups(label, #"^(\d{4})年"#), let year = Int(g[0]) {
            return cal.date(from: DateComponents(year: year, month: 6, day: 1))
        }
        // Month/day with optional time: "6月5日(金)放送分", "5月29日(金) 18:29".
        if let g = regexGroups(label, #"(\d+)月(\d+)日"#), let month = Int(g[0]), let day = Int(g[1]) {
            var hour = 0, minute = 0
            if let t = regexGroups(label, #"(\d+):(\d+)"#), let h = Int(t[0]), let m = Int(t[1]) {
                hour = h; minute = m
            }
            let year = cal.component(.year, from: currentDate)
            var comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            guard var dt = cal.date(from: comps) else { return nil }
            // No year in the label — if the date lands more than a week in the
            // future, it must be from last year.
            if dt > currentDate.addingTimeInterval(7 * 86400) {
                comps.year = year - 1
                dt = cal.date(from: comps) ?? dt
            }
            return dt
        }
        return nil
    }

    /// Return the capture groups (1...) of the first match, or nil if no match.
    private func regexGroups(_ s: String, _ pattern: String) -> [String]? {
        guard let re = Self.generalRegex(for: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1 else { return nil }
        var out = [String]()
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            out.append(String(s[r]))
        }
        return out
    }

    private static func generalRegex(for pattern: String) -> NSRegularExpression? {
        generalRegexLock.lock()
        if let cached = generalRegexes[pattern] {
            generalRegexLock.unlock()
            return cached
        }
        generalRegexLock.unlock()

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        generalRegexLock.lock()
        generalRegexes[pattern] = regex
        generalRegexLock.unlock()
        return regex
    }

    // MARK: - YouTube (keyless search)

    private func fetchYouTube(keyword: String) async -> [FeedItem] {
        let apiItems = await fetchYouTubeInnertube(keyword: keyword)
        if !apiItems.isEmpty { return apiItems }
        return await fetchYouTubeScrape(keyword: keyword)
    }

    private func fetchYouTubeInnertube(keyword: String) async -> [FeedItem] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else { return [] }
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20260617.03.00",
                    "hl": "ja",
                    "gl": "JP"
                ]
            ],
            "query": keyword,
            "params": Self.youTubeUploadDateSearchParam
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              case .success(let data, _) = await httpPOST(url, body: body, headers: [
                "Content-Type": "application/json",
                "User-Agent": browserUA,
                "Accept-Language": "ja,ja-JP;q=0.9,en;q=0.8"
              ], timeout: 15),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let cutoff = now().addingTimeInterval(-90 * 86400)
        // Both renderer kinds live in the same response tree; collecting them
        // in one walk avoids traversing the (potentially large) JSON twice.
        var grouped = [String: [[String: Any]]]()
        collectDictionaries(named: ["videoRenderer", "videoWithContextRenderer"], in: json, into: &grouped)
        var items = makeVideoRendererFeedItems(grouped["videoRenderer"] ?? [], keyword: keyword, cutoff: cutoff)
        if items.count < 25 {
            items.append(contentsOf: makeMobileFeedItems(grouped["videoWithContextRenderer"] ?? [], keyword: keyword, cutoff: cutoff))
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }.prefix(25).map { $0 }
    }

    private func fetchYouTubeScrape(keyword: String) async -> [FeedItem] {
        guard var components = URLComponents(string: "https://www.youtube.com/results") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "search_query", value: keyword),
            URLQueryItem(name: "sp", value: Self.youTubeUploadDateSearchParam)
        ]
        guard let url = components.url else { return [] }
        guard case .success(let data, _) = await httpGET(url, headers: ["User-Agent": browserUA, "Accept-Language": "ja,ja-JP;q=0.9,en;q=0.8"], timeout: 15) else {
            return []
        }
        guard let html = String(data: data, encoding: .utf8) else {
            return []
        }
        let cutoff = now().addingTimeInterval(-90 * 86400)
        guard let json = extractYouTubeInitialData(from: html) else {
            return collectYouTubeItemsFromEscapedHTML(html, keyword: keyword, cutoff: cutoff)
        }
        let sections = (((((json["contents"] as? [String: Any])?["twoColumnSearchResultsRenderer"] as? [String: Any])?["primaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]) ?? []
        var items = [FeedItem]()
        for section in sections {
            let contents = (section["itemSectionRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
            for entry in contents {
                guard let vr = entry["videoRenderer"] as? [String: Any],
                      let vid = vr["videoId"] as? String else { continue }
                let title = ((vr["title"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String
                let channel = ((vr["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String
                let desc = ((((vr["detailedMetadataSnippets"] as? [[String: Any]])?.first?["snippetText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"]) as? String
                let thumb = ((vr["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?.first?["url"] as? String
                let relText = firstText(in: vr["publishedTimeText"]) ?? ""
                guard let published = youtubeRelativeDate(relText) else { continue }
                if published < cutoff { continue }
                items.append(FeedItem(
                    id: "youtube:\(vid)",
                    platform: "youtube",
                    url: "https://www.youtube.com/watch?v=\(vid)",
                    title: title,
                    content_text: desc,
                    author: channel,
                    thumbnail_url: thumb,
                    media_type: "video",
                    published_at: isoString(published),
                    watch_term_keyword: keyword,
                    fetched_at: nowISO(),
                    source: "youtube_scrape"
                ))
            }
        }
        if items.isEmpty {
            items = collectMobileYouTubeItems(from: json, keyword: keyword, cutoff: cutoff)
        }
        if items.isEmpty {
            items = collectYouTubeItemsFromEscapedHTML(html, keyword: keyword, cutoff: cutoff)
        }
        return items
    }

    private func extractYouTubeInitialData(from html: String) -> [String: Any]? {
        if let match = Self.youtubeInitialDataObjectRegex?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html),
           let data = String(html[range]).data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return json
        }

        guard let match = Self.youtubeInitialDataStringRegex?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let decoded = decodeJavaScriptEscapedString(String(html[range]))
        guard let data = decoded.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func decodeJavaScriptEscapedString(_ escaped: String) -> String {
        let scalars = Array(escaped.unicodeScalars)
        var output = String.UnicodeScalarView()
        var i = 0

        func hexValue(_ scalar: UnicodeScalar) -> Int? {
            Int(String(scalar), radix: 16)
        }

        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "\\" else {
                output.append(scalar)
                i += 1
                continue
            }
            let nextIndex = i + 1
            guard nextIndex < scalars.count else {
                output.append(scalar)
                i += 1
                continue
            }
            let next = scalars[nextIndex]
            if next == "x", i + 3 < scalars.count,
               let hi = hexValue(scalars[i + 2]),
               let lo = hexValue(scalars[i + 3]),
               let decoded = UnicodeScalar((hi << 4) + lo) {
                output.append(decoded)
                i += 4
            } else if next == "u", i + 5 < scalars.count {
                let hex = String(String.UnicodeScalarView(scalars[(i + 2)...(i + 5)]))
                if let value = Int(hex, radix: 16), let decoded = UnicodeScalar(value) {
                    output.append(decoded)
                    i += 6
                } else {
                    output.append(next)
                    i += 2
                }
            } else {
                switch next {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                default: output.append(next)
                }
                i += 2
            }
        }
        return String(output)
    }

    private func collectMobileYouTubeItems(from json: [String: Any], keyword: String, cutoff: Date) -> [FeedItem] {
        var grouped = [String: [[String: Any]]]()
        collectDictionaries(named: ["videoWithContextRenderer"], in: json, into: &grouped)
        return makeMobileFeedItems(grouped["videoWithContextRenderer"] ?? [], keyword: keyword, cutoff: cutoff)
    }

    private func makeMobileFeedItems(_ renderers: [[String: Any]], keyword: String, cutoff: Date) -> [FeedItem] {
        var items = [FeedItem]()
        var seenIds = Set<String>()
        for renderer in renderers {
            guard let videoId = renderer["videoId"] as? String, seenIds.insert(videoId).inserted else { continue }
            let relText = firstText(in: renderer["publishedTimeText"]) ?? ""
            guard let published = youtubeRelativeDate(relText) else { continue }
            if published < cutoff { continue }
            let path = nestedString(renderer, ["navigationEndpoint", "commandMetadata", "webCommandMetadata", "url"])
            let itemURL = path.flatMap { URL(string: $0, relativeTo: URL(string: "https://www.youtube.com"))?.absoluteString } ?? "https://www.youtube.com/watch?v=\(videoId)"
            items.append(FeedItem(
                id: "youtube:\(videoId)",
                platform: "youtube",
                url: itemURL,
                title: firstText(in: renderer["headline"]),
                content_text: nil,
                author: firstText(in: renderer["shortBylineText"]),
                thumbnail_url: firstThumbnailURL(in: renderer["thumbnail"]),
                media_type: "video",
                published_at: isoString(published),
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "youtube_scrape"
            ))
        }
        return Array(items.prefix(25))
    }

    private func makeVideoRendererFeedItems(_ renderers: [[String: Any]], keyword: String, cutoff: Date) -> [FeedItem] {
        let items = renderers.compactMap { renderer -> FeedItem? in
            guard let videoId = renderer["videoId"] as? String else { return nil }
            let relText = firstText(in: renderer["publishedTimeText"]) ?? ""
            guard let published = youtubeRelativeDate(relText) else { return nil }
            if published < cutoff { return nil }
            let description = (((renderer["detailedMetadataSnippets"] as? [[String: Any]])?.first?["snippetText"] as? [String: Any]))

            return FeedItem(
                id: "youtube:\(videoId)",
                platform: "youtube",
                url: "https://www.youtube.com/watch?v=\(videoId)",
                title: firstText(in: renderer["title"]),
                content_text: firstText(in: description),
                author: firstText(in: renderer["ownerText"]) ?? firstText(in: renderer["shortBylineText"]),
                thumbnail_url: firstThumbnailURL(in: renderer["thumbnail"]),
                media_type: "video",
                published_at: isoString(published),
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "youtube_scrape"
            )
        }
        return Array(items.prefix(25))
    }

    /// Collects every dictionary keyed by any of `names`, grouped by which
    /// key matched, in a single recursive walk of `value`.
    private func collectDictionaries(named names: [String], in value: Any, into results: inout [String: [[String: Any]]]) {
        if let dict = value as? [String: Any] {
            for name in names {
                if let match = dict[name] as? [String: Any] {
                    results[name, default: []].append(match)
                }
            }
            for child in dict.values {
                collectDictionaries(named: names, in: child, into: &results)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectDictionaries(named: names, in: child, into: &results)
            }
        }
    }

    private func nestedValue(_ dict: [String: Any], _ path: [String]) -> Any? {
        var current: Any? = dict
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current
    }

    private func nestedString(_ dict: [String: Any], _ path: [String]) -> String? {
        nestedValue(dict, path) as? String
    }

    private func firstText(in value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let content = dict["content"] as? String { return content }
        if let first = (dict["runs"] as? [[String: Any]])?.first?["text"] as? String { return first }
        return nil
    }

    private func firstThumbnailURL(in value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        return (dict["thumbnails"] as? [[String: Any]])?.first?["url"] as? String
    }

    private func collectYouTubeItemsFromEscapedHTML(_ html: String, keyword: String, cutoff: Date) -> [FeedItem] {
        var items = [FeedItem]()
        var seen = Set<String>()
        for regex in Self.escapedYouTubeVideoIDRegexes {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let videoId = String(html[range])
                guard !seen.contains(videoId) else { continue }
                let relText = escapedYouTubeRelativeTime(for: videoId, near: match.range(at: 1), in: html)
                guard let published = relText.flatMap(youtubeRelativeDate),
                      published >= cutoff else { continue }
                seen.insert(videoId)
                items.append(FeedItem(
                    id: "youtube:\(videoId)",
                    platform: "youtube",
                    url: "https://www.youtube.com/watch?v=\(videoId)",
                    title: nil,
                    content_text: nil,
                    author: nil,
                    thumbnail_url: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                    media_type: "video",
                    published_at: isoString(published),
                    watch_term_keyword: keyword,
                    fetched_at: nowISO(),
                    source: "youtube_scrape"
                ))
                if items.count >= 25 { break }
            }
            if items.count >= 25 { break }
        }
        return items
    }

    /// Searches around a video ID for its `publishedTimeText`, bounded by the nearest
    /// *different* video's `"videoId"` field on either side. Without this boundary, a video
    /// with no date of its own nearby (e.g. YouTube Shorts, which never carry publishedTimeText)
    /// would silently borrow an unrelated neighboring video's date instead of being dropped as
    /// undated.
    private func escapedYouTubeRelativeTime(for videoId: String, near nsRange: NSRange, in html: String) -> String? {
        let lower = max(0, nsRange.location - 2_000)
        let upper = min((html as NSString).length, nsRange.location + nsRange.length + 4_000)
        guard lower < upper,
              let segmentRange = Range(NSRange(location: lower, length: upper - lower), in: html) else {
            return nil
        }
        let decoded = decodeJavaScriptEscapedString(String(html[segmentRange]))
        let scoped = Self.textAroundOwnVideoId(decoded, videoId: videoId)
        return firstRegexCapture(#""publishedTimeText"\s*:\s*\{\s*"simpleText"\s*:\s*"([^"]+)""#, in: scoped)
            ?? firstRegexCapture(#""publishedTimeText"\s*:\s*\{\s*"runs"\s*:\s*\[\s*\{\s*"text"\s*:\s*"([^"]+)""#, in: scoped)
    }

    /// Matches a `videoId` field whose surrounding quotes are either literal (`"videoId":"ID"`)
    /// or the single-decoded remnant of a double-escaped source (`\x22videoId\x22:\x22ID\x22`) —
    /// decodeJavaScriptEscapedString only unwraps one layer, so a video originally found via the
    /// double-escaped regex patterns never becomes plain quotes and would otherwise be invisible
    /// to boundary scoping.
    private static let anyEscapedVideoIdFieldRegex = try? NSRegularExpression(
        pattern: #"(?:"|\\x22)videoId(?:"|\\x22)\s*:\s*(?:"|\\x22)(\#(videoIdCharacterClass))(?:"|\\x22)"#
    )

    private static func textAroundOwnVideoId(_ decoded: String, videoId: String) -> String {
        guard let regex = anyEscapedVideoIdFieldRegex else { return decoded }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        guard let ownMatch = matches.first(where: { match in
            guard let idRange = Range(match.range(at: 1), in: decoded) else { return false }
            return decoded[idRange] == videoId
        }), let ownRange = Range(ownMatch.range, in: decoded) else {
            return decoded
        }

        var lowerBound = decoded.startIndex
        var upperBound = decoded.endIndex
        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: decoded),
                  decoded[idRange] != videoId,
                  let matchRange = Range(match.range, in: decoded) else { continue }
            if matchRange.upperBound <= ownRange.lowerBound {
                lowerBound = matchRange.upperBound
            } else if matchRange.lowerBound >= ownRange.upperBound && matchRange.lowerBound < upperBound {
                upperBound = matchRange.lowerBound
            }
        }
        guard lowerBound < upperBound else { return "" }
        return String(decoded[lowerBound..<upperBound])
    }

    private func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = Self.generalRegex(for: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Convert YouTube relative timestamps ("2 days ago", "3ヶ月前") to a Date.
    private func youtubeRelativeDate(_ text: String) -> Date? {
        guard !text.isEmpty,
              let m = text.lowercased().range(of: #"(\d+)\s*(second|minute|hour|day|week|month|year|秒|分|時間|日|週間|週|ヶ月|か月|年)"#, options: .regularExpression) else {
            return nil
        }
        let token = String(text.lowercased()[m])
        guard let numMatch = token.range(of: #"\d+"#, options: .regularExpression),
              let n = Int(token[numMatch]) else { return nil }
        let currentDate = now()
        let day = 86400.0
        if token.contains("second") || token.contains("秒") { return currentDate.addingTimeInterval(-Double(n)) }
        if token.contains("minute") || token.contains("分") { return currentDate.addingTimeInterval(-Double(n) * 60) }
        if token.contains("hour") || token.contains("時間") { return currentDate.addingTimeInterval(-Double(n) * 3600) }
        if token.contains("week") || token.contains("週") { return currentDate.addingTimeInterval(-Double(n) * 7 * day) }
        if token.contains("month") || token.contains("ヶ月") || token.contains("か月") { return currentDate.addingTimeInterval(-Double(n) * 30 * day) }
        if token.contains("year") || token.contains("年") { return currentDate.addingTimeInterval(-Double(n) * 365 * day) }
        if token.contains("day") || token.contains("日") { return currentDate.addingTimeInterval(-Double(n) * day) }
        return nil
    }

    // MARK: - Twitter / X (API v2 recent search, requires stored bearer token)

    private func fetchTwitter(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        guard let bearer = KeychainHelper.read(.twitterBearerToken) else {
            await recordFailure(.missingCredential)
            return []
        }
        let query = mediaOnly ? "\(keyword) has:media" : keyword
        var comps = URLComponents(string: "https://api.twitter.com/2/tweets/search/recent")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "max_results", value: "25"),
            URLQueryItem(name: "tweet.fields", value: "created_at,author_id,text"),
            URLQueryItem(name: "expansions", value: "author_id,attachments.media_keys"),
            URLQueryItem(name: "user.fields", value: "name,username"),
            URLQueryItem(name: "media.fields", value: "preview_image_url,url"),
        ]
        guard let url = comps.url,
              case .success(let data, let resp) = await httpGET(url, headers: ["Authorization": "Bearer \(bearer)"], timeout: 10),
              resp.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            await recordFailure(.invalidPayload)
            return []
        }
        let includes = json["includes"] as? [String: Any] ?? [:]
        var users = [String: [String: Any]]()
        for u in includes["users"] as? [[String: Any]] ?? [] {
            if let id = u["id"] as? String { users[id] = u }
        }
        var media = [String: [String: Any]]()
        for m in includes["media"] as? [[String: Any]] ?? [] {
            if let k = m["media_key"] as? String { media[k] = m }
        }
        var items = [FeedItem]()
        for tweet in json["data"] as? [[String: Any]] ?? [] {
            guard let tweetId = tweet["id"] as? String,
                  let created = (tweet["created_at"] as? String).flatMap(parseISO8601Date).map(isoString) else {
                continue
            }
            let user = users[(tweet["author_id"] as? String) ?? ""] ?? [:]
            let username = user["username"] as? String ?? ""
            var thumb: String?
            for key in (tweet["attachments"] as? [String: Any])?["media_keys"] as? [String] ?? [] {
                let m = media[key] ?? [:]
                thumb = (m["preview_image_url"] as? String) ?? (m["url"] as? String)
                if thumb != nil { break }
            }
            let url = username.isEmpty ? "https://x.com/i/status/\(tweetId)" : "https://x.com/\(username)/status/\(tweetId)"
            items.append(FeedItem(
                id: "twitter:\(tweetId)",
                platform: "twitter",
                url: url,
                title: nil,
                content_text: tweet["text"] as? String,
                author: username.isEmpty ? nil : "@\(username)",
                thumbnail_url: thumb,
                media_type: thumb != nil ? "video" : "text",
                published_at: created,
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "twitter_api"
            ))
        }
        return items
    }

    // MARK: - Shared helpers

    private func httpGET(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 12) async -> TransportResult {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return await execute(request)
    }

    private func httpPOST(_ url: URL, body: Data, headers: [String: String] = [:], timeout: TimeInterval = 12) async -> TransportResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return await execute(request)
    }

    private func request(_ request: URLRequest) async -> TransportResult {
        return await execute(request)
    }

    private func execute(_ request: URLRequest) async -> TransportResult {
        for attempt in 0..<Self.maximumTransportAttempts {
            let result: TransportResult
            // Only set for .httpFailure, where retryability depends on the
            // specific status code rather than the (Codable, persisted)
            // failure case, which collapses every non-401/403/429 status.
            var httpFailureIsRetryable: Bool?
            do {
                let (data, response) = try await requestExecutor(request)
                guard let http = response as? HTTPURLResponse else {
                    result = .failure(.invalidResponse)
                    return await finish(result)
                }
                if (200...299).contains(http.statusCode) {
                    return .success(data, http)
                }
                result = .failure(Self.failure(forHTTPStatus: http.statusCode))
                if case .failure(.httpFailure) = result {
                    httpFailureIsRetryable = (500...599).contains(http.statusCode)
                }
            } catch let error as URLError {
                result = .failure(Self.failure(for: error))
            } catch {
                result = .failure(.networkUnavailable)
            }

            guard case .failure(let failure) = result,
                  httpFailureIsRetryable ?? Self.isRetryable(failure),
                  attempt + 1 < Self.maximumTransportAttempts,
                  !Task.isCancelled else {
                return await finish(result)
            }
            await retrySleeper(Self.retryDelayNanoseconds * UInt64(attempt + 1))
            if Task.isCancelled {
                return .failure(.networkUnavailable)
            }
        }
        return await finish(.failure(.networkUnavailable))
    }

    private func finish(_ result: TransportResult) async -> TransportResult {
        if case .failure(let failure) = result {
            await recordFailure(failure)
        }
        return result
    }

    private func parseRSS(_ url: URL, headers: [String: String] = [:]) async -> Result<[RssItem], SourceRefreshFailure> {
        // Send a browser User-Agent — news.google.com and note.com throttle/deny
        // the default URLSession agent, which made some sources return nothing.
        var allHeaders = ["User-Agent": rssUA, "Accept-Language": "ja,en;q=0.9"]
        allHeaders.merge(headers) { _, override in override }
        guard case .success(let data, _) = await httpGET(url, headers: allHeaders, timeout: 12) else {
            return .failure(await currentFailure() ?? .invalidResponse)
        }
        let parser = XMLParser(data: data)
        let delegate = RSSParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            await recordFailure(.invalidPayload)
            return .failure(SourceRefreshFailure.invalidPayload)
        }
        return .success(delegate.items)
    }

    private func recordFailure(_ failure: SourceRefreshFailure) async {
        guard let recorder = Self.sourceFailureRecorder, let sourceID = Self.sourceID else { return }
        await recorder.record(failure, for: sourceID)
    }

    private func currentFailure() async -> SourceRefreshFailure? {
        guard let recorder = Self.sourceFailureRecorder, let sourceID = Self.sourceID else { return nil }
        return await recorder.failure(for: sourceID)
    }

    private static func failure(forHTTPStatus status: Int) -> SourceRefreshFailure {
        switch status {
        case 401, 403: return .authenticationRequired
        case 429: return .rateLimited
        default: return .httpFailure
        }
    }

    private static func failure(for error: URLError) -> SourceRefreshFailure {
        switch error.code {
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed:
            return .networkUnavailable
        default: return .networkUnavailable
        }
    }

    private static func isRetryable(_ failure: SourceRefreshFailure) -> Bool {
        switch failure {
        case .timeout, .networkUnavailable, .rateLimited:
            return true
        case .httpFailure:
            return true
        case .authenticationRequired, .invalidResponse, .invalidPayload, .missingCredential:
            return false
        }
    }

    private func googleNewsURL(
        _ query: String,
        locale: PlatformDefinition.NewsLocale = .japan,
        recentDays: Int? = nil
    ) -> URL? {
        let effectiveQuery = recentDays.map { "\(query) when:\($0)d" } ?? query
        var components = URLComponents()
        components.scheme = "https"
        components.host = "news.google.com"
        components.path = "/rss/search"
        switch locale {
        case .japan:
            components.queryItems = [
                URLQueryItem(name: "q", value: effectiveQuery),
                URLQueryItem(name: "hl", value: "ja"),
                URLQueryItem(name: "gl", value: "JP"),
                URLQueryItem(name: "ceid", value: "JP:ja"),
            ]
        case .englishUS:
            components.queryItems = [
                URLQueryItem(name: "q", value: effectiveQuery),
                URLQueryItem(name: "hl", value: "en"),
                URLQueryItem(name: "gl", value: "US"),
                URLQueryItem(name: "ceid", value: "US:en"),
            ]
        }
        return components.url
    }

    private func cleanTitle(_ value: String, patterns: [String]) -> String {
        var title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in Self.defaultTitleCleanupPatterns + patterns {
            guard let regex = Self.titleCleanupRegex(for: pattern) else { continue }
            title = regex.stringByReplacingMatches(
                in: title,
                range: NSRange(title.startIndex..., in: title),
                withTemplate: ""
            )
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanedOptionalTitle(_ value: String, patterns: [String] = []) -> String? {
        let title = cleanTitle(value, patterns: patterns)
        return title.isEmpty ? nil : title
    }

    private static func titleCleanupRegex(for pattern: String) -> NSRegularExpression? {
        titleCleanupRegexLock.lock()
        if let regex = titleCleanupRegexes[pattern] {
            titleCleanupRegexLock.unlock()
            return regex
        }
        titleCleanupRegexLock.unlock()

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        titleCleanupRegexLock.lock()
        titleCleanupRegexes[pattern] = regex
        titleCleanupRegexLock.unlock()
        return regex
    }

    private func matchesKeyword(title: String, desc: String, kw: String) -> Bool {
        let haystack = title.lowercased()
        let needle = kw.lowercased()
        if needle.isEmpty { return true }
        if haystack.contains(needle) { return true }
        let parts = kw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if parts.count > 1 {
            return parts.allSatisfy { haystack.contains($0.lowercased()) }
        }
        return false
    }

    private func validPublishedDate(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              parseISO8601Date(value) != nil else { return nil }
        return value
    }

    private func sortedByPublishedDate(_ items: [FeedItem]) -> [FeedItem] {
        items.sorted(by: feedItemSortPrecedes)
    }

    private func feedItemSortPrecedes(_ lhs: FeedItem, _ rhs: FeedItem) -> Bool {
        let lhsDate = parseISO8601Date(lhs.published_at) ?? .distantPast
        let rhsDate = parseISO8601Date(rhs.published_at) ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.url < rhs.url
    }

    /// Stable FNV-1a hash so the same article URL yields the same FeedItem id
    /// across refreshes (lets LocalDB dedup it).
    private func stableId(_ input: String) -> String {
        stableId(fromCanonical: Self.canonicalURLForDedup(input))
    }

    /// Same hash as `stableId(_:)`, but for callers that already computed the
    /// canonical URL (e.g. for dedup) and can skip re-parsing it.
    private func stableId(fromCanonical canonical: String) -> String {
        var v: UInt64 = 14695981039346656037
        for b in canonical.utf8 {
            v ^= UInt64(b)
            v = v &* 1099511628211
        }
        return String(v)
    }

    private func isoString(_ date: Date) -> String {
        Self.outputISO8601.string(from: date)
    }

    private func nowISO() -> String { isoString(now()) }
}

/// A simple async concurrency gate: at most `limit` holders at once, the rest
/// suspend until a slot frees up.
actor RequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if active < limit {
            active += 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            // Hand the slot directly to the next waiter; `active` stays put.
            next.continuation.resume(returning: true)
            return
        }
        precondition(active > 0)
        active -= 1
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let continuation = waiters.remove(at: index).continuation
        continuation.resume(returning: false)
    }
}
