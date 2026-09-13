import Foundation

/// Whether new-item alerts fire individually (one banner per item, as they've
/// always worked) or grouped into one banner per keyword per refresh. Purely a
/// presentation choice — grouping still respects Quiet Hours, per-term
/// `notify_on_new`, and the paid-push ownership handoff exactly like the
/// individual path.
struct NotificationDeliverySettings: Equatable {
    var groupedByKeyword: Bool

    private static var key: String {
        LocalProfileStore.defaultsKey("notification_delivery_grouped_by_keyword")
    }

    static func current(defaults: UserDefaults = .standard) -> NotificationDeliverySettings {
        NotificationDeliverySettings(groupedByKeyword: defaults.bool(forKey: key))
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(groupedByKeyword, forKey: Self.key)
    }
}
