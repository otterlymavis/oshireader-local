import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class WatchTermsTests: XCTestCase {

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

    func testWatchTerms() throws {
        // 1. Save watch term
        let term = db.saveTerm(keyword: "Test Oshi", collectionMode: "media_only")
        
        XCTAssertEqual(db.terms.count, 1)
        XCTAssertEqual(db.terms.first?.keyword, "Test Oshi")
        XCTAssertEqual(db.terms.first?.collection_mode, "media_only")
        XCTAssertTrue(db.terms.first?.is_active ?? false)
        
        // 2. Update watch term
        db.updateTerm(id: term.id, isActive: false, collectionMode: "all_info")
        
        XCTAssertEqual(db.terms.first?.is_active, false)
        XCTAssertEqual(db.terms.first?.collection_mode, "all_info")

        db.updateTerm(id: term.id, notifyOnNew: true)
        XCTAssertEqual(db.terms.first?.notify_on_new, true)
        
        // 3. Delete watch term
        db.deleteTerm(id: term.id)
        XCTAssertEqual(db.terms.count, 0)
    }

    func testBackendTermIDPersistsAndCanBeCleared() throws {
        let term = WatchTerm(keyword: "Push Oshi", backendTermID: 42)
        let data = try JSONEncoder().encode(term)
        let decoded = try JSONDecoder().decode(WatchTerm.self, from: data)
        XCTAssertEqual(decoded.backendTermID, 42)

        db.terms = [decoded]
        db.updateTerm(id: decoded.id, backendTermID: .some(nil))
        XCTAssertNil(db.terms.first?.backendTermID)
    }
}
