import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let maximumAttachmentBytes: Int64 = 10 * 1024 * 1024
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?
    private var receiptTask: URLSessionDataTask?
    private var contentWorkFinished = false
    private var receiptWorkFinished = true
    private var activeRequestID: UUID?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        downloadTask?.cancel()
        receiptTask?.cancel()
        let requestID = UUID()
        activeRequestID = requestID
        contentWorkFinished = false
        receiptWorkFinished = true
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            finish(with: request.content)
            return
        }
        bestAttemptContent = content
        receiptWorkFinished = !sendReceiptDiagnostic(userInfo: content.userInfo, requestID: requestID)

        guard let url = thumbnailURL(from: content.userInfo) else {
            contentWorkFinished = true
            finishWhenReady()
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 8
        downloadTask = URLSession.shared.downloadTask(with: urlRequest) { [weak self] tempURL, response, _ in
            guard let self else { return }
            defer {
                DispatchQueue.main.async {
                    guard self.activeRequestID == requestID else { return }
                    self.downloadTask = nil
                    self.contentWorkFinished = true
                    self.finishWhenReady()
                }
            }

            guard let tempURL,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  http.mimeType?.lowercased().hasPrefix("image/") == true,
                  http.expectedContentLength <= 0 || http.expectedContentLength <= self.maximumAttachmentBytes,
                  self.fileSize(at: tempURL) <= self.maximumAttachmentBytes
            else { return }

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "oshireader-remote-preview-\(UUID().uuidString).\(self.fileExtension(for: http, url: url))"
                )
            do {
                try FileManager.default.moveItem(at: tempURL, to: destination)
                // Keep the thumbnail out of the collapsed banner/lock screen; it only
                // appears in the custom expanded view when the user long-presses.
                let options = [UNNotificationAttachmentOptionsThumbnailHiddenKey: true]
                content.attachments = [
                    try UNNotificationAttachment(identifier: "preview", url: destination, options: options)
                ]
            } catch {
                return
            }
        }
        downloadTask?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        downloadTask?.cancel()
        receiptTask?.cancel()
        if let bestAttemptContent {
            finish(with: bestAttemptContent)
        }
    }

    private func finishWhenReady() {
        guard contentWorkFinished, receiptWorkFinished, let bestAttemptContent else { return }
        finish(with: bestAttemptContent)
    }

    private func finish(with content: UNNotificationContent) {
        guard let contentHandler else { return }
        self.contentHandler = nil
        activeRequestID = nil
        contentHandler(content)
    }

    private func thumbnailURL(from userInfo: [AnyHashable: Any]) -> URL? {
        if let value = userInfo["thumbnail_url"] as? String,
           let url = URL(string: value),
           isSupported(url) {
            return url
        }
        if let preview = userInfo["preview_item"] as? [String: Any],
           let value = preview["thumbnail_url"] as? String,
           let url = URL(string: value),
           isSupported(url) {
            return url
        }
        return nil
    }

    private func isSupported(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased())
    }

    /// Remote notification payloads are emitted only by the paid backend. Reporting
    /// receipt here therefore cannot run for free local alerts, and gives the backend
    /// enough aggregate evidence to distinguish APNs delivery from presentation gaps.
    @discardableResult
    private func sendReceiptDiagnostic(userInfo: [AnyHashable: Any], requestID: UUID) -> Bool {
        guard let url = diagnosticsURL(from: userInfo) else { return false }

        let event: [String: Any] = [
            "strategy": "notification_service_extension",
            "status": "received",
            "item_count": intValue(userInfo["new_count"]),
            "added_count": 0,
            "detail": diagnosticDetail(userInfo: userInfo),
        ]
        let payload: [String: Any] = [
            "reason": "remote_notification_received",
            "environment": "NotificationService",
            "api_base": apiBase(from: url),
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "active_terms_count": 0,
            "subscribed_platforms": [],
            "cached_feed_count": 0,
            "events": [event],
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        receiptTask = URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                guard let self, self.activeRequestID == requestID else { return }
                self.receiptTask = nil
                self.receiptWorkFinished = true
                self.finishWhenReady()
            }
        }
        receiptTask?.resume()
        return true
    }

    private func diagnosticsURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let value = userInfo["diagnostics_url"] as? String,
              let url = URL(string: value),
              isSupported(url)
        else { return nil }
        return url
    }

    private func apiBase(from url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
    }

    private func diagnosticDetail(userInfo: [AnyHashable: Any]) -> String {
        let keys = [
            "notification_id",
            "apns_token_suffix",
            "watch_term_id",
            "watch_term_keyword",
            "new_count",
            "item_id",
            "match_id",
        ]
        let parts = keys.compactMap { key -> String? in
            guard let value = userInfo[key] else { return nil }
            return "\(key)=\(value)"
        }
        return String(parts.joined(separator: " ").prefix(500))
    }

    private func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return 0
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? Int.max)
    }

    private func fileExtension(for response: HTTPURLResponse, url: URL) -> String {
        switch response.mimeType?.lowercased() {
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/heic", "image/heif":
            return "heic"
        default:
            let ext = url.pathExtension.lowercased()
            return ["jpg", "jpeg"].contains(ext) ? ext : "jpg"
        }
    }
}
