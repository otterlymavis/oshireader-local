import Foundation

func parseISO8601Date(_ value: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: value) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) { return date }
    // Naive datetime without a timezone is treated as UTC.
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(identifier: "UTC")
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
        df.dateFormat = format
        if let date = df.date(from: value) { return date }
    }
    return nil
}

func cleanDisplayText(_ value: String?) -> String? {
    guard var text = value else { return nil }
    let replacements = [
        "&amp;": "&",
        "&quot;": "\"",
        "&#39;": "'",
        "&apos;": "'",
        "&nbsp;": " "
    ]
    for (needle, replacement) in replacements {
        text = text.replacingOccurrences(of: needle, with: replacement)
    }
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - WatchTerm
struct WatchTerm: Identifiable, Codable, Hashable {
    let id: String
    var keyword: String
    var collection_mode: String // "all_info" | "media_only"
    var is_active: Bool
    var notify_on_new: Bool
    var aliases: [String]
    let created_at: String

    enum CodingKeys: String, CodingKey {
        case id, keyword, collection_mode, is_active, notify_on_new, aliases, created_at
    }

    init(id: String = UUID().uuidString, keyword: String, collection_mode: String = "all_info", is_active: Bool = true, notify_on_new: Bool = false, aliases: [String] = [], created_at: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id
        self.keyword = keyword
        self.collection_mode = collection_mode
        self.is_active = is_active
        self.notify_on_new = notify_on_new
        self.aliases = aliases
        self.created_at = created_at
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decodes ID as String or Int coerced to String
        if let stringId = try? container.decode(String.self, forKey: .id) {
            self.id = stringId
        } else if let intId = try? container.decode(Int.self, forKey: .id) {
            self.id = String(intId)
        } else {
            self.id = UUID().uuidString
        }
        self.keyword = try container.decode(String.self, forKey: .keyword)
        self.collection_mode = try container.decode(String.self, forKey: .collection_mode)
        self.is_active = try container.decodeIfPresent(Bool.self, forKey: .is_active) ?? true
        self.notify_on_new = try container.decodeIfPresent(Bool.self, forKey: .notify_on_new) ?? false
        self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.created_at = try container.decodeIfPresent(String.self, forKey: .created_at) ?? ISO8601DateFormatter().string(from: Date())
    }
}

// MARK: - SourceItem
struct SourceItem: Codable, Hashable, Identifiable {
    let id: String
    let platform: String
    let url: String
    let published_at: String
    let author: String?
    let title: String?
    let content_text: String?
    let media_type: String?
    let thumbnail_url: String?
}

// MARK: - Local Flat FeedItem
struct FeedItem: Codable, Hashable, Identifiable {
    let id: String
    let platform: String
    let url: String
    let title: String?
    let content_text: String?
    let author: String?
    let thumbnail_url: String?
    let media_type: String
    let published_at: String
    let watch_term_keyword: String
    let fetched_at: String
}

// MARK: - SavedPage
struct SavedPage: Codable, Hashable, Identifiable {
    let id: String
    let url: String
    let title: String?
    let platform: String
    let saved_at: String
}

// MARK: - CustomUrl
struct CustomUrl: Codable, Hashable, Identifiable {
    let id: String
    let url: String
    let title: String?
    let added_at: String
}

// MARK: - AvatarLayer
struct AvatarLayer: Codable, Hashable, Identifiable {
    let id: String
    let imageUrl: String
    var x: Double
    var y: Double
    var scale: Double
    var cropX: Double?
    var cropY: Double?
    var cropScale: Double?
    var rotation: Double?
    var zIndex: Int
    
    init(id: String = UUID().uuidString, imageUrl: String, x: Double, y: Double, scale: Double = 1.0, cropX: Double? = 0.0, cropY: Double? = 0.0, cropScale: Double? = 1.0, rotation: Double? = 0.0, zIndex: Int) {
        self.id = id
        self.imageUrl = imageUrl
        self.x = x
        self.y = y
        self.scale = scale
        self.cropX = cropX
        self.cropY = cropY
        self.cropScale = cropScale
        self.rotation = rotation
        self.zIndex = zIndex
    }
}

// MARK: - Credential
struct Credential: Codable, Hashable {
    let platform: String
    let has_bearer_token: Bool
    let has_api_key: Bool
    let updated_at: String?
}

// MARK: - ScraperLog
struct ScraperLog: Codable, Hashable {
    let name: String
    let count: Int
    let error: String?
    let ms: Int
}

// MARK: - ScrapeRun
struct ScrapeRun: Codable, Hashable {
    let keyword: String
    let ran_at: String
    let logs: [ScraperLog]
}

// MARK: - Local backup
struct LocalBackup: Codable {
    static let currentVersion = 1

    let version: Int
    let exported_at: String
    let terms: [WatchTerm]
    let feed_items: [FeedItem]
    let saved_pages: [SavedPage]
    let custom_urls: [CustomUrl]
    let subscribed_platforms: [String]
    let wallpaper: String?
    let sources_order: [String]?
    let oshi_avatars: [String: String]
    let compositions: [String: [AvatarLayer]]
    let hidden_items: [String]

    init(
        exportedAt: String,
        terms: [WatchTerm],
        feedItems: [FeedItem],
        savedPages: [SavedPage],
        customUrls: [CustomUrl],
        subscribedPlatforms: [String],
        wallpaper: String?,
        sourcesOrder: [String]?,
        oshiAvatars: [String: String],
        compositions: [String: [AvatarLayer]],
        hiddenItems: [String]
    ) {
        self.version = Self.currentVersion
        self.exported_at = exportedAt
        self.terms = terms
        self.feed_items = feedItems
        self.saved_pages = savedPages
        self.custom_urls = customUrls
        self.subscribed_platforms = subscribedPlatforms
        self.wallpaper = wallpaper
        self.sources_order = sourcesOrder
        self.oshi_avatars = oshiAvatars
        self.compositions = compositions
        self.hidden_items = hiddenItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported backup version")
        }
        self.version = version
        self.exported_at = try container.decodeIfPresent(String.self, forKey: .exported_at) ?? ""
        self.terms = try container.decodeIfPresent([WatchTerm].self, forKey: .terms) ?? []
        self.feed_items = try container.decodeIfPresent([FeedItem].self, forKey: .feed_items) ?? []
        self.saved_pages = try container.decodeIfPresent([SavedPage].self, forKey: .saved_pages) ?? []
        self.custom_urls = try container.decodeIfPresent([CustomUrl].self, forKey: .custom_urls) ?? []
        self.subscribed_platforms = try container.decodeIfPresent([String].self, forKey: .subscribed_platforms) ?? []
        self.wallpaper = try container.decodeIfPresent(String.self, forKey: .wallpaper)
        self.sources_order = try container.decodeIfPresent([String].self, forKey: .sources_order)
        self.oshi_avatars = try container.decodeIfPresent([String: String].self, forKey: .oshi_avatars) ?? [:]
        self.compositions = try container.decodeIfPresent([String: [AvatarLayer]].self, forKey: .compositions) ?? [:]
        self.hidden_items = try container.decodeIfPresent([String].self, forKey: .hidden_items) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case version, exported_at, terms, feed_items, saved_pages, custom_urls
        case subscribed_platforms, wallpaper, sources_order, oshi_avatars, compositions, hidden_items
    }
}
