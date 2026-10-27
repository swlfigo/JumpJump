import XCTest

final class JumpJumpUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
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

    private func wait(for predicate: NSPredicate, on element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
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
        }
    }
}
