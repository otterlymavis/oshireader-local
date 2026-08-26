import Foundation
import UIKit

enum PushDeliveryState: String, Decodable {
    case inactive
    case active
    case selectionRequired = "selection_required"
}

struct EntitlementStatus: Decodable {
    let is_active: Bool
    let product_id: String?
    let expires_at: String?
    let push_term_limit: Int
    let push_term_count: Int
    let push_delivery_state: PushDeliveryState

    private enum CodingKeys: String, CodingKey {
        case is_active, product_id, expires_at, push_term_limit, push_term_count, push_delivery_state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        is_active = try container.decode(Bool.self, forKey: .is_active)
        product_id = try container.decodeIfPresent(String.self, forKey: .product_id)
        expires_at = try container.decodeIfPresent(String.self, forKey: .expires_at)
        push_term_limit = try container.decodeIfPresent(Int.self, forKey: .push_term_limit) ?? 0
        push_term_count = try container.decodeIfPresent(Int.self, forKey: .push_term_count) ?? 0
        push_delivery_state = try container.decodeIfPresent(PushDeliveryState.self, forKey: .push_delivery_state)
            ?? (is_active ? .active : .inactive)
    }
}

struct BackendWatchTerm: Decodable {
    let id: Int
    let keyword: String
    let aliases: [String]
    let collection_mode: String
    let source_mode: String
    let selected_platforms: [String]
    let is_active: Bool
    let notify_on_new: Bool
    let refresh_tier: String?
    let created_at: String
}

private struct BackendFeedSourceItem: Decodable {
    let id: String
    let platform: String
    let url: String
    let title: String?
    let content_text: String?
    let author: String?
    let thumbnail_url: String?
    let media_type: String?
    let published_at: String
    let source: String?
}

private struct BackendFeedPayload: Decodable {
    let watch_term_keyword: String
    let item: BackendFeedSourceItem
    let matched_at: String

    func localItem(keyword: String) -> FeedItem {
        FeedItem(
            id: item.id,
            platform: item.platform,
            url: item.url,
            title: item.title,
            content_text: item.content_text,
            author: item.author,
            thumbnail_url: item.thumbnail_url,
            media_type: item.media_type ?? "article",
            published_at: item.published_at,
            watch_term_keyword: keyword,
            fetched_at: matched_at,
            source: item.source
        )
    }
}

struct APNSRegistrationResponse: Decodable {
    let is_verified: Bool?
    let verification_error: String?
    let bundle_id: String?
}

struct HostedSourceHealthEntry: Decodable, Identifiable, Equatable {
    let platform: String
    let status: String?
    let last_checked_at: String?
    let last_success_at: String?
    let last_item_count: Int?
    let last_error: String?
    let consecutive_failures: Int
    let jina_checked_at: String?
    let jina_ok: Bool?
    let jina_error: String?

    var id: String { platform }

    private enum CodingKeys: String, CodingKey {
        case platform, status, last_checked_at, last_success_at, last_item_count, last_error
        case consecutive_failures, jina_checked_at, jina_ok, jina_error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = try container.decode(String.self, forKey: .platform)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        last_checked_at = try container.decodeIfPresent(String.self, forKey: .last_checked_at)
        last_success_at = try container.decodeIfPresent(String.self, forKey: .last_success_at)
        last_item_count = try container.decodeIfPresent(Int.self, forKey: .last_item_count)
        last_error = try container.decodeIfPresent(String.self, forKey: .last_error)
        consecutive_failures = try container.decodeIfPresent(Int.self, forKey: .consecutive_failures) ?? 0
        jina_checked_at = try container.decodeIfPresent(String.self, forKey: .jina_checked_at)
        jina_ok = try container.decodeIfPresent(Bool.self, forKey: .jina_ok)
        jina_error = try container.decodeIfPresent(String.self, forKey: .jina_error)
    }
}

private struct HostedSourceHealthResponse: Decodable {
    let sources: [HostedSourceHealthEntry]
}

struct BackendNotificationDelivery: Decodable, Equatable {
    let term_id: Int
    let keyword: String
    let count: Int
    let cleared: Bool
}

struct ClientDiagnosticEvent: Encodable, Equatable {
    let strategy: String
    let status: String
    let item_count: Int
    let added_count: Int
    let detail: String?
}

struct ClientDiagnosticReport: Encodable, Equatable {
    let reason: String
    let environment: String
    let api_base: String
    let app_version: String?
    let build: String?
    let active_terms_count: Int
    let subscribed_platforms: [String]
    let cached_feed_count: Int
    let events: [ClientDiagnosticEvent]
}

enum BackendClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The OshiReader service returned an invalid response."
        case .httpStatus(_, _, let message):
            return message ?? "The OshiReader service request failed."
        }
    }
}

final class BackendClient {
    static let shared = BackendClient()

    private let baseURL = URL(string: "https://oshireader.onrender.com")!
    private let session: URLSession
    private let monotonicNow: () -> TimeInterval
    private let invalidateAPNSRegistration: () async -> Void
    private let invalidateAPNSRegistrationIfMatching: (String, String?) async -> Bool
    private let secretLock = NSLock()
    private var sessionSecret: String?

    init(
        session: URLSession = .shared,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        invalidateAPNSRegistration: @escaping () async -> Void = {
            await NotificationManager.shared.invalidateRemoteNotificationRegistration()
        },
        invalidateAPNSRegistrationIfMatching: @escaping (String, String?) async -> Bool = { token, environment in
            await NotificationManager.shared.invalidateRemoteNotificationRegistration(
                ifTokenMatches: token,
                environment: environment
            )
        }
    ) {
        self.session = session
        self.monotonicNow = monotonicNow
        self.invalidateAPNSRegistration = invalidateAPNSRegistration
        self.invalidateAPNSRegistrationIfMatching = invalidateAPNSRegistrationIfMatching
    }

    var deviceSecret: String {
        if let persisted = KeychainHelper.read(.apnsDeviceSecret) { return persisted }
        secretLock.lock()
        defer { secretLock.unlock() }
        if let sessionSecret { return sessionSecret }
        let generated = UUID().uuidString
        _ = KeychainHelper.save(.apnsDeviceSecret, generated)
        sessionSecret = generated
        return generated
    }

    var apnsEnvironment: String {
        let provisionedData = Bundle.main
            .url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        let configuredValue = Bundle.main.object(
            forInfoDictionaryKey: "OshiReaderAPNSEnvironment"
        ) as? String
#if DEBUG
        let fallback = "sandbox"
#else
        let fallback = "production"
#endif
        return Self.resolvedAPNSEnvironment(
            provisionedData: provisionedData,
            configuredValue: configuredValue,
            fallback: fallback
        )
    }

    static func normalizedAPNSEnvironment(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development", "sandbox":
            return "sandbox"
        case "production":
            return "production"
        default:
            return nil
        }
    }

    static func provisionedAPNSEnvironment(from data: Data?) -> String? {
        guard let data,
              let text = String(data: data, encoding: .isoLatin1),
              let plistStart = text.range(of: "<plist"),
              let plistEnd = text.range(
                of: "</plist>",
                range: plistStart.lowerBound..<text.endIndex
              )
        else { return nil }

        let plistXML = String(text[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistXML.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }

        return normalizedAPNSEnvironment(entitlements["aps-environment"] as? String)
    }

    static func resolvedAPNSEnvironment(
        provisionedData: Data?,
        configuredValue: String?,
        fallback: String
    ) -> String {
        if let provisioned = provisionedAPNSEnvironment(from: provisionedData) {
            return provisioned
        }
        if let configured = normalizedAPNSEnvironment(configuredValue) {
            return configured
        }
        return normalizedAPNSEnvironment(fallback) ?? "production"
    }

    var hasRegisteredAPNSDeviceForCurrentEnvironment: Bool {
        guard let token = KeychainHelper.read(.apnsDeviceToken), !token.isEmpty else { return false }
        return KeychainHelper.read(.apnsDeviceEnvironment) == apnsEnvironment
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        queryItems: [URLQueryItem] = [],
        accepted: ClosedRange<Int> = 200...299,
        timeout: TimeInterval = 30,
        absoluteDeadline: TimeInterval? = nil,
        allowsCredentialRecovery: Bool = true
    ) async throws -> T {
        let (value, _): (T, HTTPURLResponse) = try await requestWithResponse(
            path,
            method: method,
            json: json,
            queryItems: queryItems,
            accepted: accepted,
            timeout: timeout,
            absoluteDeadline: absoluteDeadline,
            allowsCredentialRecovery: allowsCredentialRecovery
        )
        return value
    }

    private func requestWithResponse<T: Decodable>(
        _ path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        queryItems: [URLQueryItem] = [],
        accepted: ClosedRange<Int> = 200...299,
        timeout: TimeInterval = 30,
        absoluteDeadline: TimeInterval? = nil,
        allowsCredentialRecovery: Bool = true
    ) async throws -> (T, HTTPURLResponse) {
        let deadline = absoluteDeadline ?? (monotonicNow() + max(0, timeout))
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        applyDeviceAuthorization(to: &request)
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await dataWithDeviceCredentialRecovery(
            for: request,
            deadline: deadline,
            allowsCredentialRecovery: allowsCredentialRecovery
        )
        guard accepted.contains(response.statusCode) else {
            throw backendError(status: response.statusCode, data: data)
        }
        return (try JSONDecoder().decode(T.self, from: data), response)
    }

    private func requestVoid(
        _ path: String,
        method: String,
        json: [String: Any]? = nil,
        encodedBody: Data? = nil,
        accepted: ClosedRange<Int>,
        timeout: TimeInterval,
        absoluteDeadline: TimeInterval? = nil,
        allowsCredentialRecovery: Bool = true
    ) async throws {
        let deadline = absoluteDeadline ?? (monotonicNow() + max(0, timeout))
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        applyDeviceAuthorization(to: &request)
        if let encodedBody {
            request.httpBody = encodedBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await dataWithDeviceCredentialRecovery(
            for: request,
            deadline: deadline,
            allowsCredentialRecovery: allowsCredentialRecovery
        )
        guard accepted.contains(response.statusCode) else {
            throw backendError(status: response.statusCode, data: data)
        }
    }

    private func applyDeviceAuthorization(to request: inout URLRequest) {
        request.setValue(deviceSecret, forHTTPHeaderField: "X-Device-Secret")
        request.setValue(KeychainHelper.read(.apnsDeviceToken), forHTTPHeaderField: "X-Device-Token")
    }

    private func dataWithDeviceCredentialRecovery(
        for request: URLRequest,
        deadline: TimeInterval,
        allowsCredentialRecovery: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let (initialData, initialResponse) = try await dataWithConnectionRetry(
            for: request,
            deadline: deadline
        )
        guard let initialHTTP = initialResponse as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard allowsCredentialRecovery,
              initialHTTP.statusCode == 401,
              hasRegisteredAPNSDeviceForCurrentEnvironment,
              let token = KeychainHelper.read(.apnsDeviceToken),
              !token.isEmpty
        else {
            return (initialData, initialHTTP)
        }

        let initialError = backendError(status: initialHTTP.statusCode, data: initialData)
        AppLogger.network.notice(
            "Paid backend device credential was rejected for \(self.logPath(for: request)); re-registering once"
        )
        do {
            try await registerAPNSToken(token, deadline: deadline)
        } catch {
            if let backendError = error as? BackendClientError,
               backendError.isUnverifiedAPNSRegistration {
                await invalidateAPNSRegistration()
            }
            try Task.checkCancellation()
            if let urlError = error as? URLError,
               urlError.code == .timedOut || urlError.code == .cancelled {
                throw urlError
            }
            AppLogger.network.warning(
                "Paid backend device credential recovery failed for \(self.logPath(for: request))"
            )
            throw initialError
        }

        try Task.checkCancellation()
        _ = try remainingTimeout(until: deadline)
        var retriedRequest = request
        applyDeviceAuthorization(to: &retriedRequest)
        let (retryData, retryResponse) = try await dataWithConnectionRetry(
            for: retriedRequest,
            deadline: deadline
        )
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        if retryHTTP.statusCode == 401 {
            await invalidateAPNSRegistration()
        }
        return (retryData, retryHTTP)
    }

    private func dataWithConnectionRetry(
        for request: URLRequest,
        deadline: TimeInterval
    ) async throws -> (Data, URLResponse) {
        do {
            return try await dataAttempt(for: request, deadline: deadline)
        } catch let error as URLError where error.code == .networkConnectionLost {
            try Task.checkCancellation()
            _ = try remainingTimeout(until: deadline)
            AppLogger.network.warning(
                "Paid backend connection was lost for \(self.logPath(for: request)); retrying once"
            )
            return try await dataAttempt(for: request, deadline: deadline)
        }
    }

    private func dataAttempt(
        for baseRequest: URLRequest,
        deadline: TimeInterval
    ) async throws -> (Data, URLResponse) {
        var request = baseRequest
        request.timeoutInterval = try remainingTimeout(until: deadline)
        return try await session.data(for: request)
    }

    private func logPath(for request: URLRequest) -> String {
        guard let path = request.url?.path else { return "request" }
        if path.hasPrefix("/api/devices/apns-token/") {
            return "/api/devices/apns-token/{token}"
        }
        return path
    }

    private func backendError(status: Int, data: Data) -> BackendClientError {
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = parsed?["detail"]
        let object = detail as? [String: Any]
        let message = (object?["message"] as? String) ?? (detail as? String)
        return .httpStatus(
            status,
            code: object?["code"] as? String,
            message: message.map { String($0.prefix(512)) }
        )
    }

    func entitlementStatus() async throws -> EntitlementStatus {
        try await request("api/entitlements/status")
    }

    func fetchHostedSourceHealth(timeout: TimeInterval = 15) async throws -> [HostedSourceHealthEntry] {
        let response: HostedSourceHealthResponse = try await request(
            "api/source-health",
            accepted: 200...200,
            timeout: timeout
        )
        return response.sources
    }

    func verifyTransaction(_ signedTransaction: String) async throws -> EntitlementStatus {
        try await request(
            "api/entitlements/verify",
            method: "POST",
            json: ["signed_transaction": signedTransaction]
        )
    }

    func fetchPushTerms() async throws -> [BackendWatchTerm] {
        try await request("api/watch-terms/")
    }

    func triggerPendingNotification(
        backendTermID: Int,
        timeout: TimeInterval = 30
    ) async throws -> BackendNotificationDelivery {
        try await request(
            "api/watch-terms/\(backendTermID)/notify",
            method: "POST",
            accepted: 200...200,
            timeout: timeout
        )
    }

    func clearPendingNotification(
        backendTermID: Int,
        timeout: TimeInterval = 30
    ) async throws {
        try await requestVoid(
            "api/watch-terms/\(backendTermID)/notify",
            method: "DELETE",
            accepted: 204...204,
            timeout: timeout
        )
    }

    func muteHostedFeedItem(
        sourceItemID: String,
        watchTermID: Int,
        timeout: TimeInterval = 30
    ) async throws {
        try await requestVoid(
            "api/feed/muted-items",
            method: "POST",
            json: [
                "source_item_id": sourceItemID,
                "watch_term_id": watchTermID,
            ],
            accepted: 204...204,
            timeout: timeout
        )
    }

    func submitClientDiagnostic(
        _ report: ClientDiagnosticReport,
        timeout: TimeInterval = 12
    ) async throws {
        try await requestVoid(
            "api/client-diagnostics",
            method: "POST",
            encodedBody: try JSONEncoder().encode(report),
            accepted: 200...200,
            timeout: timeout
        )
    }

    func createPushTerm(_ term: WatchTerm) async throws -> BackendWatchTerm {
        let backendTerms = try await fetchPushTerms()
        let existing = backendTerms.first {
            $0.keyword.caseInsensitiveCompare(term.keyword) == .orderedSame
        }
        if let existing {
            return try await updateBackendTerm(id: existing.id, term: term, notifyOnNew: true)
        }
        return try await createBackendTerm(term, notifyOnNew: true)
    }

    func createBackendTerm(_ term: WatchTerm, notifyOnNew: Bool) async throws -> BackendWatchTerm {
        try await request(
            "api/watch-terms/",
            method: "POST",
            json: [
                "keyword": term.keyword,
                "aliases": term.aliases,
                "collection_mode": term.collection_mode,
                "source_mode": term.source_mode.rawValue,
                "selected_platforms": term.selected_platforms,
                "is_active": term.is_active,
                "notify_on_new": notifyOnNew,
                "refresh_tier": "standard",
            ]
        )
    }

    func updateBackendTerm(id: Int, term: WatchTerm, notifyOnNew: Bool) async throws -> BackendWatchTerm {
        try await request(
            "api/watch-terms/\(id)",
            method: "PATCH",
            json: [
                "aliases": term.aliases,
                "collection_mode": term.collection_mode,
                "source_mode": term.source_mode.rawValue,
                "selected_platforms": term.selected_platforms,
                "is_active": term.is_active,
                "notify_on_new": notifyOnNew,
                "refresh_tier": "standard",
            ]
        )
    }

    func fetchBackendFeed(
        platform: String? = nil,
        termIDs: [Int] = [],
        limit: Int = 200,
        offset: Int = 0,
        days: Int = 30,
        since: String? = nil,
        until: String? = nil
    ) async throws -> [FeedItem] {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let since {
            query.append(URLQueryItem(name: "since", value: since))
        } else {
            query.append(URLQueryItem(name: "days", value: String(days)))
        }
        if let until { query.append(URLQueryItem(name: "until", value: until)) }
        if !termIDs.isEmpty {
            query.append(URLQueryItem(name: "term_ids", value: termIDs.map(String.init).joined(separator: ",")))
        }
        if let platform { query.append(URLQueryItem(name: "platform", value: platform)) }
        let payloads: [BackendFeedPayload] = try await request("api/feed/", queryItems: query)
        return payloads.map { $0.localItem(keyword: $0.watch_term_keyword) }
    }

    func fetchAllBackendFeed(
        platform: String? = nil,
        termIDs: [Int],
        pageSize: Int = 200,
        days: Int = 30,
        since: String? = nil,
        until: String
    ) async throws -> [FeedItem] {
        guard !termIDs.isEmpty else { return [] }
        let boundedPageSize = min(200, max(1, pageSize))
        var cursor: BackendFeedScanCursor?
        var seenCursors = Set<BackendFeedScanCursor>()
        var allItems: [FeedItem] = []
        while true {
            let (page, nextCursor) = try await fetchBackendFeedScanPage(
                platform: platform,
                termIDs: termIDs,
                limit: boundedPageSize,
                days: days,
                since: since,
                until: until,
                cursor: cursor
            )
            allItems.append(contentsOf: page)
            guard let nextCursor else {
                // A scan-capable backend returns continuation metadata whenever
                // a full page may have more rows. Older deployments ignore the
                // scan parameters and return a full legacy page without those
                // headers; fail without advancing the caller's refresh cutoff
                // instead of silently losing every later page.
                guard page.count < boundedPageSize else {
                    throw BackendClientError.invalidResponse
                }
                return allItems
            }
            if let cursor {
                guard nextCursor.matchID < cursor.matchID else {
                    throw BackendClientError.invalidResponse
                }
            }
            guard nextCursor != cursor, seenCursors.insert(nextCursor).inserted else {
                throw BackendClientError.invalidResponse
            }
            cursor = nextCursor
        }
    }

    private struct BackendFeedScanCursor: Hashable {
        let publishedAt: String
        let matchID: Int
    }

    private func fetchBackendFeedScanPage(
        platform: String?,
        termIDs: [Int],
        limit: Int,
        days: Int,
        since: String?,
        until: String,
        cursor: BackendFeedScanCursor?
    ) async throws -> ([FeedItem], BackendFeedScanCursor?) {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "scan", value: "true"),
            URLQueryItem(name: "until", value: until),
            URLQueryItem(name: "term_ids", value: termIDs.map(String.init).joined(separator: ",")),
        ]
        if let since {
            query.append(URLQueryItem(name: "since", value: since))
        } else {
            query.append(URLQueryItem(name: "days", value: String(days)))
        }
        if let platform { query.append(URLQueryItem(name: "platform", value: platform)) }
        if let cursor {
            query.append(URLQueryItem(name: "scan_before_published_at", value: cursor.publishedAt))
            query.append(URLQueryItem(name: "scan_before_match_id", value: String(cursor.matchID)))
        }

        let (payloads, response): ([BackendFeedPayload], HTTPURLResponse) = try await requestWithResponse(
            "api/feed/",
            queryItems: query
        )
        let nextPublishedAt = response.value(forHTTPHeaderField: "X-OshiReader-Next-Published-At")
        let nextMatchID = response.value(forHTTPHeaderField: "X-OshiReader-Next-Match-ID")
        let nextCursor: BackendFeedScanCursor?
        switch (nextPublishedAt, nextMatchID.flatMap(Int.init)) {
        case (nil, nil):
            nextCursor = nil
        case let (publishedAt?, matchID?):
            guard parseISO8601Date(publishedAt) != nil else {
                throw BackendClientError.invalidResponse
            }
            nextCursor = BackendFeedScanCursor(publishedAt: publishedAt, matchID: matchID)
        default:
            throw BackendClientError.invalidResponse
        }
        return (
            payloads.map { $0.localItem(keyword: $0.watch_term_keyword) },
            nextCursor
        )
    }

    func deletePushTerm(id: Int) async throws {
        let deadline = monotonicNow() + 30
        var request = URLRequest(url: baseURL.appendingPathComponent("api/watch-terms/\(id)"))
        request.httpMethod = "DELETE"
        applyDeviceAuthorization(to: &request)
        let (_, response) = try await dataWithDeviceCredentialRecovery(
            for: request,
            deadline: deadline,
            allowsCredentialRecovery: true
        )
        guard response.statusCode == 204 || response.statusCode == 404 else {
            throw BackendClientError.httpStatus(response.statusCode, code: nil, message: nil)
        }
    }

    @MainActor
    func registerAPNSToken(_ token: Data) async throws {
        try await registerAPNSToken(token.map { String(format: "%02x", $0) }.joined())
    }

    func unregisterAPNSToken(timeout: TimeInterval = 15) async throws {
        guard let token = KeychainHelper.read(.apnsDeviceToken), !token.isEmpty else { return }
        let environment = KeychainHelper.read(.apnsDeviceEnvironment)
        let deadline = monotonicNow() + max(0, timeout)
        let registrationURL = baseURL
            .appendingPathComponent("api/devices/apns-token")
            .appendingPathComponent(token)
        var request = URLRequest(url: registrationURL)
        request.httpMethod = "DELETE"
        request.setValue(deviceSecret, forHTTPHeaderField: "X-Device-Secret")

        let (data, response) = try await dataWithConnectionRetry(
            for: request,
            deadline: deadline
        )
        guard let http = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard http.statusCode == 204 || http.statusCode == 404 else {
            throw backendError(status: http.statusCode, data: data)
        }
        _ = await invalidateAPNSRegistrationIfMatching(token, environment)
    }

    @MainActor
    func registerAPNSToken(_ tokenString: String, timeout: TimeInterval = 30) async throws {
        try await registerAPNSToken(
            tokenString,
            deadline: monotonicNow() + max(0, timeout)
        )
    }

    @MainActor
    private func registerAPNSToken(_ tokenString: String, deadline: TimeInterval) async throws {
        let registration: APNSRegistrationResponse = try await request(
            "api/devices/apns-token",
            method: "POST",
            json: [
                "token": tokenString,
                "environment": apnsEnvironment,
                "device_id": UIDevice.current.identifierForVendor?.uuidString ?? "",
                "device_secret": deviceSecret,
                "bundle_id": Bundle.main.bundleIdentifier ?? "com.otterpia.oshireader",
            ],
            absoluteDeadline: deadline,
            allowsCredentialRecovery: false
        )
        guard registration.is_verified == true else {
            throw BackendClientError.httpStatus(409, code: "apns_unverified", message: registration.verification_error)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, tokenString)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, apnsEnvironment)
    }

    /// Requests the server-side poll for this entitled device. The server
    /// uses the device identity/secret to scope work and may deliver results
    /// through APNs; this is intentionally separate from local ingestion.
    func triggerBackgroundPoll(timeout: TimeInterval = 8) async throws {
        let deadline = monotonicNow() + max(0, timeout)
        let storedToken: String?
        let body: [String: String]
        if hasRegisteredAPNSDeviceForCurrentEnvironment,
           let token = KeychainHelper.read(.apnsDeviceToken),
           !token.isEmpty {
            storedToken = token
            body = [
                "token": token,
                "device_secret": deviceSecret,
            ]
        } else {
            storedToken = nil
            body = [
                "device_id": UIDevice.current.identifierForVendor?.uuidString ?? "",
                "environment": apnsEnvironment,
                "device_secret": deviceSecret,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        do {
            try await sendBackgroundPoll(body: data, deadline: deadline)
        } catch let initialError as BackendClientError {
            guard case .httpStatus(404, _, _) = initialError,
                  let storedToken else {
                throw initialError
            }

            do {
                try Task.checkCancellation()
                try await registerAPNSToken(
                    storedToken,
                    timeout: remainingTimeout(until: deadline)
                )
            } catch let registrationError as BackendClientError {
                if registrationError.isUnverifiedAPNSRegistration {
                    await invalidateAPNSRegistration()
                }
                throw registrationError
            }

            do {
                try await sendBackgroundPoll(body: data, deadline: deadline)
            } catch let retryError as BackendClientError {
                guard case .httpStatus(404, _, _) = retryError else { throw retryError }
                await invalidateAPNSRegistration()
                throw initialError
            }
        }
    }

    private func remainingTimeout(until deadline: TimeInterval) throws -> TimeInterval {
        try Task.checkCancellation()
        let remaining = deadline - monotonicNow()
        guard remaining > 0 else { throw URLError(.timedOut) }
        return remaining
    }

    private func sendBackgroundPoll(body: Data, deadline: TimeInterval) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/devices/background-refresh"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await dataWithConnectionRetry(for: request, deadline: deadline)
        guard let http = response as? HTTPURLResponse else { throw BackendClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw backendError(status: http.statusCode, data: data)
        }
    }
}

private extension BackendClientError {
    var isUnverifiedAPNSRegistration: Bool {
        guard case .httpStatus(_, let code, _) = self else { return false }
        return code == "apns_unverified" || code == "apns_registration_unverified"
    }
}
