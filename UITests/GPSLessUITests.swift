import XCTest

final class GPSLessUITests: XCTestCase {
    private func selectAndLockRoute(_ app: XCUIApplication) {
        let confirm = app.buttons["confirmStartingPoint"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 40))
        confirm.tap()
        // Khreshchatyk, reachable from the default start direction; the map
        // fills the screen behind the cards.
        let map = app.otherElements["offlineMap"]
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.30)).tap()
        XCTAssertTrue(app.buttons["startTracking"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["startTracking"].isEnabled)
    }

    private func openMore(_ item: String, app: XCUIApplication) {
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 5))
        app.buttons[item].tap()
    }

    func testInitialMapOnlyRequestsStartingPoint() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-no-selection"]
        app.launch()
        XCTAssertTrue(app.otherElements["offlineMap"].waitForExistence(timeout: 40))
        let request = app.descendants(matching: .any).matching(identifier: "startingPointRequest").firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["openSatellite"].exists)
        XCTAssertFalse(app.buttons["flipDirection"].exists)
        XCTAssertFalse(app.buttons["confirmStartingPoint"].exists)
        XCTAssertFalse(app.buttons["startTracking"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Simplified starting point request"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRouteRequiredAndLockedUntilStartingPointReset() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["confirmStartingPoint"].waitForExistence(timeout: 40))
        selectAndLockRoute(app)
        let start = app.buttons["startTracking"]
        XCTAssertTrue(start.exists)
        XCTAssertFalse(app.buttons["confirmStartingPoint"].exists)
        XCTAssertFalse(app.buttons["flipDirection"].exists)
        let marker = app.descendants(matching: .any).matching(identifier: "roadPosition").firstMatch
        let frame = marker.frame
        app.otherElements["offlineMap"].coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.25)).tap()
        XCTAssertEqual(marker.frame.midX, frame.midX, accuracy: 1)
        XCTAssertEqual(marker.frame.midY, frame.midY, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Locked offline route to B"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["resetEverything"].tap()
        XCTAssertFalse(start.exists)
        // Start over clears the starting point as well and asks for it again.
        let request = app.descendants(matching: .any).matching(identifier: "startingPointRequest").firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        let resetScreenshot = XCTAttachment(screenshot: app.screenshot())
        resetScreenshot.name = "Reset clears route and destination"
        resetScreenshot.lifetime = .keepAlways
        add(resetScreenshot)
    }

    func testGPSTracePreferenceAndDeniedPermissionDoNotBlockTracking() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--ui-testing", "--reset-gps-tracing"]
        app.launch()
        selectAndLockRoute(app)
        app.buttons["startTracking"].tap()
        let toggle = app.switches["gpsTraceToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.alerts.buttons["Don’t Allow"]
        let alternateDeny = springboard.alerts.buttons["Don't Allow"]
        XCTAssertTrue(springboard.alerts.firstMatch.waitForExistence(timeout: 5))
        if deny.exists {
            deny.tap()
        } else {
            XCTAssertTrue(alternateDeny.exists)
            alternateDeny.tap()
        }
        XCTAssertTrue(app.staticTexts["GPS trace unavailable · allow Location in Settings"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "GPS trace opt-in with denied permission"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let confirm = app.buttons["confirmMount"]
        if !confirm.isHittable {
            app.swipeUp()
        }
        confirm.tap()
        XCTAssertTrue(app.buttons["setPosition"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        selectAndLockRoute(app)
        app.buttons["startTracking"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["GPS tracing off"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testGPSTraceGrantedPermissionIsReadyBeforeDriving() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--ui-testing", "--reset-gps-tracing"]
        app.launch()
        selectAndLockRoute(app)
        app.buttons["startTracking"].tap()
        let toggle = app.switches["gpsTraceToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow While Using App"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        XCTAssertTrue(app.staticTexts["GPS trace ready · records during a ride"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saves GPS reference data with this ride for later analysis. Positioning never uses it."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "GPS tracing enabled before calibration"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        toggle.tap()
        XCTAssertTrue(app.staticTexts["GPS tracing off"].waitForExistence(timeout: 5))
    }

    func testSatelliteSelectionReturnsToOfflineMap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let satellite = app.buttons["openSatellite"]
        XCTAssertTrue(satellite.waitForExistence(timeout: 40))
        satellite.tap()
        XCTAssertTrue(app.otherElements["satelliteMap"].waitForExistence(timeout: 10))
        let marker = app.descendants(matching: .any).matching(identifier: "satellitePosition").firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        let headingBeforeFlip = marker.value as? String
        XCTAssertTrue(app.buttons["flipDirection"].isEnabled)
        app.buttons["flipDirection"].tap()
        XCTAssertNotEqual(marker.value as? String, headingBeforeFlip)
        let original = marker.frame
        let center = marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.4, thenDragTo: center.withOffset(CGVector(dx: -25, dy: -15)))
        XCTAssertGreaterThan(abs(marker.frame.midY - original.midY), 3)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Online satellite road selection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["openSatellite"].tap()
        XCTAssertTrue(app.otherElements["offlineMap"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["confirmStartingPoint"].exists)
    }

    func testOfflineMapSelectionAndCalibrationRecovery() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["confirmStartingPoint"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.otherElements["offlineMap"].exists)
        let flip = app.buttons["flipDirection"]
        XCTAssertTrue(flip.isEnabled)
        flip.tap()
        XCTAssertTrue(app.staticTexts["SE"].exists)
        let marker = app.descendants(matching: .any).matching(identifier: "roadPosition").firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        let originalFrame = marker.frame
        let markerCenter = marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        markerCenter.press(forDuration: 0.4, thenDragTo: markerCenter.withOffset(CGVector(dx: -10, dy: -6)))
        XCTAssertGreaterThan(abs(marker.frame.midY - originalFrame.midY), 3)
        XCTAssertTrue(app.staticTexts["вулиця Архітектора Городецького"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Kyiv offline map and selected road"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        selectAndLockRoute(app)
        let start = app.buttons["startTracking"]
        start.tap()
        XCTAssertTrue(app.buttons["confirmMount"].waitForExistence(timeout: 5))
        app.buttons["confirmMount"].tap()
        // Simulator has no vehicle IMU. It must expose an actionable recovery
        // state, never animate a fabricated live position.
        XCTAssertTrue(app.buttons["setPosition"].waitForExistence(timeout: 10))
        app.buttons["setPosition"].tap()
        XCTAssertTrue(app.buttons["confirmStartingPoint"].waitForExistence(timeout: 5))
        openMore("Recorded drives", app: app)
        XCTAssertTrue(app.buttons["exportAll"].waitForExistence(timeout: 5))
        let recordings = XCTAttachment(screenshot: app.screenshot())
        recordings.name = "Recorded drives and export controls"
        recordings.lifetime = .keepAlways
        add(recordings)
    }
}
