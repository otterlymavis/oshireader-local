import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class SavedBookmarksTests: XCTestCase {

    private var db: LocalDB!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = LocalDB.shared
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

    func testSavedBookmarks() throws {
        let item = FeedItem(
            id: "news:111", platform: "news", url: "https://url", title: "Bookmark test",
            content_text: nil, author: nil, thumbnail_url: nil, media_type: "article",
            published_at: "2026-06-02T12:00:00Z", watch_term_keyword: "", fetched_at: "",
            source: "google_news"
        )
        
        XCTAssertEqual(db.getSaved().count, 0)
        
        // Toggle saved (Add)
        let isSaved1 = db.toggleSaved(item: item)
        XCTAssertTrue(isSaved1)
        XCTAssertEqual(db.getSaved().count, 1)
        XCTAssertEqual(db.getSaved().first?.id, "news:111")
        XCTAssertEqual(db.getSaved().first?.source, "google_news")
        XCTAssertEqual(db.getSaved().first?.toFeedItem().source, "google_news")
        
        // Toggle saved (Remove)
        let isSaved2 = db.toggleSaved(item: item)
        XCTAssertFalse(isSaved2)
        XCTAssertEqual(db.getSaved().count, 0)
    }

    @MainActor
    func testLocalBackupRoundTrip() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(
            keyword: "Backup Oshi",
            collection_mode: "media_only",
            source_mode: .selected,
            selected_platforms: ["youtube", "news"],
            notify_on_new: true
        )
        let item = FeedItem(
            id: "news:backup",
            platform: "news",
            url: "https://example.com/backup",
            title: "Backup article",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: term.keyword,
            fetched_at: now,
            source: "google_news"
        )
        db.terms = [term]
        db.feedItems = [item]
        db.savedPages = [
            SavedPage(
                id: item.id,
                url: item.url,
                title: item.title,
                platform: item.platform,
                saved_at: now,
                source: item.source
            )
        ]
        db.customUrls = [CustomUrl(id: "custom:backup", url: "https://example.com/feed.xml", title: "Backup feed", added_at: now)]

        let data = try db.exportBackupData()
        db.terms.removeAll()
        db.feedItems.removeAll()
        db.savedPages.removeAll()
        db.customUrls.removeAll()
        try db.importBackupData(data)

        XCTAssertEqual(db.terms, [term])
        XCTAssertEqual(db.feedItems, [item])
        XCTAssertEqual(db.savedPages.count, 1)
        XCTAssertEqual(db.savedPages.first?.source, "google_news")
        XCTAssertEqual(db.customUrls.count, 1)
    }

    @MainActor
    func testEncryptedBackupRoundTripPreservesLocalData() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(id: "encrypted-term", keyword: "Encrypted Oshi", notify_on_new: true)
        let item = FeedItem(
            id: "news:encrypted", platform: "news", url: "https://example.com/encrypted",
            title: "Encrypted item", content_text: "Private local content", author: "Author",
            thumbnail_url: nil, media_type: "article", published_at: now,
            watch_term_keyword: term.keyword, fetched_at: now
        )
        db.terms = [term]
        db.feedItems = [item]
        db.customUrls = [CustomUrl(id: "custom:encrypted", url: "https://example.com/feed.xml", title: "Feed", added_at: now)]
        db.amebloBlogs = [AmebloBlog(url: "https://ameblo.jp/encrypted", title: "Blog", addedAt: now)!]

        let encrypted = try await db.exportEncryptedBackupData(password: "correct horse battery staple")
        XCTAssertNotEqual(encrypted, try db.exportBackupData())

        db.terms = []
        db.feedItems = []
        db.customUrls = []
        db.amebloBlogs = []
        try await db.importEncryptedBackupData(encrypted, password: "correct horse battery staple")

        XCTAssertEqual(db.terms.map(\.keyword), ["Encrypted Oshi"])
        XCTAssertEqual(db.feedItems.map(\.id), ["news:encrypted"])
        XCTAssertEqual(db.customUrls.map(\.id), ["custom:https://example.com/feed.xml"])
        XCTAssertEqual(db.amebloBlogs.map(\.amebaID), ["encrypted"])
    }

    @MainActor
    func testEncryptedBackupWrongPasswordLeavesCurrentDataUntouched() async throws {
        let term = db.saveTerm(keyword: "Protected Oshi")
        let encrypted = try await db.exportEncryptedBackupData(password: "correct horse battery staple")
        let beforeTerms = db.terms
        let beforeItems = db.feedItems

        do {
            try await db.importEncryptedBackupData(encrypted, password: "wrong password here")
            XCTFail("Expected authenticationFailed")
        } catch {
            XCTAssertEqual(error as? EncryptedBackupError, .authenticationFailed)
        }
        XCTAssertEqual(db.terms, beforeTerms)
        XCTAssertEqual(db.feedItems, beforeItems)
        XCTAssertEqual(db.terms.first?.id, term.id)
    }

    @MainActor
    func testEncryptedBackupTamperAndTruncationLeaveCurrentDataUntouched() async throws {
        _ = db.saveTerm(keyword: "Untouched Oshi")
        let encrypted = try await db.exportEncryptedBackupData(password: "correct horse battery staple")
        let before = db.terms

        var tampered = encrypted
        tampered[tampered.count - 1] ^= 1
        do {
            try await db.importEncryptedBackupData(tampered, password: "correct horse battery staple")
            XCTFail("Expected an error from tampered data")
        } catch {}
        do {
            try await db.importEncryptedBackupData(Data(encrypted.prefix(10)), password: "correct horse battery staple")
            XCTFail("Expected an error from truncated data")
        } catch {}
        XCTAssertEqual(db.terms, before)
    }

    func testEncryptedBackupRejectsUnsupportedAndInvalidEnvelopeVersions() throws {
        XCTAssertThrowsError(try EncryptedBackupCodec.decrypt(Data("not an encrypted backup".utf8), password: "correct horse battery staple")) { error in
            XCTAssertEqual(error as? EncryptedBackupError, .invalidEnvelope)
        }

        let encrypted = try EncryptedBackupCodec.encrypt(Data("payload".utf8), password: "correct horse battery staple")
        var unsupported = encrypted
        unsupported[EncryptedBackupCodec.magic.count] = 99
        XCTAssertThrowsError(try EncryptedBackupCodec.decrypt(unsupported, password: "correct horse battery staple")) { error in
            XCTAssertEqual(error as? EncryptedBackupError, .unsupportedVersion)
        }
    }

    func testEncryptedBackupUsesRandomSaltAndNonce() throws {
        let first = try EncryptedBackupCodec.encrypt(Data("same payload".utf8), password: "correct horse battery staple")
        let second = try EncryptedBackupCodec.encrypt(Data("same payload".utf8), password: "correct horse battery staple")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try EncryptedBackupCodec.decrypt(first, password: "correct horse battery staple"), Data("same payload".utf8))
    }

    func testEncryptedBackupPasswordValidation() {
        XCTAssertThrowsError(try EncryptedBackupCodec.validatePassword("short")) { error in
            XCTAssertEqual(error as? EncryptedBackupError, .invalidPassword)
        }
        XCTAssertNoThrow(try EncryptedBackupCodec.validatePassword(String(repeating: "🙂", count: 12)))
        XCTAssertThrowsError(try EncryptedBackupCodec.validatePassword(String(repeating: "a", count: 257)))
    }

    @MainActor
    func testProfilesIsolateDataAndProtectLastProfile() throws {
        db.clearAllData()
        let originalID = db.activeProfile.id
        for profile in db.profiles where profile.id != originalID {
            try? db.deleteProfile(id: profile.id)
        }
        let profile = try db.createProfile(name: "Profile \(UUID().uuidString)")

        try db.switchProfile(to: profile.id)
        XCTAssertTrue(db.terms.isEmpty)
        _ = db.saveTerm(keyword: "Second profile term")
        UserDefaults.standard.set("dark", forKey: LocalProfileStore.defaultsKey("app_theme_mode", profileID: profile.id))
        XCTAssertEqual(db.terms.count, 1)

        try db.switchProfile(to: originalID)
        XCTAssertTrue(db.terms.isEmpty)
        XCTAssertThrowsError(try db.renameProfile(id: originalID, name: profile.name)) { error in
            XCTAssertEqual(error as? LocalProfileError, .duplicateName)
        }

        try db.deleteProfile(id: profile.id)
        XCTAssertEqual(db.profiles.count, 1)
        XCTAssertNil(UserDefaults.standard.object(forKey: LocalProfileStore.defaultsKey("app_theme_mode", profileID: profile.id)))
        XCTAssertThrowsError(try db.deleteProfile(id: originalID)) { error in
            XCTAssertEqual(error as? LocalProfileError, .cannotDeleteLastProfile)
        }
    }

    @MainActor
    func testProfilesIsolateAppearanceAndLanguageSettings() throws {
        let originalID = db.activeProfile.id
        let theme = ThemeManager.shared
        let appearance = AppearanceManager.shared
        let i18n = I18nManager.shared
        let originalTheme = theme.mode
        let originalStyle = theme.style
        let originalFont = appearance.fontChoice
        let originalFontSize = appearance.fontSizeChoice
        let originalLanguage = i18n.lang
        let profile = try db.createProfile(name: "Settings \(UUID().uuidString)")

        theme.mode = .dark
        theme.style = .standard
        appearance.fontChoice = .comicSans
        appearance.fontSizeChoice = .extraLarge
        i18n.setLanguage("en")

        try db.switchProfile(to: profile.id)
        XCTAssertEqual(theme.mode, .light)
        XCTAssertEqual(theme.style, .colourful)
        XCTAssertEqual(appearance.fontChoice, .normal)
        XCTAssertEqual(appearance.fontSizeChoice, .normal)
        XCTAssertEqual(i18n.lang, "ja")

        try db.switchProfile(to: originalID)
        XCTAssertEqual(theme.mode, .dark)
        XCTAssertEqual(theme.style, .standard)
        XCTAssertEqual(appearance.fontChoice, .comicSans)
        XCTAssertEqual(appearance.fontSizeChoice, .extraLarge)
        XCTAssertEqual(i18n.lang, "en")

        theme.mode = originalTheme
        theme.style = originalStyle
        appearance.fontChoice = originalFont
        appearance.fontSizeChoice = originalFontSize
        i18n.setLanguage(originalLanguage)
        try db.deleteProfile(id: profile.id)
    }

    @MainActor
    func testProfileTransferCreatesNewProfileAndKeepsActiveProfile() throws {
        let originalID = db.activeProfile.id
        _ = db.saveTerm(keyword: "Transferred term")
        let data = try db.exportProfileTransferData()

        let imported = try db.importProfileTransferData(data)
        XCTAssertEqual(db.activeProfile.id, originalID)
        XCTAssertNotEqual(imported.id, originalID)
        XCTAssertTrue(db.profiles.contains(where: { $0.id == imported.id }))

        try db.switchProfile(to: imported.id)
        XCTAssertEqual(db.terms.map(\.keyword), ["Transferred term"])
        try db.switchProfile(to: originalID)
        try db.deleteProfile(id: imported.id)

        let repeatedImports = try (0..<3).map { _ in
            try db.importProfileTransferData(data)
        }
        XCTAssertEqual(Set(repeatedImports.map(\.name)).count, 3)
        for profile in repeatedImports {
            try db.deleteProfile(id: profile.id)
        }
    }

    @MainActor
    func testProfileTransferRejectsMalformedAndUnsupportedPackages() throws {
        XCTAssertThrowsError(try db.importProfileTransferData(Data("not a profile".utf8))) { error in
            XCTAssertEqual(error as? LocalProfileError, .invalidPackage)
        }

        let transfer = LocalProfileTransfer(profile: db.activeProfile, backup: LocalBackup(
            exportedAt: "",
            terms: [],
            feedItems: [],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: [],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: []
        ))
        let encoded = try JSONEncoder().encode(transfer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try db.importProfileTransferData(data)) { error in
            XCTAssertEqual(error as? LocalProfileError, .unsupportedPackageVersion)
        }

        object["version"] = 0
        let legacyVersionData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try db.importProfileTransferData(legacyVersionData)) { error in
            XCTAssertEqual(error as? LocalProfileError, .unsupportedPackageVersion)
        }
    }

    @MainActor
    func testBackupImportNormalizesAliasesToIngestionLimit() throws {
        let term = WatchTerm(
            keyword: "Primary Oshi",
            aliases: [" Alias Oshi ", "Primary Oshi", "Alias Oshi", "Alias 2", "Alias 3", "Alias 4", "Alias 5"]
        )
        let backup = LocalBackup(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            terms: [term],
            feedItems: [],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: ["news"],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: []
        )
        let data = try JSONEncoder().encode(backup)

        try db.importBackupData(data)

        XCTAssertEqual(db.terms.first?.aliases, ["Alias Oshi", "Alias 2", "Alias 3", "Alias 4", "Alias 5"])
        XCTAssertEqual(IngestionService.searchKeywords(for: db.terms[0]).count, 6)
    }

    @MainActor
    func testBackupImportDropsUnknownPlatformIDs() throws {
        let backup = LocalBackup(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            terms: [],
            feedItems: [],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: ["news", "unknown", " youtube ", "news", "custom", "backend-only"],
            wallpaper: nil,
            sourcesOrder: ["custom", "unknown", "news", "custom", " youtube "],
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: []
        )
        let data = try JSONEncoder().encode(backup)

        try db.importBackupData(data)

        XCTAssertEqual(db.subscribedPlatforms, ["news", "youtube", "custom"])
        XCTAssertEqual(db.sourcesOrder, ["custom", "news", "youtube"])
    }

    @MainActor
    func testBackupImportNormalizesCustomUrlsAndDropsInvalidEntries() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let backup = LocalBackup(
            exportedAt: now,
            terms: [],
            feedItems: [
                FeedItem(
                    id: "legacy:bad-script",
                    platform: "custom",
                    url: "javascript://example.com/feed",
                    title: "Bad",
                    content_text: nil,
                    author: nil,
                    thumbnail_url: nil,
                    media_type: "article",
                    published_at: now,
                    watch_term_keyword: "",
                    fetched_at: now
                ),
                FeedItem(
                    id: "legacy:host-port",
                    platform: "custom",
                    url: "localhost:9090/feed",
                    title: "Local cached",
                    content_text: nil,
                    author: nil,
                    thumbnail_url: nil,
                    media_type: "article",
                    published_at: now,
                    watch_term_keyword: "",
                    fetched_at: now
                ),
                FeedItem(
                    id: "legacy:tracked-dup",
                    platform: "custom",
                    url: "https://example.com/feed?b=2&a=1",
                    title: "Duplicate cached",
                    content_text: nil,
                    author: nil,
                    thumbnail_url: nil,
                    media_type: "article",
                    published_at: now,
                    watch_term_keyword: "",
                    fetched_at: now
                )
            ],
            savedPages: [
                SavedPage(
                    id: "legacy:bad-script",
                    url: "javascript://example.com/feed",
                    title: "Bad saved",
                    platform: "custom",
                    saved_at: now
                ),
                SavedPage(
                    id: "legacy:host-port",
                    url: "localhost:9090/feed",
                    title: "Local saved",
                    platform: "CUSTOM",
                    saved_at: now
                ),
                SavedPage(
                    id: "legacy:tracked-saved",
                    url: "https://www.example.com/feed/?b=2&a=1&utm_source=saved",
                    title: "Tracked saved",
                    platform: "custom",
                    saved_at: now
                ),
                SavedPage(
                    id: "legacy:tracked-dup",
                    url: "https://example.com/feed?b=2&a=1",
                    title: "Duplicate saved",
                    platform: "custom",
                    saved_at: now
                )
            ],
            customUrls: [
                CustomUrl(id: "legacy:bad-script", url: "javascript://example.com/feed", title: "Bad", added_at: now),
                CustomUrl(id: "legacy:host-port", url: "localhost:9090/feed", title: " Local Feed ", added_at: now),
                CustomUrl(id: "legacy:tracked", url: "https://www.example.com/feed/?utm_source=backup&b=2&a=1#frag", title: " ", added_at: now),
                CustomUrl(id: "legacy:tracked-dup", url: "https://example.com/feed?b=2&a=1", title: "Duplicate", added_at: now),
            ],
            subscribedPlatforms: ["custom"],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: [
                "legacy:bad-script::",
                "legacy:host-port::",
                "legacy:tracked-dup::",
                "youtube:v1::Aiko"
            ]
        )

        try db.importBackupData(JSONEncoder().encode(backup))

        XCTAssertEqual(db.customUrls.map(\.url), [
            "https://localhost:9090/feed",
            "https://example.com/feed?a=1&b=2",
        ])
        XCTAssertEqual(db.customUrls.map(\.title), ["Local Feed", nil])
        XCTAssertTrue(db.customUrls.allSatisfy { $0.id.hasPrefix("custom:") })
        XCTAssertEqual(Set(db.feedItems.map(\.id)), Set(db.customUrls.map(\.id)))
        XCTAssertEqual(Set(db.feedItems.map(\.url)), Set(db.customUrls.map(\.url)))
        XCTAssertEqual(db.savedPages.count, 2)
        XCTAssertEqual(Set(db.savedPages.map(\.id)), Set(db.customUrls.map(\.id)))
        XCTAssertEqual(Set(db.savedPages.map(\.url)), Set(db.customUrls.map(\.url)))
        XCTAssertEqual(db.hiddenItems, Set([
            "\(db.customUrls[0].id)::",
            "\(db.customUrls[1].id)::",
            "youtube:v1::Aiko"
        ]))
    }

    @MainActor
    func testProfileLoadNormalizesPersistedCustomUrlsAndCachedRows() throws {
        let originalProfileID = db.activeProfile.id
        let profile = try db.createProfile(name: "Legacy custom load \(UUID().uuidString)")
        defer {
            try? db.switchProfile(to: originalProfileID)
            try? db.deleteProfile(id: profile.id)
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let legacyCustomUrls = [
            CustomUrl(id: "legacy:bad-script", url: "javascript://example.com/feed", title: "Bad", added_at: now),
            CustomUrl(id: "legacy:host-port", url: "localhost:9090/feed", title: " Local Feed ", added_at: now),
            CustomUrl(id: "legacy:tracked", url: "https://www.example.com/feed/?utm_source=load&b=2&a=1#frag", title: "Tracked", added_at: now),
            CustomUrl(id: "legacy:tracked-dup", url: "https://example.com/feed?b=2&a=1", title: "Duplicate", added_at: now),
        ]
        let legacyFeedItems = [
            FeedItem(
                id: "legacy:host-port",
                platform: "custom",
                url: "localhost:9090/feed",
                title: "Local cached",
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: now,
                watch_term_keyword: "",
                fetched_at: now
            ),
            FeedItem(
                id: "legacy:tracked-raw",
                platform: "CUSTOM",
                url: "https://www.example.com/feed/?b=2&a=1&utm_source=cache",
                title: "Tracked cached",
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: now,
                watch_term_keyword: "",
                fetched_at: now
            ),
            FeedItem(
                id: "legacy:bad-script",
                platform: "custom",
                url: "javascript://example.com/feed",
                title: "Bad cached",
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: now,
                watch_term_keyword: "",
                fetched_at: now
            )
        ]
        let hiddenItems = [
            "legacy:bad-script::",
            "legacy:host-port::",
            "legacy:tracked-dup::",
            "youtube:v1::Aiko"
        ]
        let legacySavedPages = [
            SavedPage(
                id: "legacy:bad-script",
                url: "javascript://example.com/feed",
                title: "Bad saved",
                platform: "custom",
                saved_at: now
            ),
            SavedPage(
                id: "legacy:host-port",
                url: "localhost:9090/feed",
                title: "Local saved",
                platform: "custom",
                saved_at: now
            ),
            SavedPage(
                id: "legacy:tracked-saved",
                url: "https://www.example.com/feed/?b=2&a=1&utm_source=saved",
                title: "Tracked saved",
                platform: "CUSTOM",
                saved_at: now
            ),
            SavedPage(
                id: "legacy:tracked-dup",
                url: "https://example.com/feed?b=2&a=1",
                title: "Duplicate saved",
                platform: "custom",
                saved_at: now
            )
        ]
        let encoder = JSONEncoder()
        try encoder.encode(legacyCustomUrls).write(to: LocalProfileStore.shared.fileURL(for: "custom_urls", profileID: profile.id), options: [.atomic])
        try encoder.encode(legacyFeedItems).write(to: LocalProfileStore.shared.fileURL(for: "feed_items", profileID: profile.id), options: [.atomic])
        try encoder.encode(legacySavedPages).write(to: LocalProfileStore.shared.fileURL(for: "saved_pages", profileID: profile.id), options: [.atomic])
        try encoder.encode(hiddenItems).write(to: LocalProfileStore.shared.fileURL(for: "hidden_items", profileID: profile.id), options: [.atomic])

        try db.switchProfile(to: profile.id)

        XCTAssertEqual(db.customUrls.map(\.url), [
            "https://localhost:9090/feed",
            "https://example.com/feed?a=1&b=2",
        ])
        XCTAssertEqual(Set(db.feedItems.map(\.id)), Set(db.customUrls.map(\.id)))
        XCTAssertEqual(Set(db.feedItems.map(\.url)), Set(db.customUrls.map(\.url)))
        XCTAssertEqual(db.savedPages.count, 2)
        XCTAssertEqual(Set(db.savedPages.map(\.id)), Set(db.customUrls.map(\.id)))
        XCTAssertEqual(Set(db.savedPages.map(\.url)), Set(db.customUrls.map(\.url)))
        XCTAssertEqual(db.hiddenItems, Set([
            "\(db.customUrls[0].id)::",
            "\(db.customUrls[1].id)::",
            "youtube:v1::Aiko"
        ]))
    }

    @MainActor
    func testProfileLoadDropsHiddenItemsForPrunedLegacyYouTubeRows() throws {
        let originalProfileID = db.activeProfile.id
        let profile = try db.createProfile(name: "Legacy youtube load \(UUID().uuidString)")
        defer {
            try? db.switchProfile(to: originalProfileID)
            try? db.deleteProfile(id: profile.id)
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let legacyUnmarked = FeedItem(
            id: "load-youtube:unmarked",
            platform: "youtube",
            url: "https://news.google.com/articles/load-unmarked",
            title: "Legacy unmarked",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )
        let legacyGoogleNews = FeedItem(
            id: "load-youtube:google",
            platform: "youtube",
            url: "https://news.google.com/articles/load-google",
            title: "Legacy Google News",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "google_news"
        )
        let currentScrape = FeedItem(
            id: "load-youtube:current",
            platform: "youtube",
            url: "https://youtube.com/watch?v=current",
            title: "Current scrape",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "youtube_scrape"
        )
        let hiddenItems = [
            "\(legacyUnmarked.id)::\(legacyUnmarked.watch_term_keyword)",
            "\(legacyGoogleNews.id)::\(legacyGoogleNews.watch_term_keyword)",
            "\(currentScrape.id)::\(currentScrape.watch_term_keyword)"
        ]
        let encoder = JSONEncoder()
        try encoder.encode([legacyUnmarked, legacyGoogleNews, currentScrape]).write(to: LocalProfileStore.shared.fileURL(for: "feed_items", profileID: profile.id), options: [.atomic])
        try encoder.encode(hiddenItems).write(to: LocalProfileStore.shared.fileURL(for: "hidden_items", profileID: profile.id), options: [.atomic])

        try db.switchProfile(to: profile.id)

        XCTAssertEqual(db.feedItems.map(\.id), [currentScrape.id])
        XCTAssertEqual(db.hiddenItems, ["\(currentScrape.id)::\(currentScrape.watch_term_keyword)"])
    }

    @MainActor
    func testBackupImportUsesParsedDateCapAndRetainsDiscussionItems() throws {
        let formatter = ISO8601DateFormatter()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let newsItems = (0..<600).map { index in
            FeedItem(
                id: "backup-news:\(index)",
                platform: "news",
                url: "https://example.com/backup/news/\(index)",
                title: "Backup news \(index)",
                content_text: "Aiko news",
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: formatter.string(from: baseDate.addingTimeInterval(TimeInterval(600 - index))),
                watch_term_keyword: "Aiko",
                fetched_at: formatter.string(from: baseDate)
            )
        }
        let fiveChItems = (0..<30).map { index in
            FeedItem(
                id: "backup-5ch:\(index)",
                platform: "5ch",
                url: "https://example.5ch.net/test/read.cgi/thread/\(index)",
                title: "Backup thread \(index)",
                content_text: "Aiko thread",
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: formatter.string(from: baseDate.addingTimeInterval(TimeInterval(index))),
                watch_term_keyword: "Aiko",
                fetched_at: formatter.string(from: baseDate)
            )
        }
        let newerUTC = FeedItem(
            id: "backup-youtube:newer",
            platform: "youtube",
            url: "https://yt.example/backup/newer",
            title: "Backup newer",
            content_text: "Aiko",
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: "2024-06-01T03:00:00Z",
            watch_term_keyword: "Aiko",
            fetched_at: "2024-06-01T03:00:00Z",
            source: "youtube_scrape"
        )
        let olderOffset = FeedItem(
            id: "backup-youtube:older",
            platform: "youtube",
            url: "https://yt.example/backup/older",
            title: "Backup older",
            content_text: "Aiko",
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: "2024-06-01T10:00:00+09:00",
            watch_term_keyword: "Aiko",
            fetched_at: "2024-06-01T10:00:00+09:00",
            source: "youtube_scrape"
        )
        let backup = LocalBackup(
            exportedAt: formatter.string(from: Date()),
            terms: [],
            feedItems: newsItems + fiveChItems + [olderOffset, newerUTC],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: ["news", "5ch", "youtube"],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: []
        )

        try db.importBackupData(JSONEncoder().encode(backup))

        XCTAssertEqual(db.feedItems.count, 600)
        XCTAssertEqual(db.feedItems.filter { $0.platform == "5ch" }.count, 25)
        XCTAssertLessThan(
            try XCTUnwrap(db.feedItems.firstIndex { $0.id == newerUTC.id }),
            try XCTUnwrap(db.feedItems.firstIndex { $0.id == olderOffset.id })
        )
    }

    @MainActor
    func testBackupImportPrunesLegacyYouTubeFallbackRows() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let legacyUnmarked = FeedItem(
            id: "backup-youtube:legacy-unmarked",
            platform: "youtube",
            url: "https://youtube.com/watch?v=legacy-unmarked",
            title: "Legacy unmarked",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )
        let legacyGoogleNews = FeedItem(
            id: "backup-youtube:legacy-google",
            platform: "youtube",
            url: "https://news.google.com/articles/legacy-google",
            title: "Legacy Google News",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "google_news"
        )
        let currentScrape = FeedItem(
            id: "backup-youtube:current",
            platform: "youtube",
            url: "https://youtube.com/watch?v=current",
            title: "Current scrape",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "youtube_scrape"
        )
        let backup = LocalBackup(
            exportedAt: now,
            terms: [],
            feedItems: [legacyUnmarked, legacyGoogleNews, currentScrape],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: ["youtube"],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: [
                "\(legacyUnmarked.id)::\(legacyUnmarked.watch_term_keyword)",
                "\(legacyGoogleNews.id)::\(legacyGoogleNews.watch_term_keyword)",
                "\(currentScrape.id)::\(currentScrape.watch_term_keyword)"
            ]
        )

        try db.importBackupData(JSONEncoder().encode(backup))

        XCTAssertEqual(db.feedItems.map(\.id), [currentScrape.id])
        XCTAssertEqual(db.hiddenItems, ["\(currentScrape.id)::\(currentScrape.watch_term_keyword)"])
    }

    @MainActor
    func testNotificationPayloadRecoversEvictedItem() throws {
        let item = FeedItem(
            id: "news:evicted",
            platform: "news",
            url: "https://example.com/evicted",
            title: "Evicted article",
            content_text: "Cached in the notification payload.",
            author: "Desk",
            thumbnail_url: nil,
            media_type: "article",
            published_at: "2026-07-27T00:00:00Z",
            watch_term_keyword: "Evicted Oshi",
            fetched_at: "2026-07-27T00:00:00Z",
            source: "google_news"
        )
        db.feedItems = []
        NotificationNavigationManager.shared.open(userInfo: [
            "feed_item_id": item.id,
            "watch_term_keyword": item.watch_term_keyword,
            "platform": item.platform,
            "url": item.url,
            "title": item.title as Any,
            "content_text": item.content_text as Any,
            "author": item.author as Any,
            "media_type": item.media_type,
            "published_at": item.published_at,
            "fetched_at": item.fetched_at,
            "source": item.source as Any
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem, item)
        NotificationNavigationManager.shared.selectedItem = nil
    }

    @MainActor
    func testSilentPushPreviewMergesOnceWithoutASecondFeedItem() {
        let now = ISO8601DateFormatter().string(from: Date())
        let payload: [AnyHashable: Any] = [
            "item_id": "news:silent-preview",
            "item_url": "https://example.com/silent-preview",
            "watch_term_keyword": "Preview Oshi",
            "preview_item": [
                "id": "news:silent-preview",
                "url": "https://example.com/silent-preview",
                "platform": "news",
                "title": "Silent preview",
                "media_type": "article",
                "published_at": now,
                "source": "backend_feed",
            ],
        ]

        XCTAssertTrue(NotificationNavigationManager.shared.mergeNotificationItem(userInfo: payload))
        XCTAssertTrue(NotificationNavigationManager.shared.mergeNotificationItem(userInfo: payload))
        XCTAssertEqual(db.feedItems.filter { $0.id == "news:silent-preview" }.count, 1)
        XCTAssertEqual(db.feedItems.first { $0.id == "news:silent-preview" }?.source, "backend_feed")
    }

    @MainActor
    func testNotificationPayloadUsesCachedItemForMissingFields() throws {
        let cached = FeedItem(
            id: "youtube:abc123def45",
            platform: "youtube",
            url: "https://www.youtube.com/watch?v=abc123def45",
            title: "Cached title",
            content_text: "Cached description",
            author: "Cached channel",
            thumbnail_url: "https://i.ytimg.com/vi/abc123def45/hqdefault.jpg",
            media_type: "video",
            published_at: "2026-07-27T00:00:00Z",
            watch_term_keyword: "Cached Oshi",
            fetched_at: "2026-07-27T00:01:00Z",
            source: "youtube_scrape"
        )
        db.feedItems = [cached]

        NotificationNavigationManager.shared.open(userInfo: [
            "feed_item_id": cached.id,
            "url": cached.url
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem, cached)
        NotificationNavigationManager.shared.selectedItem = nil

        let twitterCached = FeedItem(
            id: "twitter:legacy-platform",
            platform: "twitter",
            url: "https://x.com/example/status/1",
            title: "Cached X title",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: "2026-07-27T00:00:00Z",
            watch_term_keyword: "Cached Oshi",
            fetched_at: "2026-07-27T00:01:00Z",
            source: "twitter_api"
        )
        db.feedItems = [twitterCached]

        NotificationNavigationManager.shared.open(userInfo: [
            "feed_item_id": twitterCached.id,
            "watch_term_keyword": twitterCached.watch_term_keyword,
            "platform": "x",
            "url": twitterCached.url
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem?.platform, "twitter")
        NotificationNavigationManager.shared.selectedItem = nil

        db.feedItems = []
        NotificationNavigationManager.shared.open(userInfo: [
            "feed_item_id": "x:evicted-status",
            "url": "https://x.com/example/status/2",
            "title": "Evicted X post",
            "media_type": "text",
            "published_at": "2026-07-27T00:00:00Z",
            "fetched_at": "2026-07-27T00:01:00Z"
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem?.platform, "twitter")
        NotificationNavigationManager.shared.selectedItem = nil
    }
}
