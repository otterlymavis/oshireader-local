import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LocalProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    var lastUsedAt: Date
}

struct LocalProfileSettings: Codable, Equatable {
    let themeMode: String?
    let colorStyle: String?
    let fontChoice: String?
    let fontSizeChoice: String?
    let language: String?
    let autoTranslateReader: Bool?

    static func load(profileID: UUID, defaults: UserDefaults = .standard) -> LocalProfileSettings {
        LocalProfileSettings(
            themeMode: defaults.string(forKey: LocalProfileStore.defaultsKey("app_theme_mode", profileID: profileID)),
            colorStyle: defaults.string(forKey: LocalProfileStore.defaultsKey("app_color_style", profileID: profileID)),
            fontChoice: defaults.string(forKey: LocalProfileStore.defaultsKey("app_font_choice", profileID: profileID)),
            fontSizeChoice: defaults.string(forKey: LocalProfileStore.defaultsKey("app_font_size_choice", profileID: profileID)),
            language: defaults.string(forKey: LocalProfileStore.defaultsKey("selected_lang", profileID: profileID)),
            autoTranslateReader: defaults.object(forKey: LocalProfileStore.defaultsKey("auto_translate_reader", profileID: profileID)) as? Bool
        )
    }

    func apply(to profileID: UUID, defaults: UserDefaults = .standard) {
        let values: [(String, Any?)] = [
            ("app_theme_mode", themeMode),
            ("app_color_style", colorStyle),
            ("app_font_choice", fontChoice),
            ("app_font_size_choice", fontSizeChoice),
            ("selected_lang", language),
            ("auto_translate_reader", autoTranslateReader)
        ]
        for (key, value) in values {
            let storageKey = LocalProfileStore.defaultsKey(key, profileID: profileID)
            if let value { defaults.set(value, forKey: storageKey) }
            else { defaults.removeObject(forKey: storageKey) }
        }
    }
}

struct LocalProfileTransfer: Codable {
    static let currentVersion = 1

    let version: Int
    let profile: LocalProfile
    let backup: LocalBackup
    let settings: LocalProfileSettings?

    init(profile: LocalProfile, backup: LocalBackup, settings: LocalProfileSettings? = nil) {
        self.version = Self.currentVersion
        self.profile = profile
        self.backup = backup
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case version, profile, backup, settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version >= 1, version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported profile package version"
            )
        }
        self.version = version
        self.profile = try container.decode(LocalProfile.self, forKey: .profile)
        self.backup = try container.decode(LocalBackup.self, forKey: .backup)
        self.settings = try container.decodeIfPresent(LocalProfileSettings.self, forKey: .settings)
    }
}

enum LocalProfileError: LocalizedError, Equatable {
    case invalidName
    case duplicateName
    case profileNotFound
    case cannotDeleteLastProfile
    case invalidPackage
    case unsupportedPackageVersion

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Profile names must not be empty."
        case .duplicateName: return "A profile with that name already exists."
        case .profileNotFound: return "The selected profile is no longer available."
        case .cannotDeleteLastProfile: return "The final profile cannot be deleted."
        case .invalidPackage: return "The profile package is invalid or incomplete."
        case .unsupportedPackageVersion: return "This profile package version is not supported."
        }
    }
}

final class LocalProfileStore: ObservableObject {
    static let shared = LocalProfileStore()
    static let rootDirectoryName = "profiles"
    static let registryFileName = ".oshireader-profiles.json"
    static let defaultProfileName = "Default"

    @Published private(set) var profiles: [LocalProfile] = []
    @Published private(set) var activeProfileID: UUID {
        didSet { setAtomicProfileID(activeProfileID) }
    }

    /// `activeProfileID` is a `@Published` value mutated on the main thread but
    /// read from background ingestion (`IngestionService`, `defaultsKey(_:)`).
    /// A profile switch concurrent with one of those reads is a data race on a
    /// 16-byte `UUID` store. This lock-guarded mirror is the safe accessor for
    /// non-main-thread callers.
    private let atomicProfileIDLock = NSLock()
    private var atomicProfileID: UUID
    var currentProfileIDThreadSafe: UUID {
        atomicProfileIDLock.lock()
        defer { atomicProfileIDLock.unlock() }
        return atomicProfileID
    }
    private func setAtomicProfileID(_ id: UUID) {
        atomicProfileIDLock.lock()
        atomicProfileID = id
        atomicProfileIDLock.unlock()
    }

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let documentsDirectory: URL

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documentsDirectory.appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        if let registry = Self.loadRegistry(from: documentsDirectory, decoder: JSONDecoder()), !registry.profiles.isEmpty,
           registry.profiles.contains(where: { $0.id == registry.activeProfileID }) {
            self.profiles = registry.profiles
            self.activeProfileID = registry.activeProfileID
            self.atomicProfileID = registry.activeProfileID
        } else {
            let profile = LocalProfile(id: UUID(), name: Self.defaultProfileName, createdAt: Date(), lastUsedAt: Date())
            self.profiles = [profile]
            self.activeProfileID = profile.id
            self.atomicProfileID = profile.id
            ensureProfileDirectory(for: profile.id)
            migrateLegacyData(to: profile.id)
            persist()
        }
        ensureProfileDirectory(for: activeProfileID)
        migrateLegacySettingsIfNeeded(to: activeProfileID)
    }

    var activeProfile: LocalProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
    }

    func profile(named name: String) -> LocalProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func createProfile(name: String) throws -> LocalProfile {
        let normalized = normalizedName(name)
        guard !normalized.isEmpty else { throw LocalProfileError.invalidName }
        guard profile(named: normalized) == nil else { throw LocalProfileError.duplicateName }
        let profile = LocalProfile(id: UUID(), name: normalized, createdAt: Date(), lastUsedAt: Date())
        profiles.append(profile)
        ensureProfileDirectory(for: profile.id)
        persist()
        return profile
    }

    func renameProfile(id: UUID, name: String) throws {
        let normalized = normalizedName(name)
        guard !normalized.isEmpty else { throw LocalProfileError.invalidName }
        guard !profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            throw LocalProfileError.duplicateName
        }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw LocalProfileError.profileNotFound }
        profiles[index].name = normalized
        persist()
    }

    func deleteProfile(id: UUID) throws {
        guard profiles.count > 1 else { throw LocalProfileError.cannotDeleteLastProfile }
        guard profiles.contains(where: { $0.id == id }) else { throw LocalProfileError.profileNotFound }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles[0].id
            profiles[0].lastUsedAt = Date()
        }
        try? fileManager.removeItem(at: directoryURL(for: id))
        removeScopedDefaults(for: id)
        persist()
    }

    func activateProfile(id: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw LocalProfileError.profileNotFound }
        activeProfileID = id
        profiles[index].lastUsedAt = Date()
        ensureProfileDirectory(for: id)
        persist()
    }

    func resetForUITesting() {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting"), let retained = profiles.first else { return }
        for profile in profiles where profile.id != retained.id {
            try? fileManager.removeItem(at: directoryURL(for: profile.id))
            removeScopedDefaults(for: profile.id)
        }
        profiles = [retained]
        activeProfileID = retained.id
        ensureProfileDirectory(for: retained.id)
        persist()
    }

    func directoryURL(for profileID: UUID) -> URL {
        documentsDirectory
            .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    func fileURL(for name: String, profileID: UUID? = nil) -> URL {
        directoryURL(for: profileID ?? activeProfileID).appendingPathComponent("\(name).json")
    }

    func assetURL(for name: String, profileID: UUID? = nil) -> URL {
        directoryURL(for: profileID ?? activeProfileID).appendingPathComponent(name)
    }

    static func defaultsKey(_ key: String, profileID: UUID? = nil) -> String {
        let id = (profileID ?? shared.currentProfileIDThreadSafe).uuidString
        return "profile.\(id).\(key)"
    }

    /// Like `defaultsKey(_:profileID:)`, but leaves `key` unscoped when
    /// `profileID` is nil instead of falling back to the active profile.
    /// Shared by the per-profile managers (`I18nManager`, `ThemeManager`,
    /// `AppearanceManager`) whose keys are unscoped until `configure(profileID:)`.
    static func scopedDefaultsKey(_ key: String, profileID: UUID?) -> String {
        guard let profileID else { return key }
        return defaultsKey(key, profileID: profileID)
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureProfileDirectory(for id: UUID) {
        try? fileManager.createDirectory(at: directoryURL(for: id), withIntermediateDirectories: true)
    }

    private func removeScopedDefaults(for profileID: UUID) {
        let prefix = "profile.\(profileID.uuidString)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func persist() {
        let registry = Registry(profiles: profiles, activeProfileID: activeProfileID)
        guard let data = try? JSONEncoder().encode(registry) else { return }
        try? data.write(to: documentsDirectory.appendingPathComponent(Self.registryFileName), options: [.atomic])
    }

    private struct Registry: Codable {
        let profiles: [LocalProfile]
        let activeProfileID: UUID
    }

    private static func loadRegistry(from directory: URL, decoder: JSONDecoder) -> Registry? {
        let url = directory.appendingPathComponent(Self.registryFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Registry.self, from: data)
    }

    private func migrateLegacyData(to profileID: UUID) {
        let names = ProfileDataFiles.all
        let target = directoryURL(for: profileID)
        for name in names {
            let source = documentsDirectory.appendingPathComponent("\(name).json")
            let destination = target.appendingPathComponent("\(name).json")
            if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        if let contents = try? fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil) {
            for source in contents where source.lastPathComponent.hasPrefix("cache_") || source.lastPathComponent.hasPrefix("oshi_wallpaper") {
                let destination = target.appendingPathComponent(source.lastPathComponent)
                if !fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.moveItem(at: source, to: destination)
                }
            }
        }
        let restoreManifest = documentsDirectory.appendingPathComponent("restore_manifest.json")
        if let manifestData = try? Data(contentsOf: restoreManifest),
           let manifest = try? JSONDecoder().decode(LegacyRestoreManifest.self, from: manifestData),
           manifest.stagingDirectory.hasPrefix(".oshireader-restore-"),
           !manifest.stagingDirectory.contains("/") {
            let stagingSource = documentsDirectory.appendingPathComponent(manifest.stagingDirectory, isDirectory: true)
            let stagingDestination = target.appendingPathComponent(manifest.stagingDirectory, isDirectory: true)
            if fileManager.fileExists(atPath: stagingSource.path), !fileManager.fileExists(atPath: stagingDestination.path) {
                try? fileManager.moveItem(at: stagingSource, to: stagingDestination)
            }
            let manifestDestination = target.appendingPathComponent("restore_manifest.json")
            if !fileManager.fileExists(atPath: manifestDestination.path) {
                try? fileManager.moveItem(at: restoreManifest, to: manifestDestination)
            }
        }
        let keys = [
            "wallpaper_url", "sources_order", "content_cache_generation", "local_data_revision",
            "refresh.recent_term_usage", "refresh_diagnostics.source_health_history",
            "refresh_diagnostics.last_started_at", "refresh_diagnostics.last_completed_at",
            "refresh_diagnostics.last_succeeded", "refresh_diagnostics.last_added_count",
            "refresh_diagnostics.last_was_partial", "background_refresh.last_completed_at",
            "background_refresh.last_completed_unit_id", "background_refresh.selection_cursor",
            "app_theme_mode", "app_color_style", "app_font_choice", "app_font_size_choice",
            "selected_lang", "auto_translate_reader"
        ]
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            defaults.set(value, forKey: Self.defaultsKey(key, profileID: profileID))
            defaults.removeObject(forKey: key)
        }
    }

    // A profile registry may have been created before appearance and language
    // settings became profile-scoped. Move those legacy values once instead
    // of silently falling back to defaults for existing installations.
    private func migrateLegacySettingsIfNeeded(to profileID: UUID) {
        let keys = [
            "app_theme_mode", "app_color_style", "app_font_choice",
            "app_font_size_choice", "selected_lang", "auto_translate_reader"
        ]
        for key in keys {
            let scopedKey = Self.defaultsKey(key, profileID: profileID)
            if defaults.object(forKey: scopedKey) == nil,
               let value = defaults.object(forKey: key) {
                defaults.set(value, forKey: scopedKey)
            }
            defaults.removeObject(forKey: key)
        }
    }

    private struct LegacyRestoreManifest: Decodable {
        let stagingDirectory: String
    }
}

extension UTType {
    static let oshiReaderProfile = UTType(exportedAs: "com.otterpia.oshireader.profile", conformingTo: .data)
}
