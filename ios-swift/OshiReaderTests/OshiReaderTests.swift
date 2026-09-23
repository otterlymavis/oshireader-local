import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

private actor RequestCapture {
    private(set) var urls: [String] = []

    func record(_ url: String) {
        urls.append(url)
    }

    func count() -> Int {
        urls.count
    }

    func firstURL() -> String? {
        urls.first
    }

    func contains(_ predicate: (String) -> Bool) -> Bool {
        urls.contains(where: predicate)
    }

    func count(containing fragment: String) -> Int {
        urls.filter { $0.contains(fragment) }.count
    }
}

private actor RequestPolicyCapture {
    private(set) var requests: [(url: String, timeout: TimeInterval)] = []

    func record(_ request: URLRequest) {
        requests.append((request.url?.absoluteString ?? "", request.timeoutInterval))
    }
}

private actor ConcurrentRequestCapture {
    private var active = 0
    private var started = 0
    private(set) var maximumActive = 0

    func begin() {
        active += 1
        started += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }

    func startedCount() -> Int {
        started
    }

    func waitUntilStarted(_ expectedCount: Int) async {
        while started < expectedCount {
            await Task.yield()
        }
    }
}

private struct RequestStartEvent: Sendable {
    let url: String
    let uptimeNanoseconds: UInt64
}

private actor RequestStartCapture {
    private var events: [RequestStartEvent] = []
    private var active = 0
    private(set) var maximumActive = 0

    func begin(_ url: String) {
        events.append(RequestStartEvent(
            url: url,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }

    func snapshot() -> [RequestStartEvent] {
        events
    }

    func waitUntilCount(_ expectedCount: Int) async {
        while events.count < expectedCount {
            await Task.yield()
        }
    }
}

private actor PacingDelayCapture {
    private var delays: [UInt64] = []

    func record(_ delay: UInt64) {
        delays.append(delay)
    }

    func waitUntilCount(_ expectedCount: Int) async {
        while delays.count < expectedCount {
            await Task.yield()
        }
    }
}

private actor RetryGate {
    private var entered = false

    func enter() {
        entered = true
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: TimeInterval) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

private actor AsyncCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                var body = Data()
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count > 0 {
                        body.append(buffer, count: count)
                    } else {
                        break
                    }
                }
                stream.close()
                request.httpBody = body
            }
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class NonHTTPResponseURLProtocol: URLProtocol {
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: "application/json",
            expectedContentLength: 0,
            textEncodingName: "utf-8"
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OshiReaderTests: XCTestCase {

    private var db: LocalDB!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        db = LocalDB.shared
        // Clear state before tests if needed, or work with a clean slate
        db.terms.removeAll()
        db.feedItems.removeAll()
        db.savedPages.removeAll()
        db.customUrls.removeAll()
        db.amebloBlogs.removeAll()
        db.hiddenItems.removeAll()
        db.compositions.removeAll()
        db.setSubscribedPlatforms(platforms: ["news", "tver", "youtube", "yahoonews", "custom"])
    }
    
    override func tearDownWithError() throws {
        db = nil
        try super.tearDownWithError()
    }

    func testAPNSEnvironmentNormalizationRejectsInvalidAndUnexpandedValues() {
        XCTAssertEqual(BackendClient.normalizedAPNSEnvironment("development"), "sandbox")
        XCTAssertEqual(BackendClient.normalizedAPNSEnvironment("SANDBOX"), "sandbox")
        XCTAssertEqual(BackendClient.normalizedAPNSEnvironment("  Production  "), "production")
        XCTAssertNil(BackendClient.normalizedAPNSEnvironment(""))
        XCTAssertNil(BackendClient.normalizedAPNSEnvironment("invalid"))
        XCTAssertNil(BackendClient.normalizedAPNSEnvironment("$(APNS_ENVIRONMENT)"))
        XCTAssertNil(BackendClient.normalizedAPNSEnvironment(nil))
    }

    func testAPNSEnvironmentParsesEmbeddedProvisioningEntitlements() {
        func profile(environment: String) -> Data {
            Data("CMS-prefix\u{00ff}\n".utf8) + Data(
                """
                <plist version="1.0">
                <dict>
                  <key>Entitlements</key>
                  <dict>
                    <key>aps-environment</key>
                    <string>\(environment)</string>
                  </dict>
                </dict>
                </plist>
                """.utf8
            ) + Data("\nCMS-suffix".utf8)
        }

        XCTAssertEqual(
            BackendClient.provisionedAPNSEnvironment(from: profile(environment: "development")),
            "sandbox"
        )
        XCTAssertEqual(
            BackendClient.provisionedAPNSEnvironment(from: profile(environment: "production")),
            "production"
        )
        XCTAssertNil(BackendClient.provisionedAPNSEnvironment(from: profile(environment: "invalid")))
        XCTAssertNil(BackendClient.provisionedAPNSEnvironment(from: Data("not a profile".utf8)))
        XCTAssertNil(BackendClient.provisionedAPNSEnvironment(from: Data("<plist><dict>".utf8)))
        XCTAssertNil(BackendClient.provisionedAPNSEnvironment(from: Data(
            "<plist version=\"1.0\"><dict><key>Name</key><string>Missing entitlements</string></dict></plist>".utf8
        )))
        XCTAssertNil(BackendClient.provisionedAPNSEnvironment(from: nil))
    }

    func testAPNSEnvironmentResolutionUsesProvisioningThenConfigurationThenFallback() {
        let productionProfile = Data(
            """
            prefix<plist version="1.0"><dict><key>Entitlements</key><dict>
            <key>aps-environment</key><string>production</string>
            </dict></dict></plist>suffix
            """.utf8
        )

        XCTAssertEqual(
            BackendClient.resolvedAPNSEnvironment(
                provisionedData: productionProfile,
                configuredValue: "development",
                fallback: "sandbox"
            ),
            "production"
        )
        XCTAssertEqual(
            BackendClient.resolvedAPNSEnvironment(
                provisionedData: Data("malformed".utf8),
                configuredValue: "development",
                fallback: "production"
            ),
            "sandbox"
        )
        XCTAssertEqual(
            BackendClient.resolvedAPNSEnvironment(
                provisionedData: nil,
                configuredValue: "$(APNS_ENVIRONMENT)",
                fallback: "sandbox"
            ),
            "sandbox"
        )
        XCTAssertEqual(
            BackendClient.resolvedAPNSEnvironment(
                provisionedData: nil,
                configuredValue: nil,
                fallback: "production"
            ),
            "production"
        )
        XCTAssertEqual(
            BackendClient.resolvedAPNSEnvironment(
                provisionedData: nil,
                configuredValue: nil,
                fallback: "invalid"
            ),
            "production"
        )
    }

    func testAPNSRegistrationAuthorityRequiresResolvedEnvironmentMatch() {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        let client = BackendClient()
        _ = KeychainHelper.save(.apnsDeviceToken, "cached-token")
        _ = KeychainHelper.save(
            .apnsDeviceEnvironment,
            client.apnsEnvironment == "sandbox" ? "production" : "sandbox"
        )
        XCTAssertFalse(client.hasRegisteredAPNSDeviceForCurrentEnvironment)

        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        XCTAssertTrue(client.hasRegisteredAPNSDeviceForCurrentEnvironment)
    }

    func testBackendFeedClientDecodesHostedItemsAndQuery() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/api/feed/")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "platform" })?.value, "youtube")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "25")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "days" })?.value, "7")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Device-Secret"))
            let data = Data("""
            [{
              "watch_term_keyword": "Aiko",
              "matched_at": "2026-08-22T12:01:00Z",
              "item": {
                "id": "youtube:1",
                "platform": "youtube",
                "url": "https://example.com/1",
                "title": "Aiko update",
                "content_text": null,
                "author": "Channel",
                "thumbnail_url": null,
                "media_type": "video",
                "published_at": "2026-08-22T12:00:00Z",
                "source": "youtube"
              }
            }]
            """.utf8)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let items = try await client.fetchBackendFeed(platform: "youtube", limit: 25, days: 7)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "youtube:1")
        XCTAssertEqual(items.first?.watch_term_keyword, "Aiko")
        XCTAssertEqual(items.first?.fetched_at, "2026-08-22T12:01:00Z")
    }

    func testHostedSourceHealthClientDecodesCompleteResponseAndPreservesOrder() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/api/source-health")
            XCTAssertEqual(request.timeoutInterval, 7, accuracy: 0.01)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Device-Secret"))
            return (
                Data("""
                {"sources":[
                  {
                    "platform":"youtube",
                    "status":"success",
                    "last_checked_at":"2026-08-26T10:00:00Z",
                    "last_success_at":"2026-08-26T10:00:00Z",
                    "last_item_count":4,
                    "last_error":null,
                    "consecutive_failures":0,
                    "jina_checked_at":"2026-08-26T09:59:00Z",
                    "jina_ok":false,
                    "jina_error":"upstream timeout"
                  },
                  {
                    "platform":"news",
                    "status":"failure",
                    "last_checked_at":"2026-08-26T09:00:00Z",
                    "last_success_at":"2026-08-25T09:00:00Z",
                    "last_item_count":0,
                    "last_error":"rate limited",
                    "consecutive_failures":3,
                    "jina_checked_at":null,
                    "jina_ok":null,
                    "jina_error":null
                  }
                ]}
                """.utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let entries = try await client.fetchHostedSourceHealth(timeout: 7)

        XCTAssertEqual(entries.map(\.platform), ["youtube", "news"])
        XCTAssertEqual(entries[0].last_item_count, 4)
        XCTAssertEqual(entries[0].jina_ok, false)
        XCTAssertEqual(entries[0].jina_error, "upstream timeout")
        XCTAssertEqual(entries[1].last_error, "rate limited")
        XCTAssertEqual(entries[1].consecutive_failures, 3)
    }

    func testHostedSourceHealthClientAcceptsMissingOptionalAndLegacyFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            (
                Data(#"{"sources":[{"platform":"custom-source"}]}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let entries = try await client.fetchHostedSourceHealth()
        let entry = try XCTUnwrap(entries.first)

        XCTAssertNil(entry.status)
        XCTAssertNil(entry.last_checked_at)
        XCTAssertNil(entry.last_item_count)
        XCTAssertEqual(entry.consecutive_failures, 0)
        XCTAssertNil(entry.jina_ok)
    }

    func testHostedSourceHealthPresentationMapsAllStatusesAndKeepsJinaIndependent() async throws {
        let expected: [(String?, HostedSourceHealthBadgeKind, String)] = [
            ("success", .success, "checkmark.circle.fill"),
            ("empty", .empty, "circle.dashed"),
            ("filtered", .filtered, "line.diagonal"),
            ("failure", .failure, "exclamationmark.triangle.fill"),
            ("new-status", .unknown, "questionmark.circle"),
            (nil, .unknown, "questionmark.circle"),
        ]
        for (raw, kind, symbol) in expected {
            let presentation = HostedSourceHealthPresentation(status: raw)
            XCTAssertEqual(presentation.kind, kind)
            XCTAssertEqual(presentation.symbolName, symbol)
        }

        let entry = try JSONDecoder().decode(
            HostedSourceHealthEntry.self,
            from: Data(#"{"platform":"youtube","status":"success","jina_ok":false}"#.utf8)
        )
        XCTAssertEqual(HostedSourceHealthPresentation(status: entry.status).kind, .success)
        XCTAssertEqual(entry.jina_ok, false)
    }

    @MainActor
    func testHostedSourceHealthViewModelPreservesEntriesAfterFailedReload() async throws {
        let entry = try JSONDecoder().decode(
            HostedSourceHealthEntry.self,
            from: Data(#"{"platform":"youtube","status":"success","consecutive_failures":0}"#.utf8)
        )
        var attempt = 0
        let model = HostedSourceHealthViewModel(
            fetch: { _ in
                attempt += 1
                if attempt == 1 { return [entry] }
                throw URLError(.notConnectedToInternet)
            },
            refreshEntitlement: {}
        )

        await model.load()
        XCTAssertEqual(model.entries, [entry])
        XCTAssertNil(model.loadFailure)

        await model.load()
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(model.loadFailure, .requestFailed)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testHostedSourceHealthViewModelRefreshesEntitlementForPaidAccessFailure() async {
        var refreshedEntitlement = false
        let model = HostedSourceHealthViewModel(
            fetch: { _ in
                throw BackendClientError.httpStatus(
                    402,
                    code: "paid_backend_required",
                    message: "An active purchase is required"
                )
            },
            refreshEntitlement: { refreshedEntitlement = true }
        )

        await model.load()

        XCTAssertEqual(model.loadFailure, .accessUnavailable)
        XCTAssertTrue(refreshedEntitlement)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testHostedSourceStatusIsVisibleOnlyForConfiguredActivePaidUsers() {
        XCTAssertTrue(SettingsView.shouldShowHostedSourceStatus(isPaidConfigured: true, hasActiveEntitlement: true))
        XCTAssertFalse(SettingsView.shouldShowHostedSourceStatus(isPaidConfigured: true, hasActiveEntitlement: false))
        XCTAssertFalse(SettingsView.shouldShowHostedSourceStatus(isPaidConfigured: false, hasActiveEntitlement: true))
    }

    func testClientDiagnosticRequestUsesDeviceAuthorizationAndSharedTransientRetry() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        let originalSecret = KeychainHelper.read(.apnsDeviceSecret)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
            _ = KeychainHelper.save(.apnsDeviceSecret, originalSecret)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, "diagnostic-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, "sandbox")
        _ = KeychainHelper.save(.apnsDeviceSecret, "diagnostic-secret")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        let report = ClientDiagnosticReport(
            reason: "paid_hosted_operation_failed",
            environment: "sandbox",
            api_base: "hosted",
            app_version: "1.2",
            build: "34",
            active_terms_count: 2,
            subscribed_platforms: ["news", "youtube"],
            cached_feed_count: 7,
            events: [ClientDiagnosticEvent(
                strategy: "hosted_feed_refresh",
                status: "failed",
                item_count: 0,
                added_count: 0,
                detail: "timeout"
            )]
        )
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 {
                clock.set(102)
                throw URLError(.networkConnectionLost)
            }
            return (
                Data(#"{"status":"received"}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        try await client.submitClientDiagnostic(report, timeout: 12)

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/api/client-diagnostics")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].timeoutInterval, 12, accuracy: 0.01)
        XCTAssertEqual(requests[1].timeoutInterval, 10, accuracy: 0.01)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Device-Secret"), "diagnostic-secret")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Device-Token"), "diagnostic-token")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(requests[0].httpBody)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(decoded["reason"] as? String, "paid_hosted_operation_failed")
        XCTAssertEqual(decoded["api_base"] as? String, "hosted")
        XCTAssertEqual(decoded["active_terms_count"] as? Int, 2)
        let events = try XCTUnwrap(decoded["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["detail"] as? String, "timeout")
    }

    func testClientDiagnosticRequestPreservesBackendErrorDetails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            (
                Data(#"{"detail":{"code":"diagnostic_rejected","message":"Rejected"}}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let report = ClientDiagnosticReport(
            reason: "paid_hosted_operation_failed",
            environment: "sandbox",
            api_base: "hosted",
            app_version: nil,
            build: nil,
            active_terms_count: 0,
            subscribed_platforms: [],
            cached_feed_count: 0,
            events: []
        )

        do {
            try await client.submitClientDiagnostic(report)
            XCTFail("Expected diagnostic rejection")
        } catch let BackendClientError.httpStatus(status, code, message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(code, "diagnostic_rejected")
            XCTAssertEqual(message, "Rejected")
        }
    }

    @MainActor
    func testAPNSRegistrationPersistsTokenOnlyAfterBackendVerification() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, nil)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/devices/apns-token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Device-Secret"))
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["token"] as? String, "aabb")
            let verified = requestCount > 1
            return (
                Data("""
                {"is_verified":\(verified),"verification_error":\(verified ? "null" : "\"temporary rejection\"")}
                """.utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            try await client.registerAPNSToken("aabb")
            XCTFail("Expected unverified registration to fail")
        } catch let BackendClientError.httpStatus(status, code, _) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "apns_unverified")
        }
        XCTAssertNil(KeychainHelper.read(.apnsDeviceToken))
        XCTAssertNil(KeychainHelper.read(.apnsDeviceEnvironment))

        try await client.registerAPNSToken("aabb")
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), "aabb")
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceEnvironment), client.apnsEnvironment)
    }

    func testAPNSUnregistrationAcceptsMissingServerRowsAndClearsLocalRegistration() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        let originalSecret = KeychainHelper.read(.apnsDeviceSecret)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
            _ = KeychainHelper.save(.apnsDeviceSecret, originalSecret)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistrationIfMatching: { _, _ in
                await invalidations.increment()
                _ = KeychainHelper.save(.apnsDeviceToken, nil)
                _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)
                return true
            }
        )
        let token = String(repeating: "a", count: 64)
        _ = KeychainHelper.save(.apnsDeviceSecret, "device-secret")
        var statuses = [204, 404]
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            return (
                Data(),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: statuses.removeFirst(),
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        for environment in ["wrong-environment", client.apnsEnvironment] {
            _ = KeychainHelper.save(.apnsDeviceToken, token)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, environment)
            try await client.unregisterAPNSToken(timeout: 7)
            XCTAssertNil(KeychainHelper.read(.apnsDeviceToken))
            XCTAssertNil(KeychainHelper.read(.apnsDeviceEnvironment))
        }

        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.path, "/api/devices/apns-token/\(token)")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.timeoutInterval, 7, accuracy: 0.01)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Secret"), "device-secret")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Device-Token"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody)
        }
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 2)
    }

    func testAPNSUnregistrationWithoutCachedTokenPerformsNoRequest() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, nil)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, "stale-environment")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return (
                Data(),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        try await client.unregisterAPNSToken(timeout: 7)

        XCTAssertEqual(requestCount, 0)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceEnvironment), "stale-environment")
    }

    func testAPNSUnregistrationRetriesConnectionLossWithinSharedDeadline() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            monotonicNow: { clock.now() },
            invalidateAPNSRegistrationIfMatching: { _, _ in
                await invalidations.increment()
                return true
            }
        )
        let token = String(repeating: "b", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, "another-environment")
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 {
                clock.set(102)
                throw URLError(.networkConnectionLost)
            }
            return (
                Data(),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        try await client.unregisterAPNSToken(timeout: 8)

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, requests[1].url)
        XCTAssertEqual(requests[0].httpMethod, requests[1].httpMethod)
        XCTAssertEqual(requests[0].timeoutInterval, 8, accuracy: 0.01)
        XCTAssertEqual(requests[1].timeoutInterval, 6, accuracy: 0.01)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 1)
    }

    func testAPNSUnregistrationDoesNotInvalidateRegistrationThatChangedInFlight() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let oldToken = String(repeating: "e", count: 64)
        let newToken = String(repeating: "f", count: 64)
        let oldEnvironment = "sandbox"
        let newEnvironment = "production"
        _ = KeychainHelper.save(.apnsDeviceToken, oldToken)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, oldEnvironment)
        var invalidationTargets: [(String, String?)] = []
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistrationIfMatching: { token, environment in
                invalidationTargets.append((token, environment))
                guard KeychainHelper.read(.apnsDeviceToken) == token,
                      KeychainHelper.read(.apnsDeviceEnvironment) == environment
                else { return false }
                _ = KeychainHelper.save(.apnsDeviceToken, nil)
                _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)
                return true
            }
        )
        MockURLProtocol.handler = { request in
            _ = KeychainHelper.save(.apnsDeviceToken, newToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, newEnvironment)
            return (
                Data(),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        try await client.unregisterAPNSToken(timeout: 8)

        XCTAssertEqual(invalidationTargets.count, 1)
        XCTAssertEqual(invalidationTargets.first?.0, oldToken)
        XCTAssertEqual(invalidationTargets.first?.1, oldEnvironment)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), newToken)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceEnvironment), newEnvironment)
    }

    @MainActor
    func testAPNSUnregistrationDeadlineAndCancellationPreventRetry() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            monotonicNow: { clock.now() },
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        let token = String(repeating: "d", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        var requestCount = 0
        MockURLProtocol.handler = { _ in
            requestCount += 1
            clock.set(109)
            throw URLError(.networkConnectionLost)
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            try await client.unregisterAPNSToken(timeout: 8)
            XCTFail("Expected shared deadline expiry")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(requestCount, 1)

        requestCount = 0
        clock.set(100)
        let requestStarted = expectation(description: "APNs cleanup started")
        MockURLProtocol.handler = { _ in
            requestCount += 1
            requestStarted.fulfill()
            Thread.sleep(forTimeInterval: 0.2)
            throw URLError(.networkConnectionLost)
        }
        let cancelled = Task { try await client.unregisterAPNSToken(timeout: 8) }
        await fulfillment(of: [requestStarted], timeout: 1)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), token)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
    }

    func testAPNSUnregistrationFailuresRetainCachedRegistrationWithoutCredentialRecovery() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        let token = String(repeating: "c", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        let statuses = [401, 402, 500]
        var requestCount = 0
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            requestCount += 1
            if requestCount > statuses.count { throw URLError(.notConnectedToInternet) }
            return (
                Data(#"{"detail":{"code":"cleanup_failed","message":"Rejected"}}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: statuses[requestCount - 1],
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        for expectedStatus in statuses {
            do {
                try await client.unregisterAPNSToken(timeout: 8)
                XCTFail("Expected HTTP \(expectedStatus)")
            } catch let BackendClientError.httpStatus(status, code, message) {
                XCTAssertEqual(status, expectedStatus)
                XCTAssertEqual(code, "cleanup_failed")
                XCTAssertEqual(message, "Rejected")
            }
        }
        do {
            try await client.unregisterAPNSToken(timeout: 8)
            XCTFail("Expected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        XCTAssertEqual(requestCount, 4)
        XCTAssertFalse(paths.contains("/api/devices/apns-token"))
        XCTAssertEqual(Set(paths), ["/api/devices/apns-token/\(token)"])
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), token)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceEnvironment), client.apnsEnvironment)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
    }

    func testPaidBackendTransportRetriesDecodedVoidAndDeleteRequestsWithinSharedBudgets() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        let originalSecret = KeychainHelper.read(.apnsDeviceSecret)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
            _ = KeychainHelper.save(.apnsDeviceSecret, originalSecret)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, "device-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, "test-environment")
        _ = KeychainHelper.save(.apnsDeviceSecret, "device-secret")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        var attempts: [String: Int] = [:]
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            attempts[key, default: 0] += 1
            if attempts[key] == 1 {
                clock.set(clock.now() + 2)
                throw URLError(.networkConnectionLost)
            }

            let data: Data
            let status: Int
            switch key {
            case "GET /api/source-health":
                data = Data(#"{"sources":[]}"#.utf8)
                status = 200
            case "PATCH /api/watch-terms/42":
                data = Data(#"{"id":42,"keyword":"Aiko","aliases":[],"collection_mode":"all_info","source_mode":"all","selected_platforms":[],"is_active":true,"notify_on_new":false,"refresh_tier":"standard","created_at":"2026-08-26T12:00:00Z"}"#.utf8)
                status = 200
            case "POST /api/feed/muted-items":
                data = Data()
                status = 204
            case "DELETE /api/watch-terms/42":
                data = Data()
                status = 404
            default:
                XCTFail("Unexpected paid backend request: \(key)")
                data = Data()
                status = 500
            }
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        _ = try await client.fetchHostedSourceHealth(timeout: 8)
        _ = try await client.updateBackendTerm(
            id: 42,
            term: WatchTerm(keyword: "Aiko"),
            notifyOnNew: false
        )
        try await client.muteHostedFeedItem(
            sourceItemID: "news:item-1",
            watchTermID: 42,
            timeout: 8
        )
        try await client.deletePushTerm(id: 42)

        XCTAssertEqual(requests.count, 8)
        for pairStart in stride(from: 0, to: requests.count, by: 2) {
            let first = requests[pairStart]
            let retry = requests[pairStart + 1]
            XCTAssertEqual(first.url, retry.url)
            XCTAssertEqual(first.httpMethod, retry.httpMethod)
            XCTAssertEqual(first.httpBody, retry.httpBody)
            XCTAssertEqual(
                first.value(forHTTPHeaderField: "X-Device-Secret"),
                retry.value(forHTTPHeaderField: "X-Device-Secret")
            )
            XCTAssertEqual(
                first.value(forHTTPHeaderField: "X-Device-Token"),
                retry.value(forHTTPHeaderField: "X-Device-Token")
            )
            XCTAssertNil(first.value(forHTTPHeaderField: "Authorization"))
            XCTAssertLessThan(retry.timeoutInterval, first.timeoutInterval)
            XCTAssertEqual(first.timeoutInterval - retry.timeoutInterval, 2, accuracy: 0.01)
        }
        XCTAssertEqual(attempts.values.sorted(), [2, 2, 2, 2])
    }

    func testPaidBackendTransportDoesNotRetryUnrelatedHTTPOrDecodeFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            switch requestCount {
            case 1:
                throw URLError(.timedOut)
            case 2:
                return (
                    Data(#"{"detail":{"code":"paid_backend_required","message":"Paid access required"}}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 402,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            default:
                return (
                    Data(#"{"unexpected":true}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchHostedSourceHealth(timeout: 8)
            XCTFail("Expected timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        do {
            _ = try await client.fetchHostedSourceHealth(timeout: 8)
            XCTFail("Expected paid access rejection")
        } catch let BackendClientError.httpStatus(status, code, message) {
            XCTAssertEqual(status, 402)
            XCTAssertEqual(code, "paid_backend_required")
            XCTAssertEqual(message, "Paid access required")
        }
        do {
            _ = try await client.fetchHostedSourceHealth(timeout: 8)
            XCTFail("Expected decoding failure")
        } catch is DecodingError {
            // Expected.
        }
        XCTAssertEqual(requestCount, 3)
    }

    func testPaidBackendTransportStopsAfterSecondConnectionLoss() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        var requestCount = 0
        MockURLProtocol.handler = { _ in
            requestCount += 1
            throw URLError(.networkConnectionLost)
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchHostedSourceHealth(timeout: 8)
            XCTFail("Expected the second connection loss to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testPaidBackendCredentialRecoveryRetriesDecodedVoidAndDeleteRequestsWithinSharedDeadline() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        let originalSecret = KeychainHelper.read(.apnsDeviceSecret)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
            _ = KeychainHelper.save(.apnsDeviceSecret, originalSecret)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            monotonicNow: { clock.now() },
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        let token = String(repeating: "c", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        _ = KeychainHelper.save(.apnsDeviceSecret, "device-secret")

        var operationAttempts: [String: Int] = [:]
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            let path = request.url?.path ?? ""
            if path == "/api/devices/apns-token" {
                clock.set(clock.now() + 2)
                return (
                    Data(#"{"is_verified":true,"verification_error":null}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }

            let key = "\(request.httpMethod ?? "") \(path)"
            operationAttempts[key, default: 0] += 1
            if operationAttempts[key] == 1 {
                clock.set(clock.now() + 2)
                return (
                    Data(#"{"detail":{"code":"invalid_device","message":"Credential rejected"}}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }

            let data: Data
            let status: Int
            switch key {
            case "GET /api/source-health":
                data = Data(#"{"sources":[]}"#.utf8)
                status = 200
            case "POST /api/feed/muted-items":
                data = Data()
                status = 204
            case "DELETE /api/watch-terms/42":
                data = Data()
                status = 204
            default:
                XCTFail("Unexpected paid backend request: \(key)")
                data = Data()
                status = 500
            }
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        _ = try await client.fetchHostedSourceHealth(timeout: 10)
        try await client.muteHostedFeedItem(
            sourceItemID: "news:item-1",
            watchTermID: 42,
            timeout: 10
        )
        try await client.deletePushTerm(id: 42)

        XCTAssertEqual(requests.map { $0.url?.path ?? "" }, [
            "/api/source-health", "/api/devices/apns-token", "/api/source-health",
            "/api/feed/muted-items", "/api/devices/apns-token", "/api/feed/muted-items",
            "/api/watch-terms/42", "/api/devices/apns-token", "/api/watch-terms/42",
        ])
        for start in stride(from: 0, to: requests.count, by: 3) {
            let initial = requests[start]
            let registration = requests[start + 1]
            let retry = requests[start + 2]
            XCTAssertEqual(initial.url, retry.url)
            XCTAssertEqual(initial.httpMethod, retry.httpMethod)
            XCTAssertEqual(initial.httpBody, retry.httpBody)
            XCTAssertEqual(initial.value(forHTTPHeaderField: "X-Device-Secret"), "device-secret")
            XCTAssertEqual(retry.value(forHTTPHeaderField: "X-Device-Secret"), "device-secret")
            XCTAssertEqual(initial.value(forHTTPHeaderField: "X-Device-Token"), token)
            XCTAssertEqual(retry.value(forHTTPHeaderField: "X-Device-Token"), token)
            XCTAssertEqual(registration.url?.path, "/api/devices/apns-token")
            XCTAssertEqual(initial.timeoutInterval - registration.timeoutInterval, 2, accuracy: 0.01)
            XCTAssertEqual(registration.timeoutInterval - retry.timeoutInterval, 2, accuracy: 0.01)
        }
        XCTAssertEqual(operationAttempts.values.sorted(), [2, 2, 2])
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
    }

    func testPaidBackendCredentialRecoveryRequiresCurrentEnvironmentToken() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (
                Data(#"{"detail":"Unauthorized"}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let states: [(String?, String?)] = [
            (nil, nil),
            ("", client.apnsEnvironment),
            (String(repeating: "d", count: 64), "wrong-environment"),
        ]
        for (token, environment) in states {
            _ = KeychainHelper.save(.apnsDeviceToken, token)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, environment)
            do {
                _ = try await client.fetchHostedSourceHealth(timeout: 8)
                XCTFail("Expected unauthorized response")
            } catch let BackendClientError.httpStatus(status, _, _) {
                XCTAssertEqual(status, 401)
            }
        }

        XCTAssertEqual(paths, Array(repeating: "/api/source-health", count: states.count))
    }

    @MainActor
    func testAPNSRegistrationDoesNotRecursivelyRecoverFromUnauthorizedResponse() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        let token = String(repeating: "e", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/devices/apns-token")
            return (
                Data(#"{"detail":"Unauthorized"}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            try await client.registerAPNSToken(token)
            XCTFail("Expected unauthorized registration")
        } catch let BackendClientError.httpStatus(status, _, _) {
            XCTAssertEqual(status, 401)
        }
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testPaidBackendCredentialRecoveryInvalidatesRejectedButPreservesTransientRegistration() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistration: {
                await invalidations.increment()
                _ = KeychainHelper.save(.apnsDeviceToken, nil)
                _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)
            }
        )
        let token = String(repeating: "f", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)

        enum RecoveryScenario { case second401, unverified, transient }
        var scenario = RecoveryScenario.second401
        var originalAttempts = 0
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/devices/apns-token" {
                switch scenario {
                case .second401:
                    return (
                        Data(#"{"is_verified":true}"#.utf8),
                        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: nil))
                    )
                case .unverified:
                    return (
                        Data(#"{"is_verified":false,"verification_error":"Rejected"}"#.utf8),
                        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                    )
                case .transient:
                    throw URLError(.cannotConnectToHost)
                }
            }
            originalAttempts += 1
            return (
                Data(#"{"detail":"Unauthorized"}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        for nextScenario in [RecoveryScenario.second401, .unverified, .transient] {
            scenario = nextScenario
            originalAttempts = 0
            _ = KeychainHelper.save(.apnsDeviceToken, token)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
            do {
                _ = try await client.fetchHostedSourceHealth(timeout: 8)
                XCTFail("Expected credential recovery failure")
            } catch let BackendClientError.httpStatus(status, _, _) {
                XCTAssertEqual(status, 401)
            }
            switch nextScenario {
            case .second401:
                XCTAssertEqual(originalAttempts, 2)
                XCTAssertNil(KeychainHelper.read(.apnsDeviceToken))
                XCTAssertNil(KeychainHelper.read(.apnsDeviceEnvironment))
            case .unverified:
                XCTAssertEqual(originalAttempts, 1)
                XCTAssertNil(KeychainHelper.read(.apnsDeviceToken))
                XCTAssertNil(KeychainHelper.read(.apnsDeviceEnvironment))
            case .transient:
                XCTAssertEqual(originalAttempts, 1)
                XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), token)
                XCTAssertEqual(KeychainHelper.read(.apnsDeviceEnvironment), client.apnsEnvironment)
            }
        }

        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 2)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), token)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceEnvironment), client.apnsEnvironment)
    }

    @MainActor
    func testPaidBackendCredentialRecoveryStagesRetainIndependentConnectionLossRetries() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        let token = String(repeating: "a", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        var originalAttempts = 0
        var registrationAttempts = 0
        var timeouts: [TimeInterval] = []
        MockURLProtocol.handler = { request in
            timeouts.append(request.timeoutInterval)
            clock.set(clock.now() + 1)
            if request.url?.path == "/api/devices/apns-token" {
                registrationAttempts += 1
                if registrationAttempts == 1 { throw URLError(.networkConnectionLost) }
                return (
                    Data(#"{"is_verified":true}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: nil))
                )
            }
            originalAttempts += 1
            switch originalAttempts {
            case 1, 3:
                throw URLError(.networkConnectionLost)
            case 2:
                return (
                    Data(#"{"detail":"Unauthorized"}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil))
                )
            default:
                return (
                    Data(#"{"sources":[]}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            }
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        _ = try await client.fetchHostedSourceHealth(timeout: 10)

        XCTAssertEqual(originalAttempts, 4)
        XCTAssertEqual(registrationAttempts, 2)
        XCTAssertEqual(timeouts.count, 6)
        for index in 1..<timeouts.count {
            XCTAssertEqual(timeouts[index - 1] - timeouts[index], 1, accuracy: 0.01)
        }
    }

    @MainActor
    func testPaidBackendCredentialRecoveryDeadlineAndCancellationPreventRegistration() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            monotonicNow: { clock.now() },
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        let token = String(repeating: "b", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            clock.set(109)
            return (
                Data(#"{"detail":"Unauthorized"}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchHostedSourceHealth(timeout: 8)
            XCTFail("Expected shared deadline expiry")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(requestCount, 1)

        requestCount = 0
        clock.set(100)
        let requestStarted = expectation(description: "device-authorized request started")
        MockURLProtocol.handler = { request in
            requestCount += 1
            requestStarted.fulfill()
            Thread.sleep(forTimeInterval: 0.2)
            return (
                Data(#"{"detail":"Unauthorized"}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil))
            )
        }
        let cancelled = Task {
            try await client.fetchHostedSourceHealth(timeout: 8)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), token)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
    }

    func testPaidBackendCredentialRecoveryDoesNotRunForOtherHTTPOrDecodeFailures() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        let token = String(repeating: "c", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        let statuses = [402, 403, 404, 500]
        var requestCount = 0
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            requestCount += 1
            let status = requestCount <= statuses.count ? statuses[requestCount - 1] : 200
            let data = status == 200
                ? Data(#"{"unexpected":true}"#.utf8)
                : Data(#"{"detail":{"code":"request_failed","message":"Rejected"}}"#.utf8)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        for expectedStatus in statuses {
            do {
                _ = try await client.fetchHostedSourceHealth(timeout: 8)
                XCTFail("Expected HTTP \(expectedStatus)")
            } catch let BackendClientError.httpStatus(status, code, message) {
                XCTAssertEqual(status, expectedStatus)
                XCTAssertEqual(code, "request_failed")
                XCTAssertEqual(message, "Rejected")
            }
        }
        do {
            _ = try await client.fetchHostedSourceHealth(timeout: 8)
            XCTFail("Expected decoding failure")
        } catch is DecodingError {
            // Expected.
        }

        XCTAssertEqual(requestCount, 5)
        XCTAssertEqual(paths, Array(repeating: "/api/source-health", count: 5))
    }

    @MainActor
    func testPaidBackendTransportDeadlineAndCancellationPreventRetry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(10)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        var requestCount = 0
        MockURLProtocol.handler = { _ in
            requestCount += 1
            clock.set(19)
            throw URLError(.networkConnectionLost)
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchHostedSourceHealth(timeout: 8)
            XCTFail("Expected shared deadline expiry")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(requestCount, 1)

        requestCount = 0
        clock.set(10)
        let requestStarted = expectation(description: "paid backend request started")
        MockURLProtocol.handler = { _ in
            requestCount += 1
            requestStarted.fulfill()
            Thread.sleep(forTimeInterval: 0.2)
            throw URLError(.networkConnectionLost)
        }
        let cancelled = Task {
            try await client.fetchHostedSourceHealth(timeout: 8)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testBackgroundPollRecoversRejectedCurrentEnvironmentTokenWithinSharedBudget() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        let originalSecret = KeychainHelper.read(.apnsDeviceSecret)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
            _ = KeychainHelper.save(.apnsDeviceSecret, originalSecret)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            monotonicNow: { clock.now() },
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        let token = String(repeating: "a", count: 64)
        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        _ = KeychainHelper.save(.apnsDeviceSecret, "device-secret")

        var paths: [String] = []
        var timeouts: [TimeInterval] = []
        var backgroundRequestCount = 0
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            timeouts.append(request.timeoutInterval)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "POST")
            if path == "/api/devices/background-refresh" {
                backgroundRequestCount += 1
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["token"] as? String, token)
                XCTAssertEqual(json["device_secret"] as? String, "device-secret")
                clock.set(backgroundRequestCount == 1 ? 102 : 106)
                return (
                    backgroundRequestCount == 1
                        ? Data(#"{"detail":{"code":"device_not_found","message":"Registration missing"}}"#.utf8)
                        : Data(),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: backgroundRequestCount == 1 ? 404 : 204,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
            XCTAssertEqual(path, "/api/devices/apns-token")
            clock.set(105)
            return (
                Data(#"{"is_verified":true,"verification_error":null}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        try await client.triggerBackgroundPoll(timeout: 8)

        XCTAssertEqual(paths, [
            "/api/devices/background-refresh",
            "/api/devices/apns-token",
            "/api/devices/background-refresh",
        ])
        XCTAssertEqual(timeouts[0], 8, accuracy: 0.01)
        XCTAssertEqual(timeouts[1], 6, accuracy: 0.01)
        XCTAssertEqual(timeouts[2], 3, accuracy: 0.01)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
    }

    func testBackgroundPollRetriesConnectionLostOnceWithRemainingDeadline() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, nil)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        var bodies: [Data] = []
        var timeouts: [TimeInterval] = []
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/devices/background-refresh")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            bodies.append(try XCTUnwrap(request.httpBody))
            timeouts.append(request.timeoutInterval)
            if requestCount == 1 {
                clock.set(102)
                throw URLError(.networkConnectionLost)
            }
            return (
                Data(),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        try await client.triggerBackgroundPoll(timeout: 8)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(timeouts[0], 8, accuracy: 0.01)
        XCTAssertEqual(timeouts[1], 6, accuracy: 0.01)
    }

    func testBackgroundPollStopsAfterSecondConnectionLoss() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, nil)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        var requestCount = 0
        MockURLProtocol.handler = { _ in
            requestCount += 1
            throw URLError(.networkConnectionLost)
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected the second connection loss to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(requestCount, 2)
    }

    func testBackgroundPollDoesNotRetryOtherTransportFailures() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, nil)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        var requestCount = 0
        let expectedErrors: [URLError.Code] = [.timedOut, .notConnectedToInternet, .badServerResponse]
        var nextErrorIndex = 0
        MockURLProtocol.handler = { _ in
            requestCount += 1
            defer { nextErrorIndex += 1 }
            throw URLError(expectedErrors[nextErrorIndex])
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        for expected in expectedErrors {
            do {
                try await client.triggerBackgroundPoll(timeout: 8)
                XCTFail("Expected transport failure \(expected)")
            } catch let error as URLError {
                XCTAssertEqual(error.code, expected)
            }
        }
        XCTAssertEqual(requestCount, expectedErrors.count)
    }

    func testBackgroundPollDoesNotRetryNonHTTPResponse() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, nil)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonHTTPResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        NonHTTPResponseURLProtocol.requestCount = 0
        defer {
            session.invalidateAndCancel()
            NonHTTPResponseURLProtocol.requestCount = 0
        }

        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected a non-HTTP response to be rejected")
        } catch BackendClientError.invalidResponse {
            // Expected.
        }
        XCTAssertEqual(NonHTTPResponseURLProtocol.requestCount, 1)
    }

    @MainActor
    func testBackgroundPollConnectionRetryStillRepairs404AndRetriesPostRegistrationLoss() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            monotonicNow: { clock.now() },
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        _ = KeychainHelper.save(.apnsDeviceToken, "cached-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        var paths: [String] = []
        var timeouts: [TimeInterval] = []
        var backgroundCount = 0
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            timeouts.append(request.timeoutInterval)
            if path == "/api/devices/apns-token" {
                clock.set(103)
                return (
                    Data(#"{"is_verified":true}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }

            backgroundCount += 1
            switch backgroundCount {
            case 1:
                clock.set(101)
                throw URLError(.networkConnectionLost)
            case 2:
                clock.set(102)
                return (
                    Data(#"{"detail":"Registration missing"}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            case 3:
                clock.set(104)
                throw URLError(.networkConnectionLost)
            default:
                return (
                    Data(),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 204,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        try await client.triggerBackgroundPoll(timeout: 8)

        XCTAssertEqual(paths, [
            "/api/devices/background-refresh",
            "/api/devices/background-refresh",
            "/api/devices/apns-token",
            "/api/devices/background-refresh",
            "/api/devices/background-refresh",
        ])
        XCTAssertEqual(timeouts[0], 8, accuracy: 0.01)
        XCTAssertEqual(timeouts[1], 7, accuracy: 0.01)
        XCTAssertEqual(timeouts[2], 6, accuracy: 0.01)
        XCTAssertEqual(timeouts[3], 5, accuracy: 0.01)
        XCTAssertEqual(timeouts[4], 4, accuracy: 0.01)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
    }

    func testBackgroundPollConnectionRetryHonorsSharedDeadline() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, nil)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(10)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        var requestCount = 0
        MockURLProtocol.handler = { _ in
            requestCount += 1
            clock.set(19)
            throw URLError(.networkConnectionLost)
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected shared deadline expiry")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testBackgroundPollDoesNotRecoverWithoutCurrentEnvironmentToken() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/devices/background-refresh")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(json["token"])
            XCTAssertNotNil(json["device_id"])
            return (
                Data(#"{"detail":"Device registration was not found"}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        for (token, environment) in [(nil, nil), ("cached-token", "other-environment")] {
            _ = KeychainHelper.save(.apnsDeviceToken, token)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, environment)
            do {
                try await client.triggerBackgroundPoll(timeout: 8)
                XCTFail("Expected missing device registration")
            } catch let BackendClientError.httpStatus(status, code, message) {
                XCTAssertEqual(status, 404)
                XCTAssertNil(code)
                XCTAssertEqual(message, "Device registration was not found")
            }
        }
        XCTAssertEqual(requestCount, 2)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
    }

    @MainActor
    func testBackgroundPollDoesNotRetryPaidOrServerFailuresAndBoundsDetail() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistration: { await invalidations.increment() }
        )
        _ = KeychainHelper.save(.apnsDeviceToken, "cached-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let paidFailure = requestCount == 1
            let message = paidFailure ? "Paid access required" : String(repeating: "x", count: 700)
            let code = paidFailure ? "paid_backend_required" : "upstream_failure"
            let data = try JSONSerialization.data(withJSONObject: [
                "detail": ["code": code, "message": message],
            ])
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: paidFailure ? 402 : 500,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected paid access rejection")
        } catch let BackendClientError.httpStatus(status, code, message) {
            XCTAssertEqual(status, 402)
            XCTAssertEqual(code, "paid_backend_required")
            XCTAssertEqual(message, "Paid access required")
        }
        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected server failure")
        } catch let BackendClientError.httpStatus(status, code, message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(code, "upstream_failure")
            XCTAssertEqual(message?.count, 512)
        }
        XCTAssertEqual(requestCount, 2)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 0)
    }

    @MainActor
    func testBackgroundPollInvalidatesUnverifiedRegistrationButKeepsTransientFailure() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistration: {
                await invalidations.increment()
                _ = KeychainHelper.save(.apnsDeviceToken, nil)
                _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)
            }
        )
        let token = "cached-token"
        var registrationAttempt = 0
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/devices/background-refresh" {
                return (
                    Data(),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
            registrationAttempt += 1
            if registrationAttempt == 1 {
                return (
                    Data(#"{"is_verified":false,"verification_error":"rejected"}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
            return (
                Data(#"{"detail":{"code":"temporary_failure","message":"Try later"}}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected unverified registration")
        } catch let BackendClientError.httpStatus(status, code, _) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "apns_unverified")
        }
        XCTAssertNil(KeychainHelper.read(.apnsDeviceToken))
        let unverifiedInvalidationCount = await invalidations.value()
        XCTAssertEqual(unverifiedInvalidationCount, 1)

        _ = KeychainHelper.save(.apnsDeviceToken, token)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected transient registration failure")
        } catch let BackendClientError.httpStatus(status, code, _) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(code, "temporary_failure")
        }
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), token)
        let transientInvalidationCount = await invalidations.value()
        XCTAssertEqual(transientInvalidationCount, 1)
    }

    @MainActor
    func testBackgroundPollSecond404InvalidatesRegistrationAndPreservesInitialDetail() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let invalidations = AsyncCounter()
        let client = BackendClient(
            session: session,
            invalidateAPNSRegistration: {
                await invalidations.increment()
                _ = KeychainHelper.save(.apnsDeviceToken, nil)
                _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)
            }
        )
        _ = KeychainHelper.save(.apnsDeviceToken, "cached-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        var backgroundCount = 0
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/devices/apns-token" {
                return (
                    Data(#"{"is_verified":true}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
            backgroundCount += 1
            let message = backgroundCount == 1 ? "Initial rejection" : "Retry rejection"
            return (
                Data("{\"detail\":\"\(message)\"}".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected repeated device rejection")
        } catch let BackendClientError.httpStatus(status, _, message) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(message, "Initial rejection")
        }
        XCTAssertEqual(backgroundCount, 2)
        let invalidationCount = await invalidations.value()
        XCTAssertEqual(invalidationCount, 1)
        XCTAssertNil(KeychainHelper.read(.apnsDeviceToken))
    }

    @MainActor
    func testBackgroundPollDeadlineAndCancellationPreventRecoveryTransport() async throws {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(10)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        _ = KeychainHelper.save(.apnsDeviceToken, "cached-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, client.apnsEnvironment)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            clock.set(19)
            return (
                Data(),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            try await client.triggerBackgroundPoll(timeout: 8)
            XCTFail("Expected shared deadline expiry")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(requestCount, 1)

        requestCount = 0
        clock.set(10)
        let requestStarted = expectation(description: "background request started")
        MockURLProtocol.handler = { request in
            requestCount += 1
            requestStarted.fulfill()
            Thread.sleep(forTimeInterval: 0.2)
            return (
                Data(),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        let cancelled = Task {
            try await client.triggerBackgroundPoll(timeout: 8)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testPaidPendingNotificationClientUsesAuthenticatedPostAndDeleteContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/watch-terms/42/notify")
            XCTAssertEqual(request.timeoutInterval, 9, accuracy: 0.01)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Device-Secret"))
            if requestCount == 1 {
                XCTAssertEqual(request.httpMethod, "POST")
                return (
                    Data(#"{"term_id":42,"keyword":"Aiko","count":3,"cleared":true}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (
                Data(),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let delivery = try await client.triggerPendingNotification(backendTermID: 42, timeout: 9)
        try await client.clearPendingNotification(backendTermID: 42, timeout: 9)

        XCTAssertEqual(
            delivery,
            BackendNotificationDelivery(term_id: 42, keyword: "Aiko", count: 3, cleared: true)
        )
        XCTAssertEqual(requestCount, 2)
    }

    func testHostedFeedMuteClientUsesAuthenticatedJSONPostAndDecodesErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/feed/muted-items")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 11, accuracy: 0.01)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Device-Secret"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["source_item_id"] as? String, "news:hosted-1")
            XCTAssertEqual(json["watch_term_id"] as? Int, 42)
            if requestCount == 1 {
                return (
                    Data(),
                    try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil))
                )
            }
            return (
                Data(#"{"detail":{"code":"paid_backend_required","message":"Paid access required"}}"#.utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 402, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        try await client.muteHostedFeedItem(
            sourceItemID: "news:hosted-1",
            watchTermID: 42,
            timeout: 11
        )
        do {
            try await client.muteHostedFeedItem(
                sourceItemID: "news:hosted-1",
                watchTermID: 42,
                timeout: 11
            )
            XCTFail("Expected paid access rejection")
        } catch let BackendClientError.httpStatus(status, code, message) {
            XCTAssertEqual(status, 402)
            XCTAssertEqual(code, "paid_backend_required")
            XCTAssertEqual(message, "Paid access required")
        }
        XCTAssertEqual(requestCount, 2)
    }

    func testBackendFeedClientDrainsSnapshotPagesBeforeAdvancing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        let lock = NSLock()
        var requestIndex = 0
        var requestedCursorIDs: [String?] = []
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            ))
            lock.lock()
            let index = requestIndex
            requestIndex += 1
            requestedCursorIDs.append(
                components.queryItems?.first(where: { $0.name == "scan_before_match_id" })?.value
            )
            lock.unlock()
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "2")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "scan" })?.value, "true")
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == "until" })?.value,
                "2026-08-22T13:00:00Z"
            )
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == "term_ids" })?.value,
                "11,22"
            )
            let ids: [String]
            let headers: [String: String]?
            switch index {
            case 0:
                ids = ["one", "two"]
                headers = [
                    "X-OshiReader-Next-Published-At": "2026-08-22T11:00:00Z",
                    "X-OshiReader-Next-Match-ID": "42",
                ]
            case 1:
                ids = []
                headers = [
                    "X-OshiReader-Next-Published-At": "2026-08-22T10:00:00Z",
                    "X-OshiReader-Next-Match-ID": "21",
                ]
            default:
                ids = ["three"]
                headers = nil
            }
            let rows = ids.map { id in
                """
                {
                  "watch_term_keyword": "Aiko",
                  "matched_at": "2026-08-22T12:01:00Z",
                  "item": {
                    "id": "news:\(id)",
                    "platform": "news",
                    "url": "https://example.com/\(id)",
                    "title": "Aiko \(id)",
                    "content_text": null,
                    "author": null,
                    "thumbnail_url": null,
                    "media_type": "article",
                    "published_at": "2026-08-22T12:00:00Z",
                    "source": "news"
                  }
                }
                """
            }.joined(separator: ",")
            return (
                Data("[\(rows)]".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let items = try await client.fetchAllBackendFeed(
            termIDs: [11, 22],
            pageSize: 2,
            since: "2026-08-22T12:00:00Z",
            until: "2026-08-22T13:00:00Z"
        )

        XCTAssertEqual(items.map(\.id), ["news:one", "news:two", "news:three"])
        lock.lock()
        let cursorIDs = requestedCursorIDs
        lock.unlock()
        XCTAssertEqual(cursorIDs.count, 3)
        XCTAssertNil(cursorIDs[0])
        XCTAssertEqual(cursorIDs[1], "42")
        XCTAssertEqual(cursorIDs[2], "21")
    }

    func testBackendFeedPaginationUsesIndependentRetryBudgetForEachPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestMonotonicClock(100)
        let client = BackendClient(session: session, monotonicNow: { clock.now() })
        var attempts: [String: Int] = [:]
        var timeouts: [String: [TimeInterval]] = [:]
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            ))
            let cursor = components.queryItems?
                .first(where: { $0.name == "scan_before_match_id" })?.value ?? "root"
            attempts[cursor, default: 0] += 1
            timeouts[cursor, default: []].append(request.timeoutInterval)
            if attempts[cursor] == 1 {
                clock.set(clock.now() + 2)
                throw URLError(.networkConnectionLost)
            }

            let data: Data
            let headers: [String: String]?
            if cursor == "root" {
                data = Data("""
                [{
                  "watch_term_keyword": "Aiko",
                  "matched_at": "2026-08-22T12:01:00Z",
                  "item": {
                    "id": "news:retry-page",
                    "platform": "news",
                    "url": "https://example.com/retry-page",
                    "title": "Aiko retry page",
                    "content_text": null,
                    "author": null,
                    "thumbnail_url": null,
                    "media_type": "article",
                    "published_at": "2026-08-22T12:00:00Z",
                    "source": "news"
                  }
                }]
                """.utf8)
                headers = [
                    "X-OshiReader-Next-Published-At": "2026-08-22T11:00:00Z",
                    "X-OshiReader-Next-Match-ID": "42",
                ]
            } else {
                XCTAssertEqual(cursor, "42")
                data = Data("[]".utf8)
                headers = nil
            }
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let items = try await client.fetchAllBackendFeed(
            termIDs: [11],
            pageSize: 2,
            until: "2026-08-22T13:00:00Z"
        )

        XCTAssertEqual(items.map(\.id), ["news:retry-page"])
        XCTAssertEqual(attempts, ["root": 2, "42": 2])
        let rootTimeouts = try XCTUnwrap(timeouts["root"])
        let continuationTimeouts = try XCTUnwrap(timeouts["42"])
        XCTAssertEqual(rootTimeouts[0], 30, accuracy: 0.01)
        XCTAssertEqual(rootTimeouts[1], 28, accuracy: 0.01)
        XCTAssertEqual(continuationTimeouts[0], 30, accuracy: 0.01)
        XCTAssertEqual(continuationTimeouts[1], 28, accuracy: 0.01)
    }

    func testBackendFeedClientRejectsFullPageWithoutScanContinuationContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            let data = Data("""
            [{
              "watch_term_keyword": "Aiko",
              "matched_at": "2026-08-22T12:01:00Z",
              "item": {
                "id": "news:legacy-page",
                "platform": "news",
                "url": "https://example.com/legacy-page",
                "title": "Aiko legacy page",
                "content_text": null,
                "author": null,
                "thumbnail_url": null,
                "media_type": "article",
                "published_at": "2026-08-22T12:00:00Z",
                "source": "news"
              }
            }]
            """.utf8)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchAllBackendFeed(
                termIDs: [11],
                pageSize: 1,
                until: "2026-08-22T13:00:00Z"
            )
            XCTFail("Expected a full page without scan continuation metadata to fail")
        } catch BackendClientError.invalidResponse {
            // Expected: the caller must not advance its refresh cutoff.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendFeedClientRejectsIncreasingMatchCursor() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        let lock = NSLock()
        var requestIndex = 0
        MockURLProtocol.handler = { request in
            lock.lock()
            let index = requestIndex
            requestIndex += 1
            lock.unlock()
            let headers = [
                "X-OshiReader-Next-Published-At": "2026-08-22T\(11 - index):00:00Z",
                "X-OshiReader-Next-Match-ID": index == 0 ? "42" : "84",
            ]
            return (
                Data("[]".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchAllBackendFeed(
                termIDs: [11],
                pageSize: 1,
                until: "2026-08-22T13:00:00Z"
            )
            XCTFail("Expected an increasing immutable match cursor to fail")
        } catch BackendClientError.invalidResponse {
            // Expected: continuation scans must move to lower match IDs.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendFeedClientRejectsLaterFullPageWithoutScanContinuationContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        let lock = NSLock()
        var requestIndex = 0
        MockURLProtocol.handler = { request in
            lock.lock()
            let index = requestIndex
            requestIndex += 1
            lock.unlock()
            let headers = index == 0 ? [
                "X-OshiReader-Next-Published-At": "2026-08-22T12:00:00Z",
                "X-OshiReader-Next-Match-ID": "42",
            ] : nil
            let data = Data("""
            [{
              "watch_term_keyword": "Aiko",
              "matched_at": "2026-08-22T12:01:00Z",
              "item": {
                "id": "news:\(index)",
                "platform": "news",
                "url": "https://example.com/\(index)",
                "title": "Aiko \(index)",
                "content_text": null,
                "author": null,
                "thumbnail_url": null,
                "media_type": "article",
                "published_at": "2026-08-22T12:00:00Z",
                "source": "news"
              }
            }]
            """.utf8)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchAllBackendFeed(
                termIDs: [11],
                pageSize: 1,
                until: "2026-08-22T13:00:00Z"
            )
            XCTFail("Expected a later full page without scan continuation metadata to fail")
        } catch BackendClientError.invalidResponse {
            // Expected: every full scan page must carry continuation metadata.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(requestIndex, 2)
    }

    func testBackendFeedClientDrainsMoreThanOneHundredContinuationPages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        let lock = NSLock()
        var requestIndex = 0
        MockURLProtocol.handler = { request in
            lock.lock()
            let index = requestIndex
            requestIndex += 1
            lock.unlock()
            let headers: [String: String]? = index < 102 ? [
                "X-OshiReader-Next-Published-At": "2026-08-22T12:00:00Z",
                "X-OshiReader-Next-Match-ID": String(1_000 - index),
            ] : nil
            let data = index < 102 ? Data("""
            [{
              "watch_term_keyword": "Aiko",
              "matched_at": "2026-08-22T12:01:00Z",
              "item": {
                "id": "news:\(index)",
                "platform": "news",
                "url": "https://example.com/\(index)",
                "title": "Aiko \(index)",
                "content_text": null,
                "author": null,
                "thumbnail_url": null,
                "media_type": "article",
                "published_at": "2026-08-22T12:00:00Z",
                "source": "news"
              }
            }]
            """.utf8) : Data("[]".utf8)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let items = try await client.fetchAllBackendFeed(
            termIDs: [11],
            pageSize: 1,
            until: "2026-08-22T13:00:00Z"
        )

        XCTAssertEqual(items.count, 102)
        XCTAssertEqual(requestIndex, 103)
    }

    func testBackendFeedClientSurfacesPaidAccessError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            let data = Data("""
            {"detail":{"code":"paid_backend_required","message":"An active purchase is required for backend feed access"}}
            """.utf8)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 402, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchBackendFeed()
            XCTFail("Expected paid backend access to be rejected")
        } catch let BackendClientError.httpStatus(status, code, message) {
            XCTAssertEqual(status, 402)
            XCTAssertEqual(code, "paid_backend_required")
            XCTAssertEqual(message, "An active purchase is required for backend feed access")
        }
    }

    func testBackendFeedClientUsesIncrementalCursorInsteadOfDateWindow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == "since" })?.value,
                "2026-08-22T12:00:00Z"
            )
            XCTAssertNil(components.queryItems?.first(where: { $0.name == "days" }))
            return (
                Data("[]".utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let items = try await client.fetchBackendFeed(since: "2026-08-22T12:00:00Z")

        XCTAssertTrue(items.isEmpty)
    }

    func testFeedThumbnailLoaderDownsamplesLargeImages() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400))
        let data = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }

        let image = try XCTUnwrap(
            FeedThumbnailLoader.downsample(data: data, maxPixelSize: 144)
        )

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 144)
    }

    func testFeedThumbnailLoaderCoalescesConcurrentRequests() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/thumb.png"))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let data = renderer.pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let loader = FeedThumbnailLoader(session: session)
        let lock = NSLock()
        var requestCount = 0
        MockURLProtocol.handler = { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.1)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        async let first = loader.image(for: url)
        async let second = loader.image(for: url)
        let images = await [first, second]

        XCTAssertEqual(images.compactMap { $0 }.count, 2)
        lock.lock()
        let count = requestCount
        lock.unlock()
        XCTAssertEqual(count, 1)
    }

    func testFeedThumbnailLoaderUsesMemoryCacheForSequentialRequests() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/cached-thumb.png"))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let data = renderer.pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let loader = FeedThumbnailLoader(session: session)
        let lock = NSLock()
        var requestCount = 0
        MockURLProtocol.handler = { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let first = await loader.image(for: url)
        let second = await loader.image(for: url)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        lock.lock()
        let count = requestCount
        lock.unlock()
        XCTAssertEqual(count, 1)
    }

    func testPlatformRegistryMatchesPlusSourceCatalogOrderAndDefaults() {
        let ids = Set(PlatformRegistry.all.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [
            "smartnews", "ameblo", "aera", "hochi", "sponichi", "livedoor",
            "mantanweb", "realsound", "cinemacafe", "thetv", "natalie",
            "billboardjapan", "soompi", "allkpop", "kpopofficial", "barks"
        ]))
        XCTAssertEqual(PlatformRegistry.definition(for: "soompi")?.newsLocale, .englishUS)
        XCTAssertEqual(PlatformRegistry.definition(for: "soompi")?.newsLocale.acceptLanguage, "en,ko;q=0.9,ja;q=0.7")
        XCTAssertTrue(PlatformRegistry.strictKeywordPlatformIDs.contains("allkpop"))
        XCTAssertEqual(PlatformRegistry.definition(for: "natalie")?.googleNewsSite, "natalie.mu")
        XCTAssertNil(PlatformRegistry.definition(for: "twitter")?.googleNewsSite)
        XCTAssertEqual(PlatformRegistry.definition(for: "custom")?.googleNewsSite, nil)
        XCTAssertEqual(Array(PlatformRegistry.all.prefix(5).map(\.id)), ["youtube", "niconico", "tver", "twitter", "note"])
        XCTAssertEqual(PlatformRegistry.defaultSubscribedIDs, PlatformRegistry.all.map(\.id))
        XCTAssertEqual(PlatformRegistry.defaultSubscribedIDs.last, "custom")
        XCTAssertTrue(PlatformRegistry.defaultSubscribedIDs.contains("twitter"))
        XCTAssertTrue(PlatformRegistry.defaultSubscribedIDs.contains("soompi"))
        XCTAssertEqual(PlatformRegistry.mediaPlatformIDs, Set(["youtube", "niconico", "tver"]))
        XCTAssertEqual(PlatformRegistry.activityDateWindowPlatformIDs, Set(["5ch", "girlschannel"]))
        XCTAssertEqual(PlatformRegistry.dateCutoffExemptPlatformIDs, Set(["5ch", "girlschannel"]))
        XCTAssertEqual(PlatformRegistry.definition(for: "x")?.rawPlatformValues, Set(["twitter", "x"]))
    }

    func testPlatformRegistryExcludesRemovedTogetterSource() {
        XCTAssertNil(PlatformRegistry.definition(for: "togetter"))
        XCTAssertFalse(PlatformRegistry.defaultSubscribedIDs.contains("togetter"))
        XCTAssertFalse(PlatformRegistry.strictKeywordPlatformIDs.contains("togetter"))
        XCTAssertFalse(PlatformRegistry.googleNewsSources.contains { $0.id == "togetter" })
        XCTAssertEqual(PlatformRegistry.normalizeIDs(["togetter", "news", "youtube"]), ["news", "youtube"])
    }

    func testPlatformRegistryNormalizesLegacyRawPlatformIDs() {
        XCTAssertEqual(PlatformRegistry.normalizeID(" x "), "twitter")
        XCTAssertEqual(PlatformRegistry.normalizeID("news:mdpr"), "mdpr")
        XCTAssertEqual(PlatformRegistry.normalizeID("news:yahoo_ent"), "yahoonews")
        XCTAssertEqual(PlatformRegistry.normalizeID("news:unknown"), "news")
        XCTAssertEqual(PlatformRegistry.definition(for: "x")?.id, "twitter")
        XCTAssertEqual(PlatformRegistry.normalizeIDs(["x", "twitter", "news:mdpr", "unknown"]), ["twitter", "mdpr"])
    }

    func testDedicatedSearchLinksUseDedicatedPlatformIDs() {
        let registeredIDs = Set(PlatformRegistry.all.map(\.id))
        let mismatches = staticSearchLinks.compactMap { link -> String? in
            guard registeredIDs.contains(link.id), link.platform != link.id else { return nil }
            return "\(link.id)->\(link.platform)"
        }

        XCTAssertEqual(mismatches, [])
    }

    func testCustomSearchLinkFeedItemCarriesCustomSource() {
        let link = SearchLink(
            id: "custom:https%3A%2F%2Fexample.com%2Ffeed.xml",
            group: "Custom",
            label: "Example Feed",
            domain: "example.com",
            platform: "custom",
            makeUrl: { _ in "https://example.com/feed.xml" }
        )

        let item = link.feedItem(keyword: "  ignored  ", now: "2026-06-02T12:00:00Z")

        XCTAssertEqual(item.id, link.id)
        XCTAssertEqual(item.url, "https://example.com/feed.xml")
        XCTAssertEqual(item.title, "Example Feed")
        XCTAssertEqual(item.watch_term_keyword, "")
        XCTAssertEqual(item.source, "custom_url")
    }

    func testOrdinarySearchLinkFeedItemDoesNotCarryCustomSource() {
        let link = SearchLink(
            id: "google-news",
            group: "News",
            label: "Google News Japan",
            domain: "news.google.com",
            platform: "news",
            makeUrl: { "https://news.google.com/search?q=\($0.replacingOccurrences(of: " ", with: "+"))" }
        )

        let item = link.feedItem(keyword: "  Aiko  ", now: "2026-06-02T12:00:00Z")

        XCTAssertEqual(item.id, "search:google-news:Aiko")
        XCTAssertEqual(item.title, "Google News Japan: Aiko")
        XCTAssertEqual(item.watch_term_keyword, "Aiko")
        XCTAssertNil(item.source)
    }

    func testSavedSubscribedPlatformsDoNotReAddMissingDefaultsOnLoad() {
        XCTAssertEqual(
            LocalDB.subscribedPlatformsForLoadedValue(["news", " youtube ", "unknown", "news", "x", "news:mdpr", "NEWS:YAHOO_ENT"], hasSavedFile: true),
            ["news", "youtube", "twitter", "mdpr", "yahoonews"]
        )
        XCTAssertEqual(
            LocalDB.subscribedPlatformsForLoadedValue(["news"], hasSavedFile: false),
            PlatformRegistry.defaultSubscribedIDs
        )
    }

    @MainActor
    func testSetSourcesOrderNormalizesAliasesAndDropsUnknownIDs() {
        db.setSourcesOrder(order: ["custom", "unknown", " news:mdpr ", "x", "custom", "NEWS:YAHOO_ENT"])

        XCTAssertEqual(db.sourcesOrder, ["custom", "mdpr", "twitter", "yahoonews"])
    }

    func testLoadedSourcesOrderNormalizesAliasesAndPreservesMissingValue() {
        XCTAssertEqual(
            LocalDB.normalizedSourcesOrder(["unknown", " news:mdpr ", "x", "custom", "custom"]),
            ["mdpr", "twitter", "custom"]
        )
        XCTAssertNil(LocalDB.normalizedSourcesOrder(nil))
    }

    func testIngestionSearchKeywordsIncludesTrimmedUniqueAliases() {
        let term = WatchTerm(
            keyword: "  Primary Oshi ",
            aliases: ["Alias Oshi", "Primary Oshi", "  Alias Oshi  ", "", "Alias 3", "Alias 4", "Alias 5", "Alias 6", "Alias 7"]
        )

        XCTAssertEqual(IngestionService.searchKeywords(for: term), [
            "Primary Oshi", "Alias Oshi", "Alias 3", "Alias 4", "Alias 5", "Alias 6"
        ])
    }

    func testBackgroundRefreshCapsAliasesWithoutChangingForegroundSearchKeywords() {
        let term = WatchTerm(
            keyword: "Primary Oshi",
            aliases: ["Alias 1", "Alias 2", "Alias 3", "Alias 4", "Alias 5"]
        )

        XCTAssertEqual(IngestionService.searchKeywords(for: term), [
            "Primary Oshi", "Alias 1", "Alias 2", "Alias 3", "Alias 4", "Alias 5"
        ])
        XCTAssertEqual(
            IngestionService.searchKeywords(for: term, maximumAliases: LocalRefreshRequest.background.maximumAliases),
            ["Primary Oshi", "Alias 1"]
        )
    }

    func testBackgroundRefreshKeywordWeightCountsAliasesButNotCustomUnits() {
        let plain = WatchTerm(keyword: "Plain")
        let aliased = WatchTerm(keyword: "Aliased", aliases: ["Alias 1"])
        let custom = CustomUrl(id: "custom", url: "https://example.com", title: nil, added_at: "2026-08-01T00:00:00Z")

        XCTAssertEqual(LocalRefreshCoordinator.keywordWeight(for: .source(term: plain, platform: "news")), 1)
        XCTAssertEqual(LocalRefreshCoordinator.keywordWeight(for: .source(term: aliased, platform: "news")), 2)
        XCTAssertEqual(LocalRefreshCoordinator.keywordWeight(for: .custom(custom)), 0)
    }

    func testBackgroundRefreshChunkEndStaysWithinSharedLimiterCapacityDespiteAliases() {
        // 4 units that would each want 2 sourceRequestLimiter slots (primary +
        // 1 alias, `LocalRefreshRequest.background.maximumAliases`) must not
        // all land in one chunk: `IngestionService.sourceRequestLimiter`'s
        // capacity is 4, so 4 units × 2 keywords = 8 would oversubscribe it.
        let aliasedUnits = (0..<4).map { index in
            BackgroundRefreshUnit.source(
                term: WatchTerm(keyword: "Term \(index)", aliases: ["Alias"]),
                platform: "news"
            )
        }
        let limiterCapacity = IngestionService.sourceRequestLimiter.capacity

        let firstChunkEnd = LocalRefreshCoordinator.chunkEnd(startingAt: 0, in: aliasedUnits)
        let totalWeight = aliasedUnits[0..<firstChunkEnd].reduce(0) { $0 + LocalRefreshCoordinator.keywordWeight(for: $1) }
        XCTAssertLessThanOrEqual(totalWeight, limiterCapacity)
        XCTAssertLessThan(firstChunkEnd, aliasedUnits.count, "aliased units alone shouldn't all fit in one chunk")

        // Units with no aliases (weight 1 each) should still fill a chunk up
        // to the unit-count cap, since 4 of them fit within the limiter's
        // capacity of 4.
        let plainUnits = (0..<4).map { index in
            BackgroundRefreshUnit.source(term: WatchTerm(keyword: "Plain \(index)"), platform: "news")
        }
        XCTAssertEqual(LocalRefreshCoordinator.chunkEnd(startingAt: 0, in: plainUnits), plainUnits.count)

        // A single unit heavier than the limiter's capacity must still be
        // admitted on its own rather than producing an empty chunk.
        let heavyUnit = BackgroundRefreshUnit.source(
            term: WatchTerm(keyword: "Heavy", aliases: Array(repeating: "Alias", count: limiterCapacity + 5)),
            platform: "news"
        )
        XCTAssertEqual(LocalRefreshCoordinator.chunkEnd(startingAt: 0, in: [heavyUnit]), 1)

        // Custom-URL units carry zero weight, so a run of them fills the
        // chunk up to the raw unit-count cap regardless of the limiter.
        let customUnits = (0..<6).map { index in
            BackgroundRefreshUnit.custom(CustomUrl(id: "custom\(index)", url: "https://example.com/\(index)", title: nil, added_at: "2026-08-01T00:00:00Z"))
        }
        XCTAssertEqual(LocalRefreshCoordinator.chunkEnd(startingAt: 0, in: customUnits), 4)
    }

    func testBackgroundRefreshPlanRotatesTermsAndSourcesWithoutStarvation() {
        let first = WatchTerm(id: "first", keyword: "First")
        let second = WatchTerm(id: "second", keyword: "Second")
        let platforms = ["youtube", "news", "mdpr", "oricon", "custom"]

        let plans = (0..<3).map {
            BackgroundRefreshPlan.make(terms: [first, second], subscribedPlatforms: platforms, legacyCursor: $0)
        }

        XCTAssertEqual(plans[0].units.first, .source(term: first, platform: "mdpr"))
        XCTAssertEqual(plans[1].units.first, .source(term: second, platform: "mdpr"))
        XCTAssertEqual(plans[2].units.first, .source(term: first, platform: "news"))
        XCTAssertTrue(plans.allSatisfy { $0.totalWorkCount == 8 })
        XCTAssertEqual(Set(plans[0].units), Set([
            .source(term: first, platform: "youtube"),
            .source(term: first, platform: "news"),
            .source(term: first, platform: "mdpr"),
            .source(term: first, platform: "oricon"),
            .source(term: second, platform: "youtube"),
            .source(term: second, platform: "news"),
            .source(term: second, platform: "mdpr"),
            .source(term: second, platform: "oricon")
        ]))
    }

    func testBackgroundRefreshPlanHonorsSelectedSourcesAndSkipsCustomPlatform() {
        let selected = WatchTerm(
            id: "selected",
            keyword: "Selected",
            source_mode: .selected,
            selected_platforms: ["mdpr", "custom"]
        )

        let plan = BackgroundRefreshPlan.make(
            terms: [selected],
            subscribedPlatforms: ["youtube", "mdpr", "custom"],
            customURLs: [],
            legacyCursor: 5
        )

        XCTAssertEqual(plan.units, [.source(term: selected, platform: "mdpr")])
        XCTAssertEqual(plan.totalWorkCount, 1)
    }

    func testBackgroundRefreshPlanIncludesAndRotatesCustomURLs() {
        let term = WatchTerm(id: "term", keyword: "Term")
        let custom = CustomUrl(id: "custom", url: "https://example.com", title: nil, added_at: "2026-08-01T00:00:00Z")

        let plan = BackgroundRefreshPlan.make(
            terms: [term],
            subscribedPlatforms: ["news"],
            customURLs: [custom],
            legacyCursor: 1
        )

        XCTAssertEqual(plan.units, [
            .custom(custom),
            .source(term: term, platform: "news")
        ])
        XCTAssertEqual(plan.totalWorkCount, 2)
    }

    func testBackgroundRefreshPlanResumesAfterStableUnitWhenPriorityOrderChanges() {
        let first = WatchTerm(id: "first", keyword: "First")
        let second = WatchTerm(id: "second", keyword: "Second")
        let completed = BackgroundRefreshUnit.source(term: second, platform: "youtube")

        let plan = BackgroundRefreshPlan.make(
            terms: [second, first],
            subscribedPlatforms: ["youtube", "news"],
            lastCompletedUnitID: completed.stableID,
            legacyCursor: 99
        )

        XCTAssertEqual(plan.units.first, .source(term: first, platform: "news"))
        XCTAssertEqual(Set(plan.units).count, 4)
    }

    func testBackgroundRefreshCheckpointRejectsLateAndStaleUnits() {
        let deadline = Date()

        XCTAssertTrue(BackgroundRefreshCheckpoint.isValid(
            sourceRevision: 4,
            currentRevision: 4,
            completedAt: deadline,
            deadline: deadline
        ))
        XCTAssertFalse(BackgroundRefreshCheckpoint.isValid(
            sourceRevision: 4,
            currentRevision: 5,
            completedAt: deadline,
            deadline: deadline
        ))
        XCTAssertFalse(BackgroundRefreshCheckpoint.isValid(
            sourceRevision: 4,
            currentRevision: 4,
            completedAt: deadline.addingTimeInterval(0.001),
            deadline: deadline
        ))
    }

    func testCanonicalURLForDedupRemovesTrackingParametersOnly() {
        XCTAssertEqual(
            IngestionService.canonicalURLForDedup(
                "HTTPS://Example.COM/article/123/?utm_source=news&ref=homepage&gclid=abc#comments"
            ),
            "https://example.com/article/123?ref=homepage"
        )
        XCTAssertEqual(
            IngestionService.canonicalURLForDedup(
                "https://example.com/video?id=123&utm_campaign=spring"
            ),
            "https://example.com/video?id=123"
        )
        XCTAssertEqual(
            IngestionService.canonicalURLForDedup("not a URL"),
            "not a URL"
        )
    }

    func testFiveChBBsmenuParserNormalizesAndDeduplicatesOnly2chBoards() {
        let menu = """
        <a href=\"http://toro.2ch.sc/nogizaka/\">Nogizaka</a>
        <a href=\"https://TORO.2CH.SC/nogizaka/\">duplicate</a>
        <a href=\"https://example.com/not-fivech/\">ignore</a>
        <a href=\"http://menu.2ch.sc/bbsmenu.html\">ignore menu</a>
        <a href=\"javascript:void(0)\">malformed</a>
        """
        XCTAssertEqual(
            IngestionService.parseFiveChBBsmenu(menu),
            ["https://toro.2ch.sc/nogizaka/"]
        )
    }

    func testFiveChDirectScanDecodesShiftJISAndUsesLatestDatReplyDate() async throws {
        let capture = RequestCapture()
        let subject = try XCTUnwrap(
            "1787000000.dat<>Oshi &amp; stage update (42)\n".data(using: .shiftJIS)
        )
        let unrelatedSubject = try XCTUnwrap(
            "1787000001.dat<>Unrelated topic (3)\n".data(using: .shiftJIS)
        )
        let dat = try XCTUnwrap(
            "name<>mail<>2026/08/25(火) 12:34:56.00 ID:test<>body<>title\n".data(using: .shiftJIS)
        )
        let fixedNow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-25T12:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = try XCTUnwrap(request.url)
                await capture.record(url.absoluteString)
                let data: Data
                if url.path.hasSuffix("/subject.txt") {
                    data = url.host == "toro.2ch.sc" && url.path.contains("/nogizaka/")
                        ? subject
                        : unrelatedSubject
                } else if url.path.hasSuffix("/dat/1787000000.dat") {
                    data = dat
                } else {
                    throw URLError(.badServerResponse)
                }
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            now: { fixedNow }
        )

        let first = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["5ch"]
        )
        let second = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["5ch"]
        )

        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.items.first?.id, "2ch.sc:toro.2ch.sc:nogizaka:1787000000")
        XCTAssertEqual(first.items.first?.title, "Oshi & stage update")
        XCTAssertEqual(first.items.first?.url, "https://toro.2ch.sc/test/read.cgi/nogizaka/1787000000/")
        XCTAssertEqual(first.items.first?.published_at, "2026-08-25T03:34:56Z")
        XCTAssertEqual(first.items.first?.source, IngestionService.fiveChVerifiedActivitySource)
        XCTAssertEqual(first.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(second.items.map(\.id), first.items.map(\.id))
        let subjectRequestCount = await capture.count(containing: "/subject.txt")
        let datRequestCount = await capture.count(containing: "/dat/1787000000.dat")
        XCTAssertEqual(subjectRequestCount, 44)
        XCTAssertEqual(datRequestCount, 2)
    }

    func testFiveChDirectScanCapsResultsAndSubjectConcurrency() async throws {
        let subjectText = (0..<30).map { index in
            "178700\(String(format: "%04d", index)).dat<>Cap Oshi thread \(index) (\(index + 1))"
        }.joined(separator: "\n")
        let subject = try XCTUnwrap(subjectText.data(using: .shiftJIS))
        let unrelated = try XCTUnwrap("1787999999.dat<>Other topic (1)\n".data(using: .shiftJIS))
        let dat = try XCTUnwrap(
            "name<>mail<>2026/08/25(火) 10:00:00.00 ID:test<>body<>title\n".data(using: .shiftJIS)
        )
        let concurrency = ConcurrentRequestCapture()
        let fixedNow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-25T12:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = try XCTUnwrap(request.url)
                await concurrency.begin()
                try? await Task.sleep(nanoseconds: 1_000_000)
                await concurrency.end()
                let data: Data
                if url.path.hasSuffix("/subject.txt") {
                    data = url.host == "toro.2ch.sc" && url.path.contains("/nogizaka/") ? subject : unrelated
                } else if url.path.contains("/dat/") {
                    data = dat
                } else {
                    throw URLError(.badServerResponse)
                }
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            now: { fixedNow }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Cap Oshi"),
            platforms: ["5ch"]
        )

        XCTAssertEqual(report.items.count, 25)
        XCTAssertEqual(Set(report.items.map(\.id)).count, 25)
        let maximumActive = await concurrency.maximumActive
        XCTAssertLessThanOrEqual(maximumActive, 4)
    }

    func testFiveChForegroundFallsBackToGoogleNewsWhenDirectScanIsEmpty() async throws {
        let capture = RequestCapture()
        let unrelated = try XCTUnwrap("1787000001.dat<>Unrelated topic (3)\n".data(using: .shiftJIS))
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>Fallback Oshi thread - 5ch</title>
        <link>https://news.google.com/rss/articles/fivech-fallback</link>
        <pubDate>Tue, 25 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                let url = try XCTUnwrap(request.url)
                await capture.record(url.absoluteString)
                let data = url.host == "news.google.com" ? rss : unrelated
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["5ch"]
        )

        let directRequestCount = await capture.count(containing: "2ch.sc/")
        let googleNewsRequestCount = await capture.count(containing: "news.google.com/")
        XCTAssertGreaterThan(directRequestCount, 0)
        XCTAssertGreaterThan(googleNewsRequestCount, 0)
        XCTAssertEqual(report.items.first?.source, IngestionService.unverifiedDateGoogleNewsSource)
    }

    func testFiveChBackgroundScopeSkipsDirectBoardRequests() async throws {
        let capture = RequestCapture()
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>Background Oshi thread - 5ch</title>
        <link>https://news.google.com/rss/articles/fivech-background</link>
        <pubDate>Tue, 25 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                let url = try XCTUnwrap(request.url)
                await capture.record(url.absoluteString)
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Background Oshi"),
            platforms: ["5ch"],
            fetchScope: .background
        )

        let directRequestCount = await capture.count(containing: "2ch.sc/")
        let googleNewsRequestCount = await capture.count(containing: "news.google.com/")
        XCTAssertEqual(directRequestCount, 0)
        XCTAssertGreaterThan(googleNewsRequestCount, 0)
        XCTAssertEqual(report.items.first?.platform, "5ch")
    }

    func testFiveChExpiredDeadlineDoesNotStartDirectOrFallbackRequests() async throws {
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                throw URLError(.timedOut)
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Deadline Oshi"),
            platforms: ["5ch"],
            requestDeadline: Date().addingTimeInterval(-1)
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.timeout))
    }

    func testNatalieDedicatedRSSProducesNatalieItemsAcrossBothFeeds() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Natalie Oshi music update</title>
        <link>https://natalie.mu/music/news/123?utm_source=rss</link>
        <description>Natalie Oshi news</description>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let capture = RequestCapture()
        let service = IngestionService { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Natalie Oshi"),
            platforms: ["natalie"]
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(Set(report.items.map(\.platform)), Set(["natalie"]))
        XCTAssertTrue(report.items.allSatisfy { $0.id.hasPrefix("natalie:") })
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testBarksDedicatedRSSProducesBarksItemsAndPreservesOriginalURL() async {
        let originalURL = "https://www.barks.jp/news/123?utm_campaign=feed"
        let rss = """
        <rss version="2.0"><channel><item>
        <title>BARKS Oshi feature</title>
        <link>\(originalURL)</link>
        <description>BARKS Oshi feature description</description>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let capture = RequestCapture()
        let service = IngestionService { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BARKS Oshi"),
            platforms: ["barks"]
        )

        let requestCount = await capture.count()
        let firstURL = await capture.firstURL()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(firstURL, "https://barks.jp/feed/")
        XCTAssertEqual(report.items.first?.platform, "barks")
        XCTAssertEqual(report.items.first?.url, originalURL)
    }

    func testDedicatedRSSSortsByPublishedDateBeforeApplyingSourceCap() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss Z"
        let baseDate = Date(timeIntervalSince1970: 1_785_000_000)
        let itemXML = (0..<27).map { index in
            let date = formatter.string(from: baseDate.addingTimeInterval(TimeInterval(index * 60)))
            return """
            <item>
            <title>Cap Oshi item \(index)</title>
            <link>https://barks.jp/articles/\(index)</link>
            <pubDate>\(date)</pubDate>
            </item>
            """
        }.joined()
        let rss = Data("<rss version=\"2.0\"><channel>\(itemXML)</channel></rss>".utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Cap Oshi"),
            platforms: ["barks"]
        )

        XCTAssertEqual(report.items.count, 25)
        XCTAssertEqual(report.items.first?.url, "https://barks.jp/articles/26")
        XCTAssertFalse(report.items.contains { $0.url == "https://barks.jp/articles/0" })
    }

    func testIngestionReportItemsAreSortedNewestFirstAcrossSources() async {
        let olderRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Natalie Sort Oshi older</title>
        <link>https://natalie.mu/music/news/older</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let newerRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>BARKS Sort Oshi newer</title>
        <link>https://barks.jp/news/newer</link>
        <pubDate>Sun, 02 Aug 2026 09:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                let data = request.url?.absoluteString == "https://barks.jp/feed/" ? newerRSS : olderRSS
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Sort Oshi"),
            platforms: ["natalie", "barks"]
        )

        XCTAssertEqual(report.items.map(\.url), [
            "https://barks.jp/news/newer",
            "https://natalie.mu/music/news/older"
        ])
    }

    func testYouTubeInnertubeMatchesPlusRequestAndDropsOldResults() async throws {
        let response = Data("""
        {
          "contents": {
            "sectionListRenderer": {
              "contents": [
                {
                  "videoRenderer": {
                    "videoId": "oldoldold01",
                    "title": { "runs": [{ "text": "Fresh Oshi old result" }] },
                    "publishedTimeText": { "simpleText": "2 years ago" }
                  }
                },
                {
                  "videoRenderer": {
                    "videoId": "history0001",
                    "title": { "runs": [{ "text": "Fresh Oshi interview" }] },
                    "publishedTimeText": { "simpleText": "4 months ago" }
                  }
                },
                {
                  "videoRenderer": {
                    "videoId": "freshfresh1",
                    "title": { "runs": [{ "text": "Fresh Oshi new result" }] },
                    "publishedTimeText": { "simpleText": "2 days ago" }
                  }
                }
              ]
            }
          }
        }
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                let body = try XCTUnwrap(request.httpBody)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertNil(payload["params"])
                return (response, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fresh Oshi"),
            platforms: ["youtube"]
        )

        let firstURL = await capture.firstURL()
        XCTAssertEqual(firstURL, "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")
        XCTAssertEqual(report.items.map(\.id), ["youtube:freshfresh1", "youtube:history0001"])
    }

    func testYouTubeScrapeAcceptsPublishedTimeRunsText() async throws {
        let html = Data("""
        <html><script>
        var ytInitialData = {
          "contents": {
            "twoColumnSearchResultsRenderer": {
              "primaryContents": {
                "sectionListRenderer": {
                  "contents": [
                    {
                      "itemSectionRenderer": {
                        "contents": [
                          {
                            "videoRenderer": {
                              "videoId": "runsdate001",
                              "title": { "runs": [{ "text": "Runs Date Oshi result" }] },
                              "publishedTimeText": { "runs": [{ "text": "2 days ago" }] }
                            }
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        };
        </script></html>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                let data = request.httpMethod == "POST" ? Data("{}".utf8) : html
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Runs Date Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:runsdate001"])
    }

    func testYouTubeStructuredRenderersSkipMissingPublishedTime() async throws {
        let response = Data("""
        {
          "contents": {
            "sectionListRenderer": {
              "contents": [
                {
                  "videoRenderer": {
                    "videoId": "nodatenodt1",
                    "title": { "runs": [{ "text": "No Date Oshi structured result" }] }
                  }
                },
                {
                  "videoWithContextRenderer": {
                    "videoId": "nodatenodt2",
                    "headline": { "runs": [{ "text": "No Date Oshi mobile result" }] }
                  }
                },
                {
                  "shortsLockupViewModel": {
                    "entityId": "shorts-shelf-nodateshrt1",
                    "overlayMetadata": { "primaryText": { "content": "No Date Oshi shorts result" } },
                    "belowThumbnailMetadata": {
                      "primaryText": { "content": "Shorts channel" },
                      "secondaryText": { "content": "No publish label" }
                    },
                    "onTap": {
                      "innertubeCommand": {
                        "reelWatchEndpoint": { "videoId": "nodateshrt1" }
                      }
                    }
                  }
                }
              ]
            }
          }
        }
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (response, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "No Date Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertTrue(report.items.isEmpty)
    }

    func testYouTubeVideoRendererCapAppliesAfterFreshnessFiltering() async throws {
        let staleRenderers = (0..<25).map { index in
            """
            {
              "videoRenderer": {
                "videoId": "oldold\(String(format: "%05d", index))",
                "title": { "runs": [{ "text": "Cap Oshi stale \(index)" }] },
                "publishedTimeText": { "simpleText": "2 years ago" }
              }
            }
            """
        }.joined(separator: ",")
        let response = Data("""
        {
          "contents": {
            "sectionListRenderer": {
              "contents": [
                \(staleRenderers),
                {
                  "videoRenderer": {
                    "videoId": "freshcap001",
                    "title": { "runs": [{ "text": "Cap Oshi fresh result" }] },
                    "publishedTimeText": { "simpleText": "2 days ago" }
                  }
                }
              ]
            }
          }
        }
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                let data = request.url?.host == "www.youtube.com" && request.httpMethod == "POST"
                    ? response
                    : Data(#"<html></html>"#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Cap Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:freshcap001"])
        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 1)
    }

    func testYouTubeScrapeMatchesPlusRequestAndSkipsUndatedEscapedFallbackIDs() async throws {
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data = url.contains("/youtubei/") ? Data("{}".utf8) : Data(#""videoId":"stalevideo1""#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["youtube"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains("https://www.youtube.com/youtubei/v1/search?prettyPrint=false"))
        XCTAssertTrue(urls.contains { url in
            guard let components = URLComponents(string: url) else { return false }
            return components.path == "/results"
                && components.queryItems?.first(where: { $0.name == "search_query" })?.value == "Fallback Oshi"
                && components.queryItems?.contains(where: { $0.name == "sp" }) == false
        })
        XCTAssertTrue(report.items.isEmpty)
    }

    func testYouTubeEscapedFallbackAllowsLaterDatedDuplicateID() async throws {
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data = url.contains("/youtubei/")
                    ? Data("{}".utf8)
                    : Data(#"""
                    "videoId":"freshdupe01"
                    "videoRenderer":{"videoId":"freshdupe01","publishedTimeText":{"simpleText":"2 days ago"}}
                    """#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:freshdupe01"])
    }

    func testYouTubeEscapedFallbackDoesNotBorrowNeighboringVideosDate() async throws {
        // Shorts never carry their own publishedTimeText in scrape HTML. Regression
        // coverage for a bug where an undated video preceding a dated one picked up
        // the *next* video's date instead of being dropped as undated.
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data = url.contains("/youtubei/")
                    ? Data("{}".utf8)
                    : Data(#"""
                    "videoId":"undatedvid1"
                    "videoRenderer":{"videoId":"freshvid002","publishedTimeText":{"simpleText":"2 days ago"}}
                    """#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:freshvid002"])
    }

    func testYouTubeEscapedFallbackDoesNotBorrowNeighboringVideosDateAcrossDoubleEscapedIDs() async throws {
        // Same regression as above, but the undated video's ID only appears in the
        // double-escaped form (\x22...\x22) that decodeJavaScriptEscapedString unwraps to a
        // single layer, not a plain quote. Boundary scoping must still recognize it as "this
        // video" rather than falling back to an unbounded search that borrows the neighbor's date.
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data = url.contains("/youtubei/")
                    ? Data("{}".utf8)
                    : Data(#"""
                    \\x22videoId\\x22:\\x22undatedvid2\\x22
                    "videoRenderer":{"videoId":"freshvid003","publishedTimeText":{"simpleText":"2 days ago"}}
                    """#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:freshvid003"])
    }

    func testDedicatedRSSFallsBackToGoogleNewsWhenPublisherFeedIsBlocked() async {
        let googleNewsRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Blocked Oshi live item - Google</title>
        <link>https://example.com/articles/blocked-oshi</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                if url.contains("news.google.com") {
                    return (googleNewsRSS, try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )))
                }
                return (Data(), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 405, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Blocked Oshi"),
            platforms: ["natalie"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains { $0.contains("natalie.mu/music/feed/news") })
        XCTAssertTrue(urls.contains { $0.contains("news.google.com") && $0.contains("site:natalie.mu") })
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "natalie")
        XCTAssertEqual(report.items.first?.source, IngestionService.unverifiedDateGoogleNewsSource)
    }

    func testDedicatedRSSFallsBackWhenOnePublisherFeedIsBlockedAndOthersAreEmpty() async {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let googleNewsRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Music Oshi partial fallback - Google</title>
        <link>https://example.com/articles/music-oshi</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                if url.contains("natalie.mu/music/feed/news") {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 405, httpVersion: nil, headerFields: nil
                    )))
                }
                if url.contains("news.google.com") {
                    return (googleNewsRSS, try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )))
                }
                return (emptyRSS, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Music Oshi"),
            platforms: ["natalie"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains { $0.contains("natalie.mu/music/feed/news") })
        XCTAssertTrue(urls.contains { $0.contains("natalie.mu/tv/feed/news") })
        XCTAssertTrue(urls.contains { $0.contains("news.google.com") && $0.contains("site:natalie.mu") })
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.first?.source, IngestionService.unverifiedDateGoogleNewsSource)
    }

    func testKpopOfficialDedicatedRSSProducesKpopOfficialItems() async {
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>BLACKPINK comeback schedule</title>
        <link>https://kpopofficial.com/blackpink-comeback</link>
        <description>BLACKPINK concert and album details</description>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        let urls = await capture.urls
        XCTAssertEqual(urls, ["https://kpopofficial.com/feed/"])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "kpopofficial")
        XCTAssertEqual(report.items.first?.source, "dedicated_rss")
    }

    func testKpopOfficialStaleRSSUsesFreshSiteFallback() async throws {
        let staleRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>BLACKPINK comeback archive</title>
        <link>https://kpopofficial.com/blackpink-archive</link>
        <description>BLACKPINK archived schedule</description>
        <pubDate>Wed, 01 Jul 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let freshGoogleNewsRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>BLACKPINK comeback update - KPOP OFFICIAL</title>
        <link>https://kpopofficial.com/blackpink-current</link>
        <description>BLACKPINK current schedule</description>
        <pubDate>Sat, 22 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T08:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = url.contains("news.google.com") ? freshGoogleNewsRSS : staleRSS
                return (body, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { now }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains("https://kpopofficial.com/feed/"))
        XCTAssertTrue(urls.contains { $0.contains("news.google.com") && $0.contains("site:kpopofficial.com") })
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.first?.published_at, "2026-08-22T08:00:00Z")
        XCTAssertEqual(
            Set(report.items.compactMap(\.source)),
            ["dedicated_rss", IngestionService.unverifiedDateGoogleNewsSource]
        )
    }

    func testNiconicoSnapshotUsesPlusQueryAndTreatsValidEmptyAsAuthoritative() async throws {
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    Data(#"{"data":[]}"#.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Nico Oshi"),
            platforms: ["niconico"]
        )

        let urls = await capture.urls
        XCTAssertEqual(urls.count, 1)
        let components = try XCTUnwrap(URLComponents(string: urls[0]))
        XCTAssertEqual(components.queryItems?.first { $0.name == "targets" }?.value, "title")
        XCTAssertEqual(components.queryItems?.first { $0.name == "_context" }?.value, "OshiReader")
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .noResults)
    }

    func testNiconicoUnavailableSnapshotUsesPlusSearchAndTagRSSFallbacks() async throws {
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>Nico Oshi latest video</title>
        <link>https://www.nicovideo.jp/watch/sm123456</link>
        <pubDate>Sat, 22 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = url.contains("snapshot.search.nicovideo.jp") ? Data("malformed".utf8) : rss
                return (
                    body,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Nico Oshi"),
            platforms: ["niconico"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains { $0.contains("nicovideo.jp/search/") && $0.contains("rss=2.0") })
        XCTAssertTrue(urls.contains { $0.contains("nicovideo.jp/tag/") && $0.contains("rss=2.0") })
        XCTAssertFalse(urls.contains { $0.contains("news.google.com") })
        XCTAssertEqual(report.items.map(\.id), ["niconico:sm123456"])
        XCTAssertEqual(report.items.first?.source, "niconico_rss")
    }

    func testNiconicoUnusableSnapshotRowsFallBackAndEncodePathSeparators() async throws {
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>A/B latest video</title>
        <link>https://www.nicovideo.jp/watch/sm654321</link>
        <pubDate>Sat, 22 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = url.contains("snapshot.search.nicovideo.jp")
                    ? Data(#"{"data":[{"title":"A/B unusable row"}]}"#.utf8)
                    : rss
                return (
                    body,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "A/B"),
            platforms: ["niconico"]
        )

        let urls = await capture.urls
        let rssURLs = urls.filter { $0.contains("www.nicovideo.jp/search/") || $0.contains("www.nicovideo.jp/tag/") }
        XCTAssertEqual(rssURLs.count, 2)
        XCTAssertTrue(rssURLs.allSatisfy { $0.contains("A%2FB") })
        XCTAssertFalse(urls.contains { $0.contains("news.google.com") })
        XCTAssertEqual(report.items.map(\.id), ["niconico:sm654321"])
        XCTAssertEqual(report.items.first?.source, "niconico_rss")
    }

    func testAtomUpdatedDateWinsOverPublishedDateForDedicatedRSS() async {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>BLACKPINK updated schedule</title>
          <link rel="alternate" href="https://kpopofficial.com/blackpink-updated"/>
          <summary>BLACKPINK schedule details</summary>
          <published>2026-08-01T08:00:00Z</published>
          <updated>2026-08-02T09:30:00Z</updated>
        </entry></feed>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (atom, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        XCTAssertEqual(report.items.first?.published_at, "2026-08-02T09:30:00Z")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testAtomFractionalUpdatedDateWithColonOffsetIsAccepted() async {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>BLACKPINK fractional offset schedule</title>
          <link rel="alternate" href="https://kpopofficial.com/blackpink-fractional-offset"/>
          <summary>BLACKPINK schedule details</summary>
          <updated>2026-08-02T09:30:00.123+09:00</updated>
        </entry></feed>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (atom, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        XCTAssertEqual(report.items.first?.published_at, "2026-08-02T00:30:00Z")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testAtomParserDoesNotLeakTextAfterClosedDateElement() async {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>BLACKPINK parser spacing</title>
            <link rel="alternate" href="https://kpopofficial.com/parser-spacing"/>
            <summary>BLACKPINK parser spacing details</summary>
            <updated>2026-08-02T09:30:00Z</updated>
            ignored text after date close
            <category term="ignored"/>
          </entry>
        </feed>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (atom, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        XCTAssertEqual(report.items.first?.title, "BLACKPINK parser spacing")
        XCTAssertEqual(report.items.first?.url, "https://kpopofficial.com/parser-spacing")
        XCTAssertEqual(report.items.first?.published_at, "2026-08-02T09:30:00Z")
    }

    func testJapaneseDedicatedRSSSourcesUsePublisherFeedsAndPreserveSourceIDs() async {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi publisher update</title><link>https://publisher.example/article-1?utm_source=rss</link><description>Publisher detail</description><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Alias Oshi duplicate</title><link>https://publisher.example/article-1?utm_medium=email</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>Alias Oshi Real Sound update</title><link rel="alternate" href="https://realsound.jp/2026/08/post-1.html"/><summary>Music detail</summary><published>2026-08-02T12:00:00Z</published>
        </entry></feed>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = url.contains("realsound.jp") ? atom : rss
                return (body, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["aera", "hochi", "realsound"]
        )

        let urls = await capture.urls
        XCTAssertEqual(urls.count, 8)
        XCTAssertTrue(urls.contains("https://dot.asahi.com/list/feed/rss4provider-all"))
        XCTAssertTrue(urls.contains("https://hochi.news/rss/index.xml"))
        XCTAssertEqual(urls.filter { $0.hasPrefix("https://realsound.jp/?s=") }.count, 2)
        XCTAssertTrue(urls.contains("https://realsound.jp/atom.xml"))
        XCTAssertFalse(urls.contains { $0.contains("news.google.com") })
        XCTAssertEqual(Set(report.sourceStatuses.map(\.id)), Set(["aera", "hochi", "realsound"]))
        XCTAssertTrue(report.sourceStatuses.allSatisfy { $0.outcome == .received && $0.queryCount == 2 })
        XCTAssertEqual(report.items.filter { $0.platform == "aera" }.count, 1)
        XCTAssertEqual(report.items.filter { $0.platform == "hochi" }.count, 1)
        XCTAssertEqual(report.items.filter { $0.platform == "realsound" }.count, 1)
        XCTAssertTrue(report.items.allSatisfy { $0.watch_term_keyword == "Primary Oshi" })
    }

    func testRealSoundCorrectsJapanWallClockTimestampMarkedAsUTC() async throws {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>Timestamp Oshi Real Sound update</title>
          <link rel="alternate" href="https://realsound.jp/2026/08/post-timestamp.html"/>
          <published>2026-08-24T13:16:20Z</published>
        </entry></feed>
        """.utf8)
        let now = try XCTUnwrap(parseISO8601Date("2026-08-24T04:20:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                (atom, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { now }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Timestamp Oshi"),
            platforms: ["realsound"]
        )

        XCTAssertEqual(report.items.first?.published_at, "2026-08-24T04:16:20Z")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testRealSoundDirectSearchMatchesExcerptAndSkipsRSSFallback() async throws {
        let html = Data(#"""
        <html><body>
          <article class="entry-summary">
            <h3 class="entry-title"><a href="/2026/08/direct-match.html">Weekly music update</a></h3>
            <div class="entry-excerpt">Direct Oshi appears in the interview excerpt.</div>
            <time datetime="2026-08-23T12:30:00+09:00"></time>
            <span class="entry-author">Real Sound Music</span>
            <img src="/images/direct-match.jpg">
          </article>
        </body></html>
        """#.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(parseISO8601Date("2026-08-24T04:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (html, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Direct Oshi"),
            platforms: ["realsound"]
        )

        let urls = await capture.urls
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].hasPrefix("https://realsound.jp/?s="))
        XCTAssertFalse(urls.contains("https://realsound.jp/atom.xml"))
        XCTAssertEqual(report.items.map(\.url), ["https://realsound.jp/2026/08/direct-match.html"])
        XCTAssertEqual(report.items.first?.content_text, "Direct Oshi appears in the interview excerpt.")
        XCTAssertEqual(report.items.first?.author, "Real Sound Music")
        XCTAssertEqual(report.items.first?.thumbnail_url, "https://realsound.jp/images/direct-match.jpg")
        XCTAssertEqual(report.items.first?.published_at, "2026-08-23T03:30:00Z")
        XCTAssertEqual(report.items.first?.source, "realsound_search")
    }

    func testSponichiRemainsOnGenericGoogleNewsFallback() async {
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        _ = await service.ingestReport(term: WatchTerm(keyword: "Sponichi Oshi"), platforms: ["sponichi"])

        let usedGoogleNews = await capture.contains { $0.contains("news.google.com") }
        let usedSponichiRSS = await capture.contains { $0.contains("sponichi.co.jp/rss") }
        XCTAssertTrue(usedGoogleNews)
        XCTAssertFalse(usedSponichiRSS)
    }

    func testGoogleNewsTitlesStripSearchAndYahooSuffixes() async throws {
        let rss = Data("""
        <rss version="2.0"><channel>
        <item><title>Suffix Oshi appears - Google</title><link>https://example.com/google</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
        <item><title>Suffix Oshi appears | Bing</title><link>https://example.com/bing</link><pubDate>Sun, 02 Aug 2026 08:01:00 GMT</pubDate></item>
        <item><title>Suffix Oshi appears (エンタメニュース) - Yahoo!ニュース</title><link>https://example.com/yahoo</link><pubDate>Sun, 02 Aug 2026 08:02:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let service = IngestionService(requestExecutor: { request in
            (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        })

        let report = await service.ingestReport(term: WatchTerm(keyword: "Suffix Oshi"), platforms: ["news"])

        XCTAssertEqual(Set(report.items.map(\.title)), Set(["Suffix Oshi appears"]))
    }

    func testGoogleNewsStartsArePacedAcrossSourcesAliasesAndTerms() async throws {
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>Primary Pace Alias Pace Second Pace update</title>
        <link>https://example.com/paced-google-news</link>
        <pubDate>Sun, 23 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestStartCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.begin(request.url?.absoluteString ?? "")
            try? await Task.sleep(nanoseconds: 20_000_000)
            await capture.end()
            return (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
            )
        })

        async let aliasedReport = service.ingestReport(
            term: WatchTerm(keyword: "Primary Pace", aliases: ["Alias Pace"]),
            platforms: ["sponichi"]
        )
        async let secondTermReport = service.ingestReport(
            term: WatchTerm(keyword: "Second Pace"),
            platforms: ["livedoor"]
        )
        _ = await (aliasedReport, secondTermReport)

        let starts = await capture.snapshot().filter { $0.url.contains("news.google.com") }
            .sorted { $0.uptimeNanoseconds < $1.uptimeNanoseconds }
        XCTAssertEqual(starts.count, 3)
        for pair in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1.uptimeNanoseconds - pair.0.uptimeNanoseconds,
                175_000_000
            )
        }
        let maximumActive = await capture.maximumActive
        XCTAssertLessThanOrEqual(maximumActive, 3)
    }

    func testHistoricalGoogleSharesPacerWhileBingRunsWithoutDelay() async throws {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let bingRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Parallel Pace interview | Bing</title>
        <link>https://example.com/parallel-pace</link>
        <pubDate>Sun, 23 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestStartCapture()
        let service = IngestionService(requestExecutor: { request in
            let url = request.url?.absoluteString ?? ""
            await capture.begin(url)
            await capture.end()
            return (
                request.url?.host == "www.bing.com" ? bingRSS : emptyRSS,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
            )
        })

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Parallel Pace"),
            platforms: ["oricon"]
        )

        let starts = await capture.snapshot()
        let googleStarts = starts.filter { $0.url.contains("news.google.com") }
            .sorted { $0.uptimeNanoseconds < $1.uptimeNanoseconds }
        let bingStart = try XCTUnwrap(starts.first { $0.url.contains("www.bing.com/news/search") })
        XCTAssertEqual(googleStarts.count, 2)
        XCTAssertGreaterThanOrEqual(
            googleStarts[1].uptimeNanoseconds - googleStarts[0].uptimeNanoseconds,
            175_000_000
        )
        XCTAssertLessThan(bingStart.uptimeNanoseconds, googleStarts[1].uptimeNanoseconds)
        XCTAssertEqual(report.items.first?.source, "bing_news")
    }

    func testCancellationDuringGooglePacingPreventsRequestAndReleasesLimiter() async throws {
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>First Pace Second Pace Follow Up Pace update</title>
        <link>https://example.com/cancelled-pacing</link>
        <pubDate>Sun, 23 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let requests = RequestStartCapture()
        let delays = PacingDelayCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await requests.begin(request.url?.absoluteString ?? "")
                await requests.end()
                return (
                    rss,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            pacingSleeper: { delay in
                await delays.record(delay)
                try await Task.sleep(nanoseconds: delay)
            }
        )

        _ = await service.ingestReport(
            term: WatchTerm(keyword: "First Pace"),
            platforms: ["sponichi"]
        )
        let cancelled = Task {
            await service.ingestReport(
                term: WatchTerm(keyword: "Second Pace"),
                platforms: ["livedoor"]
            )
        }
        await delays.waitUntilCount(1)
        cancelled.cancel()
        _ = await cancelled.value

        let requestsAfterCancellation = await requests.snapshot()
        XCTAssertEqual(requestsAfterCancellation.count, 1)

        let followUpStartedAt = DispatchTime.now().uptimeNanoseconds
        _ = await service.ingestReport(
            term: WatchTerm(keyword: "Follow Up Pace"),
            platforms: ["sponichi"]
        )
        let followUpElapsed = DispatchTime.now().uptimeNanoseconds - followUpStartedAt
        let finalRequests = await requests.snapshot()
        XCTAssertEqual(finalRequests.count, 2)
        XCTAssertLessThan(followUpElapsed, 1_000_000_000)
    }

    func testDeadlineDuringGooglePacingExpiresWithoutStartingRequest() async throws {
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>Deadline First Deadline Second update</title>
        <link>https://example.com/deadline-pacing</link>
        <pubDate>Sun, 23 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let requests = RequestStartCapture()
        let service = IngestionService(requestExecutor: { request in
            await requests.begin(request.url?.absoluteString ?? "")
            await requests.end()
            return (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
            )
        })

        _ = await service.ingestReport(
            term: WatchTerm(keyword: "Deadline First"),
            platforms: ["sponichi"]
        )
        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Deadline Second"),
            platforms: ["livedoor"],
            requestDeadline: Date().addingTimeInterval(0.03)
        )

        let capturedRequests = await requests.snapshot()
        XCTAssertEqual(capturedRequests.count, 1)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.timeout))
    }

    func testJapaneseDedicatedRSSMediaOnlySkipsAllRequests() async {
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data(), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Media Oshi", collection_mode: "media_only"),
            platforms: ["aera", "hochi", "realsound"]
        )

        XCTAssertTrue(report.items.isEmpty)
        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testJapaneseDedicatedRSSFailureStaysAttachedToPublisher() async {
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Hochi Oshi update</title><link>https://hochi.news/articles/1</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                if request.url?.host == "dot.asahi.com" {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
                    )))
                }
                if request.url?.host == "news.google.com" {
                    return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )))
                }
                if request.url?.host == "www.bing.com" {
                    return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )))
                }
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["aera", "hochi"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains { $0.contains("news.google.com") && $0.contains("site:dot.asahi.com") })
        XCTAssertEqual(report.sourceStatuses.first { $0.id == "aera" }?.outcome, .failed(.rateLimited))
        XCTAssertEqual(report.sourceStatuses.first { $0.id == "hochi" }?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "hochi")
    }

    func testDedicatedRSSPublisherFailureIsNotOverwrittenByFallbackFailure() async {
        let service = IngestionService(
            requestExecutor: { request in
                if request.url?.host == "dot.asahi.com" {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
                    )))
                }
                return (Data("<rss><channel>".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["aera"]
        )

        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.rateLimited))
    }

    func testCinemaCafeAndBillboardDedicatedRSSSourcesPreserveIDsAndDeduplicate() async {
        let cinemaURL = "https://www.cinemacafe.net/article/1.html?utm_source=rss"
        let billboardURL = "https://www.billboard-japan.com/d_news/detail/1?utm_medium=email"
        let cinemaRSS = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi CinemaCafe update</title><link>\(cinemaURL)</link><description>Film detail</description><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Alias Oshi duplicate</title><link>https://www.cinemacafe.net/article/1.html?utm_medium=email</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let billboardRSS = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi Billboard update</title><link>\(billboardURL)</link><description>Music detail</description><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Alias Oshi duplicate</title><link>https://www.billboard-japan.com/d_news/detail/1?utm_source=rss</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = url.contains("cinemacafe.net") ? cinemaRSS : billboardRSS
                return (body, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["cinemacafe", "billboardjapan"]
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 4)
        XCTAssertEqual(Set(report.sourceStatuses.map(\.id)), Set(["cinemacafe", "billboardjapan"]))
        XCTAssertTrue(report.sourceStatuses.allSatisfy { $0.outcome == .received && $0.queryCount == 2 })
        XCTAssertEqual(report.items.filter { $0.platform == "cinemacafe" }.count, 1)
        XCTAssertEqual(report.items.filter { $0.platform == "billboardjapan" }.count, 1)
        XCTAssertEqual(report.items.first { $0.platform == "cinemacafe" }?.url, cinemaURL)
        XCTAssertEqual(report.items.first { $0.platform == "billboardjapan" }?.url, billboardURL)
    }

    func testBillboardDedicatedRSSMatchesStructuredArtistAndPreservesAuthor() async {
        let rss = Data("""
        <rss version="2.0"><channel><item>
          <title>Weekly chart update</title>
          <link>https://www.billboard-japan.com/d_news/detail/artist-match</link>
          <description>Chart details</description>
          <artist>Alias Oshi</artist>
          <pubDate>Sat, 22 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Alias Oshi"),
            platforms: ["billboardjapan"]
        )

        XCTAssertEqual(report.items.map(\.id).count, 1)
        XCTAssertEqual(report.items.first?.author, "Alias Oshi")
        XCTAssertEqual(report.items.first?.source, "dedicated_rss")
    }

    func testNoteStripsHTMLFromPreviewText() async {
        let rss = Data("""
        <rss version="2.0"><channel><item>
          <title>Alias Oshi update</title>
          <link>https://note.com/example/n/html-preview</link>
          <description><![CDATA[<p>Hello <b>Alias Oshi</b> &amp; friends</p>]]></description>
          <pubDate>Sat, 22 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Alias Oshi"),
            platforms: ["note"]
        )

        XCTAssertEqual(report.items.first?.content_text, "Hello Alias Oshi & friends")
    }

    func testCinemaCafeAndBillboardMediaOnlySkipRequests() async {
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data(), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Media Oshi", collection_mode: "media_only"),
            platforms: ["cinemacafe", "billboardjapan"]
        )

        let requestCount = await capture.count()
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(requestCount, 0)
    }

    func testCinemaCafeFailureAndBillboardSuccessRemainSourceSpecific() async {
        let billboardRSS = Data("<rss version=\"2.0\"><channel><item><title>Oshi Billboard update</title><link>https://www.billboard-japan.com/d_news/detail/2</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
        let service = IngestionService(
            requestExecutor: { request in
                if request.url?.host == "www.cinemacafe.net" {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
                    )))
                }
                if request.url?.host == "news.google.com" {
                    return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )))
                }
                if request.url?.host == "www.bing.com" {
                    return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )))
                }
                return (billboardRSS, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["cinemacafe", "billboardjapan"]
        )

        XCTAssertEqual(report.sourceStatuses.first { $0.id == "cinemacafe" }?.outcome, .failed(.httpFailure))
        XCTAssertEqual(report.sourceStatuses.first { $0.id == "billboardjapan" }?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "billboardjapan")
    }

    func testDeferredJapaneseSourcesUseDirectNewsSearchFallbacks() async {
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        for sourceID in ["livedoor", "mantanweb", "thetv"] {
            _ = await service.ingestReport(
                term: WatchTerm(keyword: "Fallback Oshi"),
                platforms: [sourceID]
            )
        }

        let urls = await capture.urls
        XCTAssertEqual(urls.count, 9)
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 6)
        XCTAssertEqual(urls.filter { $0.contains("www.bing.com/news/search") }.count, 3)
        XCTAssertEqual(urls.filter { $0.contains("when:10y") }.count, 3)
    }

    func testDedicatedRSSMatchesAliasAndFiltersNonmatchingEntries() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Alias Oshi exclusive</title>
        <link>https://natalie.mu/music/news/alias</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item><item>
        <title>Unrelated headline</title>
        <link>https://natalie.mu/music/news/unrelated</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let service = IngestionService { request in
            (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["natalie"]
        )

        XCTAssertFalse(report.items.isEmpty)
        XCTAssertTrue(report.items.allSatisfy { $0.title?.contains("Alias Oshi") == true })
        XCTAssertTrue(report.items.allSatisfy { $0.watch_term_keyword == "Primary Oshi" })
    }

    func testDedicatedRSSAcceptsDescriptionOnlyMatchesFromPublisherFeed() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Unrelated headline</title>
        <link>https://natalie.mu/music/news/summary-only</link>
        <description>Alias Oshi appears only in the summary.</description>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let service = IngestionService { request in
            (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["natalie"]
        )

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.url, "https://natalie.mu/music/news/summary-only")
    }

    func testDedicatedRSSNoResultsAndMediaOnlyAvoidsRequests() async {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let capture = RequestCapture()
        let service = IngestionService { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (
                emptyRSS,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let noResults = await service.ingestReport(
            term: WatchTerm(keyword: "No Match"),
            platforms: ["barks"]
        )
        XCTAssertEqual(noResults.sourceStatuses.first?.outcome, .noResults)
        let noResultsRequestCount = await capture.count()
        XCTAssertEqual(noResultsRequestCount, 1)

        let beforeMediaOnly = await capture.count()
        let mediaOnly = await service.ingestReport(
            term: WatchTerm(keyword: "Media Oshi", collection_mode: "media_only"),
            platforms: ["natalie"]
        )
        XCTAssertTrue(mediaOnly.items.isEmpty)
        let afterMediaOnly = await capture.count()
        XCTAssertEqual(afterMediaOnly, beforeMediaOnly)
    }

    func testAmebloEmptyDirectSearchFallsBackToGoogleNews() async {
        let capture = RequestCapture()
        let service = IngestionService { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (
                Data("<rss version=\"2.0\"><channel></channel></rss>".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        _ = await service.ingestReport(
            term: WatchTerm(keyword: "Ameblo Oshi"),
            platforms: ["ameblo"]
        )

        let usedGoogleNews = await capture.contains { $0.contains("news.google.com") }
        let usedAmeblo = await capture.contains { $0.contains("search.ameba.jp/search/") }
        XCTAssertTrue(usedGoogleNews)
        XCTAssertTrue(usedAmeblo)
    }

    func testAmebloDirectSearchParsesStateAndMatchesEntryContent() async throws {
        let html = Data(#"""
        <html><script>
        window.__STATE__={"blogEntry":{"blogEntryMap":{"entry-key":{
          "entryId":"12345",
          "amebaId":"example-blog",
          "entryTitle":"Daily update",
          "entryContent":"A/B appears in this post",
          "blogTitle":"Example Blog",
          "entryUpdatedDatetime":1787452200000,
          "firstImageUrl":"https://stat.ameba.jp/image.jpg"
        }}}};window.afterState=true;
        </script></html>
        """#.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (html, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "A/B"),
            platforms: ["ameblo"]
        )

        let urls = await capture.urls
        XCTAssertEqual(urls, ["https://search.ameba.jp/search/A%2FB.html"])
        XCTAssertEqual(report.items.map(\.id), ["ameblo:12345"])
        XCTAssertEqual(report.items.first?.url, "https://ameblo.jp/example-blog/entry-12345.html")
        XCTAssertEqual(report.items.first?.title, "Daily update - A/B appears in this post")
        XCTAssertEqual(report.items.first?.content_text, "A/B appears in this post")
        XCTAssertEqual(report.items.first?.author, "Example Blog")
        XCTAssertEqual(report.items.first?.source, "ameba_search")
    }

    func testAmebloStaleDirectSearchUsesFreshFallback() async throws {
        let staleHTML = Data(#"""
        <html><script>
        window.__STATE__={"blogEntry":{"blogEntryMap":{"stale-entry":{
          "entryId":"stale-1",
          "amebaId":"stale-blog",
          "entryTitle":"Fallback Oshi archive",
          "entryUpdatedDatetime":"2026-01-01T08:00:00Z"
        },"future-entry":{
          "entryId":"future-1",
          "amebaId":"future-blog",
          "entryTitle":"Fallback Oshi future timestamp",
          "entryUpdatedDatetime":"2026-08-27T08:00:00Z"
        }}}};
        </script></html>
        """#.utf8)
        let freshRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Fallback Oshi current article - Google</title>
        <link>https://ameblo.jp/current-blog/entry-current.html</link>
        <pubDate>Mon, 24 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-25T08:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = url.contains("search.ameba.jp") ? staleHTML : freshRSS
                return (body, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["ameblo"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains { $0.contains("search.ameba.jp") })
        XCTAssertTrue(urls.contains { $0.contains("news.google.com") })
        XCTAssertEqual(report.items.map(\.url), ["https://ameblo.jp/current-blog/entry-current.html"])
        XCTAssertEqual(report.items.first?.source, IngestionService.unverifiedDateGoogleNewsSource)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testAmebloBlogNormalizesURLAndBuildsOfficialRSSURL() {
        let blog = AmebloBlog(
            url: " http://www.ameblo.jp/example_id/?utm_source=test#top ",
            title: "Example",
            addedAt: "2026-01-01T00:00:00Z"
        )

        XCTAssertEqual(blog?.url, "https://ameblo.jp/example_id")
        XCTAssertEqual(blog?.amebaID, "example_id")
        XCTAssertEqual(blog?.rssURL?.absoluteString, "https://rssblog.ameba.jp/example_id/rss20.xml")
        XCTAssertNil(AmebloBlog(url: "https://example.com/example_id"))
        XCTAssertNil(AmebloBlog(url: "https://ameblo.jp/example_id/posts"))
        XCTAssertNil(AmebloBlog(url: "https://ameblo.jp/"))
    }

    func testAmebloBlogLimitDuplicateAndAutomaticSubscription() {
        let originalBlogs = db.amebloBlogs
        let originalPlatforms = db.subscribedPlatforms
        defer {
            db.amebloBlogs = originalBlogs
            db.setSubscribedPlatforms(platforms: originalPlatforms)
        }

        db.amebloBlogs = []
        db.setSubscribedPlatforms(platforms: ["news"])
        XCTAssertEqual(db.addAmebloBlog(url: "https://ameblo.jp/first", title: ""), .added)
        XCTAssertTrue(db.subscribedPlatforms.contains("ameblo"))
        XCTAssertEqual(db.addAmebloBlog(url: "https://www.ameblo.jp/first/?x=1", title: ""), .duplicate)

        db.amebloBlogs = (0..<AmebloBlog.maximumCount).compactMap {
            AmebloBlog(url: "https://ameblo.jp/blog\($0)", addedAt: "2026-01-01T00:00:00Z")
        }
        XCTAssertEqual(db.addAmebloBlog(url: "https://ameblo.jp/too-many", title: ""), .limitReached)
    }

    func testAmebloDedicatedRSSMatchesAliasPreservesURLAndDeduplicates() async {
        let originalBlogs = db.amebloBlogs
        defer { db.amebloBlogs = originalBlogs }
        db.amebloBlogs = [
            AmebloBlog(url: "https://ameblo.jp/first", addedAt: "2026-01-01T00:00:00Z")!
        ]

        let originalURL = "https://ameblo.jp/first/entry-1?utm_source=rss"
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi diary</title><link>\(originalURL)</link><description>daily update</description><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Alias Oshi duplicate</title><link>https://ameblo.jp/first/entry-1?utm_medium=email</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Unrelated</title><link>https://ameblo.jp/first/entry-2</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["ameblo"]
        )

        let requestCount = await capture.count()
        let firstURL = await capture.firstURL()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(firstURL, "https://rssblog.ameba.jp/first/rss20.xml")
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.platform, "ameblo")
        XCTAssertEqual(report.items.first?.url, originalURL)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.sourceStatuses.first?.queryCount, 2)
    }

    func testAmebloDedicatedRSSSortsByPublishedDateBeforeApplyingCap() async {
        let originalBlogs = db.amebloBlogs
        defer { db.amebloBlogs = originalBlogs }
        db.amebloBlogs = [
            AmebloBlog(url: "https://ameblo.jp/older-blog", addedAt: "2026-01-01T00:00:00Z")!,
            AmebloBlog(url: "https://ameblo.jp/newer-blog", addedAt: "2026-01-01T00:00:00Z")!
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss Z"
        let olderBase = Date(timeIntervalSince1970: 1_785_000_000)
        let olderItems = (0..<27).map { index in
            let date = formatter.string(from: olderBase.addingTimeInterval(TimeInterval(index * 60)))
            return """
            <item>
            <title>Ameblo Cap Oshi older \(index)</title>
            <link>https://ameblo.jp/older-blog/entry-\(index)</link>
            <pubDate>\(date)</pubDate>
            </item>
            """
        }.joined()
        let olderRSS = Data("<rss version=\"2.0\"><channel>\(olderItems)</channel></rss>".utf8)
        let newerRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Ameblo Cap Oshi newest</title>
        <link>https://ameblo.jp/newer-blog/entry-newest</link>
        <pubDate>Sun, 02 Aug 2026 09:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                let path = request.url?.path ?? ""
                let data = path.contains("newer-blog") ? newerRSS : olderRSS
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Ameblo Cap Oshi"),
            platforms: ["ameblo"]
        )

        XCTAssertEqual(report.items.count, 25)
        XCTAssertEqual(report.items.first?.url, "https://ameblo.jp/newer-blog/entry-newest")
        XCTAssertFalse(report.items.contains { $0.url == "https://ameblo.jp/older-blog/entry-0" })
    }

    func testAmebloMediaOnlySkipsConfiguredRSSRequests() async {
        let originalBlogs = db.amebloBlogs
        defer { db.amebloBlogs = originalBlogs }
        db.amebloBlogs = [AmebloBlog(url: "https://ameblo.jp/media-only")!]
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data(), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Video Oshi", collection_mode: "media_only"),
            platforms: ["ameblo"]
        )

        XCTAssertTrue(report.items.isEmpty)
        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testAmebloPartialFailurePreservesReceivedItemsAndStatus() async {
        let originalBlogs = db.amebloBlogs
        defer { db.amebloBlogs = originalBlogs }
        db.amebloBlogs = [
            AmebloBlog(url: "https://ameblo.jp/failing")!,
            AmebloBlog(url: "https://ameblo.jp/succeeding")!
        ]
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Oshi update</title><link>https://ameblo.jp/succeeding/entry-1</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
        let service = IngestionService(
            requestExecutor: { request in
                if request.url?.host == "rssblog.ameba.jp" && request.url?.path.contains("failing") == true {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
                    )))
                }
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["ameblo"]
        )

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.sourceStatuses.first?.itemCount, 1)
        XCTAssertEqual(report.sourceStatuses.first?.queryCount, 1)
    }

    @MainActor
    func testAmebloBlogsRoundTripThroughBackup() throws {
        let originalBlogs = db.amebloBlogs
        let originalPlatforms = db.subscribedPlatforms
        defer {
            db.amebloBlogs = originalBlogs
            db.setSubscribedPlatforms(platforms: originalPlatforms)
        }

        db.amebloBlogs = [AmebloBlog(url: "https://ameblo.jp/backup-blog", title: "Backup")!]
        db.setSubscribedPlatforms(platforms: ["news", "ameblo"])
        let data = try db.exportBackupData()
        db.amebloBlogs = []
        db.setSubscribedPlatforms(platforms: ["news"])
        try db.importBackupData(data)

        XCTAssertEqual(db.amebloBlogs.map(\.amebaID), ["backup-blog"])
        XCTAssertTrue(db.subscribedPlatforms.contains("ameblo"))
    }

    func testIngestionReportAggregatesSourceStatusForEmptyPlatforms() async {
        let service = IngestionService(requestExecutor: { request in
            (
                Data("<rss version=\"2.0\"><channel></channel></rss>".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
            )
        }, retrySleeper: { _ in })
        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi", collection_mode: "media_only"),
            platforms: ["news"]
        )

        let news = report.sourceStatuses.first { $0.id == "news" }
        XCTAssertEqual(news?.outcome, .noResults)
        XCTAssertGreaterThan(news?.queryCount ?? 0, 0)
        XCTAssertTrue(report.items.isEmpty)
    }

    func testNewsRejectsResultsOlderThanSixMonthWindow() async throws {
        let oldRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Status Oshi article from 2025</title>
        <link>https://example.com/status-oshi-2025</link>
        <description>Status Oshi archive</description>
        <pubDate>Wed, 01 Jan 2025 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T08:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url!.absoluteString)
                return (
                    oldRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["news"]
        )

        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .noResults)
        let urls = await capture.urls
        let googleURLs = urls.filter { URL(string: $0)?.host == "news.google.com" }
        XCTAssertEqual(googleURLs.count, 1, "News must not widen an empty result to an archival search")
        let components = try XCTUnwrap(URLComponents(string: XCTUnwrap(googleURLs.first)))
        XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, "Status Oshi when:180d")
        XCTAssertFalse(urls.contains { $0.contains("when:10y") || $0.contains("bing.com") })
    }

    func testNewsFiltersDatesFromSearchAndPublisherFeeds() async throws {
        let referenceDate = try XCTUnwrap(parseISO8601Date("2026-08-23T08:00:00Z"))
        let boundaryDate = referenceDate.addingTimeInterval(-180 * 24 * 60 * 60)
        let boundary = ISO8601DateFormatter().string(from: boundaryDate)
        let outsideWindow = ISO8601DateFormatter().string(from: boundaryDate.addingTimeInterval(-1))
        let service = IngestionService(
            requestExecutor: { request in
                let host = request.url!.host!
                let dates = [
                    ("fresh", "2026-08-23T07:00:00Z"),
                    ("boundary", boundary),
                    ("outsideWindow", outsideWindow),
                    ("future", "2026-08-25T08:00:00Z"),
                    ("undated", "invalid")
                ]
                let entries = dates.map { name, date in
                    """
                    <item><title>Freshness Oshi \(name)</title>
                    <link>https://\(host)/\(name)</link><pubDate>\(date)</pubDate></item>
                    """
                }.joined()
                return (
                    Data("<rss version=\"2.0\"><channel>\(entries)</channel></rss>".utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Freshness Oshi"),
            platforms: ["news"]
        )

        XCTAssertEqual(report.items.count, 4)
        XCTAssertEqual(Set(report.items.map(\.title)), ["Freshness Oshi fresh", "Freshness Oshi boundary"])
        XCTAssertEqual(Set(report.items.compactMap(\.source)), ["curated_rss", IngestionService.unverifiedDateGoogleNewsSource])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    @MainActor
    func testNewsHistoryReachesSixMonthFrontPageWithoutBeingReportedFresh() async throws {
        let referenceDate = Date()
        let publishedAt = ISO8601DateFormatter().string(from: referenceDate.addingTimeInterval(-120 * 24 * 60 * 60))
        let service = IngestionService(
            requestExecutor: { request in
                let rss = """
                <rss version="2.0"><channel><item>
                <title>History Oshi interview</title>
                <link>https://\(request.url!.host!)/interview</link>
                <pubDate>\(publishedAt)</pubDate>
                </item></channel></rss>
                """
                return (
                    Data(rss.utf8),
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )
        let term = db.saveTerm(keyword: "History Oshi")
        db.setSubscribedPlatforms(platforms: ["news"])
        let report = await service.ingestReport(term: term, platforms: ["news"])

        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .stale)
        XCTAssertEqual(Set(report.items.map(\.published_at)), [publishedAt])
        XCTAssertEqual(db.mergeItems(newItems: report.items), 2)
        for days in [30, 90, 180, 0] {
            let visible = FeedView.makeFilteredItems(
                db: db, keyword: term.keyword, platform: "news", mediaFilter: "all", days: days
            )
            XCTAssertEqual(visible.count, days == 180 || days == 0 ? 2 : 0, "Range: \(days)")
        }
    }

    func testRecentLookupFallsBackToHistoricalWithoutDroppingOlderItems() async throws {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let historicalRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Status Oshi older article - ModelPress</title>
        <link>https://mdpr.jp/news/older-status-oshi</link>
        <pubDate>Fri, 31 Jul 2026 07:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                return (
                    url.contains("when:10y") ? historicalRSS : emptyRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.published_at, "2026-07-31T07:00:00Z")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .stale)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 2)
        XCTAssertTrue(urls.contains { $0.contains("when:10y") })
    }

    func testFailedRecentLookupDoesNotMisreportHistoricalItemsAsStale() async throws {
        let historicalRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Status Oshi older article</title>
        <link>https://example.com/older-status-oshi</link>
        <pubDate>Fri, 31 Jul 2026 07:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let isInitial = request.url?.absoluteString.contains("when:") == false
                return (
                    isInitial ? Data() : historicalRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: isInitial ? 500 : 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.httpFailure))
    }

    func testModelPressUsesOfficialDatedSearchAndRejectsUnrelatedRows() async throws {
        let html = Data(#"""
        <ol>
          <li class="p-articleListItem">
            <a href="/news/irrelevant" class="p-articleListItem__link">
              <img src="https://img.example/irrelevant.jpg">
              <p class="p-articleListItem__title"><span>Unrelated current story</span></p>
              <time datetime="2026-08-11 14:10">2026.08.11</time>
            </a>
          </li>
          <li class="p-articleListItem">
            <a href="/news/relevant" class="p-articleListItem__link">
              <img src="https://img.example/relevant.jpg">
              <p class="p-articleListItem__title"><span>Status Oshi official update &amp; interview</span></p>
              <time datetime="2026-08-10 08:30">2026.08.10</time>
            </a>
          </li>
        </ol>
        """#.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    html,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["mdpr"]
        )

        XCTAssertEqual(report.items.map(\.id).count, 1)
        XCTAssertEqual(report.items.first?.title, "Status Oshi official update & interview")
        XCTAssertEqual(report.items.first?.source, "modelpress_search")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("mdpr.jp/search") }.count, 1)
        XCTAssertFalse(urls.contains { $0.contains("news.google.com") })
    }

    func testModelPressFollowsSecondPageToPreserveOlderMatches() async throws {
        let firstPage = Data(#"""
        <ol>
          <li class="p-articleListItem">
            <a href="/news/irrelevant" class="p-articleListItem__link">
              <p class="p-articleListItem__title"><span>Unrelated story</span></p>
              <time datetime="2026-08-11 14:10">2026.08.11</time>
            </a>
          </li>
        </ol>
        <a href="/search?keyword=Status&amp;type=article&amp;page=2" class="c-pager__button c-pager__button--next">Next</a>
        """#.utf8)
        let secondPage = Data(#"""
        <ol>
          <li class="p-articleListItem">
            <a href="/news/older-relevant" class="p-articleListItem__link">
              <p class="p-articleListItem__title"><span>Status Oshi older official match</span></p>
              <time datetime="2026-07-20 08:30">2026.07.20</time>
            </a>
          </li>
        </ol>
        """#.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                return (
                    url.contains("page=2") ? secondPage : firstPage,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["mdpr"]
        )

        XCTAssertEqual(report.items.map(\.title), ["Status Oshi older official match"])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .stale)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("mdpr.jp/search") }.count, 2)
        XCTAssertTrue(urls.contains { $0.contains("page=2") })
        XCTAssertFalse(urls.contains { $0.contains("news.google.com") })
    }

    func testCurrentLookupSkipsHistoricalWideningWhenRelevantItemsExist() async throws {
        let recentRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Status Oshi current article - ModelPress</title>
        <link>https://mdpr.jp/news/current-status-oshi</link>
        <pubDate>Mon, 10 Aug 2026 07:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let historicalRSS = Data("""
        <rss version="2.0"><channel>
        <item>
        <title>Status Oshi current article - ModelPress</title>
        <link>https://mdpr.jp/news/current-status-oshi</link>
        <pubDate>Mon, 10 Aug 2026 07:00:00 GMT</pubDate>
        </item>
        <item>
        <title>Status Oshi older article - ModelPress</title>
        <link>https://mdpr.jp/news/older-status-oshi</link>
        <pubDate>Fri, 31 Jul 2026 07:00:00 GMT</pubDate>
        </item>
        </channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    request.url?.absoluteString.contains("when:10y") == true ? historicalRSS : recentRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertEqual(report.items.map(\.url), ["https://mdpr.jp/news/current-status-oshi"])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 1)
        XCTAssertFalse(urls.contains { $0.contains("when:10y") })
    }

    func testRecentLookupSkipsHistoricalRequestWhenRecentResultsFillLimit() async throws {
        let items = (0..<20).map { index in
            """
            <item>
            <title>Status Oshi current article \(index)</title>
            <link>https://example.com/current-\(index)</link>
            <pubDate>Mon, 10 Aug 2026 07:00:00 GMT</pubDate>
            </item>
            """
        }.joined()
        let recentRSS = Data("<rss version=\"1.0\"><channel>\(items)</channel></rss>".utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    recentRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertEqual(report.items.count, 20)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 1)
        XCTAssertTrue(urls.first?.contains("when:") == false)
    }

    func testGoogleNewsQueryEscapesKeywordParameterDelimiters() async throws {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    emptyRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true
        )

        _ = await service.ingestReport(
            term: WatchTerm(keyword: "&TEAM"),
            platforms: ["oricon"]
        )

        let urls = await capture.urls
        XCTAssertEqual(urls.count, 3)
        for rawURL in urls {
            let components = try XCTUnwrap(URLComponents(string: rawURL))
            XCTAssertEqual(
                components.queryItems?.first { $0.name == "q" }?.value?.hasPrefix("&TEAM site:oricon.co.jp"),
                true
            )
            XCTAssertFalse(rawURL.contains("?q=&TEAM"))
            XCTAssertTrue(rawURL.contains("%26TEAM"))
        }
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 2)
        XCTAssertEqual(urls.filter { $0.contains("www.bing.com/news/search") }.count, 1)
    }

    func testGoogleNewsFallsBackToDirectBingRSSAndUnwrapsPublisherURL() async throws {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let bingRSS = Data(#"""
        <rss version="2.0"><channel>
        <item>
        <title>Status Oshi interview - ORICON NEWS | Bing</title>
        <link>https://www.bing.com/news/apiclick.aspx?ref=example&amp;url=https%3A%2F%2Foricon.co.jp%2Fnews%2F123%3Futm_source%3Dbing</link>
        <description>Status Oshi talks about the new release.</description>
        <pubDate>Sun, 23 Aug 2026 08:00:00 GMT</pubDate>
        </item>
        <item>
        <title>Status Oshi archive - ORICON NEWS</title>
        <link>https://oricon.co.jp/news/archive</link>
        <pubDate>Wed, 01 Jul 2026 08:00:00 GMT</pubDate>
        </item>
        <item>
        <title>Status Oshi outside six months - ORICON NEWS</title>
        <link>https://oricon.co.jp/news/too-old</link>
        <pubDate>Thu, 01 Jan 2026 08:00:00 GMT</pubDate>
        </item>
        <item>
        <title>Unrelated current story - ORICON NEWS</title>
        <link>https://oricon.co.jp/news/unrelated</link>
        <pubDate>Sun, 23 Aug 2026 09:00:00 GMT</pubDate>
        </item>
        </channel></rss>
        """#.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-24T08:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = request.url?.host == "www.bing.com" ? bingRSS : emptyRSS
                return (
                    body,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertEqual(report.items.map(\.url), ["https://oricon.co.jp/news/123?utm_source=bing", "https://oricon.co.jp/news/archive"])
        XCTAssertEqual(report.items.first?.title, "Status Oshi interview")
        XCTAssertEqual(report.items.first?.content_text, "Status Oshi talks about the new release.")
        XCTAssertEqual(report.items.first?.author, "ORICON NEWS")
        XCTAssertEqual(report.items.first?.source, "bing_news")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 2)
        XCTAssertEqual(urls.filter { $0.contains("www.bing.com/news/search") }.count, 1)
        let bingURL = try XCTUnwrap(urls.first { $0.contains("www.bing.com/news/search") })
        let components = try XCTUnwrap(URLComponents(string: bingURL))
        XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, "Status Oshi site:oricon.co.jp")
        XCTAssertEqual(components.queryItems?.first { $0.name == "format" }?.value, "rss")
        XCTAssertEqual(components.queryItems?.first { $0.name == "mkt" }?.value, "ja-JP")
    }

    func testBingRedirectUnwrapKeepsUnsafeOrUnrelatedURLsUntouched() {
        let unsafe = "https://www.bing.com/news/apiclick.aspx?url=javascript%3Aalert(1)"
        let unrelated = "https://example.com/news/apiclick.aspx?url=https%3A%2F%2Foricon.co.jp%2Fnews%2F1"

        XCTAssertEqual(IngestionService.unwrapBingNewsURL(unsafe), unsafe)
        XCTAssertEqual(IngestionService.unwrapBingNewsURL(unrelated), unrelated)
    }

    func testTVerDoesNotInventCurrentDateForUndatedResults() async throws {
        let createResponse = Data(#"{"result":{"platform_uid":"test-uid","platform_token":"test-token"}}"#.utf8)
        let searchResponse = Data(#"""
        {"result":{"episodes":{"contents":[
          {"content":{"id":"undated","title":"TVer Oshi undated"}},
          {"content":{"id":"dated","title":"TVer Oshi dated","broadcastDate":"2026-08-11T07:00:00Z"}}
        ]}}}
        """#.utf8)
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let data = request.url?.path.contains("/browser/create") == true ? createResponse : searchResponse
                return (
                    data,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "TVer Oshi"),
            platforms: ["tver"]
        )

        XCTAssertEqual(report.items.map(\.id), ["tver:dated"])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testTVerUsesEpisodeDetailForDescriptionOnlyMatchAndMissingDate() async throws {
        let createResponse = Data(#"{"result":{"platform_uid":"test-uid","platform_token":"test-token"}}"#.utf8)
        let searchResponse = Data(#"""
        {"result":{"episodes":{"contents":[
          {"content":{"id":"detail-match","title":"Unrelated episode","description":"List summary"}}
        ]}}}
        """#.utf8)
        let detailResponse = Data(#"""
        {"description":"Guest Detail Oshi appears","broadcastDate":"2026-08-11T07:00:00Z","broadcastProviderLabel":"TVer Provider"}
        """#.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data: Data
                if request.url?.path.contains("/browser/create") == true {
                    data = createResponse
                } else if request.url?.host == "statics.tver.jp" {
                    data = detailResponse
                } else {
                    data = searchResponse
                }
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Detail Oshi"),
            platforms: ["tver"]
        )

        XCTAssertEqual(report.items.map(\.id), ["tver:detail-match"])
        XCTAssertEqual(report.items.first?.content_text, "Guest Detail Oshi appears")
        XCTAssertEqual(report.items.first?.author, "TVer Provider")
        let urls = await capture.urls
        XCTAssertTrue(urls.contains("https://statics.tver.jp/content/episode/detail-match.json"))
    }

    func testTVerBoundsConcurrentEpisodeDetailRequests() async throws {
        let createResponse = Data(#"{"result":{"platform_uid":"test-uid","platform_token":"test-token"}}"#.utf8)
        let episodes = (0..<8).map { index in
            #"{"content":{"id":"episode-\#(index)","title":"Unrelated \#(index)","broadcastDate":"2026-08-11T07:00:00Z"}}"#
        }.joined(separator: ",")
        let searchResponse = Data("{\"result\":{\"episodes\":{\"contents\":[\(episodes)]}}}".utf8)
        let detailResponse = Data(#"{"description":"TVer Oshi guest appearance"}"#.utf8)
        let concurrency = ConcurrentRequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let data: Data
                if request.url?.path.contains("/browser/create") == true {
                    data = createResponse
                } else if request.url?.host == "statics.tver.jp" {
                    await concurrency.begin()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await concurrency.end()
                    data = detailResponse
                } else {
                    data = searchResponse
                }
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "TVer Oshi"),
            platforms: ["tver"]
        )

        XCTAssertEqual(report.items.count, 8)
        let maximumActive = await concurrency.maximumActive
        XCTAssertGreaterThan(maximumActive, 1)
        XCTAssertLessThanOrEqual(maximumActive, 4)
    }

    func testTVerSharesDetailLimitAcrossTermsAndAliases() async throws {
        let createResponse = Data(#"{"result":{"platform_uid":"test-uid","platform_token":"test-token"}}"#.utf8)
        let episodes = (0..<6).map { index in
            "{\"content\":{\"id\":\"shared-\(index)\",\"title\":\"Unrelated \(index)\",\"broadcastDate\":\"2026-08-11T07:00:00Z\"}}"
        }.joined(separator: ",")
        let searchResponse = Data("{\"result\":{\"episodes\":{\"contents\":[\(episodes)]}}}".utf8)
        let detailResponse = Data(#"{"description":"Primary TVer Alias TVer Second TVer guest appearance"}"#.utf8)
        let concurrency = ConcurrentRequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let data: Data
                if request.url?.path.contains("/browser/create") == true {
                    data = createResponse
                } else if request.url?.host == "statics.tver.jp" {
                    await concurrency.begin()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await concurrency.end()
                    data = detailResponse
                } else {
                    data = searchResponse
                }
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        async let aliasedReport = service.ingestReport(
            term: WatchTerm(keyword: "Primary TVer", aliases: ["Alias TVer"]),
            platforms: ["tver"]
        )
        async let secondReport = service.ingestReport(
            term: WatchTerm(keyword: "Second TVer"),
            platforms: ["tver"]
        )
        let (first, second) = await (aliasedReport, secondReport)

        XCTAssertEqual(first.items.count, 6)
        XCTAssertEqual(second.items.count, 6)
        let started = await concurrency.startedCount()
        let maximumActive = await concurrency.maximumActive
        XCTAssertEqual(started, 18)
        XCTAssertGreaterThan(maximumActive, 1)
        XCTAssertLessThanOrEqual(maximumActive, 4)
    }

    func testTVerListCompleteCandidatesSkipOccupiedDetailLimiterAndKeepOrder() async throws {
        let createResponse = Data(#"{"result":{"platform_uid":"test-uid","platform_token":"test-token"}}"#.utf8)
        let detailCandidates = (0..<4).map { index in
            "{\"content\":{\"id\":\"detail-\(index)\",\"title\":\"Unrelated \(index)\",\"broadcastDate\":\"2026-08-11T07:00:00Z\"}}"
        }
        let listCandidates = (0..<4).map { index in
            "{\"content\":{\"id\":\"list-\(index)\",\"title\":\"Mixed TVer list match \(index)\",\"broadcastDate\":\"2026-08-11T07:00:00Z\"}}"
        }
        let searchResponse = Data(
            "{\"result\":{\"episodes\":{\"contents\":[\((detailCandidates + listCandidates).joined(separator: ","))]}}}".utf8
        )
        let detailResponse = Data(#"{"description":"Mixed TVer detail match"}"#.utf8)
        let detailURLs = RequestCapture()
        let concurrency = ConcurrentRequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let data: Data
                if request.url?.path.contains("/browser/create") == true {
                    data = createResponse
                } else if request.url?.host == "statics.tver.jp" {
                    await detailURLs.record(request.url?.absoluteString ?? "")
                    await concurrency.begin()
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    await concurrency.end()
                    data = detailResponse
                } else {
                    data = searchResponse
                }
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Mixed TVer"),
            platforms: ["tver"]
        )

        XCTAssertEqual(
            report.items.map(\.id),
            (0..<4).map { "tver:detail-\($0)" } + (0..<4).map { "tver:list-\($0)" }
        )
        let urls = await detailURLs.urls
        XCTAssertEqual(urls.count, 4)
        XCTAssertFalse(urls.contains { $0.contains("/list-") })
        let maximumActive = await concurrency.maximumActive
        XCTAssertEqual(maximumActive, 4)
    }

    func testTVerCancellationDropsQueuedDetailsAndReleasesSharedCapacity() async throws {
        let createResponse = Data(#"{"result":{"platform_uid":"test-uid","platform_token":"test-token"}}"#.utf8)
        let cancelEpisodes = (0..<12).map { index in
            "{\"content\":{\"id\":\"cancel-\(index)\",\"title\":\"Unrelated \(index)\",\"broadcastDate\":\"2026-08-11T07:00:00Z\"}}"
        }.joined(separator: ",")
        let cancelSearch = Data("{\"result\":{\"episodes\":{\"contents\":[\(cancelEpisodes)]}}}".utf8)
        let followSearch = Data(#"{"result":{"episodes":{"contents":[{"content":{"id":"follow-0","title":"Unrelated follow","broadcastDate":"2026-08-11T07:00:00Z"}}]}}}"#.utf8)
        let detailResponse = Data(#"{"description":"Cancel TVer Follow TVer guest appearance"}"#.utf8)
        let concurrency = ConcurrentRequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let data: Data
                if request.url?.path.contains("/browser/create") == true {
                    data = createResponse
                } else if request.url?.host == "statics.tver.jp" {
                    await concurrency.begin()
                    if request.url?.path.contains("/cancel-") == true {
                        do {
                            try await Task.sleep(nanoseconds: 30_000_000_000)
                        } catch {
                            await concurrency.end()
                            throw error
                        }
                    }
                    await concurrency.end()
                    data = detailResponse
                } else {
                    let keyword = URLComponents(
                        url: request.url!, resolvingAgainstBaseURL: false
                    )?.queryItems?.first { $0.name == "keyword" }?.value
                    data = keyword == "Follow TVer" ? followSearch : cancelSearch
                }
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let cancelled = Task {
            await service.ingestReport(
                term: WatchTerm(keyword: "Cancel TVer"),
                platforms: ["tver"]
            )
        }
        await concurrency.waitUntilStarted(4)
        cancelled.cancel()
        _ = await cancelled.value

        let startsAfterCancellation = await concurrency.startedCount()
        XCTAssertEqual(startsAfterCancellation, 4)

        let followUp = await service.ingestReport(
            term: WatchTerm(keyword: "Follow TVer"),
            platforms: ["tver"]
        )
        XCTAssertEqual(followUp.items.map(\.id), ["tver:follow-0"])
        let finalStarts = await concurrency.startedCount()
        XCTAssertEqual(finalStarts, 5)
    }

    func testTVerQueuedDetailDoesNotStartAfterRefreshDeadline() async throws {
        let createResponse = Data(#"{"result":{"platform_uid":"test-uid","platform_token":"test-token"}}"#.utf8)
        let blockingEpisodes = (0..<4).map { index in
            "{\"content\":{\"id\":\"blocking-\(index)\",\"title\":\"Unrelated \(index)\",\"broadcastDate\":\"2026-08-11T07:00:00Z\"}}"
        }.joined(separator: ",")
        let blockingSearch = Data("{\"result\":{\"episodes\":{\"contents\":[\(blockingEpisodes)]}}}".utf8)
        let expiredSearch = Data(#"{"result":{"episodes":{"contents":[{"content":{"id":"expired-0","title":"Unrelated expired","broadcastDate":"2026-08-11T07:00:00Z"}}]}}}"#.utf8)
        let detailResponse = Data(#"{"description":"Blocking TVer Expired TVer guest appearance"}"#.utf8)
        let concurrency = ConcurrentRequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let data: Data
                if request.url?.path.contains("/browser/create") == true {
                    data = createResponse
                } else if request.url?.host == "statics.tver.jp" {
                    await concurrency.begin()
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    await concurrency.end()
                    data = detailResponse
                } else {
                    let keyword = URLComponents(
                        url: request.url!, resolvingAgainstBaseURL: false
                    )?.queryItems?.first { $0.name == "keyword" }?.value
                    data = keyword == "Expired TVer" ? expiredSearch : blockingSearch
                }
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let blocking = Task {
            await service.ingestReport(
                term: WatchTerm(keyword: "Blocking TVer"),
                platforms: ["tver"]
            )
        }
        await concurrency.waitUntilStarted(4)
        let expired = await service.ingestReport(
            term: WatchTerm(keyword: "Expired TVer"),
            platforms: ["tver"],
            requestDeadline: Date().addingTimeInterval(0.02)
        )
        _ = await blocking.value

        XCTAssertTrue(expired.items.isEmpty)
        let totalStarted = await concurrency.startedCount()
        XCTAssertEqual(totalStarted, 4)
    }

    func testTypedTransportFailuresMapTimeoutNetworkAndHTTPStatuses() async {
        let cases: [(SourceRefreshFailure, Int?)] = [
            (.timeout, nil),
            (.networkUnavailable, nil),
            (.authenticationRequired, 401),
            (.authenticationRequired, 403),
            (.rateLimited, 429),
            (.httpFailure, 500),
        ]

        for (expected, statusCode) in cases {
            let service = IngestionService { _ in
                if let statusCode {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: URL(string: "https://example.com")!,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: nil
                    )))
                }
                throw expected == .timeout ? URLError(.timedOut) : URLError(.notConnectedToInternet)
            }

            let report = await service.ingestReport(
                term: WatchTerm(keyword: "Transport Oshi"),
                platforms: ["news"]
            )
            XCTAssertTrue(report.sourceStatuses.contains {
                if case .failed(expected) = $0.outcome { return true }
                return false
            }, "Expected \(expected) in \(report.sourceStatuses)")
        }
    }

    func testRetryTimeoutThenSuccessReturnsItemsWithoutFailure() async {
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Retry Oshi</title><link>https://example.com/retry</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                if await capture.count() == 1 {
                    throw URLError(.timedOut)
                }
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Retry Oshi"),
            platforms: ["barks"]
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(report.items.isEmpty)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testBackgroundTransportPolicyUsesOneBoundedAttemptPerRequest() async {
        let capture = RequestPolicyCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request)
                throw URLError(.timedOut)
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Bounded Oshi"),
            platforms: ["barks"],
            maximumAliases: 0,
            transportAttemptLimit: 1,
            requestTimeoutCap: 7
        )

        let requests = await capture.requests
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.timeout == 7 })
        XCTAssertEqual(requests.filter { $0.url == "https://barks.jp/feed/" }.count, 1)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.timeout))
    }

    func testBackgroundAbsoluteDeadlineStopsSequentialFallbackRequests() async {
        let capture = RequestPolicyCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request)
                try? await Task.sleep(nanoseconds: 60_000_000)
                throw URLError(.timedOut)
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Deadline Oshi"),
            platforms: ["barks"],
            maximumAliases: 0,
            transportAttemptLimit: 1,
            requestTimeoutCap: 7,
            requestDeadline: Date(timeIntervalSinceNow: 0.03)
        )

        let requests = await capture.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertLessThanOrEqual(requests[0].timeout, 0.03)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.timeout))
    }

    func testRetryNetworkFailureThenSuccessCanReturnNoResults() async {
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                if await capture.count() == 1 {
                    throw URLError(.notConnectedToInternet)
                }
                return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Retry Empty"),
            platforms: ["barks"]
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .noResults)
    }

    func testRetryHTTP503ThenSuccessAndHTTP429Exhaustion() async {
        let successRSS = Data("<rss version=\"2.0\"><channel><item><title>Server Oshi</title><link>https://example.com/server</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
        let serverCapture = RequestCapture()
        let serverService = IngestionService(
            requestExecutor: { request in
                await serverCapture.record(request.url?.absoluteString ?? "")
                let status = await serverCapture.count() == 1 ? 503 : 200
                return (successRSS, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )
        let recovered = await serverService.ingestReport(
            term: WatchTerm(keyword: "Server Oshi"), platforms: ["barks"]
        )
        let serverRequestCount = await serverCapture.count()
        XCTAssertEqual(serverRequestCount, 2)
        XCTAssertEqual(recovered.sourceStatuses.first?.outcome, .received)

        let limitedCapture = RequestCapture()
        let limitedService = IngestionService(
            requestExecutor: { request in
                await limitedCapture.record(request.url?.absoluteString ?? "")
                return (Data(), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )
        let limited = await limitedService.ingestReport(
            term: WatchTerm(keyword: "Limited Oshi"), platforms: ["barks"]
        )
        let limitedRequestCount = await limitedCapture.count()
        let limitedURLs = await limitedCapture.urls
        XCTAssertEqual(limitedRequestCount, 6)
        XCTAssertEqual(limitedURLs.filter { $0 == "https://barks.jp/feed/" }.count, 2)
        XCTAssertEqual(limitedURLs.filter { $0.contains("news.google.com") }.count, 2)
        XCTAssertEqual(limitedURLs.filter { $0.contains("www.bing.com/news/search") }.count, 2)
        XCTAssertEqual(limited.sourceStatuses.first?.outcome, .failed(.rateLimited))
    }

    func testAuthenticationAndMalformedPayloadsAreNotRetried() async {
        for status in [401, 403] {
            let capture = RequestCapture()
            let service = IngestionService(
                requestExecutor: { request in
                    await capture.record(request.url?.absoluteString ?? "")
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                    )))
                },
                retrySleeper: { _ in }
            )
            let report = await service.ingestReport(
                term: WatchTerm(keyword: "Auth Oshi"), platforms: ["barks"]
            )
            let requestCount = await capture.count()
            XCTAssertEqual(requestCount, 1)
            XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.authenticationRequired))
        }

        let malformedCapture = RequestCapture()
        let malformedService = IngestionService(
            requestExecutor: { request in
                await malformedCapture.record(request.url?.absoluteString ?? "")
                return (Data("<rss><channel>".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )
        let malformed = await malformedService.ingestReport(
            term: WatchTerm(keyword: "Malformed Retry Oshi"), platforms: ["barks"]
        )
        let malformedRequestCount = await malformedCapture.count()
        let malformedURLs = await malformedCapture.urls
        XCTAssertEqual(malformedRequestCount, 3)
        XCTAssertEqual(malformedURLs.filter { $0 == "https://barks.jp/feed/" }.count, 1)
        XCTAssertEqual(malformedURLs.filter { $0.contains("news.google.com") }.count, 1)
        XCTAssertEqual(malformedURLs.filter { $0.contains("www.bing.com/news/search") }.count, 1)
        XCTAssertEqual(malformed.sourceStatuses.first?.outcome, .failed(.invalidPayload))
    }

    func testRetryPolicyAppliesToPOSTTransport() async {
        let postCapture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                if request.httpMethod == "POST" {
                    await postCapture.record(request.url?.absoluteString ?? "")
                    let status = await postCapture.count() == 1 ? 503 : 200
                    return (Data("{}".utf8), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                    )))
                }
                return (Data("{}".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        _ = await service.ingestReport(
            term: WatchTerm(keyword: "POST Retry Oshi"), platforms: ["youtube"]
        )

        let postRequestCount = await postCapture.count()
        XCTAssertEqual(postRequestCount, 2)
    }

    func testCancellationDuringBackoffDoesNotLeakRequestCapacity() async {
        let capture = RequestCapture()
        let gate = RetryGate()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                if await capture.count() == 1 {
                    throw URLError(.timedOut)
                }
                return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in
                await gate.enter()
                while !Task.isCancelled {
                    await Task.yield()
                }
            }
        )

        let cancelled = Task {
            await service.ingestReport(
                term: WatchTerm(keyword: "Cancelled Retry"), platforms: ["barks"]
            )
        }
        await gate.waitUntilEntered()
        cancelled.cancel()
        _ = await cancelled.value

        let followUp = await service.ingestReport(
            term: WatchTerm(keyword: "Follow Up"), platforms: ["barks"]
        )
        XCTAssertEqual(followUp.sourceStatuses.first?.outcome, .noResults)
        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 2)
    }

    func testMalformedRSSIsReportedAsInvalidPayload() async {
        let service = IngestionService { _ in
            (
                Data("<rss><channel>".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Malformed Oshi"),
            platforms: ["news"]
        )

        XCTAssertTrue(report.sourceStatuses.contains {
            if case .failed(.invalidPayload) = $0.outcome { return true }
            return false
        })
    }

    func testMalformedJSONIsReportedAsInvalidPayload() async {
        let service = IngestionService { request in
            (
                Data("{malformed".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Malformed JSON Oshi"),
            platforms: ["niconico"]
        )

        XCTAssertTrue(report.sourceStatuses.contains {
            if case .failed(.invalidPayload) = $0.outcome { return true }
            return false
        })
    }

    func testSuccessfulRSSReturnsItemsAndCompatibilityAPIStillReturnsItems() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Transport Oshi headline</title>
        <link>https://example.com/transport-oshi</link>
        <description>Transport Oshi update</description>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let service = IngestionService { _ in
            (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Transport Oshi"),
            platforms: ["news"]
        )
        let items = await service.ingest(
            term: WatchTerm(keyword: "Transport Oshi"),
            platforms: ["news"]
        )

        XCTAssertFalse(report.items.isEmpty)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(report.sourceStatuses.contains { $0.outcome == .received })
    }

    func testMixedSourceRefreshKeepsSuccessAndFailureTogether() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Mixed Oshi headline</title>
        <link>https://example.com/mixed-oshi</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let service = IngestionService { request in
            if request.url?.absoluteString.contains("soompi") == true {
                return (
                    Data(),
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!,
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
            return (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Mixed Oshi"),
            platforms: ["news", "soompi"]
        )

        XCTAssertTrue(report.sourceStatuses.contains { $0.id == "news" && $0.outcome == .received })
        XCTAssertTrue(report.sourceStatuses.contains {
            $0.id == "soompi" && $0.outcome == .failed(.rateLimited)
        })
        XCTAssertFalse(report.items.isEmpty)
    }

    func testMissingTwitterCredentialUsesPublicIndexFallback() async throws {
        let existing = KeychainHelper.read(.twitterBearerToken)
        KeychainHelper.save(.twitterBearerToken, nil)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        let rss = """
        <rss version="2.0"><channel><item>
        <title>Credential Oshi posted an update - x.com</title>
        <link>https://news.google.com/rss/articles/twitter-public-result</link>
        <pubDate>Fri, 14 Aug 2026 12:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let capture = RequestCapture()

        let report = await IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    rss,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            classifyFreshness: true,
            now: { ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")! }
        ).ingestReport(
            term: WatchTerm(keyword: "Credential Oshi"),
            platforms: ["twitter"]
        )

        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.source, IngestionService.twitterPublicIndexSource)
        let requestedPublicIndex = await capture.contains { url in
            url.contains("news.google.com/rss/search") && url.contains("site:x.com")
        }
        XCTAssertTrue(requestedPublicIndex)
    }

    func testMissingTwitterCredentialDoesNotClaimMediaResultsFromPublicIndex() async {
        let existing = KeychainHelper.read(.twitterBearerToken)
        KeychainHelper.save(.twitterBearerToken, nil)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        let report = await IngestionService(
            requestExecutor: { _ in
                XCTFail("Media-only X refresh must not use text-only public index results")
                throw URLError(.cancelled)
            }
        ).ingestReport(
            term: WatchTerm(keyword: "Credential Oshi", collection_mode: "media_only"),
            platforms: ["twitter"]
        )

        XCTAssertEqual(report.sourceStatuses.first?.outcome, .noResults)
    }

    func testKeychainSaveReportsSuccessfulWrite() {
        let existing = KeychainHelper.read(.twitterBearerToken)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        XCTAssertTrue(KeychainHelper.save(.twitterBearerToken, "test-token-\(UUID().uuidString)"))
        XCTAssertNotNil(KeychainHelper.read(.twitterBearerToken))
    }

    func testKeychainSaveReplacesExistingValue() {
        let existing = KeychainHelper.read(.twitterBearerToken)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        XCTAssertTrue(KeychainHelper.save(.twitterBearerToken, "first-token"))
        XCTAssertEqual(KeychainHelper.read(.twitterBearerToken), "first-token")
        XCTAssertTrue(KeychainHelper.save(.twitterBearerToken, "second-token"))
        XCTAssertEqual(KeychainHelper.read(.twitterBearerToken), "second-token")
    }

    func testWatchTermDecodesLegacyBackupWithoutSourceSelection() throws {
        let legacy = #"{"id":"legacy","keyword":"Legacy Oshi","collection_mode":"all_info","is_active":true,"notify_on_new":false,"aliases":[],"created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let term = try JSONDecoder().decode(WatchTerm.self, from: legacy)

        XCTAssertEqual(term.source_mode, .all)
        XCTAssertEqual(term.selected_platforms, [])
    }

    func testSavedPageDecodesLegacyBookmarkWithoutSource() throws {
        let legacy = #"{"id":"legacy","url":"https://example.com/saved","title":"Saved","platform":"news","saved_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let page = try JSONDecoder().decode(SavedPage.self, from: legacy)

        XCTAssertNil(page.source)
        XCTAssertNil(page.toFeedItem().source)
    }

    func testWatchTermDecodesMissingAndUnknownCollectionModeAsAllInfo() throws {
        let missing = #"{"id":"missing-mode","keyword":"Legacy Oshi","is_active":true,"aliases":[],"created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let unknown = #"{"id":"unknown-mode","keyword":"Legacy Oshi","collection_mode":"everything","is_active":true,"aliases":[],"created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!

        XCTAssertEqual(try JSONDecoder().decode(WatchTerm.self, from: missing).collection_mode, WatchTerm.allInfoCollectionMode)
        XCTAssertEqual(try JSONDecoder().decode(WatchTerm.self, from: unknown).collection_mode, WatchTerm.allInfoCollectionMode)
        XCTAssertEqual(WatchTerm(keyword: "Video Oshi", collection_mode: "media_only").collection_mode, WatchTerm.mediaOnlyCollectionMode)
        XCTAssertEqual(WatchTerm(keyword: "Unknown Oshi", collection_mode: "bad").collection_mode, WatchTerm.allInfoCollectionMode)
    }

    func testISO8601DateParsingCachePreservesSupportedFormatsAndFailures() {
        let zoned = "2026-01-01T12:34:56.123Z"
        let naive = "2026-01-01T12:34:56"

        XCTAssertNotNil(parseISO8601Date(zoned))
        XCTAssertNotNil(parseISO8601Date(zoned))
        XCTAssertNotNil(parseISO8601Date(naive))
        XCTAssertNil(parseISO8601Date("not-a-date"))
        XCTAssertNil(parseISO8601Date("not-a-date"))
    }

    func testISO8601DateParsingCacheHandlesConcurrentCalls() {
        let values = [
            "2024-06-15T10:30:00.123456Z",
            "2024-06-15T10:30:00Z",
            "2024-06-15T19:30:00+09:00",
            "2024-06-15T10:30:00",
            "not-a-date",
            ""
        ]
        let lock = NSLock()
        var mismatches: [String] = []

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            let value = values[index % values.count]
            let date = parseISO8601Date(value)
            let shouldBeNil = value.isEmpty || value == "not-a-date"
            if shouldBeNil != (date == nil) {
                lock.lock()
                mismatches.append(value)
                lock.unlock()
            }
        }

        XCTAssertTrue(mismatches.isEmpty, "Unexpected parse results for \(mismatches)")
    }

    func testSharedRelativeTimeFormatterProducesStableOutput() {
        let reference = Date(timeIntervalSince1970: 2_000_000)
        let earlier = reference.addingTimeInterval(-120)

        let first = relativeTimeString(from: earlier, relativeTo: reference)
        let second = relativeTimeString(from: earlier, relativeTo: reference)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    func testCleanDisplayTextHTMLEntities() {
        XCTAssertEqual(cleanDisplayText("Fish &amp; Chips"), "Fish & Chips")
        XCTAssertEqual(cleanDisplayText("He said &quot;hello&quot;"), "He said \"hello\"")
        XCTAssertEqual(cleanDisplayText("It&#39;s &apos;OK&apos;"), "It's 'OK'")
        XCTAssertEqual(cleanDisplayText("a&nbsp;b"), "a b")
        XCTAssertEqual(cleanDisplayText("x &lt; y &gt; z"), "x < y > z")
    }

    func testCleanDisplayTextStripsHTMLTagsBeforeDecodingEntities() {
        XCTAssertEqual(cleanDisplayText("<p>Hello <b>World</b></p>"), "Hello World")
        XCTAssertEqual(cleanDisplayText("Escaped &lt;b&gt;not a tag&lt;/b&gt;"), "Escaped <b>not a tag</b>")
    }

    func testCleanDisplayTextCollapsesWhitespaceAndEmptyResults() {
        XCTAssertEqual(cleanDisplayText("too   many   spaces"), "too many spaces")
        XCTAssertNil(cleanDisplayText("   "))
        XCTAssertNil(cleanDisplayText("<br/>"))
        XCTAssertNil(cleanDisplayText(nil))
    }

    @MainActor
    func testSelectedSourcesAdvanceRevisionAndFilterIngestion() throws {
        let initialRevision = db.dataRevision
        let term = db.saveTerm(
            keyword: "Selected Oshi",
            sourceMode: .selected,
            selectedPlatforms: [" youtube ", "unknown", "youtube"]
        )

        XCTAssertEqual(term.source_mode, .selected)
        XCTAssertEqual(term.selected_platforms, ["youtube"])
        XCTAssertGreaterThan(db.dataRevision, initialRevision)
        XCTAssertEqual(
            IngestionService.effectivePlatforms(for: term, available: ["youtube", "news", "tver"]),
            ["youtube"]
        )
        XCTAssertEqual(
            IngestionService.effectivePlatforms(for: term, available: [" x ", "news:yahoo_ent", "youtube", "unknown"]),
            ["youtube"]
        )
        XCTAssertEqual(
            IngestionService.effectivePlatforms(
                for: WatchTerm(keyword: "All Source Oshi"),
                available: [" x ", "news:yahoo_ent", "unknown"]
            ),
            ["twitter", "yahoonews"]
        )

        let revisionAfterCreate = db.dataRevision
        db.updateTerm(id: term.id, sourceMode: .selected, selectedPlatforms: [])
        XCTAssertEqual(db.terms.first?.source_mode, .all)
        XCTAssertEqual(db.terms.first?.selected_platforms, [])
        XCTAssertGreaterThan(db.dataRevision, revisionAfterCreate)
    }

    @MainActor
    func testUnsubscribingSourcesNormalizesSelectedTermSources() throws {
        let term = db.saveTerm(
            keyword: "Subscription Oshi",
            sourceMode: .selected,
            selectedPlatforms: ["youtube", "news"]
        )

        db.setSubscribedPlatforms(platforms: ["news", "tver"])
        let partiallyValid = try XCTUnwrap(db.terms.first(where: { $0.id == term.id }))
        XCTAssertEqual(partiallyValid.source_mode, .selected)
        XCTAssertEqual(partiallyValid.selected_platforms, ["news"])

        db.setSubscribedPlatforms(platforms: ["tver"])
        let noLongerValid = try XCTUnwrap(db.terms.first(where: { $0.id == term.id }))
        XCTAssertEqual(noLongerValid.source_mode, .all)
        XCTAssertEqual(noLongerValid.selected_platforms, [])
    }

    @MainActor
    func testRemovedSourceIsDroppedFromSavedSourcePreferences() throws {
        XCTAssertEqual(
            LocalDB.subscribedPlatformsForLoadedValue(["togetter", "news", "youtube"], hasSavedFile: true),
            ["news", "youtube"]
        )
        XCTAssertEqual(
            LocalDB.normalizedSourcesOrder(["custom", "togetter", "news", "youtube"]),
            ["custom", "news", "youtube"]
        )

        let term = db.saveTerm(
            keyword: "Removed Source Oshi",
            sourceMode: .selected,
            selectedPlatforms: ["togetter", "news"]
        )

        let saved = try XCTUnwrap(db.terms.first { $0.id == term.id })
        XCTAssertEqual(saved.source_mode, .selected)
        XCTAssertEqual(saved.selected_platforms, ["news"])

        db.updateTerm(id: term.id, sourceMode: .selected, selectedPlatforms: ["togetter"])
        let noLongerValid = try XCTUnwrap(db.terms.first { $0.id == term.id })
        XCTAssertEqual(noLongerValid.source_mode, .all)
        XCTAssertEqual(noLongerValid.selected_platforms, [])
    }

    func testLocalRefreshRequestNormalizesPlatformIDs() {
        XCTAssertEqual(
            LocalRefreshRequest.platform(" news:yahoo_ent ").platforms(subscribedPlatforms: ["youtube"]),
            ["yahoonews"]
        )
        XCTAssertEqual(
            LocalRefreshRequest.platform("unknown").platforms(subscribedPlatforms: ["youtube"]),
            []
        )
        XCTAssertEqual(
            LocalRefreshRequest.platform("custom").platforms(subscribedPlatforms: ["youtube", "custom"]),
            []
        )
        XCTAssertEqual(
            LocalRefreshRequest.foreground.platforms(subscribedPlatforms: ["custom", "x", "news:mdpr", "unknown", "youtube"]),
            ["twitter", "mdpr", "youtube"]
        )
        XCTAssertFalse(LocalRefreshRequest.platform("youtube").refreshesCustomURLs())
        XCTAssertTrue(LocalRefreshRequest.platform(" CUSTOM ").refreshesCustomURLs())
        XCTAssertTrue(LocalRefreshRequest.foreground.refreshesCustomURLs())
    }

    func testRequestLimiterCancellationDoesNotLeakOrBlockNextAcquire() async {
        let limiter = RequestLimiter(limit: 1)
        let firstAcquire = await limiter.acquire()
        XCTAssertTrue(firstAcquire)

        let waitingTask = Task { await limiter.acquire() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        waitingTask.cancel()

        let cancelledAcquire = await waitingTask.value
        XCTAssertFalse(cancelledAcquire)
        await limiter.release()
        let nextAcquire = await limiter.acquire()
        XCTAssertTrue(nextAcquire)
        await limiter.release()
    }

    @MainActor
    func testRefreshDiagnosticsPersistsSuccessfulRefreshSummary() {
        let diagnostics = RefreshDiagnostics.shared
        diagnostics.begin()
        XCTAssertTrue(diagnostics.isRefreshing)

        diagnostics.finish(succeeded: true, addedCount: 3)

        XCTAssertFalse(diagnostics.isRefreshing)
        XCTAssertEqual(diagnostics.lastSucceeded, true)
        XCTAssertEqual(diagnostics.lastAddedCount, 3)
        XCTAssertNotNil(diagnostics.lastStartedAt)
        XCTAssertNotNil(diagnostics.lastCompletedAt)
        XCTAssertTrue(diagnostics.statusText.contains("3 new"))
    }

    func testRefreshResultReportsCustomURLFailure() {
        let result = LocalRefreshResult(
            completion: .completed,
            addedCount: 0,
            sourceStatuses: [],
            customRefreshCompleted: false
        )

        XCTAssertFalse(result.succeeded)
    }

    func testRefreshResultKeepsSourceFailurePartialNotFailed() {
        let result = LocalRefreshResult(
            completion: .completed,
            addedCount: 0,
            sourceStatuses: [
                SourceRefreshStatus(id: "twitter", outcome: .failed(.missingCredential), itemCount: 0, queryCount: 1)
            ],
            customRefreshCompleted: true
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.hasSourceFailures)
    }

    func testRefreshResultKeepsStaleSourcePartialNotFailed() {
        let result = LocalRefreshResult(
            completion: .completed,
            addedCount: 0,
            sourceStatuses: [
                SourceRefreshStatus(id: "mdpr", outcome: .stale, itemCount: 15, queryCount: 1)
            ],
            customRefreshCompleted: true
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.hasSourceFailures)
        XCTAssertTrue(result.wasPartial)
    }

    func testRefreshResultTreatsCappedBackgroundWorkAsPartialButSuccessful() {
        let result = LocalRefreshResult(
            completion: .completed,
            addedCount: 0,
            sourceStatuses: [],
            customRefreshCompleted: true,
            cappedWorkCount: 2
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.wasPartial)
    }

    @MainActor
    func testCustomURLRefreshReportsAllFailedScrapesAsSourceFailure() async {
        db.setSubscribedPlatforms(platforms: ["custom"])
        db.customUrls = [
            CustomUrl(
                id: "custom:invalid",
                url: "::::",
                title: "Broken feed",
                added_at: "2026-08-01T00:00:00Z"
            )
        ]

        let result = await LocalRefreshCoordinator.shared.refresh(.foreground)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.sourceStatuses.first?.id, "custom")
        XCTAssertEqual(result.sourceStatuses.first?.outcome, .failed(.httpFailure))
    }

    @MainActor
    func testRefreshDiagnosticsPreservesCustomFailureWithReturnedItems() {
        let suiteName = "OshiReaderTests.custom.partial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "custom", outcome: .failed(.httpFailure), itemCount: 1, queryCount: 2)
        ])

        XCTAssertEqual(diagnostics.sourceStatuses.first?.outcome, .failed(.httpFailure))
        XCTAssertEqual(diagnostics.sourceStatuses.first?.itemCount, 1)
    }

    @MainActor
    func testRefreshDiagnosticsUsesInjectedDefaultsForLifecycleMetadata() {
        let suiteName = "OshiReaderTests.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let diagnostics = RefreshDiagnostics(defaults: defaults)
        diagnostics.begin()
        diagnostics.finish(succeeded: false)

        XCTAssertGreaterThan(defaults.double(forKey: "refresh_diagnostics.last_started_at"), 0)
        XCTAssertGreaterThan(defaults.double(forKey: "refresh_diagnostics.last_completed_at"), 0)
        XCTAssertFalse(defaults.bool(forKey: "refresh_diagnostics.last_succeeded"))
        XCTAssertFalse(diagnostics.statusText.contains("0 sec"))
        XCTAssertTrue(diagnostics.statusText.contains("just now"))
    }

    @MainActor
    func testRecentTermUsagePrioritizesNotificationsAndPreservesStableOrder() {
        let suiteName = "OshiReaderTests.recent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentTermUsageStore(defaults: defaults)
        let first = WatchTerm(id: "first", keyword: "First", notify_on_new: false)
        let second = WatchTerm(id: "second", keyword: "Second", notify_on_new: true)
        let third = WatchTerm(id: "third", keyword: "Third", notify_on_new: true)

        store.markUsed(termID: first.id)
        store.markUsed(termID: third.id)

        XCTAssertEqual(store.priorityOrdered([first, second, third]).map(\.id), ["third", "second", "first"])
    }

    @MainActor
    func testBackgroundPriorityKeepsNonNotificationTermsAfterNotificationTerms() {
        let suiteName = "OshiReaderTests.background.priority.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentTermUsageStore(defaults: defaults)
        let first = WatchTerm(id: "first", keyword: "First", notify_on_new: false)
        let second = WatchTerm(id: "second", keyword: "Second", notify_on_new: true)
        let third = WatchTerm(id: "third", keyword: "Third", notify_on_new: false)

        store.markUsed(termID: third.id)

        XCTAssertEqual(store.priorityOrdered([first, second, third]).map(\.id), ["second", "third", "first"])
    }

    @MainActor
    func testRecentTermUsageIsBoundedAndDeletionRemovesTimestamp() {
        let suiteName = "OshiReaderTests.recent.bound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentTermUsageStore(defaults: defaults)

        for index in 0..<(RecentTermUsageStore.maximumEntries + 5) {
            store.markUsed(termID: "term-\(index)")
        }

        XCTAssertEqual(store.timestamps.count, RecentTermUsageStore.maximumEntries)
        store.remove(termID: "term-104")
        XCTAssertNil(store.timestamps["term-104"])
    }

    @MainActor
    func testRefreshDiagnosticsMarksPartialSourceFailure() {
        let diagnostics = RefreshDiagnostics.shared
        diagnostics.resetSourceStatuses()
        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "natalie", outcome: .received, itemCount: 2, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1),
        ])

        XCTAssertTrue(diagnostics.hasSourceFailures)
        XCTAssertTrue(diagnostics.sourceSummaryText.contains("1 failed"))
    }

    @MainActor
    func testRefreshDiagnosticsReportsAndPersistsStaleSources() {
        let suiteName = "OshiReaderTests.health.stale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "mdpr", outcome: .stale, itemCount: 12, queryCount: 1)
        ])
        diagnostics.recordCompletedSourceStatuses(diagnostics.sourceStatuses)

        XCTAssertTrue(diagnostics.hasSourceFailures)
        XCTAssertTrue(diagnostics.sourceSummaryText.contains("1 stale"))

        let reloaded = RefreshDiagnostics(defaults: defaults)
        let summary = reloaded.sourceHealthSummaries.first { $0.id == "mdpr" }
        XCTAssertEqual(summary?.staleCount, 1)
        XCTAssertEqual(summary?.currentStatus?.outcome, .stale)
        XCTAssertEqual(summary?.totalItemCount, 12)
    }

    @MainActor
    func testRefreshDiagnosticsUsesCurrentPrecedenceOverStaleAcrossTerms() {
        let suiteName = "OshiReaderTests.health.stale-precedence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "mdpr", outcome: .stale, itemCount: 2, queryCount: 1),
            SourceRefreshStatus(id: "mdpr", outcome: .received, itemCount: 1, queryCount: 1),
        ])

        let status = diagnostics.sourceStatuses.first
        XCTAssertEqual(status?.outcome, .received)
        XCTAssertEqual(status?.itemCount, 3)
        XCTAssertEqual(status?.queryCount, 2)
        XCTAssertFalse(diagnostics.sourceStatuses.hasFailures)
    }

    @MainActor
    func testRefreshDiagnosticsKeepsFailureWhenHistoricalItemsWereRetained() {
        let suiteName = "OshiReaderTests.health.items-with-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(
                id: "oricon",
                outcome: .failed(.httpFailure),
                itemCount: 1,
                queryCount: 1
            )
        ])

        XCTAssertEqual(diagnostics.sourceStatuses.first?.outcome, .failed(.httpFailure))
        XCTAssertEqual(diagnostics.sourceStatuses.first?.itemCount, 1)
        XCTAssertTrue(diagnostics.hasSourceFailures)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "oricon", outcome: .received, itemCount: 2, queryCount: 1)
        ])
        XCTAssertEqual(diagnostics.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(diagnostics.sourceStatuses.first?.itemCount, 3)
        XCTAssertFalse(diagnostics.hasSourceFailures)
    }

    @MainActor
    func testRefreshDiagnosticsShowsCurrentStatusesBeforeHistoryIsPersisted() {
        let suiteName = "OshiReaderTests.health.current.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "news", outcome: .received, itemCount: 1, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1),
        ])

        XCTAssertEqual(diagnostics.visibleSourceHealthSummaries.map(\.id), ["barks", "news"])
        XCTAssertEqual(diagnostics.visibleSourceHealthSummaries.first { $0.id == "barks" }?.failedCount, 1)
    }

    @MainActor
    func testRefreshDiagnosticsMergesCurrentSourcesIntoExistingHistory() {
        let suiteName = "OshiReaderTests.health.merge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "news", outcome: .received, itemCount: 2, queryCount: 1)
        ])
        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1)
        ])

        XCTAssertEqual(diagnostics.visibleSourceHealthSummaries.map(\.id), ["barks", "news"])
        XCTAssertEqual(diagnostics.visibleSourceHealthSummaries.first { $0.id == "barks" }?.currentStatus?.outcome, .failed(.timeout))
    }

    @MainActor
    func testSourceHealthHistoryPersistsAndReloadsAggregatedSummary() {
        let suiteName = "OshiReaderTests.health.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let checkedAt = Date(timeIntervalSinceNow: -3600)
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "natalie", outcome: .received, itemCount: 3, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .noResults, itemCount: 0, queryCount: 1),
        ], completedAt: checkedAt)

        let reloaded = RefreshDiagnostics(defaults: defaults)
        let natalie = reloaded.sourceHealthSummaries.first { $0.id == "natalie" }
        let barks = reloaded.sourceHealthSummaries.first { $0.id == "barks" }
        XCTAssertEqual(natalie?.receivedCount, 1)
        XCTAssertEqual(natalie?.totalItemCount, 3)
        XCTAssertEqual(natalie?.currentStatus?.outcome, .received)
        XCTAssertEqual(barks?.emptyCount, 1)
        XCTAssertEqual(barks?.currentStatus?.outcome, .noResults)
    }

    @MainActor
    func testSourceHealthHistoryUsesTenDayRetention() {
        let suiteName = "OshiReaderTests.health.prune.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)
        let now = Date()
        XCTAssertEqual(RefreshDiagnostics.healthHistoryRetention, 10 * 24 * 60 * 60)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "old", outcome: .received, itemCount: 9, queryCount: 1),
        ], completedAt: now.addingTimeInterval(-(RefreshDiagnostics.healthHistoryRetention + 1)))
        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "recent", outcome: .received, itemCount: 2, queryCount: 1),
        ], completedAt: now)

        XCTAssertNil(diagnostics.sourceHealthSummaries.first { $0.id == "old" })
        XCTAssertNotNil(diagnostics.sourceHealthSummaries.first { $0.id == "recent" })
    }

    @MainActor
    func testSourceHealthHistoryUsesReceivedPrecedenceAndKeepsLatestFailure() {
        let suiteName = "OshiReaderTests.health.precedence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)
        let first = Date(timeIntervalSinceNow: -7200)
        let second = Date(timeIntervalSinceNow: -3600)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .noResults, itemCount: 0, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .received, itemCount: 2, queryCount: 1),
        ])
        XCTAssertEqual(diagnostics.sourceStatuses.first?.outcome, .received)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1),
        ], completedAt: first)
        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.rateLimited), itemCount: 0, queryCount: 1),
        ], completedAt: second)

        let summary = diagnostics.sourceHealthSummaries.first { $0.id == "barks" }
        XCTAssertEqual(summary?.failedCount, 2)
        XCTAssertEqual(summary?.lastFailure, .rateLimited)
        XCTAssertEqual(summary?.currentStatus?.outcome, .failed(.rateLimited))
    }

    @MainActor
    func testSourceHealthHistoryRetryAttemptsRemainOneLogicalRecord() {
        let suiteName = "OshiReaderTests.health.retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "natalie", outcome: .received, itemCount: 1, queryCount: 1),
        ])

        let summary = diagnostics.sourceHealthSummaries.first { $0.id == "natalie" }
        XCTAssertEqual(summary?.receivedCount, 1)
        XCTAssertEqual(summary?.totalItemCount, 1)
        XCTAssertEqual(summary?.currentStatus?.queryCount, 1)
    }

    @MainActor
    func testSourceHealthHistoryReplacesProvisionalRecordsWithinOneRefresh() {
        let suiteName = "OshiReaderTests.health.provisional.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)
        let refreshStart = Date(timeIntervalSinceNow: -60)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .noResults, itemCount: 0, queryCount: 1)
        ], completedAt: refreshStart.addingTimeInterval(-60))
        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1)
        ], completedAt: refreshStart.addingTimeInterval(1), replacingRecordsSince: refreshStart)
        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.rateLimited), itemCount: 0, queryCount: 2)
        ], completedAt: refreshStart.addingTimeInterval(2), replacingRecordsSince: refreshStart)

        let summary = diagnostics.sourceHealthSummaries.first { $0.id == "barks" }
        XCTAssertEqual(summary?.emptyCount, 1)
        XCTAssertEqual(summary?.failedCount, 1)
        XCTAssertEqual(summary?.lastFailure, .rateLimited)
        XCTAssertEqual(summary?.currentStatus?.queryCount, 2)
    }

    @MainActor
    func testSourceHealthHistoryEmptyStoreIsSafe() {
        let suiteName = "OshiReaderTests.health.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        XCTAssertTrue(diagnostics.sourceHealthSummaries.isEmpty)
        XCTAssertTrue(diagnostics.sourceStatuses.isEmpty)
    }

    @MainActor
    func testStrictFeedMatchingAcceptsAliasOnlyArticle() throws {
        let term = db.saveTerm(keyword: "Primary Oshi")
        db.updateTerm(id: term.id, aliases: ["Alias Oshi"])
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "news:alias-only",
            platform: "news",
            url: "https://example.com/alias-only",
            title: "Latest update on Alias Oshi",
            content_text: "Alias Oshi appeared in a new report.",
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: term.keyword,
            fetched_at: nowString
        )

        XCTAssertEqual(db.mergeItems(newItems: [item]), 1)
        XCTAssertEqual(db.queryFeed(keyword: term.keyword, days: 30).first?.id, item.id)
    }

    @MainActor
    func testDeletingSourcesRejectsStaleIngestionResults() throws {
        let term = db.saveTerm(keyword: "Deleted Oshi")
        let staleTermRevision = db.dataRevision
        db.deleteTerm(id: term.id)

        let termItem = FeedItem(
            id: "news:stale-term",
            platform: "news",
            url: "https://example.com/stale-term",
            title: "Stale term result",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: ISO8601DateFormatter().string(from: Date()),
            watch_term_keyword: term.keyword,
            fetched_at: ISO8601DateFormatter().string(from: Date())
        )
        XCTAssertEqual(db.mergeItems(newItems: [termItem], sourceRevision: staleTermRevision), 0)
        XCTAssertFalse(db.feedItems.contains(where: { $0.id == termItem.id }))

        db.addCustomUrl(url: "https://example.com/stale-feed.xml", title: "Stale feed")
        let customURL = try XCTUnwrap(db.customUrls.first)
        let staleCustomRevision = db.dataRevision
        db.removeCustomUrl(id: customURL.id)

        let customItem = FeedItem(
            id: "custom:stale-feed",
            platform: "custom",
            url: customURL.url,
            title: "Stale custom result",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: ISO8601DateFormatter().string(from: Date()),
            watch_term_keyword: "",
            fetched_at: ISO8601DateFormatter().string(from: Date())
        )
        XCTAssertEqual(db.mergeItems(newItems: [customItem], sourceRevision: staleCustomRevision), 0)
        XCTAssertFalse(db.feedItems.contains(where: { $0.id == customItem.id }))
    }

    @MainActor
    func testDeletingTermClearsHiddenItemsForThatKeywordOnly() throws {
        let deletedTerm = db.saveTerm(keyword: "Deleted Oshi")
        let keptTerm = db.saveTerm(keyword: "Kept Oshi")
        let separatorKeptTerm = db.saveTerm(keyword: "Prefix::Deleted Oshi")
        let nowString = ISO8601DateFormatter().string(from: Date())
        let deletedItem = FeedItem(
            id: "news:deleted-hidden",
            platform: "news",
            url: "https://example.com/deleted-hidden",
            title: "Deleted Oshi update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: deletedTerm.keyword,
            fetched_at: nowString
        )
        let keptItem = FeedItem(
            id: "news:kept-hidden",
            platform: "news",
            url: "https://example.com/kept-hidden",
            title: "Kept Oshi update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: keptTerm.keyword,
            fetched_at: nowString
        )
        let separatorKeptItem = FeedItem(
            id: "news:separator-kept-hidden",
            platform: "news",
            url: "https://example.com/separator-kept-hidden",
            title: "Prefix Deleted Oshi update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: separatorKeptTerm.keyword,
            fetched_at: nowString
        )
        db.feedItems = [deletedItem, keptItem, separatorKeptItem]

        db.deleteFeedItem(id: deletedItem.id, watchTermKeyword: deletedTerm.keyword)
        db.deleteFeedItem(id: keptItem.id, watchTermKeyword: keptTerm.keyword)
        db.deleteFeedItem(id: separatorKeptItem.id, watchTermKeyword: separatorKeptTerm.keyword)

        db.deleteTerm(id: deletedTerm.id)

        XCTAssertFalse(db.hiddenItems.contains("\(deletedItem.id)::\(deletedTerm.keyword)"))
        XCTAssertTrue(db.hiddenItems.contains("\(keptItem.id)::\(keptTerm.keyword)"))
        XCTAssertTrue(db.hiddenItems.contains("\(separatorKeptItem.id)::\(separatorKeptTerm.keyword)"))
    }

    @MainActor
    func testChangingIngestionSourcesRejectsStaleResults() throws {
        let term = db.saveTerm(keyword: "Disabled Oshi")
        let staleTermRevision = db.dataRevision
        db.updateTerm(id: term.id, isActive: false)

        let staleTermItem = FeedItem(
            id: "news:disabled-term",
            platform: "news",
            url: "https://example.com/disabled-term",
            title: "Disabled term result",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: ISO8601DateFormatter().string(from: Date()),
            watch_term_keyword: term.keyword,
            fetched_at: ISO8601DateFormatter().string(from: Date())
        )
        XCTAssertEqual(db.mergeItems(newItems: [staleTermItem], sourceRevision: staleTermRevision), 0)

        let stalePlatformRevision = db.dataRevision
        db.setSubscribedPlatforms(platforms: ["youtube"])
        XCTAssertNotEqual(db.dataRevision, stalePlatformRevision)
        XCTAssertEqual(
            db.mergeItems(newItems: [staleTermItem], sourceRevision: stalePlatformRevision),
            0
        )
    }

    @MainActor
    func testDataRevisionTracksOnlyIngestionAffectingChanges() throws {
        let initialRevision = db.dataRevision
        let term = db.saveTerm(keyword: "Revision Oshi")
        XCTAssertNotEqual(db.dataRevision, initialRevision)

        let afterTermCreateRevision = db.dataRevision
        db.updateTerm(id: term.id, notifyOnNew: !term.notify_on_new)
        XCTAssertEqual(db.dataRevision, afterTermCreateRevision)

        db.updateTerm(id: term.id, aliases: ["Revision Alias"])
        XCTAssertNotEqual(db.dataRevision, afterTermCreateRevision)

        let afterAliasRevision = db.dataRevision
        db.addCustomUrl(url: "https://example.com/revision-feed.xml", title: "Revision Feed")
        XCTAssertNotEqual(db.dataRevision, afterAliasRevision)
    }

    /// Times a full ingestReport fan-out (every subscribed platform, one
    /// watch term) against a mocked instant transport — isolates parsing/
    /// dedup CPU cost from real network latency, which measure() can't do
    /// for these async source fetchers. Most sources route through the
    /// generic Google News / dedicated RSS parser, so one shared RSS
    /// fixture (with the watch term's keyword in every item, satisfying
    /// strict-keyword-matching sources) exercises that shared path across
    /// all of them concurrently, same as LocalRefreshCoordinator does for
    /// one term in production. Sources needing JSON/HTML (YouTube, Twitter,
    /// TVer, niconico) will fail to parse this RSS payload and contribute
    /// no items — their cost isn't captured here.
    func testFullTermIngestionPerformanceWithMockedNetwork() async throws {
        let itemsXML = (0..<20).map { index -> String in
            """
            <item>
            <title>Perf Oshi story \(index) - Yahoo!ニュース</title>
            <link>https://example.com/perf/\(index)?utm_source=rss</link>
            <description>Perf Oshi description number \(index) with enough body text to exercise HTML-entity and whitespace cleanup.</description>
            <pubDate>Sun, 02 Aug 2026 08:0\(index % 6):00 GMT</pubDate>
            </item>
            """
        }.joined()
        let rss = Data("<rss version=\"2.0\"><channel>\(itemsXML)</channel></rss>".utf8)

        let service = IngestionService(
            requestExecutor: { request in
                (rss, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
            },
            retrySleeper: { _ in },
            pacingSleeper: { _ in }
        )
        let allPlatformIDs = Set(PlatformRegistry.all.map(\.id)).subtracting(["custom"])
        let term = WatchTerm(keyword: "Perf Oshi")

        var durationsMs: [Double] = []
        var itemCounts: [Int] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            let report = await service.ingestReport(term: term, platforms: allPlatformIDs)
            durationsMs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            itemCounts.append(report.items.count)
        }
        XCTAssertTrue(itemCounts.allSatisfy { $0 > 0 }, "mocked RSS should have produced items from at least the RSS-routed sources")
        // Steady-state average (dropping the first, JIT/warmup-affected run)
        // as a loose regression guard — this call was ~30ms against a real
        // device baseline; a large multiple of that signals an accidental
        // O(n^2) regression rather than normal machine variance.
        let steadyStateAverage = durationsMs.dropFirst().reduce(0, +) / Double(durationsMs.count - 1)
        XCTAssertLessThan(steadyStateAverage, 500, "full-platform ingestion against a mocked instant transport regressed well past its ~30ms baseline")
    }

}


extension OshiReaderTests {
    func testAllSearchFallbacksRetainSixMonthResults() async throws {
        let reference = Date()
        let service = IngestionService(requestExecutor: { request in
            let rows = [1,40,120,190].map { age in
                let date = ISO8601DateFormatter().string(from: reference.addingTimeInterval(-Double(age)*86400))
                return "<item><title>Range Audit \(age)</title><link>https://example.com/audit/\(age)</link><pubDate>\(date)</pubDate></item>"
            }.joined()
            if request.url?.host != "news.google.com" && request.url?.host != "www.bing.com" {
                return (Data(), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)))
            }
            return (Data("<rss version=\"2.0\"><channel>\(rows)</channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, retrySleeper: { _ in }, classifyFreshness: true, now: { reference })
        for platform in Set(PlatformRegistry.googleNewsSources.map(\.id) + ["news", "twitter", "niconico"]).sorted() {
            let report = await service.ingestReport(term: WatchTerm(keyword: "Range Audit"), platforms: [platform], fetchScope: .background)
            let titles = Set(report.items.compactMap(\.title))
            XCTAssertEqual(titles, ["Range Audit 1", "Range Audit 40", "Range Audit 120"], platform)
        }
    }

}


extension OshiReaderTests {
    func testTVerKeepsSixMonthHistoryAndRejectsOlderEpisodes() async throws {
        let reference = Date()
        let rows = [1,40,120,190].map { age -> [String: Any] in
            ["content": ["id": "history-\(age)", "title": "History Oshi episode \(age)",
                "broadcastDate": ISO8601DateFormatter().string(from: reference.addingTimeInterval(-Double(age) * 86400))]]
        }
        let response = try JSONSerialization.data(withJSONObject: ["result": ["episodes": ["contents": rows]]])
        let service = IngestionService(requestExecutor: { request in
            let data = request.url!.path.contains("/browser/create")
                ? Data(#"{"result":{"platform_uid":"test","platform_token":"test"}}"#.utf8) : response
            return (data, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, classifyFreshness: true, now: { reference })
        let report = await service.ingestReport(term: WatchTerm(keyword: "History Oshi"), platforms: ["tver"])
        XCTAssertEqual(Set(report.items.map(\.id)), ["tver:history-1", "tver:history-40", "tver:history-120"])
    }

    func testAmebloAndRealSoundDirectSearchKeepFourMonthHistory() async throws {
        let reference = Date()
        let date = ISO8601DateFormatter().string(from: reference.addingTimeInterval(-120 * 86400))
        let service = IngestionService(requestExecutor: { request in
            let html: String
            if request.url!.host == "search.ameba.jp" {
                html = """
                <script>window.__STATE__={"blogEntry":{"blogEntryMap":{"history":{
                "entryId":"history","amebaId":"history-blog","entryTitle":"History Oshi interview",
                "entryUpdatedDatetime":"\(date)"}}}};</script>
                """
            } else {
                html = """
                <article class="entry-summary"><h3 class="entry-title"><a href="https://realsound.jp/history">History Oshi interview</a></h3>
                <time datetime="\(date)"></time></article>
                """
            }
            return (Data(html.utf8), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, retrySleeper: { _ in }, classifyFreshness: true, now: { reference })
        for platform in ["ameblo", "realsound"] {
            let report = await service.ingestReport(term: WatchTerm(keyword: "History Oshi"), platforms: [platform])
            XCTAssertEqual(report.items.count, 1, platform)
            XCTAssertEqual(report.items.first?.published_at, date, platform)
            XCTAssertEqual(report.sourceStatuses.first?.outcome, .stale, platform)
            XCTAssertEqual(report.items.first?.source, platform == "ameblo" ? "ameba_search" : "realsound_search")
        }
    }
}
