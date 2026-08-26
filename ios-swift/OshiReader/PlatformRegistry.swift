import Foundation

/// The local app's source catalog.  This is deliberately independent from
/// ThemeManager so ingestion, settings, and migrations share the same IDs.
struct PlatformDefinition: Equatable {
    enum NewsLocale: Equatable {
        case japan
        case englishUS

        var acceptLanguage: String {
            switch self {
            case .japan:
                return "ja,en;q=0.9"
            case .englishUS:
                return "en,ko;q=0.9,ja;q=0.7"
            }
        }
    }

    let id: String
    let name: String
    let icon: String
    let rawPlatformValues: Set<String>
    let googleNewsSite: String?
    let newsLocale: NewsLocale
    let usesStrictKeywordMatching: Bool
    let isMediaPlatform: Bool
    let skipDateCutoff: Bool
    let usesActivityDateWindow: Bool

    init(
        id: String,
        name: String,
        icon: String,
        rawPlatformValues: Set<String>? = nil,
        googleNewsSite: String? = nil,
        newsLocale: NewsLocale = .japan,
        usesStrictKeywordMatching: Bool = false,
        isMediaPlatform: Bool = false,
        skipDateCutoff: Bool = false,
        usesActivityDateWindow: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.rawPlatformValues = rawPlatformValues ?? [id]
        self.googleNewsSite = googleNewsSite
        self.newsLocale = newsLocale
        self.usesStrictKeywordMatching = usesStrictKeywordMatching
        self.isMediaPlatform = isMediaPlatform
        self.skipDateCutoff = skipDateCutoff
        self.usesActivityDateWindow = usesActivityDateWindow
    }
}

enum PlatformRegistry {
    /// Keep this order stable: it is the default order shown in Settings and
    /// becomes the fallback order when no custom source order is saved.
    static let all: [PlatformDefinition] = [
        PlatformDefinition(id: "youtube", name: "YouTube", icon: "📹", isMediaPlatform: true),
        PlatformDefinition(id: "niconico", name: "NicoNico", icon: "💬", isMediaPlatform: true),
        PlatformDefinition(id: "tver", name: "TVer", icon: "📺", isMediaPlatform: true),
        PlatformDefinition(id: "twitter", name: "X", icon: "𝕏", rawPlatformValues: ["twitter", "x"]),
        PlatformDefinition(id: "note", name: "Note", icon: "📝"),
        PlatformDefinition(id: "girlschannel", name: "GirlsChannel", icon: "👭", googleNewsSite: "girlschannel.net", usesStrictKeywordMatching: true, skipDateCutoff: true, usesActivityDateWindow: true),
        PlatformDefinition(id: "5ch", name: "5ch", icon: "💬", googleNewsSite: "5ch.net", usesStrictKeywordMatching: true, skipDateCutoff: true, usesActivityDateWindow: true),
        PlatformDefinition(id: "news", name: "General News", icon: "📰"),
        PlatformDefinition(id: "yahoonews", name: "YahooNews", icon: "🇯🇵", rawPlatformValues: ["yahoonews", "news:yahoo_ent"], googleNewsSite: "news.yahoo.co.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "mdpr", name: "ModelPress", icon: "💅", rawPlatformValues: ["mdpr", "news:mdpr"], googleNewsSite: "mdpr.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "oricon", name: "Oricon", icon: "🎤", googleNewsSite: "oricon.co.jp", usesStrictKeywordMatching: true),

        // Additional reference sources, implemented locally through the same
        // dated Google News RSS path used by the existing source fallbacks.
        PlatformDefinition(id: "smartnews", name: "SmartNews", icon: "📰", googleNewsSite: "smartnews.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "ameblo", name: "Ameblo", icon: "✏️", googleNewsSite: "ameblo.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "aera", name: "AERA dot.", icon: "📝", googleNewsSite: "dot.asahi.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "hochi", name: "Hochi", icon: "🏅", googleNewsSite: "hochi.news", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "sponichi", name: "Sponichi", icon: "⚽", googleNewsSite: "sponichi.co.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "livedoor", name: "Livedoor", icon: "🔴", googleNewsSite: "news.livedoor.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "mantanweb", name: "Mantan Web", icon: "🎌", googleNewsSite: "mantan-web.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "realsound", name: "Real Sound", icon: "🎧", googleNewsSite: "realsound.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "cinemacafe", name: "CinemaCafe", icon: "🎬", googleNewsSite: "cinemacafe.net", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "thetv", name: "TheTV", icon: "📺", googleNewsSite: "thetv.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "natalie", name: "Natalie", icon: "🎵", googleNewsSite: "natalie.mu", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "billboardjapan", name: "Billboard Japan", icon: "📈", googleNewsSite: "billboard-japan.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "soompi", name: "Soompi", icon: "🇰🇷", googleNewsSite: "soompi.com", newsLocale: .englishUS, usesStrictKeywordMatching: true),
        PlatformDefinition(id: "allkpop", name: "allkpop", icon: "🎤", googleNewsSite: "allkpop.com", newsLocale: .englishUS, usesStrictKeywordMatching: true),
        PlatformDefinition(id: "kpopofficial", name: "KpopOfficial", icon: "🗓️", googleNewsSite: "kpopofficial.com", newsLocale: .englishUS, usesStrictKeywordMatching: true),
        PlatformDefinition(id: "barks", name: "BARKS", icon: "🎸", googleNewsSite: "barks.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "custom", name: "Custom Feeds", icon: "🌐")
    ]

    static func definition(for id: String) -> PlatformDefinition? {
        let normalized = normalizeID(id)
        return all.first { $0.id == normalized }
    }

    static var googleNewsSources: [PlatformDefinition] {
        all.filter { $0.googleNewsSite != nil }
    }

    static var defaultSubscribedIDs: [String] {
        all.map(\.id)
    }

    static var strictKeywordPlatformIDs: Set<String> {
        Set(all.filter(\.usesStrictKeywordMatching).map(\.id))
    }

    static var mediaPlatformIDs: Set<String> {
        Set(all.filter(\.isMediaPlatform).map(\.id))
    }

    static var activityDateWindowPlatformIDs: Set<String> {
        Set(all.filter(\.usesActivityDateWindow).map(\.id))
    }

    static var dateCutoffExemptPlatformIDs: Set<String> {
        Set(all.filter(\.skipDateCutoff).map(\.id))
    }

    static func normalizeIDs(_ ids: [String]) -> [String] {
        let known = Set(all.map(\.id))
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = normalizeID(raw)
            guard known.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func normalizeID(_ rawID: String) -> String {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch id {
        case "x":
            return "twitter"
        case "news:mdpr":
            return "mdpr"
        case "news:yahoo_ent":
            return "yahoonews"
        default:
            if let definition = all.first(where: { $0.rawPlatformValues.contains(id) }) {
                return definition.id
            }
            if id.hasPrefix("news:") { return "news" }
            return id
        }
    }
}
