import Foundation

/// Bridges an App Intent's `perform()` — which may run on a freshly launched
/// scene — into the already-mounted SwiftUI hierarchy, the same way
/// `NotificationNavigationManager` bridges a notification tap.
@MainActor
final class AppIntentNavigationManager: ObservableObject {
    static let shared = AppIntentNavigationManager()

    @Published var pendingSearchQuery: String?

    private init() {}
}
