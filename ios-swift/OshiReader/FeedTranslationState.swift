import Foundation

/// Feed-card translation: the per-profile "Translate feed" setting and the
/// cards the user flipped back to the original from the long-press menu.
/// Translation itself goes through `NotificationAlertTranslator.feed` (on-device,
/// iOS 26+, installed language pairs only).
@MainActor
final class FeedTranslationState: ObservableObject {
    static let shared = FeedTranslationState()
    static let enabledKey = "translate_feed"

    @Published private(set) var originalItemIDs: Set<String> = []
    /// Bumped on every setting change so cards re-run their translation task.
    @Published private(set) var settingRevision = 0

    /// The translator needs the UI-less session added in iOS 26.
    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    func isEnabled(profileID: UUID? = nil) -> Bool {
        Self.isSupported
            && UserDefaults.standard.bool(forKey: LocalProfileStore.defaultsKey(Self.enabledKey, profileID: profileID))
    }

    func setEnabled(_ enabled: Bool, profileID: UUID?) {
        UserDefaults.standard.set(enabled, forKey: LocalProfileStore.defaultsKey(Self.enabledKey, profileID: profileID))
        settingRevision += 1
    }

    /// Re-runs every card's translation, e.g. after a language download made
    /// a pair available that cards already gave up on.
    func retranslateAll() {
        settingRevision += 1
    }

    func showsOriginal(_ itemID: String) -> Bool {
        originalItemIDs.contains(itemID)
    }

    func toggleOriginal(_ itemID: String) {
        if originalItemIDs.remove(itemID) == nil {
            originalItemIDs.insert(itemID)
        }
    }
}
