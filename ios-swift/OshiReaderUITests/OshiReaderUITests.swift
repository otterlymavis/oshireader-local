import XCTest

final class OshiReaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    func testAddKeywordFlow() throws {
        tapTab(index: 4, labels: ["Settings"])

        let addKeywordButton = app.buttons["settings.addKeywordButton"]
        XCTAssertTrue(addKeywordButton.waitForExistence(timeout: 3))
        addKeywordButton.forceTap()
        let keywordField = firstExistingTextField(labels: ["settings.keywordField", "Enter keyword..."]) ?? app.textFields.firstMatch
        XCTAssertTrue(keywordField.waitForExistence(timeout: 3))

        keywordField.tap()
        keywordField.typeText("New UI Keyword")
        app.toolbars.buttons["Done"].tapIfExists()
        let addButton = waitForButton(identifier: "settings.confirmAddKeywordButton", timeout: 3)
        XCTAssertNotNil(addButton)
        addButton?.tap()

        XCTAssertTrue(app.staticTexts["New UI Keyword"].waitForExistence(timeout: 3))
    }

    func testAddKeywordWithSelectedSourceFlow() throws {
        tapTab(index: 4, labels: ["Settings"])

        let addKeywordButton = app.buttons["settings.addKeywordButton"]
        XCTAssertTrue(addKeywordButton.waitForExistence(timeout: 3))
        addKeywordButton.forceTap()

        let keywordField = firstExistingTextField(labels: ["settings.keywordField", "Enter keyword..."]) ?? app.textFields.firstMatch
        XCTAssertTrue(keywordField.waitForExistence(timeout: 3))
        keywordField.tap()
        keywordField.typeText("Selected Source UI Keyword")
        app.toolbars.buttons["Done"].tapIfExists()

        let selectedMode = waitForAnyButton(containing: ["Selected", "選択", "選取", "选择"], timeout: 3)
        XCTAssertNotNil(selectedMode)
        selectedMode?.tap()

        let sourceMenu = app.buttons["settings.newKeywordSources"]
        XCTAssertTrue(sourceMenu.waitForExistence(timeout: 3))
        sourceMenu.tap()

        let youtubeSource = app.buttons["settings.newKeywordSource.youtube"]
        XCTAssertTrue(youtubeSource.waitForExistence(timeout: 3))
        youtubeSource.tap()

        XCTAssertTrue(sourceMenu.waitForExistence(timeout: 3))
        let addButton = waitForButton(identifier: "settings.confirmAddKeywordButton", timeout: 3)
        XCTAssertNotNil(addButton)
        addButton?.tap()

        XCTAssertTrue(app.staticTexts["Selected Source UI Keyword"].waitForExistence(timeout: 3))
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
    }

    func testOpenReaderFromFeedAndSave() throws {
        tapTab(index: 0, labels: ["Feed"])

        let headline = app.staticTexts["UITest Oshi headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 3))
        (firstExistingButton(containing: "UITest Oshi headline") ?? headline).tap()

        let readerModeButton = waitForButton(identifier: "reader.modeToggleButton", timeout: 5)
        XCTAssertNotNil(readerModeButton)
        readerModeButton?.tap()
    }

    func testSavedReaderFlow() throws {
        tapTab(index: 2, labels: ["Saved"])

        let savedTitle = app.staticTexts["UITest saved article"]
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 3))
        (firstExistingButton(containing: "UITest saved article") ?? savedTitle).tap()

        XCTAssertNotNil(waitForButton(identifier: "reader.modeToggleButton", timeout: 5))
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
        let saveButton = waitForButton(containing: "保存", timeout: 3)
        XCTAssertNotNil(saveButton)
        saveButton?.tap()
    }

    func testSettingsPrivacyPolicyFlow() throws {
        tapTab(index: 4, labels: ["Settings"])

        XCTAssertTrue(waitForElement(identifier: "settings.fontPicker", timeout: 2, swipes: 8).exists)
        let comicSansButton = waitForAnyButton(containing: ["Comic"], timeout: 2, swipes: 1)
        XCTAssertNotNil(comicSansButton)
        comicSansButton?.tap()

        XCTAssertTrue(waitForElement(identifier: "settings.fontSizePicker", timeout: 2, swipes: 2).exists)
        let largeButton = waitForAnyButton(exactly: ["Large", "大"], timeout: 2, swipes: 1)
        XCTAssertNotNil(largeButton)
        largeButton?.tap()

        let privacyLink = waitForElement(identifier: "settings.privacyPolicyLink", timeout: 2, swipes: 6)
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

        XCTAssertTrue(waitForElement(identifier: "settings.notificationStatus", timeout: 2, swipes: 4).exists)
        let notificationAction = waitForAnyElement(
            identifiers: [
                "settings.enableNotificationsButton",
                "settings.openSettingsButton",
                "settings.testNotificationButton"
            ],
            timeout: 2,
            swipes: 1
        )
        XCTAssertTrue(notificationAction.exists)
    }

    private func tapTab(index: Int, labels: [String]) {
        let tabIdentifiers = ["tab.feed", "tab.search", "tab.saved", "tab.oshi", "tab.settings"]
        if tabIdentifiers.indices.contains(index) {
            let tabElement = app.descendants(matching: .any)[tabIdentifiers[index]]
            if tabElement.waitForExistence(timeout: 1) {
                tabElement.tap()
                return
            }
        }

        for label in labels {
            let button = app.tabBars.buttons[label]
            if button.waitForExistence(timeout: 1) {
                button.tap()
                return
            }
        }

        let indexedButton = app.tabBars.buttons.element(boundBy: index)
        if indexedButton.waitForExistence(timeout: 2) {
            indexedButton.tap()
            return
        }

        XCTFail("Could not find tab at index \(index) with labels \(labels)")
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
