import XCTest

final class JumpJumpUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        // JUMPJUMP_SERVER (e.g. 127.0.0.1:7790) points the online lobby at a
        // private test server instead of whichever one Bonjour finds first.
        if let server = ProcessInfo.processInfo.environment["JUMPJUMP_SERVER"] {
            app.launchEnvironment["JUMPJUMP_SERVER"] = server
        }
        app.launch()
        // Every launch opens on the menu; these tests play single player.
        let solo = app.buttons["playSolo"]
        XCTAssertTrue(solo.waitForExistence(timeout: 10), "Launch did not show the menu")
        solo.tap()
    }

    func testHomeButtonReturnsToMenu() throws {
        let playArea = try settledInitialPlayArea()
        app.buttons["home"].tap()
        XCTAssertTrue(app.buttons["playSolo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["playOnline"].exists)
        XCTAssertFalse(playArea.exists, "The play area must not take touches on the menu")
        app.buttons["playSolo"].tap()
        XCTAssertTrue(playArea.waitForExistence(timeout: 5))
        XCTAssertEqual(try XCTUnwrap(Diagnostics(playArea.value)).jumps, 0)
        for id in ["sound", "restart", "home"] {
            XCTAssertGreaterThan(app.buttons[id].frame.width, 40, "\(id) button collapsed")
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testShortPressReleasesBeforeFullCharge() throws {
        try assertJump(afterPressDuration: 0.15)
    }

    func testMediumPressReleasesBeforeFullCharge() throws {
        try assertJump(afterPressDuration: 0.45)
    }

    func testLongPressReleasesBeforeFullCharge() throws {
        try assertJump(afterPressDuration: 0.8)
    }

    func testRestartResetsJumpCount() throws {
        let playArea = try assertJump(afterPressDuration: 0.15)
        let restart = app.buttons["restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        restart.tap()

        let reset = NSPredicate { _, _ in
            guard let diagnostics = Diagnostics(playArea.value) else { return false }
            return diagnostics.jumps == 0
        }
        XCTAssertTrue(wait(for: reset, on: playArea), "Restart did not reset jumps: \(String(describing: playArea.value))")
        XCTAssertEqual(try XCTUnwrap(Diagnostics(playArea.value)).jumps, 0)
    }

    func testVeryShortStationaryJumpsDoNotReplayNextPlatformArrival() throws {
        try assertStationaryJumps(afterPressDuration: 0.05)
    }

    func testShortStationaryJumpsDoNotReplayNextPlatformArrival() throws {
        try assertStationaryJumps(afterPressDuration: 0.15)
    }

    func testSuccessfulLandingShowsOnlyTransientFloatingScore() throws {
        let playArea = try settledInitialPlayArea()
        let initial = try XCTUnwrap(Diagnostics(playArea.value))
        let initialID = try XCTUnwrap(initial.nextID)
        let initialArrivals = try XCTUnwrap(initial.arrivals)
        XCTAssertEqual(try XCTUnwrap(initial.scorePops), 0)
        let idealPress = try XCTUnwrap(initial.idealPress, "Missing pure-solver press duration")
        XCTAssertGreaterThan(idealPress, 0)
        XCTAssertLessThan(idealPress, 1.5)

        // Exercise actual UIKit touch delivery, not the renderer's debug jump.
        playArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: idealPress)
        let landedOnNext = NSPredicate { _, _ in
            guard let diagnostics = Diagnostics(playArea.value), let nextID = diagnostics.nextID else { return false }
            return diagnostics.jumps == 1 && diagnostics.phase == "ready" && nextID != initialID
        }
        XCTAssertTrue(wait(for: landedOnNext, on: playArea), "Solver-duration press did not reach the next platform: \(String(describing: playArea.value))")
        let landed = try XCTUnwrap(Diagnostics(playArea.value))
        XCTAssertNotEqual(try XCTUnwrap(landed.nextID), initialID)
        XCTAssertEqual(try XCTUnwrap(landed.arrivals), initialArrivals + 1)
        XCTAssertEqual(try XCTUnwrap(landed.scorePops), 1)
        let popupVisible = try XCTUnwrap(landed.popupVisible)
        XCTAssertTrue(popupVisible == 0 || popupVisible == 1)

        let score = app.descendants(matching: .any)["score"]
        XCTAssertTrue(score.waitForExistence(timeout: 5))
        let scoreValue = try XCTUnwrap((score.value as? String).flatMap(Int.init))
        XCTAssertGreaterThan(scoreValue, 0)
        XCTAssertTrue((playArea.value as? String)?.contains(";popupDisplayed=1") == true,
                      "The score label must actually appear at a projected on-screen landing point")

        // XCUI snapshots can miss a subsecond UILabel entirely. The accumulated
        // scorePops field proves its presentation path ran even in that case.
        // Check removal rather than requiring a snapshot during the animation.
        let popupExpired = NSPredicate { _, _ in
            guard let diagnostics = Diagnostics(playArea.value) else { return false }
            return diagnostics.scorePops == 1 && diagnostics.popupVisible == 0
                && !self.app.staticTexts["floatingScore"].exists
                && diagnostics.nextY == 0 && diagnostics.nextScale == 1
        }
        XCTAssertTrue(wait(for: popupExpired, on: playArea), "Floating score or arrival animation did not finish: \(String(describing: playArea.value))")
        let settled = try XCTUnwrap(Diagnostics(playArea.value))
        XCTAssertEqual(try XCTUnwrap(settled.scorePops), 1)
        XCTAssertEqual(try XCTUnwrap(settled.popupVisible), 0)
        XCTAssertEqual(try XCTUnwrap(settled.arrivals), initialArrivals + 1)
        XCTAssertFalse(app.staticTexts["floatingScore"].exists)
        let gameMessage = app.staticTexts["gameMessage"]
        // An empty UIKit label is omitted from the accessibility snapshot.
        let messageText = gameMessage.exists ? gameMessage.label : ""
        XCTAssertFalse(messageText.contains("+1"), "Score must not persist in the bottom message")
        XCTAssertFalse(messageText.contains("+2"), "Perfect score must not persist in the bottom message")
    }

    func testTenScoreTapsToggleAssistWithoutJumping() throws {
        let playArea = try settledInitialPlayArea()
        let meter = app.otherElements["forceMeter"]
        let guideText = app.staticTexts["forceGuideText"]
        XCTAssertFalse(meter.exists, "Assist must be hidden on launch")
        XCTAssertFalse(guideText.exists)
        XCTAssertEqual(try XCTUnwrap(Diagnostics(playArea.value)?.trainer), 0)

        try tapScore(times: 9)
        XCTAssertFalse(meter.exists, "Nine score taps must not activate assist")
        XCTAssertFalse(guideText.exists)
        XCTAssertEqual(try XCTUnwrap(Diagnostics(playArea.value)).jumps, 0)
        try tapScore(times: 1)
        XCTAssertTrue(meter.waitForExistence(timeout: 5), "The tenth actual score tap must activate assist")
        XCTAssertTrue(guideText.waitForExistence(timeout: 5))
        let activated = try XCTUnwrap(Diagnostics(playArea.value))
        XCTAssertEqual(activated.jumps, 0, "Score taps must not reach the jump input")
        XCTAssertEqual(try XCTUnwrap(activated.trainer), 1)
        let sample = try captureGuideSample(named: "Assist activated", meter: meter, playArea: playArea)
        try assertGuideBounds(sample, diagnostics: activated)
        XCTAssertFalse(guideText.label.isEmpty)
        XCTAssertTrue(guideText.label.contains("%"), "Guide text must show the target percentage")

        try tapScore(times: 10)
        let hidden = NSPredicate { _, _ in
            !meter.exists && !guideText.exists && Diagnostics(playArea.value)?.trainer == 0
        }
        XCTAssertTrue(wait(for: hidden, on: playArea), "Ten more score taps must hide assist")
        XCTAssertEqual(try XCTUnwrap(Diagnostics(playArea.value)).jumps, 0)
    }

    func testAssistUpdatesAfterStayedJumpAndPersistsAcrossRestart() throws {
        let playArea = try settledInitialPlayArea()
        let meter = app.otherElements["forceMeter"]
        let guideText = app.staticTexts["forceGuideText"]
        try tapScore(times: 10)
        XCTAssertTrue(meter.waitForExistence(timeout: 5))
        XCTAssertTrue(guideText.waitForExistence(timeout: 5))
        let initialDiagnostics = try XCTUnwrap(Diagnostics(playArea.value))
        let initial = try captureGuideSample(named: "Initial assist hint", meter: meter, playArea: playArea)
        try assertGuideBounds(initial, diagnostics: initialDiagnostics)
        XCTAssertEqual(initialDiagnostics.jumps, 0)
        let initialID = try XCTUnwrap(initialDiagnostics.nextID)
        let initialArrivals = try XCTUnwrap(initialDiagnostics.arrivals)
        let initialText = guideText.label

        // Deliver a real short UIKit press: it shifts the character forward but
        // stays on the current platform, so the next target must not change.
        playArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05)
        let landedAndUpdated = NSPredicate { _, _ in
            guard let diagnostics = Diagnostics(playArea.value),
                  let sample = ForceMeterValues(meter.value) else { return false }
            return diagnostics.phase == "ready" && diagnostics.jumps == 1
                && diagnostics.maxHeight > 0 && sample.seconds < initial.seconds
        }
        XCTAssertTrue(wait(for: landedAndUpdated, on: playArea), "Stayed jump did not reduce the position-aware hint: \(String(describing: playArea.value)); \(String(describing: meter.value))")
        let shiftedDiagnostics = try XCTUnwrap(Diagnostics(playArea.value))
        try assertUnchangedNextPlatform(shiftedDiagnostics, nextID: initialID, arrivals: initialArrivals)
        XCTAssertEqual(try XCTUnwrap(shiftedDiagnostics.scorePops), 0)
        XCTAssertEqual(try XCTUnwrap(shiftedDiagnostics.trainer), 1)
        XCTAssertTrue(meter.exists)
        XCTAssertTrue(guideText.exists)
        let shifted = try captureGuideSample(named: "Assist hint after real 0.05s stayed jump", meter: meter, playArea: playArea)
        try assertGuideBounds(shifted, diagnostics: shiftedDiagnostics)
        XCTAssertEqual(shifted.targetID, initial.targetID)
        XCTAssertLessThan(shifted.seconds, initial.seconds)
        XCTAssertLessThan(try XCTUnwrap(shiftedDiagnostics.idealPress), try XCTUnwrap(initialDiagnostics.idealPress))

        let restart = app.buttons["restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        restart.tap()
        let restored = NSPredicate { _, _ in
            guard let diagnostics = Diagnostics(playArea.value),
                  let sample = ForceMeterValues(meter.value) else { return false }
            return diagnostics.phase == "ready" && diagnostics.jumps == 0
                && diagnostics.nextY == 0 && diagnostics.nextScale == 1
                && diagnostics.trainer == 1 && sample.targetID == initial.targetID
                && abs(sample.seconds - initial.seconds) <= 0.00001
        }
        XCTAssertTrue(wait(for: restored, on: playArea), "Restart did not preserve assist and restore its initial hint")
        XCTAssertTrue(meter.exists)
        XCTAssertTrue(guideText.exists)
        XCTAssertEqual(guideText.label, initialText)
        let resetDiagnostics = try XCTUnwrap(Diagnostics(playArea.value))
        let reset = try captureGuideSample(named: "Assist hint after restart", meter: meter, playArea: playArea)
        try assertGuideBounds(reset, diagnostics: resetDiagnostics)
        XCTAssertEqual(reset.current, 0, accuracy: 0.00001)
        XCTAssertEqual(reset.ideal, initial.ideal, accuracy: 0.00001)
        XCTAssertEqual(reset.minimum, initial.minimum, accuracy: 0.00001)
        XCTAssertEqual(reset.maximum, initial.maximum, accuracy: 0.00001)
        XCTAssertEqual(reset.seconds, initial.seconds, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(resetDiagnostics.nextID), initialID)
        XCTAssertEqual(try XCTUnwrap(resetDiagnostics.idealPress), try XCTUnwrap(initialDiagnostics.idealPress), accuracy: 0.00001)
    }

    private func tapScore(times count: Int) throws {
        let score = app.descendants(matching: .any)["score"]
        XCTAssertTrue(score.waitForExistence(timeout: 5))
        XCTAssertTrue(score.isHittable, "Score UILabel must accept the hidden gesture")
        // Center-coordinate taps exercise the UILabel's real gesture recognizer,
        // without relying on an accessibility activation action or debug hook.
        for _ in 0..<count {
            score.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func captureGuideSample(named name: String, meter: XCUIElement, playArea: XCUIElement) throws -> ForceMeterValues {
        let rawValue = try XCTUnwrap(meter.value as? String)
        let sample = try XCTUnwrap(ForceMeterValues(rawValue), "Invalid force meter accessibility grammar: \(rawValue)")
        let guideText = app.staticTexts["forceGuideText"].label
        let attachment = XCTAttachment(string: "forceMeter=\(rawValue)\nforceGuideText=\(guideText)\nplayArea=\(String(describing: playArea.value))")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return sample
    }

    private func assertGuideBounds(_ sample: ForceMeterValues, diagnostics: Diagnostics) throws {
        XCTAssertGreaterThanOrEqual(sample.current, 0)
        XCTAssertLessThanOrEqual(sample.current, 1)
        XCTAssertGreaterThanOrEqual(sample.minimum, 0)
        XCTAssertLessThanOrEqual(sample.maximum, 1)
        XCTAssertLessThanOrEqual(sample.minimum, sample.ideal)
        XCTAssertLessThanOrEqual(sample.ideal, sample.maximum)
        XCTAssertGreaterThan(sample.seconds, 0)
        XCTAssertLessThanOrEqual(sample.seconds, 1.5)
        XCTAssertEqual(sample.ideal, sample.seconds / 1.5, accuracy: 0.00002,
                       "Meter values use fractions of the full 1.5-second scale")
        XCTAssertEqual(sample.targetID, try XCTUnwrap(diagnostics.nextID))
        // idealPress keeps its existing three-decimal diagnostics precision.
        XCTAssertEqual(sample.seconds, try XCTUnwrap(diagnostics.idealPress), accuracy: 0.001)
    }

    private struct ForceMeterValues {
        let current: Double
        let ideal: Double
        let minimum: Double
        let maximum: Double
        let seconds: Double
        let targetID: Int

        init?(_ value: Any?) {
            guard let text = value as? String else { return nil }
            let components = text.split(separator: ";", omittingEmptySubsequences: false)
            let expectedKeys = ["current", "ideal", "minimum", "maximum", "seconds", "targetID"]
            guard components.count == expectedKeys.count else { return nil }
            var fields: [String: String] = [:]
            for (component, expectedKey) in zip(components, expectedKeys) {
                let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, String(pair[0]) == expectedKey else { return nil }
                fields[expectedKey] = String(pair[1])
            }
            guard let current = fields["current"].flatMap(Double.init), current.isFinite,
                  let ideal = fields["ideal"].flatMap(Double.init), ideal.isFinite,
                  let minimum = fields["minimum"].flatMap(Double.init), minimum.isFinite,
                  let maximum = fields["maximum"].flatMap(Double.init), maximum.isFinite,
                  let seconds = fields["seconds"].flatMap(Double.init), seconds.isFinite,
                  let targetID = fields["targetID"].flatMap(Int.init) else { return nil }
            self.current = current
            self.ideal = ideal
            self.minimum = minimum
            self.maximum = maximum
            self.seconds = seconds
            self.targetID = targetID
        }
    }

    private func assertStationaryJumps(afterPressDuration duration: TimeInterval) throws {
        let playArea = try settledInitialPlayArea()
        let initial = try XCTUnwrap(Diagnostics(playArea.value))
        let initialID = try XCTUnwrap(initial.nextID)
        let initialArrivals = try XCTUnwrap(initial.arrivals)
        XCTAssertEqual(initialID, 1)
        XCTAssertEqual(initialArrivals, 1)

        for jumpCount in 1...2 {
            let before = try XCTUnwrap(Diagnostics(playArea.value))
            XCTAssertEqual(before.phase, "ready")
            try assertUnchangedNextPlatform(before, nextID: initialID, arrivals: initialArrivals)
            // A .15s first hop moves toward the platform edge. Repeating .15s
            // would genuinely fall off, not exercise a second stayed landing.
            // Keep the second hop short enough to remain inside the same block.
            let press = jumpCount == 2 && duration > 0.1 ? 0.02 : duration
            playArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: press)
            let landed = NSPredicate { _, _ in
                guard let diagnostics = Diagnostics(playArea.value) else { return false }
                return diagnostics.jumps == jumpCount && diagnostics.phase == "ready" && diagnostics.maxHeight > 0
            }
            XCTAssertTrue(wait(for: landed, on: playArea), "Stationary jump \(jumpCount) did not land ready (duration \(duration)): \(String(describing: playArea.value))")
            let after = try XCTUnwrap(Diagnostics(playArea.value))
            XCTAssertEqual(after.jumps, jumpCount)
            XCTAssertGreaterThan(after.lastPress, 0)
            try assertUnchangedNextPlatform(after, nextID: initialID, arrivals: initialArrivals)
            XCTAssertEqual(try XCTUnwrap(after.scorePops), 0, "Remaining on the same platform must not score")
        }
    }

    private func assertUnchangedNextPlatform(_ diagnostics: Diagnostics, nextID: Int, arrivals: Int) throws {
        XCTAssertEqual(try XCTUnwrap(diagnostics.nextID), nextID)
        XCTAssertEqual(try XCTUnwrap(diagnostics.arrivals), arrivals)
        XCTAssertEqual(try XCTUnwrap(diagnostics.nextY), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(diagnostics.nextScale), 1, accuracy: 0.001)
        // Accumulated minimum catches shrink/replay between XCUI snapshots,
        // even if the next platform has already recovered by the landing.
        XCTAssertEqual(try XCTUnwrap(diagnostics.nextMinScale), 1, accuracy: 0.001)
    }

    // The online tests need a local JumpJumpServer and a bot waiting in its room:
    //   jumpjump-server & jumpbot -name Bot -jumps 8
    // then: TEST_RUNNER_JUMPJUMP_ONLINE_TEST=1 xcodebuild test ... -only-testing:JumpJumpUITests/JumpJumpUITests/testOnline...
    func testOnlineRaceAgainstBot() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUMPJUMP_ONLINE_TEST"] == "1", "Needs a running jumpjump-server and jumpbot")
        let playArea = try settledInitialPlayArea()
        app.buttons["home"].tap()
        joinOnlineRace(as: "Sim")
        for id in ["sound", "restart", "home"] { // a UIKit stack bug once squashed these to 12pt
            XCTAssertGreaterThan(app.buttons[id].frame.width, 40, "\(id) button collapsed")
        }
        let standings = app.descendants(matching: .any)["standings"]
        let ideal = try XCTUnwrap(Diagnostics(playArea.value)?.idealPress)
        playArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: ideal)
        XCTAssertTrue(wait(for: NSPredicate(format: "NOT (label CONTAINS '你，Sim，0')"), on: standings),
                      "Server never credited the jump: \(standings.label)")
        sleep(2)
        attachScreenshot("2-race")
        finishOnlineRace(as: "Sim")
        XCTAssertEqual(Diagnostics(playArea.value)?.desyncs, 0, "Client prediction diverged from the server")
        attachScreenshot("3-result")

        // The bot stays and readies up, so a rematch goes back through the room
        // view straight into a fresh race.
        app.buttons["playAgain"].tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "label CONTAINS '你，Sim，0' AND NOT (label CONTAINS '掉落')"), on: standings, timeout: 15),
                      "Rematch did not start: \(standings.label)")
        sleep(4)
        finishOnlineRace(as: "Sim")
        app.buttons["exitOnline"].tap()
        XCTAssertTrue(app.buttons["playSolo"].waitForExistence(timeout: 5), "Did not return to the menu")
    }

    // Needs a second bot that leaves after every match:
    //   jumpbot -name LeaveBot -jumps 6 -rejoin 20s
    func testOnlineRematchAloneReturnsHome() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUMPJUMP_ONLINE_TEST"] == "1", "Needs a running jumpjump-server and jumpbot")
        _ = try settledInitialPlayArea()
        app.buttons["home"].tap()
        joinOnlineRace(as: "Sim3", host: "LeaveBot")
        finishOnlineRace(as: "Sim3")
        app.buttons["playAgain"].tap()
        XCTAssertTrue(app.buttons["playSolo"].waitForExistence(timeout: 5), "An empty room must send the player back to the menu")
        XCTAssertEqual(app.staticTexts["homeNotice"].label, "其他玩家都已离开房间")
        attachScreenshot("4-empty-room")
    }

    // Opening a room and never readying: a countdown from the 10th second,
    // then out, back on the room list.
    func testOnlineReadyTimeoutLeavesRoom() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUMPJUMP_ONLINE_TEST"] == "1", "Needs a running jumpjump-server")
        _ = try settledInitialPlayArea()
        app.buttons["home"].tap()
        openRoomList(as: "Sim4")
        app.buttons["onlineCreate"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onlinePlayers"].waitForExistence(timeout: 10), "Did not enter the new room")
        let status = app.staticTexts["onlineStatus"]
        XCTAssertTrue(wait(for: NSPredicate(format: "label CONTAINS '秒后将自动退出房间'"), on: status, timeout: 14), "No ready countdown: \(status.label)")
        attachScreenshot("5-ready-countdown")
        XCTAssertTrue(wait(for: NSPredicate(format: "label == '长时间未准备，已退出房间'"), on: status, timeout: 8), "Not removed: \(status.label)")
        XCTAssertTrue(app.buttons["onlineCreate"].exists, "Should be back at the room list")
        app.buttons["onlineClose"].tap()
        XCTAssertTrue(app.buttons["playSolo"].waitForExistence(timeout: 5))
    }

    // Needs a bot in a locked room:
    //   jumpbot -name LockBot -password 1234
    func testOnlineLockedRoomNeedsPassword() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUMPJUMP_ONLINE_TEST"] == "1", "Needs a running jumpjump-server and jumpbot")
        _ = try settledInitialPlayArea()
        app.buttons["home"].tap()
        openRoomList(as: "Sim6")
        let room = app.buttons["room_LockBot"]
        XCTAssertTrue(room.waitForExistence(timeout: 10), "LockBot's room is not listed")
        XCTAssertTrue(room.label.contains("需要密码"), "Locked room not marked: \(room.label)")
        attachScreenshot("7-locked-room")
        enterPassword("0000", for: room)
        let status = app.staticTexts["onlineStatus"]
        XCTAssertTrue(wait(for: NSPredicate(format: "label == '密码不对'"), on: status), "Wrong password not refused: \(status.label)")
        enterPassword("1234", for: room)
        let players = app.descendants(matching: .any)["onlinePlayers"]
        XCTAssertTrue(players.waitForExistence(timeout: 10), "The right password did not get in")
        XCTAssertTrue(players.label.contains("LockBot"), "Not in LockBot's room: \(players.label)")
        app.buttons["onlineLeave"].tap()
        XCTAssertTrue(app.buttons["onlineCreate"].waitForExistence(timeout: 5), "Leaving should go back to the room list")
        // Switching servers stays manual: no reconnect until asked.
        app.buttons["onlineServers"].tap()
        XCTAssertFalse(app.buttons["onlineCreate"].waitForExistence(timeout: 2), "Reconnected without being asked")
        app.buttons["onlineConnect"].tap()
        XCTAssertTrue(app.buttons["onlineCreate"].waitForExistence(timeout: 10), "Connecting by hand did not reach the room list")
        app.buttons["onlineClose"].tap()
        XCTAssertTrue(app.buttons["playSolo"].waitForExistence(timeout: 5))
    }

    // With no server on the network the lobby must say why there are no rooms,
    // not search forever. Run it only when no jumpjump-server is reachable:
    //   TEST_RUNNER_JUMPJUMP_NO_SERVER_TEST=1 xcodebuild test ... -only-testing:JumpJumpUITests/JumpJumpUITests/testOnlineWithoutServerExplains
    func testOnlineWithoutServerExplains() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUMPJUMP_NO_SERVER_TEST"] == "1", "Needs a network without a jumpjump-server")
        app.buttons["home"].tap()
        app.buttons["playOnline"].tap()
        let status = app.staticTexts["onlineStatus"]
        XCTAssertTrue(wait(for: NSPredicate(format: "label BEGINSWITH '没有发现服务器'"), on: status, timeout: 6), "Still: \(status.label)")
        attachScreenshot("8-no-server")
        app.buttons["onlineClose"].tap()
        XCTAssertTrue(app.buttons["playSolo"].waitForExistence(timeout: 5))
    }

    // Lingering on the result counts as not readying for the next race.
    func testOnlineResultTimeoutReturnsHome() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUMPJUMP_ONLINE_TEST"] == "1", "Needs a running jumpjump-server and jumpbot")
        _ = try settledInitialPlayArea()
        app.buttons["home"].tap()
        joinOnlineRace(as: "Sim5")
        finishOnlineRace(as: "Sim5")
        let note = app.staticTexts["resultNote"]
        XCTAssertTrue(wait(for: NSPredicate(format: "label CONTAINS '再来一局'"), on: note, timeout: 14), "No countdown on the result")
        attachScreenshot("6-result-countdown")
        XCTAssertTrue(app.buttons["playSolo"].waitForExistence(timeout: 8), "Not sent home after the countdown")
        XCTAssertEqual(app.staticTexts["homeNotice"].label, "长时间未准备，已退出房间")
    }

    // A regular launch without --ui-test hooks, exactly as players get the app.
    func testOnlineDisablesAssist() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUMPJUMP_ONLINE_TEST"] == "1", "Needs a running jumpjump-server and jumpbot")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["playSolo"].waitForExistence(timeout: 10))
        app.buttons["playSolo"].tap()
        let meter = app.otherElements["forceMeter"]
        try tapScore(times: 10)
        XCTAssertTrue(meter.waitForExistence(timeout: 5), "Assist did not turn on in single player")

        app.buttons["home"].tap()
        joinOnlineRace(as: "Sim2")
        XCTAssertFalse(meter.exists, "Going online must switch the assist off")
        try tapScore(times: 10)
        XCTAssertFalse(meter.waitForExistence(timeout: 2), "Ten score taps must not turn the assist on online")
        let playArea = app.otherElements["playArea"]
        let value = try XCTUnwrap(playArea.value as? String)
        XCTAssertFalse(value.contains("idealPress"), "VoiceOver would read the ideal press aloud: \(value)")
        XCTAssertEqual(Diagnostics(value)?.trainer, 0)
        finishOnlineRace(as: "Sim2")
        app.buttons["exitOnline"].tap()
    }

    // From the menu: open the lobby, which connects by itself, and set the name.
    private func openRoomList(as name: String) {
        app.buttons["playOnline"].tap()
        XCTAssertTrue(app.buttons["onlineCreate"].waitForExistence(timeout: 10), "Did not connect to a server by itself")
        replaceText(in: app.textFields["onlineName"], with: name)
    }

    // Join the room `host` opened from the room list.
    private func enterRoom(as name: String, host: String) {
        openRoomList(as: name)
        let room = app.buttons["room_\(host)"]
        XCTAssertTrue(room.waitForExistence(timeout: 10), "\(host)'s room is not listed")
        attachScreenshot("1a-rooms")
        room.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onlinePlayers"].waitForExistence(timeout: 10), "Join did not reach the room lobby")
    }

    private func enterPassword(_ password: String, for room: XCUIElement) {
        room.tap()
        let field = app.alerts.textFields["roomPasswordEntry"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No password prompt")
        field.tap()
        field.typeText(password)
        app.alerts.buttons["加入"].tap()
    }

    // Join the waiting bot's room, ready up and wait out the countdown.
    private func joinOnlineRace(as name: String, host: String = "Bot") {
        enterRoom(as: name, host: host)
        let players = app.descendants(matching: .any)["onlinePlayers"]
        XCTAssertTrue(players.label.contains("Bot"), "Bot is not in the room: \(players.label)")
        attachScreenshot("1b-room")
        app.buttons["onlineReady"].tap()
        let standings = app.descendants(matching: .any)["standings"]
        XCTAssertTrue(wait(for: NSPredicate(format: "label CONTAINS %@", "你，\(name)，"), on: standings), "Race did not start")
        sleep(4)
    }

    // Fall on purpose, spectate, and wait for the bot to finish the match.
    private func finishOnlineRace(as name: String) {
        app.otherElements["playArea"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 2.5)
        let detail = app.descendants(matching: .any)["resultDetail"]
        XCTAssertTrue(wait(for: NSPredicate(format: "label CONTAINS 'Bot' AND label CONTAINS %@", name), on: detail, timeout: 40),
                      "No match result")
        // The bot falls last; its fall must finish before the scoreboard covers it.
        XCTAssertEqual(Diagnostics(app.otherElements["playArea"].value)?.racersMoving, 0, "Result appeared mid-fall")
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + text)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settledInitialPlayArea() throws -> XCUIElement {
        let playArea = app.otherElements["playArea"]
        XCTAssertTrue(playArea.waitForExistence(timeout: 10), "Accessible input overlay is missing")
        let settled = NSPredicate { _, _ in
            guard let diagnostics = Diagnostics(playArea.value) else { return false }
            return diagnostics.phase == "ready" && diagnostics.jumps == 0
                && diagnostics.nextY == 0 && diagnostics.nextScale == 1
        }
        XCTAssertTrue(wait(for: settled, on: playArea), "Initial one-time drop did not settle: \(String(describing: playArea.value))")
        return playArea
    }

    @discardableResult
    private func assertJump(afterPressDuration duration: TimeInterval) throws -> XCUIElement {
        let playArea = app.otherElements["playArea"]
        XCTAssertTrue(playArea.waitForExistence(timeout: 10), "Accessible input overlay is missing")

        let ready = NSPredicate { _, _ in
            guard let diagnostics = Diagnostics(playArea.value) else { return false }
            return diagnostics.phase == "ready" && diagnostics.jumps == 0
        }
        XCTAssertTrue(wait(for: ready, on: playArea), "App did not become ready: \(String(describing: playArea.value))")
        XCTAssertTrue((playArea.value as? String)?.hasPrefix("phase=ready;jumps=0;lastPress=0.000;maxHeight=0.000;charge=0.000") == true,
                      "Initial diagnostics prefix changed: \(String(describing: playArea.value))")

        // Release must trigger a jump for a partial charge, not only a full bar.
        playArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: duration)

        // Jump count is updated immediately on release; maxHeight accumulates for
        // that jump and remains observable after landing. Do not wait for a
        // transient phase such as "jumping", which UI snapshots can miss.
        let releasedAndRose = NSPredicate { _, _ in
            guard let diagnostics = Diagnostics(playArea.value) else { return false }
            return diagnostics.jumps == 1
                && diagnostics.lastPress > 0
                && diagnostics.lastPress < 1.5
                && diagnostics.maxHeight > 0
        }
        XCTAssertTrue(wait(for: releasedAndRose, on: playArea), "Partial-charge release did not jump (duration \(duration)): \(String(describing: playArea.value))")

        let diagnostics = try XCTUnwrap(Diagnostics(playArea.value))
        XCTAssertEqual(diagnostics.jumps, 1)
        XCTAssertGreaterThan(diagnostics.lastPress, 0)
        XCTAssertLessThan(diagnostics.lastPress, 1.5)
        XCTAssertGreaterThan(diagnostics.maxHeight, 0)
        return playArea
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private struct Diagnostics {
        let phase: String
        let jumps: Int
        let lastPress: Double
        let maxHeight: Double
        let charge: Double
        let nextID: Int?
        let arrivals: Int?
        let nextY: Double?
        let nextScale: Double?
        let nextMinScale: Double?
        let idealPress: Double?
        let scorePops: Int?
        let popupVisible: Int?
        let trainer: Int?
        let desyncs: Int?
        let racersMoving: Int?

        init?(_ value: Any?) {
            guard let text = value as? String else { return nil }
            var fields: [String: String] = [:]
            for component in text.split(separator: ";") {
                let pair = component.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                fields[String(pair[0])] = String(pair[1])
            }
            guard let phase = fields["phase"],
                  let jumps = fields["jumps"].flatMap(Int.init),
                  let lastPress = fields["lastPress"].flatMap(Double.init),
                  let maxHeight = fields["maxHeight"].flatMap(Double.init),
                  let charge = fields["charge"].flatMap(Double.init) else { return nil }
            self.phase = phase
            self.jumps = jumps
            self.lastPress = lastPress
            self.maxHeight = maxHeight
            self.charge = charge
            self.nextID = fields["nextID"].flatMap(Int.init)
            self.arrivals = fields["arrivals"].flatMap(Int.init)
            self.nextY = fields["nextY"].flatMap(Double.init)
            self.nextScale = fields["nextScale"].flatMap(Double.init)
            self.nextMinScale = fields["nextMinScale"].flatMap(Double.init)
            self.idealPress = fields["idealPress"].flatMap(Double.init)
            self.scorePops = fields["scorePops"].flatMap(Int.init)
            self.popupVisible = fields["popupVisible"].flatMap(Int.init)
            self.trainer = fields["trainer"].flatMap(Int.init)
            self.desyncs = fields["desyncs"].flatMap(Int.init)
            self.racersMoving = fields["racersMoving"].flatMap(Int.init)
        }
    }
}
