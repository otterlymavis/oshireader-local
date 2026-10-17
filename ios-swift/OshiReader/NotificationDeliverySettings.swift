import Foundation

/// Whether new-item alerts fire individually (one banner per item) or update
/// one rolling summary per keyword until the posts are reviewed. Purely a
/// presentation choice — summaries still respect Quiet Hours, per-term
/// `notify_on_new`, and the paid-push ownership handoff exactly like the
/// individual path.
struct NotificationDeliverySettings: Equatable {
    var groupedByKeyword: Bool

    private static var key: String {
        LocalProfileStore.defaultsKey("notification_delivery_grouped_by_keyword")
    }

    static func current(defaults: UserDefaults = .standard) -> NotificationDeliverySettings {
        let storedChoice = defaults.object(forKey: key) as? Bool
        return NotificationDeliverySettings(groupedByKeyword: storedChoice ?? true)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(groupedByKeyword, forKey: Self.key)
    }
}
