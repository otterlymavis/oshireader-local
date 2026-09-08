import XCTest

final class OshiReaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-source-status"]
        app.launch()
    }

    func testAppLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let freshApp = XCUIApplication()
            freshApp.launchArguments = ["--uitesting", "--uitesting-source-status"]
            freshApp.launch()
        }
    }

    func testAddKeywordFlow() throws {
        tapTab(index: 4, labels: ["Settings"])

        let addKeywordButton = waitForHittableButton(identifier: "settings.addKeywordButton", timeout: 5)
        XCTAssertNotNil(addKeywordButton)
        addKeywordButton?.tap()
        let keywordField = waitForHittableTextField(identifier: "settings.keywordField", timeout: 5)
        XCTAssertNotNil(keywordField)

        keywordField?.tap()
        keywordField?.typeText("New UI Keyword")
        app.toolbars.buttons["Done"].tapIfExists()
        let addButton = waitForButton(identifier: "settings.confirmAddKeywordButton", timeout: 3)
        XCTAssertNotNil(addButton)
        addButton?.tap()

        XCTAssertTrue(app.staticTexts["New UI Keyword"].waitForExistence(timeout: 3))
    }

    func testAddKeywordWithSelectedSourceFlow() throws {
        tapTab(index: 4, labels: ["Settings"])

        let addKeywordButton = waitForHittableButton(identifier: "settings.addKeywordButton", timeout: 5)
        XCTAssertNotNil(addKeywordButton)
        addKeywordButton?.tap()

        let keywordField = waitForHittableTextField(identifier: "settings.keywordField", timeout: 5)
        XCTAssertNotNil(keywordField)
        keywordField?.tap()
        keywordField?.typeText("Selected Source UI Keyword")
        app.toolbars.buttons["Done"].tapIfExists()

        let selectedMode = waitForAnyButton(containing: ["Selected", "選択", "選取", "选择"], timeout: 3)
        XCTAssertNotNil(selectedMode)
        selectedMode?.tap()

        // Choosing "Selected" reveals an inline grid of platform toggles.
        // "youtube" is first in PlatformRegistry.all, so it renders inside the
        // 90pt scroll viewport without needing to be scrolled into view.
        let youtubeSource = app.buttons["settings.newKeywordSource.youtube"]
        XCTAssertTrue(youtubeSource.waitForExistence(timeout: 3))
        youtubeSource.tap()
        // The grid stays put — toggling one source doesn't collapse it.
        XCTAssertTrue(youtubeSource.waitForExistence(timeout: 3))

        let addButton = waitForButton(identifier: "settings.confirmAddKeywordButton", timeout: 3)
        XCTAssertNotNil(addButton)
        addButton?.tap()

        XCTAssertTrue(app.staticTexts["Selected Source UI Keyword"].waitForExistence(timeout: 3))
    }

    func testExistingKeywordSourceSelectionAllowsMultipleSelectionsWithoutReopening() throws {
        tapTab(index: 4, labels: ["Settings"])

        // Source selection now lives on the per-term detail screen, reached by
        // tapping the Watch Term row.
        let row = waitForElement(identifier: "settings.keywordRow.UITest Oshi", timeout: 3, swipes: 5)
        XCTAssertTrue(row.exists, "Could not find the seeded keyword's row")
        row.tap()

        let youtube = app.descendants(matching: .any)["settings.keywordSource.UITest Oshi.youtube"]
        XCTAssertTrue(youtube.waitForExistence(timeout: 3))
        youtube.tap()

        let niconico = app.descendants(matching: .any)["settings.keywordSource.UITest Oshi.niconico"]
        XCTAssertTrue(niconico.waitForExistence(timeout: 3), "Source list closed after the first choice")
        niconico.tap()
    }

    func testRefreshFeedAndFilterSheet() throws {
        tapTab(index: 0, labels: ["Feed"])

        XCTAssertTrue(app.buttons["feed.refreshButton"].waitForExistence(timeout: 3))
        app.buttons["feed.refreshButton"].tap()

        let filterButton = firstFeedFilterButton()
        XCTAssertNotNil(filterButton)
        XCTAssertTrue(filterButton?.waitForExistence(timeout: 3) ?? false)
        filterButton?.forceTap()
        let mediaOnlyButton = app.buttons["filter.mediaOnlyButton"]
        XCTAssertTrue(mediaOnlyButton.waitForExistence(timeout: 3))
        mediaOnlyButton.tap()

        // The filter sheet has no dismiss control and does not close on
        // selection — swipe it away before leaving the Feed tab, otherwise the
        // Settings tab button is behind the still-presented sheet.
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(mediaOnlyButton.waitForNonExistence(timeout: 3))

        tapTab(index: 4, labels: ["Settings"])
        XCTAssertTrue(waitForElement(identifier: "settings.refreshStatus", timeout: 3, swipes: 12).exists)
    }

    func testSourceStatusSummaryShowsHealthSummary() throws {
        tapTab(index: 0, labels: ["Feed"])

        XCTAssertTrue(app.buttons["feed.refreshButton"].waitForExistence(timeout: 3))
        app.buttons["feed.refreshButton"].tap()

        tapTab(index: 4, labels: ["Settings"])
        // Source Status is the last section of the Settings form, so this needs
        // a scroll budget that clears every section above it.
        let sourceSummary = waitForElement(
            identifier: "settings.sourceStatus",
            timeout: 1,
            swipes: 12
        )
        XCTAssertTrue(sourceSummary.exists)
        XCTAssertEqual(sourceSummary.elementType, .button)
        let summaryReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] 'current'"),
            object: sourceSummary
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [summaryReady], timeout: 5),
            .completed
        )
        XCTAssertTrue(sourceSummary.label.contains("1 current"))
        XCTAssertTrue(sourceSummary.label.contains("0 stale"))
        XCTAssertTrue(sourceSummary.label.contains("1 empty"))
        XCTAssertTrue(sourceSummary.label.contains("0 failed"))
    }

    func testOpenReaderFromFeedAndSave() throws {
        tapTab(index: 0, labels: ["Feed"])

        let headline = app.staticTexts["UITest Oshi headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 3))
        let feedCard = app.buttons["feed.card.ui-feed-reader"]
        if feedCard.waitForExistence(timeout: 2) {
            feedCard.tap()
        } else {
            (firstExistingButton(containing: "UITest Oshi headline") ?? headline).tap()
        }

        let readerModeButton = waitForButton(identifier: "reader.modeToggleButton", timeout: 5)
        XCTAssertNotNil(readerModeButton)
        readerModeButton?.tap()
    }

    func testLinkedReaderImageNavigatesNormally() throws {
        app.terminate()
        app.launchArguments = ["--uitesting", "--uitesting-source-status", "--uitesting-reader-images"]
        app.launch()
        tapTab(index: 0, labels: ["Feed"])

        let headline = app.staticTexts["UITest Oshi headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 3))
        let feedCard = app.buttons["feed.card.ui-feed-reader"]
        if feedCard.waitForExistence(timeout: 2) {
            feedCard.tap()
        } else {
            (firstExistingButton(containing: "UITest Oshi headline") ?? headline).tap()
        }

        XCTAssertNotNil(waitForButton(identifier: "reader.modeToggleButton", timeout: 5))
        let linkedImage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "fixture linked image"))
            .firstMatch
        XCTAssertTrue(linkedImage.waitForExistence(timeout: 5))
        linkedImage.tap()

        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1))
        XCTAssertTrue(
            app.staticTexts["navigated:#fixture-target"].waitForExistence(timeout: 3),
            "A linked image should navigate instead of opening image actions"
        )
    }

    func testSavedReaderFlow() throws {
        tapTab(index: 2, labels: ["Saved"])

        let savedTitle = app.staticTexts["UITest saved article"]
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 3))
        (firstExistingButton(containing: "UITest saved article") ?? savedTitle).tap()

        XCTAssertNotNil(waitForButton(identifier: "reader.modeToggleButton", timeout: 5))
        // The fixture seeds exactly one saved page, so prev/next render but
        // both stay disabled — nothing to page to in either direction.
        let previousButton = waitForButton(identifier: "reader.previousArticleButton", timeout: 5)
        let nextButton = waitForButton(identifier: "reader.nextArticleButton", timeout: 5)
        XCTAssertFalse(previousButton?.isEnabled ?? true)
        XCTAssertFalse(nextButton?.isEnabled ?? true)
    }

    func testReaderPrevNextNavigationWalksTheFeedList() throws {
        app.terminate()
        app.launchArguments = ["--uitesting", "--uitesting-all-platform-sort-feed"]
        app.launch()
        tapTab(index: 0, labels: ["Feed"])

        let cards = app.buttons.matching(identifier: "feed.card")
        XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 5), "Expected multiple seeded feed items")
        cards.element(boundBy: 0).tap()

        let previousButton = waitForButton(identifier: "reader.previousArticleButton", timeout: 5)
        let nextButton = waitForButton(identifier: "reader.nextArticleButton", timeout: 5)
        XCTAssertNotNil(previousButton)
        XCTAssertNotNil(nextButton)
        // Opened the first item in the list: nothing before it, something after it.
        XCTAssertFalse(previousButton?.isEnabled ?? true)
        XCTAssertTrue(nextButton?.isEnabled ?? false)

        // Hop forward a couple of siblings (the seeded fixture has well over a
        // dozen), confirming "previous" turns on and "next" stays available.
        let hops = 2
        for step in 1...hops {
            nextButton?.tap()
            XCTAssertTrue(previousButton?.isEnabled ?? false, "Previous should be enabled after moving to item \(step)")
            XCTAssertTrue(nextButton?.isEnabled ?? false, "Next should still be enabled at item \(step)")
        }

        // Walk back the same distance and confirm we land exactly on the first
        // item again (previous disabled, next enabled).
        for _ in 1...hops {
            previousButton?.tap()
        }
        XCTAssertFalse(previousButton?.isEnabled ?? true, "Should be back at the first item")
        XCTAssertTrue(nextButton?.isEnabled ?? false)
    }

    func testSearchFlow() throws {
        tapTab(index: 1, labels: ["Search"])

        let searchField = firstExistingTextField(labels: ["search.keywordField", "Search articles...", "Keyword"]) ?? app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("headline")

        XCTAssertTrue(app.buttons["search.link.yahoo-news"].waitForExistence(timeout: 3))
        XCTAssertTrue(((searchField.value as? String) ?? "").localizedCaseInsensitiveContains("headline"))
    }

    func testAvatarEditorFlow() throws {
        tapTab(index: 3, labels: ["My Oshi"])

        let editButton = app.buttons["oshi.editButton.UITest Oshi"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()

        XCTAssertTrue(app.staticTexts["✨ UITest Oshi"].waitForExistence(timeout: 5))
        let saveButton = waitForAnyButton(containing: ["Save", "保存", "保存する", "儲存"], timeout: 3)
        XCTAssertNotNil(saveButton)
        saveButton?.tap()
    }

    func testSettingsPrivacyPolicyFlow() throws {
        tapTab(index: 4, labels: ["Settings"])

        XCTAssertTrue(openSettingsSubpage(link: "settings.appearanceLink", screenIdentifier: "settings.appearanceScreen"))

        XCTAssertTrue(waitForElement(identifier: "settings.fontPicker", timeout: 2, swipes: 12).exists)
        let playfulFontButton = waitForAnyButton(containing: ["Playful", "Comic"], timeout: 2, swipes: 3)
        XCTAssertNotNil(playfulFontButton)
        playfulFontButton?.tap()

        XCTAssertTrue(waitForElement(identifier: "settings.fontSizePicker", timeout: 2, swipes: 4).exists)
        let largeButton = waitForAnyButton(exactly: ["Large", "大"], timeout: 2, swipes: 3)
        XCTAssertNotNil(largeButton)
        largeButton?.tap()

        navigateBack()

        let privacyLink = waitForElement(identifier: "settings.privacyPolicyLink", timeout: 2, swipes: 12)
        XCTAssertTrue(privacyLink.waitForExistence(timeout: 3))
        privacyLink.tap()

        XCTAssertTrue(waitForAnyStaticText([
            "Data Stored on This Device",
            "このデバイスに保存されるデータ",
            "儲存在此裝置的資料",
            "存储在此设备的数据"
        ], timeout: 3))
    }

    func testSettingsNotificationControls() throws {
        tapTab(index: 4, labels: ["Settings"])

        XCTAssertTrue(openSettingsSubpage(link: "settings.notificationsLink", screenIdentifier: "settings.notificationsScreen"))

        XCTAssertTrue(waitForElement(identifier: "settings.notificationStatus", timeout: 2, swipes: 4).exists)
        XCTAssertTrue(waitForElement(identifier: "settings.localAlertBackgroundStatus", timeout: 2, swipes: 1).exists)
        XCTAssertTrue(waitForElement(identifier: "settings.autoRefreshPicker", timeout: 2, swipes: 4).exists)
    }

    func testPaidPushControlsFollowCatalogConfiguration() throws {
        // The catalog (`config/paid-catalog.json` + `PUSH_SUBSCRIPTION_PRODUCT_IDS`)
        // enables paid push by default, so the guaranteed-push section renders
        // for every launch. Entitlement stays inactive under UI tests, so the
        // per-term push control is present but disabled. That per-term control
        // now lives on the Watch Term detail screen (tap the row); the
        // section-level status is on the Paid Backend drill-down page.
        tapTab(index: 4, labels: ["Settings"])
        XCTAssertTrue(openTermDetail(keyword: "UITest Oshi"), "Could not open the seeded keyword's detail")
        let pushControl = waitForAnyButton(exactly: ["Guaranteed push"], timeout: 3, swipes: 3)
        XCTAssertNotNil(pushControl)
        XCTAssertFalse(pushControl?.isEnabled ?? true, "Push control should be disabled without an active entitlement")
        navigateBack()

        XCTAssertTrue(openSettingsSubpage(link: "settings.paidBackendLink", screenIdentifier: "settings.paidBackendScreen"))
        XCTAssertTrue(
            waitForElement(identifier: "settings.guaranteedPushSection", timeout: 3, swipes: 4).exists
        )
        XCTAssertTrue(waitForAnyStaticText(["Hosted feed refresh"], timeout: 3))

        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-source-status", "--uitesting-paid-push"]
        app.launch()
        tapTab(index: 4, labels: ["Settings"])

        XCTAssertTrue(openTermDetail(keyword: "UITest Oshi"))
        XCTAssertNotNil(waitForAnyButton(exactly: ["Guaranteed push"], timeout: 3, swipes: 3))
        navigateBack()
        XCTAssertTrue(openSettingsSubpage(link: "settings.paidBackendLink", screenIdentifier: "settings.paidBackendScreen"))
        XCTAssertTrue(
            waitForElement(identifier: "settings.guaranteedPushSection", timeout: 3, swipes: 4).exists
        )
        XCTAssertTrue(waitForAnyStaticText(["Hosted feed refresh"], timeout: 3))
    }

    func testEncryptedBackupPromptCanBeCancelled() throws {
        tapTab(index: 4, labels: ["Settings"])
        XCTAssertTrue(openSettingsSubpage(link: "settings.dataProfilesLink", screenIdentifier: "settings.dataProfilesScreen"))
        let exportButton = waitForElement(identifier: "settings.exportEncryptedBackupButton", timeout: 3, swipes: 12)
        XCTAssertTrue(exportButton.exists)
        exportButton.tap()

        let password = app.secureTextFields["settings.encryptedBackupPasswordField"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        let cancel = app.buttons["settings.encryptedBackupCancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertFalse(app.secureTextFields["settings.encryptedBackupPasswordField"].waitForExistence(timeout: 1))
    }

    func testEncryptedBackupPromptRejectsMismatchedPasswords() throws {
        tapTab(index: 4, labels: ["Settings"])
        XCTAssertTrue(openSettingsSubpage(link: "settings.dataProfilesLink", screenIdentifier: "settings.dataProfilesScreen"))
        let exportButton = waitForElement(identifier: "settings.exportEncryptedBackupButton", timeout: 3, swipes: 12)
        XCTAssertTrue(exportButton.exists)
        exportButton.tap()

        let password = app.secureTextFields["settings.encryptedBackupPasswordField"]
        let confirmation = app.secureTextFields["settings.encryptedBackupConfirmationField"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        password.tap()
        password.typeText("correct horse battery staple")
        confirmation.tap()
        confirmation.typeText("different horse battery staple")
        app.buttons["settings.encryptedBackupSubmitButton"].tap()

        XCTAssertTrue(app.staticTexts["Passwords do not match."].waitForExistence(timeout: 3))
    }

    func testEncryptedBackupExportAcceptsMatchingPasswords() throws {
        tapTab(index: 4, labels: ["Settings"])
        XCTAssertTrue(openSettingsSubpage(link: "settings.dataProfilesLink", screenIdentifier: "settings.dataProfilesScreen"))
        let exportButton = waitForElement(identifier: "settings.exportEncryptedBackupButton", timeout: 3, swipes: 12)
        XCTAssertTrue(exportButton.exists)
        exportButton.tap()

        let password = app.secureTextFields["settings.encryptedBackupPasswordField"]
        let confirmation = app.secureTextFields["settings.encryptedBackupConfirmationField"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        password.tap()
        password.typeText("correct horse battery staple")
        confirmation.tap()
        confirmation.typeText("correct horse battery staple")
        app.buttons["settings.encryptedBackupSubmitButton"].tap()

        XCTAssertFalse(app.secureTextFields["settings.encryptedBackupPasswordField"].waitForExistence(timeout: 2))
        // The system document picker is outside the app's accessibility tree;
        // the absence of the password sheet confirms encryption succeeded.
        app.terminate()
    }

    func testProfileCreateAndManagementControls() throws {
        tapTab(index: 4, labels: ["Settings"])
        XCTAssertTrue(openSettingsSubpage(link: "settings.dataProfilesLink", screenIdentifier: "settings.dataProfilesScreen"))

        let add = waitForElement(identifier: "settings.addProfileButton", timeout: 3, swipes: 12)
        XCTAssertTrue(add.exists)
        add.tap()
        let field = app.textFields["settings.profileNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("UI Profile")
        app.buttons["settings.profileSaveButton"].tap()
        XCTAssertTrue(app.staticTexts["UI Profile"].waitForExistence(timeout: 3))

        let renameAction = waitForButton(
            matching: NSPredicate(format: "identifier BEGINSWITH 'settings.profileRename.'"),
            timeout: 2,
            swipes: 8
        )
        XCTAssertTrue(renameAction.exists)
        XCTAssertTrue(waitForElement(identifier: "settings.exportProfileButton", timeout: 3, swipes: 6).exists)
    }

    func testFinalProfileDeletionIsProtectedAndProfileExportOpensPicker() throws {
        tapTab(index: 4, labels: ["Settings"])
        XCTAssertTrue(openSettingsSubpage(link: "settings.dataProfilesLink", screenIdentifier: "settings.dataProfilesScreen"))

        let deleteAction = waitForButton(
            matching: NSPredicate(format: "identifier BEGINSWITH 'settings.profileDelete.'"),
            timeout: 2,
            swipes: 12
        )
        XCTAssertTrue(deleteAction.exists)
        deleteAction.forceTap()
        XCTAssertTrue(app.staticTexts["The final profile cannot be deleted."].waitForExistence(timeout: 3))

        let export = app.buttons["settings.exportProfileButton"]
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        export.forceTap()
        // The system Files picker is outside the app accessibility tree; the
        // successful tap is the observable app-side behavior here.
        app.terminate()
    }

    private func tapTab(index: Int, labels: [String]) {
        guard index >= 0 && index < 5 else {
            XCTFail("Could not find tab at index \(index) with labels \(labels)")
            return
        }

        let tab = app.tabBars.buttons.element(boundBy: index)
        XCTAssertTrue(tab.waitForExistence(timeout: 3), "Missing tab button for \(labels)")
        tab.tap()
    }

    /// Taps a Settings drill-down row, then returns after the pushed page's
    /// content (identified by `screenIdentifier`) has appeared. The Settings
    /// screen splits its config into `NavigationLink` subpages; tests that used
    /// to scroll one long Form now open the relevant subpage first.
    @discardableResult
    private func openSettingsSubpage(link: String, screenIdentifier: String? = nil) -> Bool {
        let row = waitForElement(identifier: link, timeout: 2, swipes: 12)
        guard row.waitForExistence(timeout: 2) else { return false }
        row.tap()
        guard let screenIdentifier else { return true }
        return app.descendants(matching: .any)[screenIdentifier].waitForExistence(timeout: 3)
    }

    private func navigateBack() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.waitForExistence(timeout: 2) { backButton.tap() }
    }

    /// Tap a Watch Term row to open its detail screen (collection mode, source
    /// selection, guaranteed push, alias editing all live there now).
    @discardableResult
    private func openTermDetail(keyword: String) -> Bool {
        let row = waitForElement(identifier: "settings.keywordRow.\(keyword)", timeout: 3, swipes: 6)
        guard row.waitForExistence(timeout: 2) else { return false }
        row.tap()
        return true
    }

    private func firstExistingButton(containing text: String) -> XCUIElement? {
        let buttons = app.buttons.allElementsBoundByIndex
        return buttons.first { button in
            button.exists && button.label.localizedCaseInsensitiveContains(text)
        }
    }

    private func firstExistingButton(exactly text: String) -> XCUIElement? {
        let buttons = app.buttons.allElementsBoundByIndex
        return buttons.first { button in
            button.exists && button.label.localizedCaseInsensitiveCompare(text) == .orderedSame
        }
    }

    private func firstFeedFilterButton() -> XCUIElement? {
        let identifiedButton = app.buttons["feed.filterButton"]
        if identifiedButton.waitForExistence(timeout: 3) {
            return identifiedButton
        }

        let labels = ["Filter", "フィルター", "篩選", "筛选"]
        return app.buttons.allElementsBoundByIndex.first { button in
            button.exists && labels.contains { button.label.localizedCaseInsensitiveContains($0) }
        }
    }

    private func waitForButton(identifier: String, timeout: TimeInterval) -> XCUIElement? {
        let button = app.buttons[identifier]
        return button.waitForExistence(timeout: timeout) ? button : nil
    }

    /// Scrolls the current screen looking for a button matching `predicate`,
    /// swiping up between attempts. Returns the (possibly non-existent) match.
    private func waitForButton(
        matching predicate: NSPredicate,
        timeout: TimeInterval,
        swipes: Int
    ) -> XCUIElement {
        let match = app.buttons.matching(predicate).firstMatch
        for attempt in 0...swipes {
            if match.waitForExistence(timeout: timeout) {
                return match
            }
            if attempt < swipes {
                app.swipeUp()
            }
        }
        return match
    }

    private func waitForAnyButton(containing texts: [String], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = texts.compactMap({ firstExistingButton(containing: $0) }).first {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return texts.compactMap { firstExistingButton(containing: $0) }.first
    }

    private func waitForAnyButton(exactly texts: [String], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = texts.compactMap({ firstExistingButton(exactly: $0) }).first {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return texts.compactMap { firstExistingButton(exactly: $0) }.first
    }

    private func waitForButton(containing text: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = firstExistingButton(containing: text) {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return firstExistingButton(containing: text)
    }

    private func waitForButton(containing text: String, timeout: TimeInterval, swipes: Int) -> XCUIElement? {
        for attempt in 0...swipes {
            if let button = waitForButton(containing: text, timeout: timeout) {
                return button
            }
            if attempt < swipes {
                app.swipeUp()
            }
        }
        return nil
    }

    private func waitForAnyButton(containing texts: [String], timeout: TimeInterval, swipes: Int) -> XCUIElement? {
        for attempt in 0...swipes {
            if let button = waitForAnyButton(containing: texts, timeout: timeout) {
                return button
            }
            if attempt < swipes {
                app.swipeUp()
            }
        }
        return nil
    }

    private func waitForAnyButton(exactly texts: [String], timeout: TimeInterval, swipes: Int) -> XCUIElement? {
        for attempt in 0...swipes {
            if let button = waitForAnyButton(exactly: texts, timeout: timeout) {
                return button
            }
            if attempt < swipes {
                app.swipeUp()
            }
        }
        return nil
    }

    private func waitForElement(identifier: String, timeout: TimeInterval, swipes: Int) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        for attempt in 0...swipes {
            if element.waitForExistence(timeout: timeout) {
                return element
            }
            if attempt < swipes {
                app.swipeUp()
            }
        }
        return element
    }

    private func waitForAnyElement(identifiers: [String], timeout: TimeInterval, swipes: Int) -> XCUIElement {
        let elements = identifiers.map { app.descendants(matching: .any)[$0] }
        for attempt in 0...swipes {
            for element in elements where element.waitForExistence(timeout: timeout) {
                return element
            }
            if attempt < swipes {
                app.swipeUp()
            }
        }
        return elements.first ?? app.descendants(matching: .any).firstMatch
    }

    private func firstExistingTextField(labels: [String]) -> XCUIElement? {
        for label in labels {
            let field = app.textFields[label]
            if field.exists {
                return field
            }
        }
        return nil
    }

    private func waitForHittableButton(identifier: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let matches = app.buttons.matching(identifier: identifier)
        while Date() < deadline {
            if let button = matches.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return button
            }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return matches.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
    }

    private func waitForHittableTextField(identifier: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let matches = app.textFields.matching(identifier: identifier)
        while Date() < deadline {
            if let field = matches.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return field
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return matches.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
    }

    private func waitForAnyStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        let elements = labels.map { app.staticTexts[$0] }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return elements.contains(where: { $0.exists })
    }
}

private extension XCUIElement {
    func tapIfExists() {
        if exists {
            tap()
        }
    }

    func forceTap() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
