import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class I18nTranslationsTests: XCTestCase {

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

    func testTranslations() throws {
        let i18n = I18nManager.shared
        
        i18n.setLanguage("ja")
        XCTAssertEqual(i18n.lang, "ja")
        XCTAssertEqual(i18n.t("appTitle"), "推しリーダー")
        XCTAssertEqual(i18n.t("tabFeed"), "フィード")
        XCTAssertEqual(i18n.t("tabSaved"), "ブックマーク")
        XCTAssertEqual(i18n.t("sourceSelectionMenu"), "ソース選択")
        
        i18n.setLanguage("en")
        XCTAssertEqual(i18n.lang, "en")
        XCTAssertEqual(i18n.t("appTitle"), "oshireader")
        XCTAssertEqual(i18n.t("tabFeed"), "Feed")
        XCTAssertEqual(i18n.t("tabSaved"), "Saved")
        XCTAssertEqual(i18n.t("sourceSelectionMenu"), "Source Selection")
        
        i18n.setLanguage("zh-TW")
        XCTAssertEqual(i18n.lang, "zh-TW")
        XCTAssertEqual(i18n.t("appTitle"), "oshireader")
        XCTAssertEqual(i18n.t("tabFeed"), "動態")
        XCTAssertEqual(i18n.t("tabSaved"), "已儲存")
        XCTAssertEqual(i18n.t("sourceSelectionMenu"), "來源選擇")
        
        i18n.setLanguage("zh-CN")
        XCTAssertEqual(i18n.lang, "zh-CN")
        XCTAssertEqual(i18n.t("appTitle"), "oshireader")
        XCTAssertEqual(i18n.t("tabFeed"), "动态")
        XCTAssertEqual(i18n.t("tabSaved"), "已保存")
        XCTAssertEqual(i18n.t("sourceSelectionMenu"), "来源选择")
    }
}
