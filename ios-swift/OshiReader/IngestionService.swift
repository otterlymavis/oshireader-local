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
    case noResults
    case failed(SourceRefreshFailure)
}

struct SourceRefreshStatus: Identifiable, Equatable {
    let id: String
    var outcome: SourceRefreshOutcome
    var itemCount: Int
    var queryCount: Int
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
        failures[sourceID] = failure
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
    static let shared = IngestionService()
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias RetrySleeper = @Sendable (UInt64) async -> Void

    private let requestExecutor: RequestExecutor
    private let retrySleeper: RetrySleeper
    private static let maximumTransportAttempts = 2
    private static let retryDelayNanoseconds: UInt64 = 100_000_000

    init(
        requestExecutor: @escaping RequestExecutor = { request in
            try await URLSession.shared.data(for: request)
        },
        retrySleeper: @escaping RetrySleeper = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.requestExecutor = requestExecutor
        self.retrySleeper = retrySleeper
    }

    @TaskLocal private static var sourceFailureRecorder: SourceFailureRecorder?
    @TaskLocal private static var sourceID: String?

    private let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

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

    static func searchKeywords(for term: WatchTerm) -> [String] {
        var result = [String]()
        var seen = Set<String>()
        for value in [term.keyword] + term.aliases {
            let keyword = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty, seen.insert(keyword).inserted else { continue }
            result.append(keyword)
            if result.count >= 1 + Self.maximumAliasesPerTerm { break }
        }
        return result
    }

    static func effectivePlatforms(for term: WatchTerm, available: Set<String>) -> Set<String> {
        guard term.source_mode == .selected else { return available }
        let selected = Set(PlatformRegistry.normalizeIDs(term.selected_platforms))
        return selected.isEmpty ? available : available.intersection(selected)
    }

    /// Fetch every subscribed source for one watch term. Network errors in any
    /// single source are swallowed (that source just contributes no items).
    func ingest(term: WatchTerm, platforms: Set<String>) async -> [FeedItem] {
        await ingestReport(term: term, platforms: platforms).items
    }

    func ingestReport(term: WatchTerm, platforms: Set<String>) async -> IngestionReport {
        let primaryKeyword = term.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchKeywords = Self.searchKeywords(for: term)
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
            add("mdpr")        { await self.fetchGoogleNews(keyword: $0, query: "\($0) site:mdpr.jp", platform: "mdpr", mediaType: "article", mediaOnly: mediaOnly, titlePatterns: [#"\s*[-|]\s*モデルプレス\s*$"#]) }
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
            add("natalie")     { await self.fetchDedicatedRSSSource(sourceID: "natalie", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["natalie"] ?? [], mediaOnly: mediaOnly) }
            add("barks")       { await self.fetchDedicatedRSSSource(sourceID: "barks", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["barks"] ?? [], mediaOnly: mediaOnly) }
            add("aera")        { await self.fetchDedicatedRSSSource(sourceID: "aera", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["aera"] ?? [], mediaOnly: mediaOnly) }
            add("hochi")       { await self.fetchDedicatedRSSSource(sourceID: "hochi", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["hochi"] ?? [], mediaOnly: mediaOnly) }
            add("realsound")   { await self.fetchDedicatedRSSSource(sourceID: "realsound", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["realsound"] ?? [], mediaOnly: mediaOnly) }
            add("cinemacafe")  { await self.fetchDedicatedRSSSource(sourceID: "cinemacafe", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["cinemacafe"] ?? [], mediaOnly: mediaOnly) }
            add("billboardjapan") { await self.fetchDedicatedRSSSource(sourceID: "billboardjapan", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["billboardjapan"] ?? [], mediaOnly: mediaOnly) }
            // Togetter via Google News so items carry real publish dates (the
            // search-page scrape doesn't expose reliable dates).
            add("togetter")    { await self.fetchGoogleNews(keyword: $0, query: "\($0) site:togetter.com", platform: "togetter", mediaType: "article", mediaOnly: mediaOnly) }
            add("tver")        { await self.fetchTVer(keyword: $0) }
            add("youtube")     { await self.fetchYouTube(keyword: $0) }
            add("twitter")     { await self.fetchTwitter(keyword: $0, mediaOnly: mediaOnly) }

            // Keep the source catalog additive: existing dedicated fetchers
            // above win, while the remaining reference sources use dated RSS
            // results from Google News until they warrant a dedicated parser.
            for source in PlatformRegistry.googleNewsSources where
                !["5ch", "girlschannel", "mdpr", "oricon", "yahoonews", "togetter", "twitter", "ameblo", "natalie", "barks", "aera", "hochi", "realsound", "cinemacafe", "billboardjapan"].contains(source.id) {
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
            var counts: [String: (items: Int, queries: Int)] = [:]
            var seenItemIDsBySource: [String: Set<String>] = [:]
            for await (sourceID, items) in group {
                var seenItemIDs = seenItemIDsBySource[sourceID] ?? []
                let uniqueItems = items.filter { seenItemIDs.insert($0.id).inserted }
                seenItemIDsBySource[sourceID] = seenItemIDs
                all.append(contentsOf: uniqueItems)
                let current = counts[sourceID] ?? (items: 0, queries: 0)
                counts[sourceID] = (current.items + uniqueItems.count, current.queries + 1)
            }
            var statuses = [SourceRefreshStatus]()
            for sourceID in counts.keys.sorted() {
                let count = counts[sourceID] ?? (items: 0, queries: 0)
                let outcome: SourceRefreshOutcome
                if count.items > 0 {
                    outcome = .received
                } else if let failure = await recorder.failure(for: sourceID) {
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
            return IngestionReport(items: all, sourceStatuses: statuses)
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
            fetched_at: item.fetched_at
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
        // Use HTTPS for iOS App Transport Security while retaining the
        // documented BARKS RSS endpoint path.
        "barks": [
            "https://www.barks.jp/about/?m=rss",
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
                            title: entry.title.isEmpty ? nil : entry.title,
                            content_text: entry.description.isEmpty ? nil : entry.description,
                            author: nil,
                            thumbnail_url: entry.thumbnailUrl,
                            media_type: "article",
                            published_at: publishedAt,
                            watch_term_keyword: keyword,
                            fetched_at: self.nowISO()
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
        mediaOnly: Bool
    ) async -> [FeedItem] {
        guard !mediaOnly, !feedURLs.isEmpty else { return [] }

        return await withTaskGroup(of: [FeedItem].self) { group in
            for feedURL in feedURLs {
                group.addTask {
                    guard let url = URL(string: feedURL),
                          case .success(let entries) = await self.parseRSS(url) else {
                        return []
                    }

                    var seen = Set<String>()
                    return entries.compactMap { entry -> FeedItem? in
                        guard !entry.link.isEmpty,
                              let publishedAt = self.validPublishedDate(entry.pubDate),
                              self.matchesKeyword(title: entry.title, desc: entry.description, kw: keyword) else {
                            return nil
                        }
                        let canonical = Self.canonicalURLForDedup(entry.link)
                        guard seen.insert(canonical).inserted else { return nil }
                        return FeedItem(
                            id: "\(sourceID):\(self.stableId(entry.link))",
                            platform: sourceID,
                            url: entry.link,
                            title: entry.title.isEmpty ? nil : entry.title,
                            content_text: entry.description.isEmpty ? nil : entry.description,
                            author: nil,
                            thumbnail_url: entry.thumbnailUrl,
                            media_type: "article",
                            published_at: publishedAt,
                            watch_term_keyword: keyword,
                            fetched_at: self.nowISO()
                        )
                    }
                }
            }

            var all = [FeedItem]()
            for await items in group {
                all.append(contentsOf: items)
            }

            var seen = Set<String>()
            return all.filter { seen.insert($0.id).inserted }.prefix(25).map { $0 }
        }
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
                            id: "ameblo:\(self.stableId(entry.link))",
                            platform: "ameblo",
                            url: entry.link,
                            title: entry.title.isEmpty ? nil : entry.title,
                            content_text: entry.description.isEmpty ? nil : entry.description,
                            author: blog.title ?? blog.amebaID,
                            thumbnail_url: entry.thumbnailUrl,
                            media_type: "article",
                            published_at: publishedAt,
                            watch_term_keyword: keyword,
                            fetched_at: self.nowISO()
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
            .prefix(25)
            .map { $0 }
    }

    // MARK: - Google News site-filtered RSS (5ch, girlschannel, mdpr, oricon, yahoonews, niconico fallback)

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
        guard let url = googleNewsURL(query, locale: locale) else { return [] }
        // Many sources funnel through news.google.com; throttle so we don't get
        // rate-limited (which previously made sources like 5ch return nothing).
        guard await Self.googleNewsLimiter.acquire() else { return [] }
        guard !Task.isCancelled else {
            await Self.googleNewsLimiter.release()
            return []
        }
        let entries: [RssItem]
        switch await parseRSS(url, headers: ["Accept-Language": locale.acceptLanguage]) {
        case .success(let value):
            entries = value
        case .failure:
            await Self.googleNewsLimiter.release()
            return []
        }
        await Self.googleNewsLimiter.release()

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
                fetched_at: nowISO()
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
                        guard let contentId = raw["contentId"] as? String else { continue }
                        let published = (raw["startTime"] as? String).flatMap(parseISO8601Date).map(isoString) ?? nowISO()
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
                            fetched_at: nowISO()
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
                title: entry.title.isEmpty ? nil : entry.title,
                content_text: entry.description.isEmpty ? nil : entry.description,
                author: nil,
                thumbnail_url: entry.thumbnailUrl,
                media_type: "article",
                published_at: publishedAt,
                watch_term_keyword: keyword,
                fetched_at: nowISO()
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
            guard let title, !title.isEmpty else { continue }

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
                published_at: tverDate(content) ?? nowISO(),
                watch_term_keyword: keyword,
                fetched_at: nowISO()
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
        let now = Date()

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
            let year = cal.component(.year, from: now)
            var comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            guard var dt = cal.date(from: comps) else { return nil }
            // No year in the label — if the date lands more than a week in the
            // future, it must be from last year.
            if dt > now.addingTimeInterval(7 * 86400) {
                comps.year = year - 1
                dt = cal.date(from: comps) ?? dt
            }
            return dt
        }
        return nil
    }

    /// Return the capture groups (1...) of the first match, or nil if no match.
    private func regexGroups(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1 else { return nil }
        var out = [String]()
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            out.append(String(s[r]))
        }
        return out
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
            "query": keyword
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
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        var items = collectYouTubeVideoRendererItems(from: json, keyword: keyword, cutoff: cutoff)
        if items.count < 25 {
            items.append(contentsOf: collectMobileYouTubeItems(from: json, keyword: keyword, cutoff: cutoff))
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }.prefix(25).map { $0 }
    }

    private func fetchYouTubeScrape(keyword: String) async -> [FeedItem] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") else {
            return []
        }
        guard case .success(let data, _) = await httpGET(url, headers: ["User-Agent": browserUA, "Accept-Language": "ja,ja-JP;q=0.9,en;q=0.8"], timeout: 15) else {
            return []
        }
        guard let html = String(data: data, encoding: .utf8) else {
            return []
        }
        guard let json = extractYouTubeInitialData(from: html) else {
            return collectYouTubeItemsFromEscapedHTML(html, keyword: keyword)
        }
        let sections = (((((json["contents"] as? [String: Any])?["twoColumnSearchResultsRenderer"] as? [String: Any])?["primaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]) ?? []
        let cutoff = Date().addingTimeInterval(-90 * 86400)
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
                let relText = (vr["publishedTimeText"] as? [String: Any])?["simpleText"] as? String ?? ""
                let published = youtubeRelativeDate(relText) ?? Date()
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
                    fetched_at: nowISO()
                ))
            }
        }
        if items.isEmpty {
            items = collectMobileYouTubeItems(from: json, keyword: keyword, cutoff: cutoff)
        }
        if items.isEmpty {
            items = collectYouTubeItemsFromEscapedHTML(html, keyword: keyword)
        }
        return items
    }

    private func extractYouTubeInitialData(from html: String) -> [String: Any]? {
        if let regex = try? NSRegularExpression(pattern: #"ytInitialData\s*=\s*(\{.+?\});"#, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html),
           let data = String(html[range]).data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return json
        }

        guard let regex = try? NSRegularExpression(pattern: #"ytInitialData\s*=\s*'((?:\\'|[^'])*)';"#, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
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
        var items = [FeedItem]()
        var seenIds = Set<String>()
        var videoRenderers = [[String: Any]]()
        var shortsRenderers = [[String: Any]]()
        collectDictionaries(named: "videoWithContextRenderer", in: json, into: &videoRenderers)
        collectDictionaries(named: "shortsLockupViewModel", in: json, into: &shortsRenderers)

        for renderer in videoRenderers {
            guard let videoId = renderer["videoId"] as? String, seenIds.insert(videoId).inserted else { continue }
            let relText = firstText(in: renderer["publishedTimeText"]) ?? ""
            let published = youtubeRelativeDate(relText) ?? Date()
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
                fetched_at: nowISO()
            ))
        }

        for renderer in shortsRenderers {
            let videoId = nestedString(renderer, ["onTap", "innertubeCommand", "reelWatchEndpoint", "videoId"])
                ?? (renderer["entityId"] as? String)?.split(separator: "-").last.map(String.init)
            guard let videoId, seenIds.insert(videoId).inserted else { continue }
            let secondary = nestedString(renderer, ["belowThumbnailMetadata", "secondaryText", "content"]) ?? ""
            let published = youtubeRelativeDate(secondary) ?? Date()
            if published < cutoff { continue }
            items.append(FeedItem(
                id: "youtube:\(videoId)",
                platform: "youtube",
                url: "https://www.youtube.com/shorts/\(videoId)",
                title: nestedString(renderer, ["overlayMetadata", "primaryText", "content"]) ?? (renderer["accessibilityText"] as? String),
                content_text: nil,
                author: nestedString(renderer, ["belowThumbnailMetadata", "primaryText", "content"]),
                thumbnail_url: firstThumbnailURL(in: nestedValue(renderer, ["onTap", "innertubeCommand", "reelWatchEndpoint", "thumbnail"])),
                media_type: "video",
                published_at: isoString(published),
                watch_term_keyword: keyword,
                fetched_at: nowISO()
            ))
        }
        return Array(items.prefix(25))
    }

    private func collectYouTubeVideoRendererItems(from json: [String: Any], keyword: String, cutoff: Date) -> [FeedItem] {
        var renderers = [[String: Any]]()
        collectDictionaries(named: "videoRenderer", in: json, into: &renderers)

        return renderers.prefix(25).compactMap { renderer -> FeedItem? in
            guard let videoId = renderer["videoId"] as? String else { return nil }
            let relText = firstText(in: renderer["publishedTimeText"]) ?? ""
            let published = youtubeRelativeDate(relText) ?? Date()
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
                fetched_at: nowISO()
            )
        }
    }

    private func collectDictionaries(named name: String, in value: Any, into results: inout [[String: Any]]) {
        if let dict = value as? [String: Any] {
            if let match = dict[name] as? [String: Any] {
                results.append(match)
            }
            for child in dict.values {
                collectDictionaries(named: name, in: child, into: &results)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectDictionaries(named: name, in: child, into: &results)
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

    private func collectYouTubeItemsFromEscapedHTML(_ html: String, keyword: String) -> [FeedItem] {
        let patterns = [
            #""videoId":"([A-Za-z0-9_-]{11})""#,
            #"/(?:watch\?v=|shorts/)([A-Za-z0-9_-]{11})"#,
            #"\\\\x22videoId\\\\x22:\\\\x22([A-Za-z0-9_-]{11})\\\\x22"#,
            #"/(?:watch\?v\\\\x3d|shorts/)([A-Za-z0-9_-]{11})"#
        ]
        var ids = [String]()
        var seen = Set<String>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let id = String(html[range])
                if seen.insert(id).inserted {
                    ids.append(id)
                }
                if ids.count >= 25 { break }
            }
            if ids.count >= 25 { break }
        }

        return ids.map { videoId in
            FeedItem(
                id: "youtube:\(videoId)",
                platform: "youtube",
                url: "https://www.youtube.com/watch?v=\(videoId)",
                title: nil,
                content_text: nil,
                author: nil,
                thumbnail_url: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                media_type: "video",
                published_at: nowISO(),
                watch_term_keyword: keyword,
                fetched_at: nowISO()
            )
        }
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
        let now = Date()
        let day = 86400.0
        if token.contains("second") || token.contains("秒") { return now.addingTimeInterval(-Double(n)) }
        if token.contains("minute") || token.contains("分") { return now.addingTimeInterval(-Double(n) * 60) }
        if token.contains("hour") || token.contains("時間") { return now.addingTimeInterval(-Double(n) * 3600) }
        if token.contains("week") || token.contains("週") { return now.addingTimeInterval(-Double(n) * 7 * day) }
        if token.contains("month") || token.contains("ヶ月") || token.contains("か月") { return now.addingTimeInterval(-Double(n) * 30 * day) }
        if token.contains("year") || token.contains("年") { return now.addingTimeInterval(-Double(n) * 365 * day) }
        if token.contains("day") || token.contains("日") { return now.addingTimeInterval(-Double(n) * day) }
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
            guard let tweetId = tweet["id"] as? String else { continue }
            let user = users[(tweet["author_id"] as? String) ?? ""] ?? [:]
            let username = user["username"] as? String ?? ""
            let created = (tweet["created_at"] as? String).flatMap(parseISO8601Date).map(isoString) ?? nowISO()
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
                fetched_at: nowISO()
            ))
        }
        return items
    }

    // MARK: - Shared helpers

    private func httpGET(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 12) async -> TransportResult {
        var request = URLRequest(url: url)
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
            } catch let error as URLError {
                result = .failure(Self.failure(for: error))
            } catch {
                result = .failure(.networkUnavailable)
            }

            guard case .failure(let failure) = result,
                  Self.isRetryable(failure),
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
        var allHeaders = ["User-Agent": browserUA, "Accept-Language": "ja,en;q=0.9"]
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

    private func googleNewsURL(_ query: String, locale: PlatformDefinition.NewsLocale = .japan) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch locale {
        case .japan:
            return URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=ja&gl=JP&ceid=JP%3Aja")
        case .englishUS:
            return URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=en&gl=US&ceid=US%3Aen")
        }
    }

    private func cleanTitle(_ value: String, patterns: [String]) -> String {
        var title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            title = title.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesKeyword(title: String, desc: String, kw: String) -> Bool {
        let haystack = "\(title) \(desc)".lowercased()
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

    /// Stable FNV-1a hash so the same article URL yields the same FeedItem id
    /// across refreshes (lets LocalDB dedup it).
    private func stableId(_ input: String) -> String {
        let canonical = Self.canonicalURLForDedup(input)
        var v: UInt64 = 14695981039346656037
        for b in canonical.utf8 {
            v ^= UInt64(b)
            v = v &* 1099511628211
        }
        return String(v)
    }

    private func isoString(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    private func nowISO() -> String { isoString(Date()) }
}

/// A simple async concurrency gate: at most `limit` holders at once, the rest
/// suspend until a slot frees up.
actor RequestLimiter {
    private let limit: Int
    private var active = 0

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func acquire() async -> Bool {
        while !Task.isCancelled {
            if active < limit {
                active += 1
                return true
            }

            // Polling keeps the wait cancellation-aware without storing
            // continuations that can race with release().
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    func release() {
        precondition(active > 0)
        active -= 1
    }
}
