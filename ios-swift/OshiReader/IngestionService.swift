import Foundation

/// On-device ingestion for public RSS feeds, JSON APIs, and pages.
///
/// Each `fetch*` method reads directly from the phone.
/// `ingest(term:platforms:)` fans them out for a single watch term and returns
/// flat `FeedItem`s ready for `LocalDB.mergeItems`.
final class IngestionService {
    static let shared = IngestionService()
    private init() {}

    private let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Caps concurrent news.google.com requests across all in-flight terms.
    private static let googleNewsLimiter = RequestLimiter(limit: 3)

    // MARK: - Orchestration

    /// Fetch every subscribed source for one watch term. Network errors in any
    /// single source are swallowed (that source just contributes no items).
    func ingest(term: WatchTerm, platforms: Set<String>) async -> [FeedItem] {
        let keyword = term.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let mediaOnly = term.collection_mode == "media_only"

        return await withTaskGroup(of: [FeedItem].self) { group in
            func add(_ id: String, _ work: @escaping () async -> [FeedItem]) {
                guard platforms.contains(id) else { return }
                group.addTask { await work() }
            }

            add("news")        { await self.fetchCuratedNews(keyword: keyword, mediaOnly: mediaOnly) }
            add("5ch")         { await self.fetchGoogleNews(keyword: keyword, query: "\(keyword) site:5ch.net", platform: "5ch", mediaType: "text", mediaOnly: mediaOnly) }
            add("girlschannel") { await self.fetchGoogleNews(keyword: keyword, query: "\(keyword) site:girlschannel.net", platform: "girlschannel", mediaType: "text", mediaOnly: mediaOnly) }
            add("mdpr")        { await self.fetchGoogleNews(keyword: keyword, query: "\(keyword) site:mdpr.jp", platform: "mdpr", mediaType: "article", mediaOnly: mediaOnly, titlePatterns: [#"\s*[-|]\s*モデルプレス\s*$"#]) }
            add("oricon")      { await self.fetchGoogleNews(keyword: keyword, query: "\(keyword) site:oricon.co.jp", platform: "oricon", mediaType: "article", mediaOnly: mediaOnly, author: "ORICON NEWS", limit: 20, titlePatterns: [#"\s*[-|]\s*(ORICON NEWS|オリコンニュース|オリコン)\s*$"#]) }
            add("yahoonews")   { await self.fetchYahooNews(keyword: keyword, mediaOnly: mediaOnly) }
            add("niconico")    { await self.fetchNiconico(keyword: keyword) }
            add("note")        { await self.fetchNote(keyword: keyword, mediaOnly: mediaOnly) }
            // Togetter via Google News so items carry real publish dates (the
            // search-page scrape doesn't expose reliable dates).
            add("togetter")    { await self.fetchGoogleNews(keyword: keyword, query: "\(keyword) site:togetter.com", platform: "togetter", mediaType: "article", mediaOnly: mediaOnly) }
            add("tver")        { await self.fetchTVer(keyword: keyword) }
            add("youtube")     { await self.fetchYouTube(keyword: keyword) }
            add("twitter")     { await self.fetchTwitter(keyword: keyword, mediaOnly: mediaOnly) }

            var all = [FeedItem]()
            for await items in group { all.append(contentsOf: items) }
            return all
        }
    }

    // MARK: - General news
    //
    // Discovery is a keyword-targeted Google News search (reliable, relevant),
    // augmented by a couple of general entertainment feeds filtered client-side.
    // "news" items are also keyword-filtered at display time in LocalDB.queryFeed.
    private static let curatedFeeds = [
        "https://natalie.mu/music/feed/news",
        "https://natalie.mu/tv/feed/news",
        "https://www3.nhk.or.jp/rss/news/cat7.xml",
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
                    let entries = await self.parseRSS(url)
                    return entries.compactMap { entry -> FeedItem? in
                        guard !entry.link.isEmpty else { return nil }
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
                            published_at: entry.pubDate ?? self.nowISO(),
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

    // MARK: - Google News site-filtered RSS (5ch, girlschannel, mdpr, oricon, yahoonews, niconico fallback)

    private func fetchGoogleNews(
        keyword: String,
        query: String,
        platform: String,
        mediaType: String,
        mediaOnly: Bool,
        author: String? = nil,
        limit: Int = 25,
        titlePatterns: [String] = []
    ) async -> [FeedItem] {
        if mediaOnly { return [] }
        guard let url = googleNewsURL(query) else { return [] }
        // Many sources funnel through news.google.com; throttle so we don't get
        // rate-limited (which previously made sources like 5ch return nothing).
        await Self.googleNewsLimiter.acquire()
        let entries = await parseRSS(url)
        await Self.googleNewsLimiter.release()

        var seen = Set<String>()
        var items = [FeedItem]()
        for entry in entries {
            if items.count >= limit { break }
            guard !entry.link.isEmpty else { continue }
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
                published_at: entry.pubDate ?? nowISO(),
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
        if let url = comps.url,
           let (data, _) = await httpGET(url, headers: ["Accept": "application/json"], timeout: 10),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let rows = json["data"] as? [[String: Any]], !rows.isEmpty {
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
        // Fallback: Google News filtered to nicovideo.jp
        return await fetchGoogleNews(keyword: keyword, query: "\(keyword) site:nicovideo.jp", platform: "niconico", mediaType: "video", mediaOnly: false)
    }

    // MARK: - note.com (hashtag RSS)

    private func fetchNote(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        if mediaOnly { return [] }
        // note.com's old /api/v2/searches endpoint now 404s, so we use the
        // hashtag RSS feed (notes tagged with the keyword) directly.
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://note.com/hashtag/\(encoded)/rss") else { return [] }
        let entries = await parseRSS(url)
        return entries.prefix(25).compactMap { entry -> FeedItem? in
            guard !entry.link.isEmpty else { return nil }
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
                published_at: entry.pubDate ?? nowISO(),
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

        guard let (cData, cResp) = try? await URLSession.shared.data(for: createReq),
              (cResp as? HTTPURLResponse)?.statusCode == 200,
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
        guard let (data, _) = await httpGET(searchURL, headers: searchHeaders, timeout: 15),
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

    // MARK: - YouTube (keyless HTML scrape of the search page)

    private func fetchYouTube(keyword: String) async -> [FeedItem] {
        await fetchYouTubeScrape(keyword: keyword)
    }

    private func fetchYouTubeScrape(keyword: String) async -> [FeedItem] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)"),
              let (data, _) = await httpGET(url, headers: ["User-Agent": browserUA, "Accept-Language": "ja,ja-JP;q=0.9,en;q=0.8"], timeout: 15),
              let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"ytInitialData\s*=\s*(\{.+?\});"#, options: [.dotMatchesLineSeparators]),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let jsonRange = Range(m.range(at: 1), in: html),
              let jsonData = String(html[jsonRange]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return []
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
        return items
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
        guard let bearer = KeychainHelper.read(.twitterBearerToken) else { return [] }
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
              let (data, resp) = await httpGET(url, headers: ["Authorization": "Bearer \(bearer)"], timeout: 10),
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

    private func httpGET(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 12) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return (data, http)
    }

    private func parseRSS(_ url: URL, headers: [String: String] = [:]) async -> [RssItem] {
        // Send a browser User-Agent — news.google.com and note.com throttle/deny
        // the default URLSession agent, which made some sources return nothing.
        var allHeaders = ["User-Agent": browserUA, "Accept-Language": "ja,en;q=0.9"]
        allHeaders.merge(headers) { _, override in override }
        guard let (data, _) = await httpGET(url, headers: allHeaders, timeout: 12) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = RSSParserDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private func googleNewsURL(_ query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=ja&gl=JP&ceid=JP%3Aja")
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

    /// Stable FNV-1a hash so the same article URL yields the same FeedItem id
    /// across refreshes (lets LocalDB dedup it).
    private func stableId(_ input: String) -> String {
        var v: UInt64 = 14695981039346656037
        for b in input.utf8 {
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()   // hand the slot directly to a waiter
        } else {
            active -= 1
        }
    }
}
