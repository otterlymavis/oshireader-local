import Foundation
import NaturalLanguage
import Translation

/// Translates post titles / bodies into the app language the user picked
/// (`I18nManager.lang`): local alerts before they're scheduled, paid pushes in
/// the service extension, and feed cards when "Translate feed" is on.
///
/// On-device only (Apple Translation, iOS 26+ for the UI-less
/// `TranslationSession(installedSource:target:)`), so it also works inside a
/// `BGAppRefreshTask`. Text already in the user's language, text whose
/// language can't be told, an older OS, or a language pair whose model isn't
/// downloaded all fall back to the original text — a banner is never held up
/// or dropped over translation.
@MainActor
final class NotificationAlertTranslator {
    static let shared = NotificationAlertTranslator()

    /// Hard cap per string so a stalled translation can't eat the background
    /// refresh budget (callers also cap their total, see `NotificationManager`).
    private static let deadlineSeconds: Double = 1.5
    /// How long a pair stays skipped after it was found not installed or
    /// kept timing out, so later alerts don't pay for the same answer again.
    private static let unavailablePairBackoff: TimeInterval = 10 * 60
    /// Timeouts in a row before a pair is skipped. One slow call (a first
    /// model load while a feed full of cards translates at once) mustn't turn
    /// translation off for every card and alert for 10 minutes.
    private static let timeoutsBeforeBackoff = 3
    /// Alerts only show ~100 characters; translating more is wasted work.
    private static let maximumSourceLength = 400
    // Sized for a scrolled feed (title + snippet per card), not just alerts.
    private static let maximumCachedTranslations = 600

    // Rolling summaries re-post the same anchor title on every refresh and
    // review, so remember results instead of re-translating.
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var unavailablePairsUntil: [String: Date] = [:]
    private var consecutiveTimeouts: [String: Int] = [:]

    func translate(_ text: String, to appLanguage: String) async -> String {
        guard !Self.isTesting,
              let target = Self.targetLanguage(forAppLanguage: appLanguage),
              let source = Self.sourceLanguageNeedingTranslation(text, target: target.natural)
        else { return text }

        let sourceText = String(text.prefix(Self.maximumSourceLength))
        let cacheKey = "\(appLanguage)|\(sourceText)"
        if let cached = cache[cacheKey] { return cached }

        guard #available(iOS 26.0, *) else { return text }
        let pairKey = "\(source.rawValue)>\(appLanguage)"
        if let until = unavailablePairsUntil[pairKey], until > Date() { return text }
        let sourceLocale = Locale.Language(identifier: source.rawValue)
        let targetLocale = target.locale
        let outcome = await Self.withDeadline(Self.deadlineSeconds) {
            await Self.translateOnDevice(sourceText, from: sourceLocale, to: targetLocale)
        }
        switch outcome {
        case .translated(let translated) where !translated.isEmpty:
            unavailablePairsUntil[pairKey] = nil
            consecutiveTimeouts[pairKey] = nil
            remember(translated, for: cacheKey)
            return translated
        case .notInstalled:
            unavailablePairsUntil[pairKey] = Date().addingTimeInterval(Self.unavailablePairBackoff)
            return text
        case nil:
            let timeouts = consecutiveTimeouts[pairKey, default: 0] + 1
            if timeouts >= Self.timeoutsBeforeBackoff {
                consecutiveTimeouts[pairKey] = nil
                unavailablePairsUntil[pairKey] = Date().addingTimeInterval(Self.unavailablePairBackoff)
            } else {
                consecutiveTimeouts[pairKey] = timeouts
            }
            return text
        default:
            return text
        }
    }

    /// Settings calls this after a download finishes so a just-installed pair
    /// is tried again right away instead of after the backoff.
    func resetUnavailablePairs() {
        unavailablePairsUntil.removeAll()
        consecutiveTimeouts.removeAll()
    }

    // Unit / UI test runs keep the original text: the simulator has no
    // Translation support, and its per-call round trip skews the
    // notification spacing those suites assert on.
    private static let isTesting: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains("--uitesting")

    private func remember(_ translation: String, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = translation
        if cacheOrder.count > Self.maximumCachedTranslations {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    // MARK: - Language decisions (pure, unit-tested)

    /// The app's language codes (`I18nManager.lang`) mapped to the detector's
    /// and the translator's identifiers.
    nonisolated static func targetLanguage(forAppLanguage appLanguage: String) -> (natural: NLLanguage, locale: Locale.Language)? {
        switch appLanguage {
        case "en": return (.english, Locale.Language(identifier: "en"))
        case "ja": return (.japanese, Locale.Language(identifier: "ja"))
        case "zh-TW": return (.traditionalChinese, Locale.Language(identifier: "zh-Hant"))
        case "zh-CN": return (.simplifiedChinese, Locale.Language(identifier: "zh-Hans"))
        default: return nil
        }
    }

    /// Languages most matched posts arrive in (the sources are Japanese media,
    /// plus English news / X). Settings offers to download each one paired with
    /// the user's app language.
    nonisolated static let commonSourceAppLanguages = ["ja", "en"]

    /// `(source, target)` translator languages Settings should have installed
    /// for `appLanguage`; a source equal to the app language is skipped.
    nonisolated static func sourceLanguagesToPrepare(forAppLanguage appLanguage: String) -> [Locale.Language] {
        guard targetLanguage(forAppLanguage: appLanguage) != nil else { return [] }
        return commonSourceAppLanguages
            .filter { $0 != appLanguage }
            .compactMap { targetLanguage(forAppLanguage: $0)?.locale }
    }

    /// The text's language when it differs from `target`; `nil` when it is
    /// already in the user's language or can't be identified.
    nonisolated static func sourceLanguageNeedingTranslation(_ text: String, target: NLLanguage) -> NLLanguage? {
        guard let source = detectedLanguage(of: text), source != target else { return nil }
        return source
    }

    nonisolated static func detectedLanguage(of text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Kana is Japanese-only. Short kanji-heavy Japanese titles are otherwise
        // easily read as Chinese, which would "translate" Japanese for ja users.
        // Kana with kanji, or kana that isn't swamped by Latin letters, is
        // Japanese ("SixTONES新曲MV公開へ", "ちゃんみなLIVE TOUR"); a kana name
        // inside an English sentence is left to the recognizer.
        var kana = 0, han = 0, latin = 0
        for scalar in trimmed.unicodeScalars {
            if isKana(scalar) { kana += 1 } else if isHan(scalar) { han += 1 } else if scalar.isASCII, scalar.properties.isAlphabetic { latin += 1 }
        }
        if kana > 0, han > 0 || kana * 2 >= latin { return .japanese }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language
    }

    private nonisolated static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF: return true
        default: return false
        }
    }

    private nonisolated static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true
        default: return false
        }
    }

    // MARK: - Translation

    enum TranslationOutcome: Sendable {
        case translated(String)
        case notInstalled
        case failed
    }

    @available(iOS 26.0, *)
    private nonisolated static func translateOnDevice(
        _ text: String,
        from source: Locale.Language,
        to target: Locale.Language
    ) async -> TranslationOutcome {
        // A missing model can't be downloaded without UI, so only use pairs
        // that are already installed.
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return .notInstalled }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            return .translated(try await session.translate(text).targetText)
        } catch {
            AppLogger.notifications.error("Notification translation failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Returns `nil` if `operation` hasn't finished within `seconds`; the
    /// operation is cancelled but not awaited, so a hung call can't block.
    /// Whichever side finishes first cancels the other, so a fast translation
    /// doesn't leave its timer sleeping (feed scrolling starts many of these).
    nonisolated static func withDeadline<Value: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce<Value>(continuation)
            let work = CancellableTaskBox()
            let timer = Task {
                guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
                work.cancel()
                gate.resume(nil)
            }
            work.set(Task {
                let result = await operation()
                timer.cancel()
                gate.resume(result)
            })
        }
    }
}

private final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Lets the deadline timer cancel a task created after it; a `cancel()` that
/// lands first cancels the task as soon as it's set.
private final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let cancelNow = isCancelled
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let pending = task
        lock.unlock()
        pending?.cancel()
    }
}
