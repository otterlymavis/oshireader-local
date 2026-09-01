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

/// Rebuildable, profile-scoped cache for rotating 2ch.sc subject listings.
actor FiveChIndexStore {
    static let shared = FiveChIndexStore()
    static let version = 1
    static let boardCap = 900
    static let entriesPerBoardCap = 500
    static let totalEntryCap = 10_000
    static let catalogTTL: TimeInterval = 24 * 60 * 60
    struct BoardSnapshot: Codable, Sendable { var boardURL: String; var fetchedAt: Date; var entries: [FiveChSubjectEntry] }
    struct State: Codable, Sendable { var version: Int; var catalogFetchedAt: Date?; var boards: [String]; var snapshots: [String: BoardSnapshot]; var cursor: Int }
    private var states: [UUID: State] = [:]
    private static let empty = State(version: version, catalogFetchedAt: nil, boards: [], snapshots: [:], cursor: 0)

    func state(for profileID: UUID) -> State {
        if let state = states[profileID] { return state }
        let loaded: State
        do {
            let data = try Data(contentsOf: LocalProfileStore.shared.fileURL(for: "fivech_index", profileID: profileID))
            let value = try JSONDecoder().decode(State.self, from: data)
            loaded = value.version == Self.version ? Self.capped(value) : Self.empty
        } catch {
            loaded = Self.empty
            try? FileManager.default.removeItem(at: LocalProfileStore.shared.fileURL(for: "fivech_index", profileID: profileID))
        }
        states[profileID] = loaded
        return loaded
    }
    func indexedEntries(for profileID: UUID) -> [FiveChSubjectEntry] { state(for: profileID).snapshots.values.flatMap(\.entries) }
    func catalog(for profileID: UUID) -> (boards: [String], fetchedAt: Date?) { let value = state(for: profileID); return (value.boards, value.catalogFetchedAt) }
    func shouldRefreshCatalog(for profileID: UUID, now: Date) -> Bool { state(for: profileID).catalogFetchedAt.map { now.timeIntervalSince($0) >= Self.catalogTTL } ?? true }
    func updateCatalog(_ boards: [String], fetchedAt: Date, profileID: UUID) {
        var value = state(for: profileID); value.boards = Array(NSOrderedSet(array: boards).compactMap { $0 as? String }.prefix(Self.boardCap)); value.snapshots = value.snapshots.filter { value.boards.contains($0.key) }; value.catalogFetchedAt = fetchedAt; value.cursor = value.boards.isEmpty ? 0 : min(value.cursor, value.boards.count - 1); commit(value, profileID: profileID)
    }
    func nextBatch(for profileID: UUID, count: Int) -> (boards: [String], start: Int) {
        let value = state(for: profileID); guard !value.boards.isEmpty else { return ([], 0) }; let start = value.cursor % value.boards.count
        return ((0..<min(count, value.boards.count)).map { value.boards[(start + $0) % value.boards.count] }, start)
    }
    func commit(snapshots: [BoardSnapshot], nextCursor: Int, profileID: UUID) {
        var value = state(for: profileID); for snapshot in snapshots { value.snapshots[snapshot.boardURL] = snapshot }; value.cursor = value.boards.isEmpty ? 0 : nextCursor % value.boards.count; commit(Self.capped(value), profileID: profileID)
    }
    private func commit(_ value: State, profileID: UUID) {
        states[profileID] = value
        let url = LocalProfileStore.shared.fileURL(for: "fivech_index", profileID: profileID)
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".fivech-index-\(UUID().uuidString).tmp")
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            // A failed replace/move leaves the staging file behind — remove it
            // so `.fivech-index-*.tmp` doesn't accumulate in the profile dir.
            try? FileManager.default.removeItem(at: temp)
        }
    }
    private static func capped(_ input: State) -> State {
        var value = input; value.version = version; value.boards = Array(input.boards.prefix(boardCap)); var snapshots: [String: BoardSnapshot] = [:]; var total = 0
        for board in value.boards { guard let snapshot = input.snapshots[board], total < totalEntryCap else { continue }; let entries = Array(snapshot.entries.prefix(min(entriesPerBoardCap, totalEntryCap - total))); snapshots[board] = BoardSnapshot(boardURL: board, fetchedAt: snapshot.fetchedAt, entries: entries); total += entries.count }
        value.snapshots = snapshots; value.cursor = value.boards.isEmpty ? 0 : value.cursor % value.boards.count; return value
    }
}

enum SourceRefreshOutcome: Equatable {
    case received
    case stale
    case noResults
    case failed(SourceRefreshFailure)
    /// Deliberately skipped this refresh — see
    /// `RefreshDiagnostics.sourcesInCooldown` — rather than actually
    /// checked and found empty/failed.
    case cooldown
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
            // .cooldown means "known broken, deliberately not rechecked this
            // cycle" — it must still read as a failure, or the toolbar
            // warning and "some sources incomplete" messaging silently go
            // quiet for a source that's still actually broken, which is the
            // opposite of what surfacing .cooldown was for.
            case .stale, .failed, .cooldown: return true
            case .received, .noResults: return false
            }
        }
    }
}

struct IngestionReport {
    let items: [FeedItem]
    let sourceStatuses: [SourceRefreshStatus]
}

enum IngestionFetchScope {
    case foreground
    case background
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

struct FiveChSubjectEntry: Codable, Sendable, Equatable {
    let host: String
    let board: String
    let threadID: String
    let title: String
    let posts: Int
    let boardURL: URL
}

/// Caches the anonymous TVer platform token (keyword-independent) so a
/// multi-alias term doesn't mint one per `fetchTVer` call. Concurrent misses
/// on a cold cache may each create a token — the same as today for that first
/// burst — but every later refresh within the TTL reuses one.
private actor TVerTokenCache {
    private struct Entry { let uid: String; let token: String; let expiresAt: Date }
    private var entry: Entry?

    func cached(now: Date) -> (uid: String, token: String)? {
        guard let entry, entry.expiresAt > now else { return nil }
        return (entry.uid, entry.token)
    }

    func store(uid: String, token: String, expiresAt: Date) {
        entry = Entry(uid: uid, token: token, expiresAt: expiresAt)
    }

    func invalidate() {
        entry = nil
    }
}

private actor FiveChSubjectCache {
    private struct CachedValue {
        let entries: [FiveChSubjectEntry]
        let expiresAt: Date
    }

    private var values: [String: CachedValue] = [:]
    private var inFlight: [String: Task<[FiveChSubjectEntry]?, Never>] = [:]

    func entries(
        for url: URL,
        now: Date,
        ttl: TimeInterval,
        loader: @escaping @Sendable () async -> [FiveChSubjectEntry]?
    ) async -> [FiveChSubjectEntry]? {
        let key = url.absoluteString
        if let cached = values[key], cached.expiresAt > now {
            return cached.entries
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task { await loader() }
        inFlight[key] = task
        let loaded = await task.value
        inFlight[key] = nil
        if let loaded {
            values[key] = CachedValue(entries: loaded, expiresAt: now.addingTimeInterval(ttl))
        }
        return loaded
    }
}

private actor RequestStartPacer {
    private let intervalNanoseconds: UInt64
    private var nextStartNanoseconds: UInt64 = 0

    init(intervalNanoseconds: UInt64) {
        self.intervalNanoseconds = intervalNanoseconds
    }

    func wait(
        deadline: Date?,
        sleeper: @escaping IngestionService.PacingSleeper
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let deadline, deadline.timeIntervalSinceNow <= 0 {
            return false
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let reservedStart = max(now, nextStartNanoseconds)
        let (nextStart, overflowed) = reservedStart.addingReportingOverflow(intervalNanoseconds)
        nextStartNanoseconds = overflowed ? UInt64.max : nextStart
        let delay = reservedStart > now ? reservedStart - now : 0
        if delay > 0 {
            let boundedDelay: UInt64
            if let deadline {
                let remainingNanoseconds = max(0, deadline.timeIntervalSinceNow * 1_000_000_000)
                guard remainingNanoseconds > 0 else { return false }
                boundedDelay = min(delay, UInt64(remainingNanoseconds))
            } else {
                boundedDelay = delay
            }
            do {
                try await sleeper(boundedDelay)
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        if let deadline, deadline.timeIntervalSinceNow <= 0 {
            return false
        }
        return true
    }
}

/// On-device ingestion for public RSS feeds, JSON APIs, and pages.
///
/// Each `fetch*` method reads directly from the phone.
/// `ingest(term:platforms:)` fans them out for a single watch term and returns
/// flat `FeedItem`s ready for `LocalDB.mergeItems`.
final class IngestionService {
    static let freshnessWindow: TimeInterval = 10 * 24 * 60 * 60
    // Match the front page's six-month range without treating older items as fresh.
    private static let newsLookbackDays = FeedDatePolicy.maximumLookbackDays
    private static let newsMaximumAge = FeedDatePolicy.maximumLookbackAge
    static let googleNewsHistoricalLookbackYears = 10
    static let twitterPublicIndexSource = "twitter_public_index"
    static let fiveChVerifiedActivitySource = "2ch_sc_dat"
    static let fiveChThreadCreatedSource = "2ch_sc_thread_created"
    // Google News RSS's pubDate reflects when Google indexed/re-surfaced the
    // page, not the page's real publish date, for sources that don't expose
    // reliable article metadata (an unrestricted keyword search, or a
    // fallback for a platform whose own dates are just thread/post creation
    // time). Tag those so notifications can skip them while still trusting
    // the dated RSS from real news sites (Yahoo News, Oricon, etc.).
    static let unverifiedDateGoogleNewsSource = "google_news_unverified_date"
    static let shared = IngestionService(classifyFreshness: true)
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias RetrySleeper = @Sendable (UInt64) async -> Void
    typealias PacingSleeper = @Sendable (UInt64) async throws -> Void

    private let requestExecutor: RequestExecutor
    private let retrySleeper: RetrySleeper
    private let pacingSleeper: PacingSleeper
    private let classifyFreshness: Bool
    private let now: @Sendable () -> Date
    private let fiveChSubjectCache = FiveChSubjectCache()
    private let fiveChSubjectLimiter = RequestLimiter(limit: 4)
    private let fiveChDatLimiter = RequestLimiter(limit: 3)
    private let tverDetailLimiter = RequestLimiter(limit: 4)
    private let tverTokenCache = TVerTokenCache()
    /// The anonymous TVer platform token is keyword-independent and stays
    /// valid well beyond one refresh, so cache it instead of minting a fresh
    /// one per keyword *and* per alias (up to 5 `create` POSTs per term).
    private static let tverTokenTTL: TimeInterval = 30 * 60
    private let googleNewsPacer = RequestStartPacer(intervalNanoseconds: 200_000_000)
    private static let maximumTransportAttempts = 2
    private static let retryDelayNanoseconds: UInt64 = 100_000_000
    private static let titleCleanupRegexLock = NSLock()
    private static var titleCleanupRegexes: [String: NSRegularExpression] = [:]
    private static let defaultTitleCleanupPatterns = [
        #"\s*\([^)]*ニュース\)\s*[-|]\s*Yahoo!ニュース\s*$"#,
        #"\s*[-|]\s*Yahoo!ニュース\s*$"#,
        #"\s*[-|]\s*(?:Bing|Google)\s*$"#
    ]
    private static let generalRegexLock = NSLock()
    private static var generalRegexes: [String: NSRegularExpression] = [:]
    private static let pathComponentAllowedCharacters: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()
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
    private static let youTubeFallbackMaximumAge = FeedDatePolicy.maximumLookbackAge
    private static let fiveChDirectBudget: TimeInterval = 12
    private static let fiveChSubjectCacheTTL: TimeInterval = 5 * 60
    private static let fiveChResultLimit = 25
    private static let fiveChRequestTimeout: TimeInterval = 8
    private static let fiveChHeaders = [
        "User-Agent": "Monazilla/1.00 OshiReader/1.0",
        "Accept": "text/plain,text/html;q=0.8,*/*;q=0.5",
        "Accept-Language": "ja,en;q=0.9",
    ]
    private static let fiveChBoardURLs: [URL] = [
        "https://toro.2ch.sc/nogizaka/",
        "https://tarte.2ch.sc/keyakizaka46/",
        "https://awabi.2ch.sc/akb/",
        "https://tarte.2ch.sc/akbsaloon/",
        "https://tarte.2ch.sc/world48/",
        "https://nozomi.2ch.sc/idol/",
        "https://awabi.2ch.sc/uraidol/",
        "https://anago.2ch.sc/indieidol/",
        "https://anago.2ch.sc/netidol/",
        "https://tarte.2ch.sc/idolplus/",
        "https://anago.2ch.sc/geino/",
        "https://hayabusa3.2ch.sc/mnewsalpha/",
        "https://hayabusa3.2ch.sc/mnewsplus/",
        "https://anago.2ch.sc/news5plus/",
        "https://sweet.2ch.sc/headline/",
        "https://ai.2ch.sc/newsalpha/",
        "https://ai.2ch.sc/newsplus/",
        "https://nozomi.2ch.sc/snsplus/",
        "https://hayabusa3.2ch.sc/news/",
        "https://hayabusa3.2ch.sc/news4viptasu/",
        "https://ikura.2ch.sc/musicnews/",
        "https://awabi.2ch.sc/drama/",
        "https://awabi.2ch.sc/cinema/",
        "https://anago.2ch.sc/tvsaloon/",
        "https://toro.2ch.sc/tv/",
        "https://awabi.2ch.sc/tvd/",
        "https://nozomi.2ch.sc/nhkdrama/",
        "https://anago.2ch.sc/cm/",
        "https://anago.2ch.sc/actor/",
        "https://anago.2ch.sc/mendol/",
        "https://toro.2ch.sc/sfx/",
        "https://maguro.2ch.sc/fortune/",
        "https://sweet.2ch.sc/patisserie/",
        "https://anago.2ch.sc/mass/",
        "https://ai.2ch.sc/kokusai/",
        "https://nozomi.2ch.sc/4649/",
        "https://anago.2ch.sc/am/",
        "https://awabi.2ch.sc/musicj/",
        "https://awabi.2ch.sc/musicjm/",
        "https://awabi.2ch.sc/musicjf/",
        "https://toro.2ch.sc/musicjg/",
        "https://awabi.2ch.sc/music/",
        "https://anago.2ch.sc/streaming/",
        "https://anago.2ch.sc/sns/",
    ].compactMap(URL.init(string:))
    private static let fiveChSubjectRegex = try? NSRegularExpression(
        pattern: #"^(\d+)\.dat<>(.+?)\s*\((\d+)\)\s*$"#
    )
    private static let fiveChDatDateRegex = try? NSRegularExpression(
        pattern: #"(\d{4})/(\d{2})/(\d{2})\([^)]+\)\s+(\d{2}):(\d{2}):(\d{2})"#
    )

    init(
        requestExecutor: @escaping RequestExecutor = { request in
            try await IngestionNetworking.session.data(for: request)
        },
        retrySleeper: @escaping RetrySleeper = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        pacingSleeper: @escaping PacingSleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        classifyFreshness: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.requestExecutor = requestExecutor
        self.retrySleeper = retrySleeper
        self.pacingSleeper = pacingSleeper
        self.classifyFreshness = classifyFreshness
        self.now = now
    }

    @TaskLocal private static var sourceFailureRecorder: SourceFailureRecorder?
    @TaskLocal private static var sourceID: String?
    @TaskLocal private static var transportAttemptLimit: Int = maximumTransportAttempts
    @TaskLocal private static var requestTimeoutCap: TimeInterval?
    @TaskLocal private static var requestDeadline: Date?

    private let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private let rssUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Caps concurrent news.google.com requests across all in-flight terms.
    private static let googleNewsLimiter = RequestLimiter(limit: 3)
    /// Caps concurrent bing.com/news requests across all in-flight terms.
    private static let bingNewsLimiter = RequestLimiter(limit: 3)
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
    func ingest(
        term: WatchTerm,
        platforms: Set<String>,
        maximumAliases: Int? = nil,
        skippedSourceIDs: Set<String> = [],
        fetchScope: IngestionFetchScope = .foreground
    ) async -> [FeedItem] {
        await ingestReport(
            term: term,
            platforms: platforms,
            maximumAliases: maximumAliases,
            skippedSourceIDs: skippedSourceIDs,
            fetchScope: fetchScope
        ).items
    }

    /// - Parameter skippedSourceIDs: Sources to skip entirely for this call
    ///   (e.g. chronically failing sources currently in cooldown — see
    ///   `RefreshDiagnostics.sourcesInCooldown`), so they aren't retried at
    ///   full frequency every refresh.
    func ingestReport(
        term: WatchTerm,
        platforms: Set<String>,
        maximumAliases: Int? = nil,
        skippedSourceIDs: Set<String> = [],
        fetchScope: IngestionFetchScope = .foreground,
        transportAttemptLimit: Int? = nil,
        requestTimeoutCap: TimeInterval? = nil,
        requestDeadline: Date? = nil
    ) async -> IngestionReport {
        if transportAttemptLimit != nil || requestTimeoutCap != nil || requestDeadline != nil {
            return await Self.$transportAttemptLimit.withValue(max(1, transportAttemptLimit ?? Self.maximumTransportAttempts)) {
                await Self.$requestTimeoutCap.withValue(requestTimeoutCap) {
                    await Self.$requestDeadline.withValue(requestDeadline) {
                        await ingestReport(
                            term: term,
                            platforms: platforms,
                            maximumAliases: maximumAliases,
                            skippedSourceIDs: skippedSourceIDs,
                            fetchScope: fetchScope
                        )
                    }
                }
            }
        }
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
                guard effectivePlatforms.contains(id), !skippedSourceIDs.contains(id) else { return }
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
            add("5ch")         { await self.fetchFiveCh(keyword: $0, mediaOnly: mediaOnly, fetchScope: fetchScope) }
            add("girlschannel") { await self.fetchGirlsChannel(keyword: $0, mediaOnly: mediaOnly) }
            add("mdpr")        { await self.fetchModelPress(keyword: $0, mediaOnly: mediaOnly) }
            add("oricon")      { await self.fetchGoogleNews(keyword: $0, query: "\($0) site:oricon.co.jp", platform: "oricon", mediaType: "article", mediaOnly: mediaOnly, author: "ORICON NEWS", limit: 20, titlePatterns: [#"\s*[-|]\s*(ORICON NEWS|オリコンニュース|オリコン)\s*$"#]) }
            add("yahoonews")   { await self.fetchYahooNews(keyword: $0, mediaOnly: mediaOnly) }
            add("niconico")    { await self.fetchNiconico(keyword: $0) }
            add("note")        { await self.fetchNote(keyword: $0, mediaOnly: mediaOnly) }
            add("ameblo")     {
                let blogs = LocalDB.shared.amebloBlogs
                if blogs.isEmpty {
                    return await self.fetchAmebloDiscovery(keyword: $0, mediaOnly: mediaOnly)
                }
                return await self.fetchAmeblo(keyword: $0, blogs: blogs, mediaOnly: mediaOnly)
            }
            add("natalie")     { await self.fetchDedicatedRSSSource(sourceID: "natalie", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["natalie"] ?? [], mediaOnly: mediaOnly, fallbackSite: "natalie.mu") }
            add("barks")       { await self.fetchDedicatedRSSSource(sourceID: "barks", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["barks"] ?? [], mediaOnly: mediaOnly, fallbackSite: "barks.jp") }
            add("aera")        { await self.fetchDedicatedRSSSource(sourceID: "aera", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["aera"] ?? [], mediaOnly: mediaOnly, fallbackSite: "dot.asahi.com") }
            add("hochi")       { await self.fetchDedicatedRSSSource(sourceID: "hochi", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["hochi"] ?? [], mediaOnly: mediaOnly, fallbackSite: "hochi.news") }
            add("realsound")   { await self.fetchRealSound(keyword: $0, mediaOnly: mediaOnly) }
            add("cinemacafe")  { await self.fetchDedicatedRSSSource(sourceID: "cinemacafe", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["cinemacafe"] ?? [], mediaOnly: mediaOnly, fallbackSite: "cinemacafe.net") }
            add("billboardjapan") { await self.fetchDedicatedRSSSource(sourceID: "billboardjapan", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["billboardjapan"] ?? [], mediaOnly: mediaOnly, fallbackSite: "billboard-japan.com") }
            add("soompi") { await self.fetchDedicatedRSSSource(sourceID: "soompi", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["soompi"] ?? [], mediaOnly: mediaOnly, fallbackSite: "soompi.com", locale: .englishUS) }
            add("kpopofficial") { await self.fetchDedicatedRSSSource(sourceID: "kpopofficial", keyword: $0, feedURLs: Self.dedicatedRSSFeeds["kpopofficial"] ?? [], mediaOnly: mediaOnly, fallbackSite: "kpopofficial.com", locale: .englishUS, supplementStaleWithFallback: true) }
            add("tver")        { await self.fetchTVer(keyword: $0) }
            add("youtube")     { await self.fetchYouTube(keyword: $0) }
            add("twitter")     { await self.fetchTwitter(keyword: $0, mediaOnly: mediaOnly) }

            // Keep the source catalog additive: existing dedicated fetchers
            // above win, while the remaining reference sources use dated RSS
            // results from Google News until they warrant a dedicated parser.
            for source in PlatformRegistry.googleNewsSources where
                !["5ch", "girlschannel", "mdpr", "oricon", "yahoonews", "twitter", "ameblo", "natalie", "barks", "aera", "hochi", "realsound", "cinemacafe", "billboardjapan", "soompi", "kpopofficial"].contains(source.id) {
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
        item.with(watch_term_keyword: keyword)
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
        // Publisher feeds already used by the backend-free target remain
        // primary; the shared Plus RSS-first routes below use the same URLs.
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
        "soompi": [
            "https://www.soompi.com/feed",
        ],
        "natalie": [
            "https://natalie.mu/music/feed/news",
            "https://natalie.mu/tv/feed/news",
        ],
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
                await self.fetchGoogleNews(
                    keyword: keyword,
                    query: keyword,
                    platform: "news",
                    mediaType: "article",
                    mediaOnly: false,
                    source: Self.unverifiedDateGoogleNewsSource,
                    allowsBingFallback: false
                )
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
            guard classifyFreshness else { return all }
            return all.filter { item in
                guard let publishedAt = parseISO8601Date(item.published_at) else { return false }
                return self.isWithinFreshnessWindow(publishedAt, maximumAge: Self.newsMaximumAge)
            }
        }
    }

    private func fetchDedicatedRSSSource(
        sourceID: String,
        keyword: String,
        feedURLs: [String],
        mediaOnly: Bool,
        fallbackSite: String? = nil,
        locale: PlatformDefinition.NewsLocale = .japan,
        supplementStaleWithFallback: Bool = false
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
                              let publishedAt = self.dedicatedPublishedDate(entry.pubDate, sourceID: sourceID),
                              self.matchesKeyword(
                                title: entry.title,
                                desc: [entry.description, entry.author].compactMap { $0 }.joined(separator: " "),
                                kw: keyword
                              ) else {
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
                            author: entry.author,
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

            return (
                dedupedSortedCapped(all),
                parsedAnyFeed,
                failedAnyFeed,
                hasFallbackEligibleFailure
            )
        }

        let dedicatedItems = dedicatedResult.0
        if !dedicatedItems.isEmpty {
            let newestPublishedAt = dedicatedItems
                .compactMap { parseISO8601Date($0.published_at) }
                .max() ?? .distantPast
            guard supplementStaleWithFallback,
                  classifyFreshness,
                  newestPublishedAt < now().addingTimeInterval(-Self.freshnessWindow),
                  let fallbackSite,
                  !fallbackSite.isEmpty else {
                return dedicatedItems
            }
            let fallbackItems = await fetchGoogleNews(
                keyword: keyword,
                query: "\(keyword) site:\(fallbackSite)",
                platform: sourceID,
                mediaType: "article",
                mediaOnly: mediaOnly,
                locale: locale,
                source: Self.unverifiedDateGoogleNewsSource
            )
            return dedupedSortedCapped(dedicatedItems + fallbackItems)
        }
        if dedicatedResult.1 && !dedicatedResult.2 { return [] }
        if dedicatedResult.2 && !dedicatedResult.3 { return [] }
        guard let fallbackSite, !fallbackSite.isEmpty else { return [] }
        return await fetchGoogleNews(
            keyword: keyword,
            query: "\(keyword) site:\(fallbackSite)",
            platform: sourceID,
            mediaType: "article",
            mediaOnly: mediaOnly,
            locale: locale,
            source: Self.unverifiedDateGoogleNewsSource
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
        return dedupedSortedCapped(results.flatMap(\.1))
    }

    private func fetchAmebloDiscovery(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        guard !mediaOnly else { return [] }
        let directItems = await fetchAmebloSearch(keyword: keyword)
        if !directItems.isEmpty { return directItems }
        return await fetchGoogleNews(
            keyword: keyword,
            query: "\(keyword) site:ameblo.jp",
            platform: "ameblo",
            mediaType: "article",
            mediaOnly: false,
            source: Self.unverifiedDateGoogleNewsSource
        )
    }

    private func fetchAmebloSearch(keyword: String) async -> [FeedItem] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowedCharacters),
              let url = URL(string: "https://search.ameba.jp/search/\(encoded).html"),
              case .success(let data, _) = await httpGET(
                url,
                headers: ["User-Agent": browserUA, "Accept-Language": "ja,en;q=0.9"],
                timeout: 15
              ),
              let html = String(data: data, encoding: .utf8),
              let state = extractJSONObject(after: "window.__STATE__=", in: html),
              let blogEntry = state["blogEntry"] as? [String: Any],
              let entryMap = blogEntry["blogEntryMap"] as? [String: Any] else {
            return []
        }

        var seen = Set<String>()
        var items = [FeedItem]()
        for key in entryMap.keys.sorted() {
            guard let raw = entryMap[key] as? [String: Any],
                  let itemID = sourceString(raw["entryId"]),
                  seen.insert(itemID).inserted,
                  let title = cleanDisplayText(sourceString(raw["entryTitle"])),
                  !title.isEmpty else { continue }
            let content = cleanDisplayText(sourceString(raw["entryContent"]))
            let blogTitle = cleanDisplayText(sourceString(raw["blogTitle"]))
            let context = [content, blogTitle].compactMap { $0 }.joined(separator: " ")
            guard matchesKeyword(title: title, desc: context, kw: keyword) else { continue }

            let amebaID = sourceString(raw["amebaId"])
            let rawURL = sourceString(raw["url"])
            let itemURL: String
            if let amebaID {
                itemURL = "https://ameblo.jp/\(amebaID)/entry-\(itemID).html"
            } else if let rawURL {
                itemURL = rawURL
            } else {
                continue
            }
            let publishedDate = [
                raw["entryUpdatedDatetime"], raw["updatedTime"], raw["updatedAt"],
                raw["entryCreatedDatetime"], raw["publishedTime"]
            ].compactMap(amebloDate).max()
            guard let publishedDate else { continue }
            if classifyFreshness {
                guard isWithinFreshnessWindow(publishedDate) else { continue }
            }
            let displayTitle = matchesKeyword(title: title, desc: "", kw: keyword) || content == nil
                ? title
                : "\(title) - \(content ?? "")"
            items.append(FeedItem(
                id: "ameblo:\(itemID)",
                platform: "ameblo",
                url: itemURL,
                title: displayTitle,
                content_text: content,
                author: blogTitle,
                thumbnail_url: sourceString(raw["firstImageUrl"]),
                media_type: "article",
                published_at: isoString(publishedDate),
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "ameba_search"
            ))
        }
        return Array(sortedByPublishedDate(items).prefix(25))
    }

    private func amebloDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        guard let string = sourceString(value) else { return nil }
        return parseISO8601Date(string)
    }

    private func extractJSONObject(after marker: String, in text: String) -> [String: Any]? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let suffix = text[markerRange.upperBound...]
        guard let start = suffix.firstIndex(of: "{") else { return nil }
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start
        while index < suffix.endIndex {
            let character = suffix[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = suffix.index(after: index)
                    guard let data = String(suffix[start..<end]).data(using: .utf8) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
            }
            index = suffix.index(after: index)
        }
        return nil
    }

    private func fetchRealSound(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        guard !mediaOnly else { return [] }
        let directItems = await fetchRealSoundSearch(keyword: keyword)
        if !directItems.isEmpty { return directItems }
        return await fetchDedicatedRSSSource(
            sourceID: "realsound",
            keyword: keyword,
            feedURLs: Self.dedicatedRSSFeeds["realsound"] ?? [],
            mediaOnly: false,
            fallbackSite: "realsound.jp"
        )
    }

    private func fetchRealSoundSearch(keyword: String) async -> [FeedItem] {
        guard var components = URLComponents(string: "https://realsound.jp/") else { return [] }
        components.queryItems = [URLQueryItem(name: "s", value: keyword)]
        guard let url = components.url,
              case .success(let data, _) = await httpGET(url, timeout: 12),
              let html = String(data: data, encoding: .utf8),
              let articleRegex = Self.generalRegex(for: #"(?is)<article[^>]*class=[\"'][^\"']*\bentry-summary\b[^\"']*[\"'][^>]*>(.*?)</article>"#) else {
            return []
        }

        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var items = [FeedItem]()
        for match in articleRegex.matches(in: html, range: range) {
            guard items.count < 25,
                  let blockRange = Range(match.range(at: 1), in: html) else { continue }
            let block = String(html[blockRange])
            guard let titleMatch = regexGroups(
                block,
                #"(?is)<h3[^>]*class=[\"'][^\"']*\bentry-title\b[^\"']*[\"'][^>]*>.*?<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#
            ),
                  let title = cleanDisplayText(titleMatch[1]),
                  let itemURL = URL(string: titleMatch[0], relativeTo: URL(string: "https://realsound.jp/"))?.absoluteURL.absoluteString else { continue }
            let excerpt = regexGroups(
                block,
                #"(?is)<[^>]*class=[\"'][^\"']*\bentry-excerpt\b[^\"']*[\"'][^>]*>(.*?)</[^>]+>"#
            )?.first.flatMap { cleanDisplayText($0) }
            guard matchesKeyword(title: title, desc: excerpt ?? "", kw: keyword) else { continue }
            let dateValue = regexGroups(block, #"(?is)<time[^>]*datetime=[\"']([^\"']+)[\"']"#)?.first
            guard let publishedDate = realSoundSearchDate(dateValue) else { continue }
            if classifyFreshness {
                guard isWithinFreshnessWindow(publishedDate) else { continue }
            }
            guard seen.insert(itemURL).inserted else { continue }
            let author = regexGroups(
                block,
                #"(?is)<[^>]*class=[\"'][^\"']*\bentry-author\b[^\"']*[\"'][^>]*>(.*?)</[^>]+>"#
            )?.first.flatMap { cleanDisplayText($0) }
            let thumbnail = regexGroups(block, #"(?is)<img[^>]*src=[\"']([^\"']+)[\"']"#)?.first
                .flatMap { URL(string: $0, relativeTo: URL(string: "https://realsound.jp/"))?.absoluteURL.absoluteString }
            items.append(FeedItem(
                id: "realsound:\(stableId(itemURL))",
                platform: "realsound",
                url: itemURL,
                title: title,
                content_text: excerpt,
                author: author,
                thumbnail_url: thumbnail,
                media_type: "article",
                published_at: isoString(publishedDate),
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "realsound_search"
            ))
        }
        return sortedByPublishedDate(items)
    }

    /// realsound.jp's `<time datetime>` values omit a UTC/offset suffix when
    /// they're bare Japan wall-clock timestamps, so — unlike the shared
    /// `parseISO8601Date` naive-formatter fallbacks, which assume UTC — these
    /// need Asia/Tokyo. Built once and reused rather than allocated per call.
    private static let realSoundNaiveFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = format
        return formatter
    }

    private func realSoundSearchDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let date = parseISO8601Date(value), value.range(of: #"(?:Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil {
            return date
        }
        return Self.realSoundNaiveFormatters.lazy.compactMap { $0.date(from: value) }.first
    }

    // MARK: - 5ch (bounded direct 2ch.sc scan, Google News fallback)

    private func fetchFiveCh(
        keyword: String,
        mediaOnly: Bool,
        fetchScope: IngestionFetchScope
    ) async -> [FeedItem] {
        if mediaOnly { return [] }
        if fetchScope == .background {
            return await fetchFiveChGoogleNews(keyword: keyword)
        }

        let directItems = await Self.$transportAttemptLimit.withValue(1) {
            await fetchFiveChDirect(keyword: keyword)
        }
        if !directItems.isEmpty { return directItems }
        return await fetchFiveChGoogleNews(keyword: keyword)
    }

    private func fetchFiveChGoogleNews(keyword: String) async -> [FeedItem] {
        await fetchGoogleNews(
            keyword: keyword,
            query: "\(keyword) site:5ch.net",
            platform: "5ch",
            mediaType: "text",
            mediaOnly: false,
            source: Self.unverifiedDateGoogleNewsSource
        )
    }

    private func fetchFiveChDirect(keyword: String) async -> [FeedItem] {
        let localDeadline = Date().addingTimeInterval(Self.fiveChDirectBudget)
        let deadline = min(Self.requestDeadline ?? localDeadline, localDeadline)
        var seen = Set<String>()
        var hits = [FiveChSubjectEntry]()

        let profileID = LocalProfileStore.shared.currentProfileIDThreadSafe
        let indexed = await FiveChIndexStore.shared.indexedEntries(for: profileID)
        let catalog = await FiveChIndexStore.shared.catalog(for: profileID)
        let indexedBoards = catalog.boards.compactMap(URL.init(string:))
        let boards = Array(Set(Self.fiveChBoardURLs + indexedBoards)).sorted { $0.absoluteString < $1.absoluteString }

        for entry in indexed where matchesKeyword(title: entry.title, desc: "", kw: keyword) {
            let key = "\(entry.host)|\(entry.board)|\(entry.threadID)"
            if seen.insert(key).inserted { hits.append(entry) }
        }

        await withTaskGroup(of: [FiveChSubjectEntry].self) { group in
            for boardURL in boards {
                group.addTask {
                    guard !Task.isCancelled, Date() < deadline,
                          await self.fiveChSubjectLimiter.acquire() else { return [] }
                    guard !Task.isCancelled, Date() < deadline else {
                        await self.fiveChSubjectLimiter.release()
                        return []
                    }
                    let entries = await self.fiveChSubjectCache.entries(
                        for: boardURL,
                        now: self.now(),
                        ttl: Self.fiveChSubjectCacheTTL
                    ) {
                        await self.fetchFiveChSubject(boardURL, deadline: deadline)
                    } ?? []
                    await self.fiveChSubjectLimiter.release()
                    return entries
                }
            }

            for await entries in group {
                guard !Task.isCancelled, Date() < deadline else {
                    group.cancelAll()
                    break
                }
                for entry in entries where matchesKeyword(title: entry.title, desc: "", kw: keyword) {
                    let key = "\(entry.host)|\(entry.board)|\(entry.threadID)"
                    guard seen.insert(key).inserted else { continue }
                    hits.append(entry)
                    if hits.count >= Self.fiveChResultLimit {
                        group.cancelAll()
                        break
                    }
                }
                if hits.count >= Self.fiveChResultLimit { break }
            }
        }

        // Refresh the rotating cache after the live subject fan-out so the
        // shared four-slot subject limiter remains a strict global cap.
        let hasIndexedCatalogBoards = catalog.boards.contains { indexedBoard in
            !Self.fiveChBoardURLs.contains(where: { $0.absoluteString == indexedBoard })
        }
        if hasIndexedCatalogBoards, !Task.isCancelled, Date() < deadline {
            await maintainFiveChIndex(profileID: profileID, deadline: deadline)
        }
        guard !hits.isEmpty, !Task.isCancelled, Date() < deadline else { return [] }
        return await withTaskGroup(of: FeedItem?.self) { group in
            for hit in hits.prefix(Self.fiveChResultLimit) {
                group.addTask {
                    guard !Task.isCancelled, Date() < deadline,
                          await self.fiveChDatLimiter.acquire() else { return nil }
                    guard !Task.isCancelled, Date() < deadline else {
                        await self.fiveChDatLimiter.release()
                        return nil
                    }
                    let item = await self.makeFiveChItem(hit, keyword: keyword, deadline: deadline)
                    await self.fiveChDatLimiter.release()
                    return item
                }
            }

            var items = [FeedItem]()
            for await item in group {
                guard !Task.isCancelled, Date() < deadline else {
                    group.cancelAll()
                    break
                }
                if let item { items.append(item) }
            }
            return dedupedSortedCapped(items)
        }
    }

    private func fetchFiveChSubject(_ boardURL: URL, deadline: Date) async -> [FiveChSubjectEntry]? {
        guard let url = URL(string: "subject.txt", relativeTo: boardURL)?.absoluteURL,
              let data = await fetchFiveChData(url, deadline: deadline),
              let text = decodeFiveChText(data) else { return nil }
        let entries = parseFiveChSubject(text, boardURL: boardURL)
        return entries.isEmpty && !text.contains(".dat<>") ? nil : entries
    }

    /// Advances the disposable profile-scoped board index. Failures are
    /// intentionally swallowed: this is maintenance, not a feed source.
    func maintainFiveChIndex(profileID: UUID, deadline: Date) async {
        guard !Task.isCancelled, Date() < deadline else { return }
        let store = FiveChIndexStore.shared
        let now = now()
        let existingCatalog = await store.catalog(for: profileID)
        if existingCatalog.boards.isEmpty {
            await store.updateCatalog(Self.fiveChBoardURLs.map(\.absoluteString), fetchedAt: .distantPast, profileID: profileID)
            guard let menuURL = URL(string: "https://menu.2ch.sc/bbsmenu.html"),
                  let data = await fetchFiveChData(menuURL, deadline: deadline),
                  let text = decodeFiveChText(data) else { return }
            let boards = Self.parseFiveChBBsmenu(text)
            if !boards.isEmpty { await store.updateCatalog(boards, fetchedAt: now, profileID: profileID) }
        }
        if await store.shouldRefreshCatalog(for: profileID, now: now),
           let menuURL = URL(string: "https://menu.2ch.sc/bbsmenu.html"),
           let data = await fetchFiveChData(menuURL, deadline: deadline),
           let text = decodeFiveChText(data) {
            let boards = Self.parseFiveChBBsmenu(text)
            if !boards.isEmpty { await store.updateCatalog(boards, fetchedAt: now, profileID: profileID) }
        }
        let batch = await store.nextBatch(for: profileID, count: 16)
        guard !batch.boards.isEmpty else { return }
        let successful = await withTaskGroup(of: FiveChIndexStore.BoardSnapshot?.self,
                                             returning: [FiveChIndexStore.BoardSnapshot].self) { group in
            for rawBoard in batch.boards {
                group.addTask {
                    guard !Task.isCancelled, Date() < deadline, let boardURL = URL(string: rawBoard),
                          await self.fiveChSubjectLimiter.acquire() else { return nil }
                    guard !Task.isCancelled, Date() < deadline else {
                        await self.fiveChSubjectLimiter.release()
                        return nil
                    }
                    let entries = await self.fetchFiveChSubject(boardURL, deadline: deadline)
                    await self.fiveChSubjectLimiter.release()
                    guard let entries else { return nil }
                    return .init(boardURL: rawBoard, fetchedAt: self.now(), entries: Array(entries.prefix(FiveChIndexStore.entriesPerBoardCap)))
                }
            }
            var completed = [FiveChIndexStore.BoardSnapshot]()
            for await snapshot in group {
                if let snapshot { completed.append(snapshot) }
                if Task.isCancelled || Date() >= deadline { group.cancelAll() }
            }
            return completed
        }
        guard !successful.isEmpty || !Task.isCancelled else { return }
        let next = batch.start + max(successful.count, 1)
        await store.commit(snapshots: successful, nextCursor: next, profileID: profileID)
    }

    static func parseFiveChBBsmenu(_ text: String) -> [String] {
        var result = [String](), seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard let start = value.range(of: "http", options: .caseInsensitive)?.lowerBound else { continue }
            let tail = value[start...]
            let endDouble = tail.firstIndex(of: "\"") ?? tail.endIndex
            let endSingle = tail.firstIndex(of: "'") ?? tail.endIndex
            let end = min(endDouble, endSingle)
            let href = String(tail[..<end])
            guard let url = URL(string: href),
                      let host = url.host?.lowercased(), host.hasSuffix(".2ch.sc"), host != "menu.2ch.sc",
                      !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.scheme = "https"; components?.host = host; components?.query = nil; components?.fragment = nil
            guard var normalized = components?.url?.absoluteString else { continue }
            if !normalized.hasSuffix("/") { normalized += "/" }
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return Array(result.prefix(FiveChIndexStore.boardCap))
    }

    private func parseFiveChSubject(_ text: String, boardURL: URL) -> [FiveChSubjectEntry] {
        guard let regex = Self.fiveChSubjectRegex,
              let host = boardURL.host,
              let board = boardURL.pathComponents.filter({ $0 != "/" }).last else { return [] }
        return text.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let idRange = Range(match.range(at: 1), in: line),
                  let titleRange = Range(match.range(at: 2), in: line),
                  let postsRange = Range(match.range(at: 3), in: line),
                  let posts = Int(line[postsRange]),
                  let title = cleanDisplayText(String(line[titleRange])),
                  !title.isEmpty else { return nil }
            return FiveChSubjectEntry(
                host: host,
                board: board,
                threadID: String(line[idRange]),
                title: title,
                posts: posts,
                boardURL: boardURL
            )
        }
    }

    private func makeFiveChItem(
        _ hit: FiveChSubjectEntry,
        keyword: String,
        deadline: Date
    ) async -> FeedItem? {
        let datURL = URL(string: "dat/\(hit.threadID).dat", relativeTo: hit.boardURL)?.absoluteURL
        let latestPostAt: Date?
        if let datURL,
           let data = await fetchFiveChData(datURL, deadline: deadline),
           let text = decodeFiveChText(data) {
            latestPostAt = parseFiveChLatestPostDate(text)
        } else {
            latestPostAt = nil
        }
        guard let publishedAt = latestPostAt ?? fiveChThreadCreatedAt(hit.threadID) else { return nil }
        let source = latestPostAt == nil
            ? Self.fiveChThreadCreatedSource
            : Self.fiveChVerifiedActivitySource
        let url = "https://\(hit.host)/test/read.cgi/\(hit.board)/\(hit.threadID)/"
        return FeedItem(
            id: "2ch.sc:\(hit.host):\(hit.board):\(hit.threadID)",
            platform: "5ch",
            url: url,
            title: hit.title,
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: isoString(publishedAt),
            watch_term_keyword: keyword,
            fetched_at: nowISO(),
            source: source
        )
    }

    private func fetchFiveChData(_ url: URL, deadline: Date) async -> Data? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let timeout = min(Self.fiveChRequestTimeout, remaining)
        guard case .success(let data, _) = await httpGET(
            url,
            headers: Self.fiveChHeaders,
            timeout: timeout
        ) else { return nil }
        return data
    }

    private func decodeFiveChText(_ data: Data) -> String? {
        String(data: data, encoding: .shiftJIS) ?? String(data: data, encoding: .utf8)
    }

    private func parseFiveChLatestPostDate(_ text: String) -> Date? {
        guard let regex = Self.fiveChDatDateRegex else { return nil }
        for rawLine in text.split(whereSeparator: \Character.isNewline).reversed() {
            let fields = rawLine.split(separator: "<>", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let dateField = String(fields[2])
            let range = NSRange(dateField.startIndex..., in: dateField)
            guard let match = regex.firstMatch(in: dateField, range: range) else { continue }
            let values = (1...6).compactMap { index -> Int? in
                guard let matchRange = Range(match.range(at: index), in: dateField) else { return nil }
                return Int(dateField[matchRange])
            }
            guard values.count == 6 else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 3600)!
            let components = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: values[0], month: values[1], day: values[2],
                hour: values[3], minute: values[4], second: values[5]
            )
            if let date = calendar.date(from: components), date <= now().addingTimeInterval(Self.searchResultFutureGrace) {
                return date
            }
        }
        return nil
    }

    private func fiveChThreadCreatedAt(_ threadID: String) -> Date? {
        guard (9...12).contains(threadID.count),
              threadID.allSatisfy(\.isNumber),
              let timestamp = TimeInterval(threadID) else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        guard date <= now().addingTimeInterval(Self.searchResultFutureGrace) else { return nil }
        return date
    }

    // MARK: - Google News site-filtered RSS (girlschannel, mdpr, oricon, yahoonews, niconico fallback)

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

    // MARK: - GirlsChannel (own keyword-topic listing — carries last-comment time)

    private func fetchGirlsChannel(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        if mediaOnly { return [] }
        if let items = await fetchGirlsChannelTopics(keyword: keyword), !items.isEmpty {
            return items
        }
        // Google News RSS only carries the date it indexed the thread (close
        // to thread-creation time), not the last-reply time — but it's a
        // reasonable fallback if girlschannel's own page is unreachable or
        // its markup changes underneath us.
        return await fetchGoogleNews(keyword: keyword, query: "\(keyword) site:girlschannel.net", platform: "girlschannel", mediaType: "text", mediaOnly: mediaOnly, source: Self.unverifiedDateGoogleNewsSource)
    }

    /// girlschannel.net's own keyword-topic listing shows each topic's
    /// last-comment time next to it — confirmed against live pages: topics
    /// are ordered by creation, but the printed timestamp jumps around as
    /// older threads get bumped by new comments — so it's a real "last
    /// updated" time, unlike Google News RSS's indexing-date pubDate.
    private func fetchGirlsChannelTopics(keyword: String) async -> [FeedItem]? {
        // `.path`'s unencoded setter leaves "/" untouched, so a keyword
        // containing one would silently splice in extra path segments —
        // encode it as a single path component via `percentEncodedPath`.
        guard let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowedCharacters) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "girlschannel.net"
        components.percentEncodedPath = "/topics/keyword/\(encodedKeyword)/"
        components.queryItems = [URLQueryItem(name: "date", value: "")]
        guard let url = components.url,
              case .success(let data, _) = await httpGET(
                url,
                headers: ["User-Agent": browserUA, "Accept-Language": "ja,en;q=0.9"]
              ),
              let html = String(data: data, encoding: .utf8),
              let itemRegex = Self.generalRegex(for: #"<li><a href="(/topics/\d+/)">([\s\S]*?)</a></li>"#),
              let timeRegex = Self.generalRegex(for: #"^(\d{4}/\d{2}/\d{2})\([^)]*\)\s*(\d{2}:\d{2})$"#) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"

        var items = [FeedItem]()
        var seen = Set<String>()
        for match in itemRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard items.count < 25,
                  let pathRange = Range(match.range(at: 1), in: html),
                  let blockRange = Range(match.range(at: 2), in: html) else { continue }
            let path = String(html[pathRange])
            let block = String(html[blockRange])
            guard let rawTitle = regexGroups(block, #"<p class="title">([\s\S]*?)</p>"#)?.first,
                  let title = cleanDisplayText(rawTitle),
                  matchesKeyword(title: title, desc: "", kw: keyword),
                  let rawTime = regexGroups(block, #"<p class="time">([^<]+)</p>"#)?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let timeMatch = timeRegex.firstMatch(in: rawTime, range: NSRange(rawTime.startIndex..., in: rawTime)),
                  let dateRange = Range(timeMatch.range(at: 1), in: rawTime),
                  let clockRange = Range(timeMatch.range(at: 2), in: rawTime),
                  let publishedDate = formatter.date(from: "\(rawTime[dateRange]) \(rawTime[clockRange])"),
                  let articleURL = URL(string: path, relativeTo: url)?.absoluteURL else { continue }
            let absoluteURL = articleURL.absoluteString
            guard seen.insert(absoluteURL).inserted else { continue }
            let thumbnail = regexGroups(block, #"data-src="([^"]+)""#)?.first
            items.append(FeedItem(
                id: "girlschannel:\(stableId(absoluteURL))",
                platform: "girlschannel",
                url: absoluteURL,
                title: title,
                content_text: nil,
                author: nil,
                thumbnail_url: thumbnail,
                media_type: "text",
                published_at: isoString(publishedDate),
                watch_term_keyword: keyword,
                fetched_at: nowISO(),
                source: "girlschannel_keyword"
            ))
        }
        return items
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
        locale: PlatformDefinition.NewsLocale = .japan,
        source: String = "google_news",
        allowsBingFallback: Bool = true
    ) async -> [FeedItem] {
        if mediaOnly { return [] }
        func bingFallback() async -> [FeedItem] {
            await fetchBingNews(
                keyword: keyword,
                query: query,
                platform: platform,
                mediaType: mediaType,
                author: author,
                limit: limit,
                titlePatterns: titlePatterns,
                locale: locale,
                source: source
            )
        }
        // News must cover the front page's six-month range. Bound discovery
        // and parsed dates independently of the ten-day source-health check.
        // Other sources retain their existing discovery behavior.
        guard let initialURL = Self.googleNewsURL(
            query,
            locale: locale,
            recentDays: platform == "news" ? Self.newsLookbackDays : nil
        ),
              let initialEntries = await fetchGoogleNewsEntries(initialURL, locale: locale) else {
            guard allowsBingFallback else { return [] }
            return await bingFallback()
        }
        let initialItems = makeGoogleNewsItems(
            entries: initialEntries,
            keyword: keyword,
            platform: platform,
            mediaType: mediaType,
            author: author,
            limit: limit,
            titlePatterns: titlePatterns,
            source: source
        )
        // An empty News result must stay empty, not retry a ten-year search.
        guard platform != "news" else { return initialItems }
        // Match OshiReader+'s device fallback: widen to a ten-year indexed
        // search only when the normal Google News result has no relevant hit.
        guard initialItems.isEmpty else {
            return initialItems
        }
        // Start the Bing fallback as a plain unstructured Task rather than
        // `async let`: if historical comes back non-empty we return without
        // ever needing Bing's result, and `async let` would implicitly
        // cancel-and-*await* an unconsumed child task at scope exit — still
        // blocking this return on Bing's in-flight round trip. A Task isn't
        // joined automatically, so an early return can leave it to finish
        // (or get cancelled) in the background instead.
        let bingTask: Task<[FeedItem], Never>? = allowsBingFallback ? Task { await bingFallback() } : nil

        if let historicalURL = Self.googleNewsURL(
            query,
            locale: locale,
            recentYears: Self.googleNewsHistoricalLookbackYears
        ), let historicalEntries = await fetchGoogleNewsEntries(historicalURL, locale: locale) {
            let historicalItems = makeGoogleNewsItems(
                entries: historicalEntries,
                keyword: keyword,
                platform: platform,
                mediaType: mediaType,
                author: author,
                limit: limit,
                titlePatterns: titlePatterns,
                source: source
            )
            if !historicalItems.isEmpty {
                bingTask?.cancel()
                return historicalItems
            }
        }
        guard let bingTask else { return [] }
        return await bingTask.value
    }

    private func fetchBingNews(
        keyword: String,
        query: String,
        platform: String,
        mediaType: String,
        author: String?,
        limit: Int,
        titlePatterns: [String],
        locale: PlatformDefinition.NewsLocale,
        source: String
    ) async -> [FeedItem] {
        guard !Task.isCancelled else { return [] }
        guard await Self.bingNewsLimiter.acquire() else { return [] }
        guard !Task.isCancelled else {
            await Self.bingNewsLimiter.release()
            return []
        }
        guard let url = Self.bingNewsURL(query, locale: locale),
              case .success(let entries) = await parseRSS(
                url,
                headers: ["Accept-Language": locale.acceptLanguage]
              ) else {
            await Self.bingNewsLimiter.release()
            return []
        }
        await Self.bingNewsLimiter.release()
        let bingSource = source == Self.unverifiedDateGoogleNewsSource ? source : "bing_news"
        let normalizedEntries = entries.map { entry -> RssItem in
            var normalized = entry
            normalized.link = Self.unwrapBingNewsURL(entry.link)
            return normalized
        }
        return makeGoogleNewsItems(
            entries: normalizedEntries,
            keyword: keyword,
            platform: platform,
            mediaType: mediaType,
            author: author,
            limit: limit,
            titlePatterns: titlePatterns,
            source: bingSource
        )
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
        guard await googleNewsPacer.wait(
            deadline: Self.requestDeadline,
            sleeper: pacingSleeper
        ) else {
            await Self.googleNewsLimiter.release()
            if !Task.isCancelled,
               let deadline = Self.requestDeadline,
               deadline.timeIntervalSinceNow <= 0 {
                await recordFailure(.timeout)
            }
            return nil
        }
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
        titlePatterns: [String],
        source: String = "google_news"
    ) -> [FeedItem] {
        var seen = Set<String>()
        var items = [FeedItem]()
        for entry in entries {
            if items.count >= limit { break }
            guard !entry.link.isEmpty,
                  let publishedAt = validPublishedDate(entry.pubDate),
                  let publishedDate = parseISO8601Date(publishedAt) else { continue }
            if classifyFreshness {
                guard isWithinFreshnessWindow(publishedDate) else { continue }
            }
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
                source: source
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
            URLQueryItem(name: "targets", value: "title"),
            URLQueryItem(name: "fields", value: "contentId,title,description,userId,channelId,startTime,thumbnailUrl"),
            URLQueryItem(name: "_sort", value: "-startTime"),
            URLQueryItem(name: "_limit", value: "25"),
            URLQueryItem(name: "_context", value: "OshiReader"),
        ]
        if let url = comps.url {
            if case .success(let data, _) = await httpGET(url, headers: ["Accept": "application/json"], timeout: 10) {
                if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let rows = json["data"] as? [[String: Any]] {
                    if rows.isEmpty { return [] }
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
                    // A nonempty payload with no usable rows is malformed, not
                    // an authoritative empty result. Preserve that diagnostic
                    // while allowing the independent RSS routes to recover.
                    await recordFailure(.invalidPayload)
                } else {
                    // Non-JSON body or a missing `data` array means the
                    // primary API itself broke (e.g. a maintenance page) —
                    // record that instead of silently falling through.
                    await recordFailure(.invalidPayload)
                }
            }
        }
        let nativeRSSItems = await fetchNiconicoNativeRSS(keyword: keyword)
        if !nativeRSSItems.isEmpty { return nativeRSSItems }
        // Retain the Plus device-side fallback after its connector-equivalent
        // native routes fail, so local refresh still works when Nico blocks RSS.
        return await fetchGoogleNews(keyword: keyword, query: "\(keyword) site:nicovideo.jp", platform: "niconico", mediaType: "video", mediaOnly: false, source: Self.unverifiedDateGoogleNewsSource)
    }

    private func fetchNiconicoNativeRSS(keyword: String) async -> [FeedItem] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowedCharacters) else {
            return []
        }
        let urls = [
            "https://www.nicovideo.jp/search/\(encoded)?sort=f&order=d&rss=2.0&lang=ja-jp",
            "https://www.nicovideo.jp/tag/\(encoded)?sort=f&order=d&rss=2.0&lang=ja-jp",
        ].compactMap(URL.init(string:))
        return await withTaskGroup(of: [FeedItem].self) { group in
            for url in urls {
                group.addTask {
                    guard case .success(let entries) = await self.parseRSS(
                        url,
                        headers: ["User-Agent": self.browserUA, "Accept-Language": "ja,en;q=0.9"]
                    ) else { return [] }
                    return entries.prefix(25).compactMap { entry -> FeedItem? in
                        guard !entry.link.isEmpty,
                              let publishedAt = self.validPublishedDate(entry.pubDate),
                              self.matchesKeyword(title: entry.title, desc: entry.description, kw: keyword) else {
                            return nil
                        }
                        let contentID = entry.link.split(separator: "/").last.map(String.init) ?? entry.link
                        return FeedItem(
                            id: "niconico:\(contentID)",
                            platform: "niconico",
                            url: entry.link,
                            title: self.cleanedOptionalTitle(entry.title),
                            content_text: nil,
                            author: nil,
                            thumbnail_url: entry.thumbnailUrl,
                            media_type: "video",
                            published_at: publishedAt,
                            watch_term_keyword: keyword,
                            fetched_at: self.nowISO(),
                            source: "niconico_rss"
                        )
                    }
                }
            }
            var all = [FeedItem]()
            for await items in group { all.append(contentsOf: items) }
            return dedupedSortedCapped(all)
        }
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
                content_text: cleanDisplayText(entry.description),
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

    private struct TVerCandidate: Sendable {
        let index: Int
        let id: String
        let title: String
        let contentType: String
        let thumbnailURL: String?
        let author: String?
        let description: String?
        let seriesTitle: String?
        let publishedAt: String?
    }

    private struct TVerDetail: Sendable {
        let description: String?
        let author: String?
        let publishedAt: String?
    }

    private static let searchResultMaximumAge = FeedDatePolicy.maximumLookbackAge
    private static let searchResultFutureGrace: TimeInterval = 24 * 60 * 60

    private func isWithinFreshnessWindow(_ date: Date, maximumAge: TimeInterval = IngestionService.searchResultMaximumAge) -> Bool {
        date >= now().addingTimeInterval(-maximumAge) && date <= now().addingTimeInterval(Self.searchResultFutureGrace)
    }

    private func createTVerToken(baseHeaders: [String: String]) async -> (uid: String, token: String)? {
        guard let createURL = URL(string: "https://platform-api.tver.jp/v2/api/platform_users/browser/create") else { return nil }
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.timeoutInterval = 15
        for (k, v) in baseHeaders { createReq.setValue(v, forHTTPHeaderField: k) }
        createReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = "device_type=pc".data(using: .utf8)

        guard case .success(let cData, let cResp) = await request(createReq),
              (200...299).contains(cResp.statusCode),
              let cJson = (try? JSONSerialization.jsonObject(with: cData)) as? [String: Any],
              let result = cJson["result"] as? [String: Any],
              let uid = result["platform_uid"] as? String,
              let token = result["platform_token"] as? String else {
            return nil
        }
        return (uid, token)
    }

    private func fetchTVer(keyword: String) async -> [FeedItem] {
        let baseHeaders = [
            "User-Agent": browserUA,
            "Origin": "https://tver.jp",
            "Referer": "https://tver.jp/",
        ]
        // 1. An anonymous platform token — reused from cache across keywords.
        let credentials: (uid: String, token: String)
        if let cached = await tverTokenCache.cached(now: now()) {
            credentials = cached
        } else {
            guard let created = await createTVerToken(baseHeaders: baseHeaders) else {
                await recordFailure(.invalidPayload)
                return []
            }
            await tverTokenCache.store(
                uid: created.uid,
                token: created.token,
                expiresAt: now().addingTimeInterval(Self.tverTokenTTL)
            )
            credentials = created
        }
        let uid = credentials.uid
        let token = credentials.token

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
            // A cached token that the search endpoint rejects would otherwise
            // wedge every TVer keyword until the TTL elapsed.
            await tverTokenCache.invalidate()
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

        let candidates = episodes.prefix(25).enumerated().compactMap { index, episode in
            makeTVerCandidate(episode, index: index)
        }
        guard !candidates.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, FeedItem?).self) { group in
            for candidate in candidates {
                group.addTask {
                    (candidate.index, await self.makeTVerItem(
                        candidate,
                        keyword: keyword,
                        headers: baseHeaders
                    ))
                }
            }

            var resolved = [(Int, FeedItem)]()
            for await (index, item) in group {
                if let item { resolved.append((index, item)) }
            }
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func makeTVerCandidate(_ episode: [String: Any], index: Int) -> TVerCandidate? {
        let content = (episode["content"] as? [String: Any])
            ?? (episode["episode"] as? [String: Any])
            ?? episode
        guard let id = sourceString(content["id"] ?? content["seriesId"] ?? episode["id"]),
              let title = sourceString(content["title"] ?? content["episodeTitle"] ?? content["seriesTitle"]) else {
            return nil
        }
        var thumbnailURL = sourceString(content["thumbnailUrl"] ?? content["thumbnailURL"] ?? content["thumbnail_path"])
        if let value = thumbnailURL, value.hasPrefix("/") {
            thumbnailURL = "https://statics.tver.jp\(value)"
        }
        return TVerCandidate(
            index: index,
            id: id,
            title: title,
            contentType: (sourceString(episode["type"] ?? content["type"]) ?? "").lowercased(),
            thumbnailURL: thumbnailURL,
            author: sourceString(content["broadcasterName"] ?? content["productionProviderName"]),
            description: sourceString(content["description"] ?? content["episodeDescription"]),
            seriesTitle: sourceString(content["seriesTitle"]),
            publishedAt: tverDate(content)
        )
    }

    private func makeTVerItem(
        _ candidate: TVerCandidate,
        keyword: String,
        headers: [String: String]
    ) async -> FeedItem? {
        let listContext = [candidate.description, candidate.author, candidate.seriesTitle]
            .compactMap { $0 }
            .joined(separator: " ")
        let listMatches = matchesKeyword(title: candidate.title, desc: listContext, kw: keyword)
        var detail: TVerDetail?
        if candidate.publishedAt == nil || !listMatches {
            detail = await fetchLimitedTVerDetail(id: candidate.id, headers: headers)
        }

        let matches: Bool
        if let detail {
            let detailContext = [detail.description, detail.author]
                .compactMap { $0 }
                .joined(separator: " ")
            matches = matchesKeyword(
                title: candidate.title,
                desc: [listContext, detailContext].filter { !$0.isEmpty }.joined(separator: " "),
                kw: keyword
            )
        } else {
            matches = listMatches
        }
        guard matches else { return nil }

        guard let publishedAt = candidate.publishedAt ?? detail?.publishedAt,
              let publishedDate = parseISO8601Date(publishedAt) else {
            return nil
        }
        if classifyFreshness {
            guard isWithinFreshnessWindow(publishedDate) else {
                return nil
            }
        }

        let description = detail?.description ?? candidate.description
        var contentParts = [candidate.seriesTitle, description]
            .compactMap { cleanDisplayText($0) }
        var seenContent = Set<String>()
        contentParts = contentParts.filter { seenContent.insert($0).inserted }
        let contentText = contentParts.isEmpty ? nil : contentParts.joined(separator: "\n")
        let url: String
        switch candidate.contentType {
        case "series": url = "https://tver.jp/series/\(candidate.id)"
        case "special": url = "https://tver.jp/specials/\(candidate.id)"
        default: url = "https://tver.jp/episodes/\(candidate.id)"
        }
        return FeedItem(
            id: "tver:\(candidate.id)",
            platform: "tver",
            url: url,
            title: candidate.title,
            content_text: contentText,
            author: candidate.author ?? detail?.author,
            thumbnail_url: candidate.thumbnailURL,
            media_type: "video",
            published_at: isoString(publishedDate),
            watch_term_keyword: keyword,
            fetched_at: nowISO(),
            source: "tver_api"
        )
    }

    private func fetchLimitedTVerDetail(id: String, headers: [String: String]) async -> TVerDetail? {
        guard await tverDetailLimiter.acquire() else { return nil }
        guard !Task.isCancelled else {
            await tverDetailLimiter.release()
            return nil
        }
        if let deadline = Self.requestDeadline, deadline.timeIntervalSinceNow <= 0 {
            await tverDetailLimiter.release()
            return nil
        }
        let detail = await fetchTVerDetail(id: id, headers: headers)
        await tverDetailLimiter.release()
        return detail
    }

    private func fetchTVerDetail(id: String, headers: [String: String]) async -> TVerDetail? {
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowedCharacters),
              let url = URL(string: "https://statics.tver.jp/content/episode/\(encodedID).json") else {
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
        request.timeoutInterval = min(10, Self.requestTimeoutCap ?? 10)
        if let deadline = Self.requestDeadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            request.timeoutInterval = min(request.timeoutInterval, remaining)
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, response) = try await requestExecutor(request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            return TVerDetail(
                description: sourceString(json["description"]),
                author: sourceString(json["broadcastProviderLabel"] ?? json["productionProviderLabel"]),
                publishedAt: tverDate(json)
            )
        } catch {
            return nil
        }
    }

    private func sourceString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
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
        let cutoff = now().addingTimeInterval(-Self.youTubeFallbackMaximumAge)
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
            URLQueryItem(name: "search_query", value: keyword)
        ]
        guard let url = components.url else { return [] }
        guard case .success(let data, _) = await httpGET(url, headers: ["User-Agent": browserUA, "Accept-Language": "ja,ja-JP;q=0.9,en;q=0.8"], timeout: 15) else {
            return []
        }
        guard let html = String(data: data, encoding: .utf8) else {
            return []
        }
        let cutoff = now().addingTimeInterval(-Self.youTubeFallbackMaximumAge)
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
                if let value = Int(hex, radix: 16) {
                    // Non-BMP scalars (emoji, CJK-ext) arrive as a `\uD8xx`
                    // high surrogate followed by a `\uDCxx` low surrogate.
                    // `UnicodeScalar(_:)` rejects a lone surrogate, so pair
                    // them here — otherwise this falls to the literal-`u`
                    // branch and emits garbage.
                    if (0xD800...0xDBFF).contains(value),
                       i + 11 < scalars.count,
                       scalars[i + 6] == "\\", scalars[i + 7] == "u",
                       let low = Int(String(String.UnicodeScalarView(scalars[(i + 8)...(i + 11)])), radix: 16),
                       (0xDC00...0xDFFF).contains(low),
                       let decoded = UnicodeScalar(0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)) {
                        output.append(decoded)
                        i += 12
                    } else if let decoded = UnicodeScalar(value) {
                        output.append(decoded)
                        i += 6
                    } else {
                        output.append(next)
                        i += 2
                    }
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
    /// key matched, in a single recursive walk of `value`. A matched renderer
    /// subtree is not re-walked — a `videoRenderer` never nests another one —
    /// which skips a large chunk of the response tree.
    private func collectDictionaries(named names: [String], in value: Any, into results: inout [String: [[String: Any]]]) {
        if let dict = value as? [String: Any] {
            var matchedKeys = Set<String>()
            for name in names {
                if let match = dict[name] as? [String: Any] {
                    results[name, default: []].append(match)
                    matchedKeys.insert(name)
                }
            }
            for (key, child) in dict where !matchedKeys.contains(key) {
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

    // MARK: - Twitter / X (API v2 recent search with public-index fallback)

    private func fetchTwitter(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        guard let bearer = KeychainHelper.read(.twitterBearerToken) else {
            return await fetchTwitterPublicIndex(keyword: keyword, mediaOnly: mediaOnly)
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
              (200...299).contains(resp.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return await fetchTwitterPublicIndex(keyword: keyword, mediaOnly: mediaOnly)
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
        if !items.isEmpty || mediaOnly { return items }
        return await fetchTwitterPublicIndex(keyword: keyword, mediaOnly: false)
    }

    private func fetchTwitterPublicIndex(keyword: String, mediaOnly: Bool) async -> [FeedItem] {
        guard !mediaOnly else { return [] }
        return await fetchGoogleNews(
            keyword: keyword,
            query: "\(keyword) site:x.com",
            platform: "twitter",
            mediaType: "text",
            mediaOnly: false
        ).map { item in
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
                watch_term_keyword: item.watch_term_keyword,
                fetched_at: item.fetched_at,
                source: Self.twitterPublicIndexSource
            )
        }
    }

    // MARK: - Shared helpers

    private func httpGET(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 12) async -> TransportResult {
        // Always revalidate rather than serving a cached body outright: a
        // stale-but-still-fresh (per Cache-Control) hit would silently mask
        // genuinely new items on the source. This still lets the origin skip
        // re-sending the body via a 304 when nothing changed.
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
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
        let attemptLimit = max(1, Self.transportAttemptLimit)
        var boundedRequest = request
        if let deadline = Self.requestDeadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return await finish(.failure(.timeout)) }
            boundedRequest.timeoutInterval = min(boundedRequest.timeoutInterval, remaining)
        }
        if let cap = Self.requestTimeoutCap {
            boundedRequest.timeoutInterval = min(boundedRequest.timeoutInterval, cap)
        }
        for attempt in 0..<attemptLimit {
            let result: TransportResult
            // Only set for .httpFailure, where retryability depends on the
            // specific status code rather than the (Codable, persisted)
            // failure case, which collapses every non-401/403/429 status.
            var httpFailureIsRetryable: Bool?
            do {
                let (data, response) = try await requestExecutor(boundedRequest)
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
                  attempt + 1 < attemptLimit,
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
        guard case .success(let data, let response) = await httpGET(url, headers: allHeaders, timeout: 12) else {
            return .failure(await currentFailure() ?? .invalidResponse)
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = RSSParserDelegate(sourceURL: response.url ?? url)
        parser.delegate = delegate
        guard parser.parse(), delegate.recognizedFeedRoot else {
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

    static func googleNewsURL(
        _ query: String,
        locale: PlatformDefinition.NewsLocale = .japan,
        recentDays: Int? = nil,
        recentYears: Int? = nil
    ) -> URL? {
        let effectiveQuery: String
        if let recentDays {
            effectiveQuery = "\(query) when:\(recentDays)d"
        } else if let recentYears {
            effectiveQuery = "\(query) when:\(recentYears)y"
        } else {
            effectiveQuery = query
        }
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

    static func bingNewsURL(
        _ query: String,
        locale: PlatformDefinition.NewsLocale = .japan
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.bing.com"
        components.path = "/news/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "rss"),
            URLQueryItem(name: "mkt", value: locale == .englishUS ? "en-US" : "ja-JP"),
        ]
        return components.url
    }

    static func unwrapBingNewsURL(_ value: String) -> String {
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              (host == "bing.com" || host.hasSuffix(".bing.com")),
              components.path.lowercased().hasSuffix("/news/apiclick.aspx"),
              let rawTarget = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return value
        }
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
              let targetURL = URL(string: target),
              ["http", "https"].contains(targetURL.scheme?.lowercased() ?? ""),
              targetURL.host != nil else {
            return value
        }
        return target
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
        keywordMatches(loweredHaystack: "\(title) \(desc)".lowercased(), keyword: kw)
    }

    private func validPublishedDate(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              parseISO8601Date(value) != nil else { return nil }
        return value
    }

    private func dedicatedPublishedDate(_ value: String?, sourceID: String) -> String? {
        guard let publishedAt = validPublishedDate(value) else { return nil }
        // Real Sound currently writes Japan local wall-clock values with a
        // trailing `Z` (for example, an article available at 04:16Z is emitted
        // as 13:16Z). Correct only that source/format combination so a future
        // upstream switch to an explicit +09:00 offset is preserved as-is.
        //
        // This can't be gated on "does the timestamp look future-dated" —
        // that signature only holds for articles published within the last
        // ~9 hours; anything older reads as past-dated either way, so such a
        // guard would silently leave most articles uncorrected.
        guard sourceID == "realsound",
              publishedAt.hasSuffix("Z"),
              let date = parseISO8601Date(publishedAt) else {
            return publishedAt
        }
        return isoString(date.addingTimeInterval(-9 * 60 * 60))
    }

    private func sortedByPublishedDate(_ items: [FeedItem]) -> [FeedItem] {
        items.sorted(by: feedItemSortPrecedes)
    }

    /// Dedupes by `FeedItem.id`, sorts newest-first, and caps to `limit` — the
    /// common tail of every fetcher that merges several source queries.
    private func dedupedSortedCapped(_ items: [FeedItem], limit: Int = 25) -> [FeedItem] {
        var seen = Set<String>()
        return sortedByPublishedDate(items.filter { seen.insert($0.id).inserted }).prefix(limit).map { $0 }
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
        iso8601String(from: date)
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
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }

        // `release()` can hand this slot over *after* the task was cancelled
        // (the onCancel hop lost the race), so `acquired` is `true` for a
        // caller that will now bail on `Task.isCancelled` without calling
        // `release()` — a permanently leaked slot. Give it straight back.
        if acquired, Task.isCancelled {
            release()
            return false
        }
        return acquired
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
