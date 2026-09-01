import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class ThemeMetadataTests: XCTestCase {

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

    func testThemeMetadata() throws {
        let manager = ThemeManager.shared
        
        let youtubeMeta = manager.metadata(for: "youtube")
        XCTAssertEqual(youtubeMeta.name, "YouTube")
        XCTAssertEqual(youtubeMeta.icon, "📹")
        XCTAssertEqual(youtubeMeta.accent, Color.red)
        
        let tverMeta = manager.metadata(for: "tver")
        XCTAssertEqual(tverMeta.name, "TVer")
        XCTAssertEqual(tverMeta.icon, "📺")
        XCTAssertEqual(tverMeta.accent, Color.blue)

        let twitterAliasMeta = manager.metadata(for: "x")
        XCTAssertEqual(twitterAliasMeta.name, "X")
        XCTAssertEqual(twitterAliasMeta.icon, "𝕏")

        let modelPressAliasMeta = manager.metadata(for: "news:mdpr")
        XCTAssertEqual(modelPressAliasMeta.name, "ModelPress")
        XCTAssertEqual(modelPressAliasMeta.icon, "💅")

        let yahooAliasMeta = manager.metadata(for: " news:yahoo_ent ")
        XCTAssertEqual(yahooAliasMeta.name, "YahooNews")
        XCTAssertEqual(yahooAliasMeta.icon, "🇯🇵")
        
        // Name and icon come from PlatformRegistry, not a second copy in
        // ThemeManager, so they match what Settings shows.
        let newsMeta = manager.metadata(for: "news")
        XCTAssertEqual(newsMeta.name, PlatformRegistry.definition(for: "news")?.name)
        XCTAssertEqual(newsMeta.name, "General News")
        XCTAssertEqual(newsMeta.accent, Color.purple)

        // A registry platform with no explicit tint falls back to the primary.
        let customRegistryMeta = manager.metadata(for: "custom")
        XCTAssertEqual(customRegistryMeta.name, "Custom Feeds")
        XCTAssertEqual(customRegistryMeta.accent, manager.colors.primary)

        let customMeta = manager.metadata(for: "unknown_platform")
        XCTAssertEqual(customMeta.name, "Unknown_Platform")
        XCTAssertEqual(customMeta.icon, "🌐")
    }
}
