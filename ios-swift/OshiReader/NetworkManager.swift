import Foundation

struct IrasutoyaImage: Codable, Identifiable, Hashable {
    var id: String { url }
    let url: String
    let thumb: String
    let title: String
}

/// Direct-to-source network helpers that aren't part of feed ingestion:
/// custom-URL card scraping, the Irasutoya avatar picker, and the Google
/// Translate helper. Feed ingestion lives in `IngestionService`.
class NetworkManager {
    static let shared = NetworkManager()

    private init() {}

    // MARK: - Google Translate Helper
    func translateToJapanese(_ text: String) async -> String {
        // Checks if contains Japanese characters
        let isJapanese = text.range(of: "\\p{Hiragana}|\\p{Katakana}|\\p{Han}", options: .regularExpression) != nil
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
            #if DEBUG
            print("Translation failed: \(error)")
            #endif
        }
        return text
    }

    // MARK: - Irasutoya popular / search
    func getPopularIrasutoya() async throws -> [IrasutoyaImage] {
        let feed1 = "https://www.irasutoya.com/feeds/posts/default?alt=json&max-results=20"
        let categoryUrl = "https://www.irasutoya.com/feeds/posts/default/-/\(URLQueryItem(name: "", value: "人物").value!.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")?alt=json&max-results=15"

        let items1 = try await fetchBloggerFeed(feed1)
        let items2 = (try? await fetchBloggerFeed(categoryUrl)) ?? []

        var combined = [IrasutoyaImage]()
        var seen = Set<String>()

        for item in items1 + items2 {
            if !seen.contains(item.url) && combined.count < 30 {
                seen.insert(item.url)
                combined.append(item)
            }
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
                let pattern = #"src="(https?://[^"]+\.(?:png|jpg|jpeg|gif))""#
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: contentHtml, range: NSRange(contentHtml.startIndex..., in: contentHtml)) {
                    if let range = Range(match.range(at: 1), in: contentHtml) {
                        thumb = String(contentHtml[range])
                    }
                }
            }

            if !altLink.isEmpty && !thumb.isEmpty {
                // Upscale small Blogger thumbnails for the editor picker.
                let upscaled = thumb
                    .replacingOccurrences(of: "/s72-c/", with: "/s400-c/")
                    .replacingOccurrences(of: "/s72-c$", with: "/s400-c", options: .regularExpression)
                    .replacingOccurrences(of: "/s1600/", with: "/s400/")
                list.append(IrasutoyaImage(url: altLink, thumb: upscaled, title: title))
            }
        }
        return list
    }

    // MARK: - Custom URL Scraping
    func scrapeCustomUrls(_ urls: [CustomUrl]) async -> [FeedItem] {
        guard !urls.isEmpty else { return [] }

        return await withTaskGroup(of: FeedItem?.self) { group in
            for entry in urls {
                group.addTask {
                    await self.scrapeCustomUrl(entry)
                }
            }

            var results = [FeedItem]()
            for await item in group {
                if let item {
                    results.append(item)
                }
            }
            return results
        }
    }

    private func scrapeCustomUrl(_ entry: CustomUrl) async -> FeedItem? {
        let normalized = normalizedCustomUrl(entry.url)
        guard let url = URL(string: normalized) else { return nil }

        let nowString = ISO8601DateFormatter().string(from: Date())
        var title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var description: String?

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)
            if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) {
                title = extractTagContent(named: "title", from: html) ?? title
                description = extractMetaDescription(from: html)
            }
        } catch {
            #if DEBUG
            print("Custom URL scrape failed for \(entry.url): \(error)")
            #endif
        }

        return FeedItem(
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
        )
    }

    private func normalizedCustomUrl(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private func extractTagContent(named tag: String, from html: String) -> String? {
        let pattern = #"<\#(tag)[^>]*>([^<]{1,240})</\#(tag)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return cleanDisplayText(String(html[range]))
    }

    private func extractMetaDescription(from html: String) -> String? {
        let patterns = [
            #"<meta[^>]+name=["']description["'][^>]+content=["']([^"']{1,360})["'][^>]*>"#,
            #"<meta[^>]+content=["']([^"']{1,360})["'][^>]+name=["']description["'][^>]*>"#,
            #"<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']{1,360})["'][^>]*>"#,
            #"<meta[^>]+content=["']([^"']{1,360})["'][^>]+property=["']og:description["'][^>]*>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
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
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")

                // Try different formats (incl. Atom's colon-offset "+09:00").
                var date: Date? = nil
                let formats = [
                    "E, d MMM yyyy HH:mm:ss Z",
                    "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                    "yyyy-MM-dd'T'HH:mm:ssZ",
                    "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                    "yyyy-MM-dd'T'HH:mm:ss'Z'"
                ]
                for format in formats {
                    df.dateFormat = format
                    if let d = df.date(from: dateString) {
                        date = d
                        break
                    }
                }

                if let date = date {
                    item.pubDate = ISO8601DateFormatter().string(from: date)
                } else {
                    item.pubDate = dateString
                }

                items.append(item)
            }
            currentItem = nil
        }
    }
}
