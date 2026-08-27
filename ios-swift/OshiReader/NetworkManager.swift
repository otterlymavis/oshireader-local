import Foundation

private let _bloggerImageRegex = try? NSRegularExpression(
    pattern: #"src="(https?://[^"]+\.(?:png|jpg|jpeg|gif))""#,
    options: .caseInsensitive
)
private let _japaneseScriptRegex = try? NSRegularExpression(pattern: "\\p{Hiragana}|\\p{Katakana}|\\p{Han}")
private let _bloggerThumbSuffixRegex = try? NSRegularExpression(pattern: "/s72-c$")
private let _networkISO8601 = ISO8601DateFormatter()

private enum _ScraperRegex {
    static let titleTag = try? NSRegularExpression(
        pattern: #"<title[^>]*>([^<]{1,240})</title>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    static let metaDescription: [NSRegularExpression] = [
        #"<meta[^>]+name=["']description["'][^>]+content=["']([^"']{1,360})["'][^>]*>"#,
        #"<meta[^>]+content=["']([^"']{1,360})["'][^>]+name=["']description["'][^>]*>"#,
        #"<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']{1,360})["'][^>]*>"#,
        #"<meta[^>]+content=["']([^"']{1,360})["'][^>]+property=["']og:description["'][^>]*>"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
}

struct IrasutoyaImage: Codable, Identifiable, Hashable {
    var id: String { url }
    let url: String
    let thumb: String
    let title: String
}

/// Shared session for repeated per-refresh fetches (feed ingestion, custom
/// URL cards). A dedicated `URLCache` lets `URLSession` revalidate unchanged
/// responses via ETag/Last-Modified instead of re-downloading in full on
/// every refresh, and a higher per-host connection cap avoids requests
/// queuing when multiple watch terms hit the same platform concurrently.
enum IngestionNetworking {
    static let session: URLSession = {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("IngestionURLCache", isDirectory: true)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024, directory: cacheDirectory)
        // Revalidate rather than serve straight from cache — this session
        // exists to skip re-downloading unchanged bodies via a 304, not to
        // skip the network request itself and risk missing new items.
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()
}

struct CustomURLScrapeReport {
    let items: [FeedItem]
    let failedCount: Int

    var completed: Bool { failedCount == 0 }
}

/// Direct-to-source network helpers that aren't part of feed ingestion:
/// custom-URL card scraping, the Irasutoya avatar picker, and the Google
/// Translate helper. Feed ingestion lives in `IngestionService`.
class NetworkManager {
    static let shared = NetworkManager()
    private static let customURLConcurrencyLimit = 4

    private init() {}

    // MARK: - Google Translate Helper
    func translateToJapanese(_ text: String) async -> String {
        let isJapanese = _japaneseScriptRegex.flatMap {
            $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        } != nil
        if isJapanese { return text }

        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let urlString = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=ja&dt=t&q=\(query)"
        guard let url = URL(string: urlString) else { return text }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let firstArray = json.first as? [Any] {
                var translatedText = ""
                for chunk in firstArray {
                    if let chunkArray = chunk as? [Any], let string = chunkArray.first as? String {
                        translatedText += string
                    }
                }
                return translatedText.isEmpty ? text : translatedText
            }
        } catch {
            AppLogger.network.error("Translation failed: \(error.localizedDescription)")
        }
        return text
    }

    // MARK: - Irasutoya popular / search
    func getPopularIrasutoya() async throws -> [IrasutoyaImage] {
        let feed1 = "https://www.irasutoya.com/feeds/posts/default?alt=json&max-results=20"
        let categoryQuery = "人物".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "人物"
        let categoryUrl = "https://www.irasutoya.com/feeds/posts/default/-/\(categoryQuery)?alt=json&max-results=15"

        async let fetch1 = fetchBloggerFeed(feed1)
        async let fetch2 = fetchBloggerFeed(categoryUrl)
        let items1 = try await fetch1
        let items2 = (try? await fetch2) ?? []

        var combined = [IrasutoyaImage]()
        var seen = Set<String>()
        for item in items1 + items2 where !seen.contains(item.url) && combined.count < 30 {
            seen.insert(item.url)
            combined.append(item)
        }
        return combined
    }

    func searchIrasutoya(query: String) async throws -> [IrasutoyaImage] {
        let jaQuery = await translateToJapanese(query)
        let escaped = jaQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? jaQuery

        let feedUrl1 = "https://www.irasutoya.com/feeds/posts/default?alt=json&q=\(escaped)&max-results=36&start-index=1"
        let feedUrl2 = "https://www.irasutoya.com/feeds/posts/default?alt=json&q=\(escaped)&max-results=36&start-index=37"

        let items1 = (try? await fetchBloggerFeed(feedUrl1)) ?? []
        let items2 = (try? await fetchBloggerFeed(feedUrl2)) ?? []

        var combined = [IrasutoyaImage]()
        var seen = Set<String>()

        for item in items1 + items2 {
            if !seen.contains(item.url) && combined.count < 72 {
                seen.insert(item.url)
                combined.append(item)
            }
        }
        return combined
    }

    private func fetchBloggerFeed(_ urlString: String) async throws -> [IrasutoyaImage] {
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = json["feed"] as? [String: Any],
              let entries = feed["entry"] as? [[String: Any]] else {
            return []
        }

        var list = [IrasutoyaImage]()
        for entry in entries {
            let titleContainer = entry["title"] as? [String: Any]
            let title = titleContainer?["$t"] as? String ?? ""

            let links = entry["link"] as? [[String: Any]] ?? []
            let altLink = links.first(where: { ($0["rel"] as? String) == "alternate" })?["href"] as? String ?? ""

            var thumb = ""
            if let mediaThumb = entry["media$thumbnail"] as? [String: Any] {
                thumb = mediaThumb["url"] as? String ?? ""
            }
            if thumb.isEmpty, let contentContainer = entry["content"] as? [String: Any],
               let contentHtml = contentContainer["$t"] as? String {
                if let regex = _bloggerImageRegex,
                   let match = regex.firstMatch(in: contentHtml, range: NSRange(contentHtml.startIndex..., in: contentHtml)) {
                    if let range = Range(match.range(at: 1), in: contentHtml) {
                        thumb = String(contentHtml[range])
                    }
                }
            }

            if !altLink.isEmpty && !thumb.isEmpty {
                // Upscale small Blogger thumbnails for the editor picker.
                var upscaled = thumb
                    .replacingOccurrences(of: "/s72-c/", with: "/s400-c/")
                    .replacingOccurrences(of: "/s1600/", with: "/s400/")
                if let regex = _bloggerThumbSuffixRegex {
                    upscaled = regex.stringByReplacingMatches(
                        in: upscaled,
                        range: NSRange(upscaled.startIndex..., in: upscaled),
                        withTemplate: "/s400-c"
                    )
                }
                list.append(IrasutoyaImage(url: altLink, thumb: upscaled, title: title))
            }
        }
        return list
    }

    // MARK: - Custom URL Scraping
    func scrapeCustomUrls(_ urls: [CustomUrl]) async -> [FeedItem] {
        await scrapeCustomUrlsReport(urls).items
    }

    func scrapeCustomUrlsReport(_ urls: [CustomUrl], requestTimeout: TimeInterval = 12) async -> CustomURLScrapeReport {
        guard !urls.isEmpty else { return CustomURLScrapeReport(items: [], failedCount: 0) }

        return await withTaskGroup(of: (item: FeedItem?, succeeded: Bool).self) { group in
            var iterator = urls.makeIterator()
            var running = 0
            var results = [FeedItem]()
            var failedCount = 0

            func add(_ entry: CustomUrl) {
                group.addTask {
                    await self.scrapeCustomUrl(entry, requestTimeout: requestTimeout)
                }
                running += 1
            }

            while running < Self.customURLConcurrencyLimit, let entry = iterator.next() {
                add(entry)
            }
            for await result in group {
                running -= 1
                guard result.succeeded else {
                    failedCount += 1
                    if let entry = iterator.next() { add(entry) }
                    continue
                }
                if let item = result.item {
                    results.append(item)
                }
                if let entry = iterator.next() { add(entry) }
            }
            return CustomURLScrapeReport(items: results, failedCount: failedCount)
        }
    }

    private func scrapeCustomUrl(_ entry: CustomUrl, requestTimeout: TimeInterval = 12) async -> (item: FeedItem?, succeeded: Bool) {
        let normalized = normalizedCustomUrl(entry.url)
        guard let url = URL(string: normalized) else { return (nil, false) }

        let nowString = _networkISO8601.string(from: Date())
        var title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var description: String?

        do {
            var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
            request.timeoutInterval = requestTimeout
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await IngestionNetworking.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return (nil, false)
            }
            if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) {
                title = extractTagContent(named: "title", from: html) ?? title
                description = extractMetaDescription(from: html)
            }
        } catch {
            AppLogger.scraping.error("Custom URL scrape failed for \(entry.url): \(error.localizedDescription)")
            return (nil, false)
        }

        return (FeedItem(
            id: entry.id,
            platform: "custom",
            url: normalized,
            title: title?.isEmpty == false ? title : normalized,
            content_text: description?.isEmpty == false ? description : nil,
            author: URL(string: normalized)?.host,
            thumbnail_url: nil,
            media_type: "article",
            published_at: entry.added_at,
            watch_term_keyword: "",
            fetched_at: nowString,
            source: "custom_url"
        ), true)
    }

    private func normalizedCustomUrl(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private func extractTagContent(named tag: String, from html: String) -> String? {
        guard tag.lowercased() == "title",
              let regex = _ScraperRegex.titleTag,
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return cleanDisplayText(String(html[range]))
    }

    private func extractMetaDescription(from html: String) -> String? {
        for regex in _ScraperRegex.metaDescription {
            guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else {
                continue
            }
            return cleanDisplayText(String(html[range]))
        }
        return nil
    }
}

// MARK: - RSS XML Parser Helper
struct RssItem {
    var title: String = ""
    var link: String = ""
    var description: String = ""
    var author: String? = nil
    var pubDate: String? = nil
    var thumbnailUrl: String? = nil
}

class RSSParserDelegate: NSObject, XMLParserDelegate {
    private static let atomNamespace = "http://www.w3.org/2005/atom"
    private static let dublinCoreNamespace = "http://purl.org/dc/elements/1.1/"
    private static let mediaRSSNamespace = "http://search.yahoo.com/mrss/"
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let rssOneNamespace = "http://purl.org/rss/1.0/"
    private static let rssContentNamespace = "http://purl.org/rss/1.0/modules/content/"

    private let sourceURL: URL?

    var items = [RssItem]()
    private(set) var recognizedFeedRoot = false
    private var sawDocumentRoot = false
    private var elementStack = [String]()
    private var baseURLStack = [URL?]()
    private var currentItem: RssItem? = nil
    private var currentItemDepth: Int? = nil

    private var currentTitle = ""
    private var currentLink = ""
    private var currentLinkBaseURL: URL?
    private var currentRDFAboutLink = ""
    private var currentRDFAboutBaseURL: URL?
    private var currentPermalinkGuid = ""
    private var currentGuidBaseURL: URL?
    private var currentGuidCanBePermalink = false
    private var currentDescription = ""
    private var currentSummary = ""
    private var currentContent = ""
    private var currentAuthor = ""
    private var currentPublishedDate = ""
    private var currentUpdatedDate = ""
    private var currentThumbnailUrl: String? = nil
    private var currentThumbnailBaseURL: URL?
    private var currentThumbnailPriority = 0
    private var currentAtomLinkPriority = 0

    init(sourceURL: URL? = nil) {
        self.sourceURL = sourceURL
        super.init()
    }

    private let _dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.twoDigitStartDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 1950, month: 1, day: 1)
        )
        return df
    }()
    private static let _dateFormats = [
        "E, d MMM yy HH:mm:ss z",
        "E, d MMM yy HH:mm z",
        "d MMM yy HH:mm:ss z",
        "d MMM yy HH:mm z",
        "E, d MMM yyyy HH:mm:ss Z",
        "E, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd"
    ]
    private let _iso8601Out = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let rawElementName = (qName ?? elementName).lowercased()
        let localElementName = Self.feedElementName(
            elementName,
            namespaceURI: namespaceURI,
            qualifiedName: qName
        )
        elementStack.append(localElementName)
        let inheritedBaseURL = baseURLStack.last.flatMap { $0 } ?? sourceURL
        let xmlBase = attributeDict.first { $0.key.lowercased() == "xml:base" }?.value
        let elementBaseURL = xmlBase.flatMap {
            URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: inheritedBaseURL)?.absoluteURL
        } ?? inheritedBaseURL
        baseURLStack.append(elementBaseURL)
        if !sawDocumentRoot {
            sawDocumentRoot = true
            recognizedFeedRoot = ["rss", "feed"].contains(localElementName) ||
                (localElementName == "rdf" && namespaceURI?.lowercased() == Self.rdfNamespace) ||
                rawElementName == "rdf:rdf"
        }
        if currentItem == nil && (localElementName == "item" || localElementName == "entry") {
            currentItem = RssItem()
            currentItemDepth = elementStack.count
            currentTitle = ""
            currentLink = ""
            currentLinkBaseURL = nil
            currentRDFAboutLink = ""
            currentRDFAboutBaseURL = nil
            currentPermalinkGuid = ""
            currentGuidBaseURL = nil
            currentGuidCanBePermalink = false
            currentDescription = ""
            currentSummary = ""
            currentContent = ""
            currentAuthor = ""
            currentPublishedDate = ""
            currentUpdatedDate = ""
            currentThumbnailUrl = nil
            currentThumbnailBaseURL = nil
            currentThumbnailPriority = 0
            currentAtomLinkPriority = 0
            if localElementName == "item",
               namespaceURI?.lowercased() == Self.rssOneNamespace {
                currentRDFAboutLink = attributeDict.first { $0.key.lowercased() == "rdf:about" }?.value ?? ""
                currentRDFAboutBaseURL = elementBaseURL
            }
        }
        if currentItem != nil {
            let isDirectItemChild = elementStack.dropLast().last.map { $0 == "item" || $0 == "entry" } == true
            if isDirectItemChild,
                elementStack.dropLast().last == "item",
               localElementName == "guid" {
                let isPermaLink = attributeDict.first { $0.key.lowercased() == "ispermalink" }?.value
                currentGuidCanBePermalink = isPermaLink?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() != "false"
                currentGuidBaseURL = elementBaseURL
            }
            if isDirectItemChild,
               localElementName == "link",
               attributeDict["href"] == nil {
                currentLinkBaseURL = elementBaseURL
            }
            if isDirectItemChild,
               localElementName == "link",
               let href = attributeDict["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !href.isEmpty,
               resolveWebURLString(href, baseURL: elementBaseURL) != nil {
                let rel = attributeDict["rel"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let priority: Int
                switch rel {
                case nil, "", "alternate": priority = 2
                case "self": priority = 1
                default: priority = 0
                }
                if priority > currentAtomLinkPriority {
                    currentLink = href
                    currentLinkBaseURL = elementBaseURL
                    currentAtomLinkPriority = priority
                }
            }
            if localElementName == "media:thumbnail",
               let url = attributeDict["url"],
               resolveWebURLString(url, baseURL: elementBaseURL) != nil,
               currentThumbnailPriority < 2 {
                currentThumbnailUrl = url
                currentThumbnailBaseURL = elementBaseURL
                currentThumbnailPriority = 2
            }
            if localElementName == "media:content",
               let url = attributeDict["url"],
               resolveWebURLString(url, baseURL: elementBaseURL) != nil,
               currentThumbnailPriority < 1,
               Self.mediaContentCanBeThumbnail(attributeDict) {
                currentThumbnailUrl = url
                currentThumbnailBaseURL = elementBaseURL
                currentThumbnailPriority = 1
            }
            if localElementName == "enclosure",
               let url = attributeDict["url"],
               resolveWebURLString(url, baseURL: elementBaseURL) != nil,
               attributeDict["type"]?
                   .trimmingCharacters(in: .whitespacesAndNewlines)
                   .lowercased()
                   .hasPrefix("image/") == true,
               currentThumbnailPriority < 1 {
                currentThumbnailUrl = url
                currentThumbnailBaseURL = elementBaseURL
                currentThumbnailPriority = 1
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        appendText(string)
    }

    private func appendText(_ string: String) {
        let cleaned = string.trimmingCharacters(in: .newlines)
        guard currentItem != nil, !cleaned.isEmpty else { return }

        let itemIndex = currentItemDepth.map { $0 - 1 }
        let contentElement = itemIndex.flatMap { index in
            elementStack.index(after: index) < elementStack.endIndex
                ? elementStack[elementStack.index(after: index)]
                : nil
        }
        switch contentElement {
        case "title":       currentTitle += string
        case "link":        currentLink += cleaned
        case "guid" where currentGuidCanBePermalink: currentPermalinkGuid += cleaned
        case "description": currentDescription += string
        case "summary": currentSummary += string
        case "content": currentContent += string
        case "artist", "creator", "author":
            // Atom's structured person construct (<author><name>...</name>
            // <email>...</email></author>) nests text several levels below
            // `contentElement`, which stays pinned to "author" for every
            // descendant. Only capture the flat text form or the <name>
            // child so sibling <email>/<uri> text isn't concatenated in.
            let leaf = elementStack.last
            if leaf == contentElement || leaf == "name" {
                currentAuthor += string
            }
        case "pubdate", "published", "date": currentPublishedDate += cleaned
        case "updated": currentUpdatedDate += cleaned
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer {
            if !elementStack.isEmpty {
                elementStack.removeLast()
            }
            if !baseURLStack.isEmpty {
                baseURLStack.removeLast()
            }
        }
        let localElementName = Self.feedElementName(
            elementName,
            namespaceURI: namespaceURI,
            qualifiedName: qName
        )
        guard (localElementName == "item" || localElementName == "entry"),
              currentItemDepth == elementStack.count,
              var item = currentItem else { return }
        item.title = normalizedText(currentTitle)
        let explicitLink = currentLink.trimmingCharacters(in: .whitespacesAndNewlines)
        item.link = [
            (explicitLink, currentLinkBaseURL),
            (currentPermalinkGuid, currentGuidBaseURL),
            (currentRDFAboutLink, currentRDFAboutBaseURL)
        ]
            .compactMap { resolveWebURLString($0.0, baseURL: $0.1) }
            .first ?? ""
        item.description = [currentDescription, currentSummary, currentContent]
            .map(normalizedText)
            .first { !$0.isEmpty } ?? ""
        item.author = cleanDisplayText(currentAuthor)
        item.thumbnailUrl = currentThumbnailUrl.flatMap {
            resolveWebURLString($0, baseURL: currentThumbnailBaseURL)
        }

        let dateStrings = [currentPublishedDate, currentUpdatedDate]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let parsedDate = dateStrings.compactMap(parseDate).max()
        item.pubDate = parsedDate.map { _iso8601Out.string(from: $0) }

        items.append(item)
        currentItem = nil
        currentItemDepth = nil
    }

    private static func feedElementName(
        _ elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) -> String {
        let localName = elementName.lowercased()
        let namespace = namespaceURI?.lowercased()
        if namespace == atomNamespace { return localName }
        if namespace == dublinCoreNamespace,
           localName == "date" || localName == "creator" {
            return localName
        }
        if namespace == mediaRSSNamespace { return "media:\(localName)" }
        if namespace == rssContentNamespace, localName == "encoded" { return "content" }

        let normalized = (qualifiedName ?? elementName).lowercased()
        let parts = normalized.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return normalized }
        switch (parts[0], parts[1]) {
        case ("atom", let localName), ("rss", let localName):
            return localName
        case ("dc", "date"):
            return "date"
        case ("dc", "creator"):
            return "creator"
        default:
            return normalized
        }
    }

    private static func mediaContentCanBeThumbnail(_ attributes: [String: String]) -> Bool {
        let medium = attributes["medium"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let type = attributes["type"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasExplicitNonImageMedium = medium.map { $0 != "image" } ?? false
        let hasExplicitNonImageType = type.map { !$0.hasPrefix("image/") } ?? false
        return !hasExplicitNonImageMedium && !hasExplicitNonImageType
    }

    private func resolveWebURLString(_ rawValue: String, baseURL: URL? = nil) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value, relativeTo: baseURL ?? sourceURL)?.absoluteURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        return url.absoluteString
    }

    private func parseDate(_ value: String) -> Date? {
        for format in Self._dateFormats {
            _dateFormatter.dateFormat = format
            if let date = _dateFormatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private func normalizedText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
