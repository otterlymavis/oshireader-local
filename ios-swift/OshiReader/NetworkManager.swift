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
        let categoryUrl = "https://www.irasutoya.com/feeds/posts/default/-/\(URLQueryItem(name: "", value: "人物").value!.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")?alt=json&max-results=15"

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

    func scrapeCustomUrlsReport(_ urls: [CustomUrl]) async -> CustomURLScrapeReport {
        guard !urls.isEmpty else { return CustomURLScrapeReport(items: [], failedCount: 0) }

        return await withTaskGroup(of: (item: FeedItem?, succeeded: Bool).self) { group in
            var iterator = urls.makeIterator()
            var running = 0
            var results = [FeedItem]()
            var failedCount = 0

            func add(_ entry: CustomUrl) {
                group.addTask {
                    await self.scrapeCustomUrl(entry)
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

    private func scrapeCustomUrl(_ entry: CustomUrl) async -> (item: FeedItem?, succeeded: Bool) {
        let normalized = normalizedCustomUrl(entry.url)
        guard let url = URL(string: normalized) else { return (nil, false) }

        let nowString = _networkISO8601.string(from: Date())
        var title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var description: String?

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
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
            fetched_at: nowString
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
    var pubDate: String? = nil
    var thumbnailUrl: String? = nil
}

class RSSParserDelegate: NSObject, XMLParserDelegate {
    var items = [RssItem]()
    private var currentElement = ""
    private var currentItem: RssItem? = nil

    private var currentTitle = ""
    private var currentLink = ""
    private var currentDescription = ""
    private var currentPubDate = ""
    private var currentThumbnailUrl: String? = nil
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    private static let dateFormats = [
        "E, d MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == "item" || elementName == "entry" {
            currentItem = RssItem()
            currentTitle = ""
            currentLink = ""
            currentDescription = ""
            currentPubDate = ""
            currentThumbnailUrl = nil
        }
        if currentItem != nil {
            // Atom feeds (e.g. natalie) carry the URL in <link href="…"> rather than
            // as element text. Prefer rel="alternate" (or an unspecified rel).
            if elementName == "link", currentLink.isEmpty, let href = attributeDict["href"] {
                let rel = attributeDict["rel"]
                if rel == nil || rel == "alternate" {
                    currentLink = href
                }
            }
            if elementName == "media:thumbnail" || elementName == "media:content" {
                if let url = attributeDict["url"], currentThumbnailUrl == nil {
                    currentThumbnailUrl = url
                }
            }
            if elementName == "enclosure",
               let url = attributeDict["url"],
               attributeDict["type"]?.hasPrefix("image") == true,
               currentThumbnailUrl == nil {
                currentThumbnailUrl = url
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let cleaned = string.trimmingCharacters(in: .newlines)
        guard !cleaned.isEmpty else { return }

        switch currentElement {
        case "title":
            currentTitle += string
        case "link":
            currentLink += cleaned
        case "description", "summary":
            currentDescription += string
        case "pubDate", "published", "updated", "dc:date":
            currentPubDate += cleaned
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" || elementName == "entry" {
            if var item = currentItem {
                item.title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                item.link = currentLink.trimmingCharacters(in: .whitespacesAndNewlines)
                item.description = currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                item.thumbnailUrl = currentThumbnailUrl

                // Try to parse pubDate into ISO8601
                let dateString = currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines)
                // Try different formats (incl. Atom's colon-offset "+09:00").
                var date: Date? = nil
                for format in Self.dateFormats {
                    dateFormatter.dateFormat = format
                    if let d = dateFormatter.date(from: dateString) {
                        date = d
                        break
                    }
                }

                if let date = date {
                    item.pubDate = _networkISO8601.string(from: date)
                } else {
                    item.pubDate = dateString
                }

                items.append(item)
            }
            currentItem = nil
        }
    }
}
