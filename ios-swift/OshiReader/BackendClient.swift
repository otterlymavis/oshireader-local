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
    private let secretLock = NSLock()
    private var sessionSecret: String?

    init(session: URLSession = .shared) {
        self.session = session
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
#if DEBUG
        return "sandbox"
#else
        return "production"
#endif
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
        accepted: ClosedRange<Int> = 200...299
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(deviceSecret, forHTTPHeaderField: "X-Device-Secret")
        if let token = KeychainHelper.read(.apnsDeviceToken) {
            request.setValue(token, forHTTPHeaderField: "X-Device-Token")
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackendClientError.invalidResponse }
        guard accepted.contains(response.statusCode) else {
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = parsed?["detail"]
            let object = detail as? [String: Any]
            throw BackendClientError.httpStatus(
                response.statusCode,
                code: object?["code"] as? String,
                message: (object?["message"] as? String) ?? (detail as? String)
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func entitlementStatus() async throws -> EntitlementStatus {
        try await request("api/entitlements/status")
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
        limit: Int = 200,
        days: Int = 30,
        since: String? = nil
    ) async throws -> [FeedItem] {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let since {
            query.append(URLQueryItem(name: "since", value: since))
        } else {
            query.append(URLQueryItem(name: "days", value: String(days)))
        }
        if let platform { query.append(URLQueryItem(name: "platform", value: platform)) }
        let payloads: [BackendFeedPayload] = try await request("api/feed/", queryItems: query)
        return payloads.map { $0.localItem(keyword: $0.watch_term_keyword) }
    }

    func deletePushTerm(id: Int) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/watch-terms/\(id)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue(deviceSecret, forHTTPHeaderField: "X-Device-Secret")
        if let token = KeychainHelper.read(.apnsDeviceToken) {
            request.setValue(token, forHTTPHeaderField: "X-Device-Token")
        }
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackendClientError.invalidResponse }
        guard response.statusCode == 204 || response.statusCode == 404 else {
            throw BackendClientError.httpStatus(response.statusCode, code: nil, message: nil)
        }
    }

    @MainActor
    func registerAPNSToken(_ token: Data) async throws {
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        let registration: APNSRegistrationResponse = try await request(
            "api/devices/apns-token",
            method: "POST",
            json: [
                "token": tokenString,
                "environment": apnsEnvironment,
                "device_id": UIDevice.current.identifierForVendor?.uuidString ?? "",
                "device_secret": deviceSecret,
                "bundle_id": Bundle.main.bundleIdentifier ?? "com.otterpia.oshireader",
            ]
        )
        guard registration.is_verified == true else {
            throw BackendClientError.httpStatus(409, code: "apns_unverified", message: registration.verification_error)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, tokenString)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, apnsEnvironment)
    }
}
