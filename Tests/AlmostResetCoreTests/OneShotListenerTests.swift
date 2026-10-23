import XCTest
@testable import AlmostResetCore

final class OneShotListenerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func snapshot(_ at: Double, _ used: Double, weekly: Double? = nil) -> QuotaSnapshot {
        var windows = [QuotaWindow(limitID: "codex", windowDurationMins: 300, usedPercent: used)]
        if let weekly { windows.append(QuotaWindow(limitID: "codex", windowDurationMins: 10080, usedPercent: weekly)) }
        return QuotaSnapshot(accountID: "a", sourceID: "local", fetchedAt: epoch.addingTimeInterval(at), windows: windows)
    }
    @discardableResult private func read(_ listener: inout OneShotListener, _ at: Double, _ used: Double, weekly: Double? = nil) -> QuotaResetEvent? {
        listener.observe(snapshot(at, used, weekly: weekly), now: epoch.addingTimeInterval(at))
    }
    func testIdleNeverTriggersAndNewStartIgnoresOffPeriodChanges() {
        var listener = OneShotListener()
        XCTAssertNil(read(&listener, 10, 80))
        XCTAssertNil(read(&listener, 20, 10))
        listener.arm(baseline: snapshot(20, 10), now: epoch.addingTimeInterval(20))
        XCTAssertEqual(listener.phase, .listening)
        XCTAssertNil(read(&listener, 30, 10))
        XCTAssertNotNil(read(&listener, 40, 9))
    }
    func testFirstResetConsumesListeningBeforeActionsFinish() {
        var listener = OneShotListener()
        listener.arm(baseline: snapshot(10, 80, weekly: 90), now: epoch.addingTimeInterval(10))
        let generation = listener.generation
        XCTAssertNotNil(read(&listener, 20, 70, weekly: 90))
        XCTAssertEqual(listener.phase, .executing)
        XCTAssertFalse(listener.isListening)
        XCTAssertNil(read(&listener, 30, 60, weekly: 10))
        listener.finish(generation: generation)
        XCTAssertEqual(listener.phase, .completed)
        XCTAssertNil(read(&listener, 40, 50))
    }
    func testExplicitRearmCanTriggerAnotherIncrease() {
        var listener = OneShotListener()
        listener.arm(baseline: snapshot(10, 80), now: epoch.addingTimeInterval(10))
        read(&listener, 20, 70)
        listener.finish(generation: listener.generation)
        listener.arm(baseline: snapshot(30, 50), now: epoch.addingTimeInterval(30))
        XCTAssertNil(read(&listener, 40, 50))
        XCTAssertNotNil(read(&listener, 50, 49))
    }
    func testStopAndLateCompletionCannotRearmOrOverwriteANewRun() {
        var listener = OneShotListener()
        listener.arm(baseline: snapshot(10, 80), now: epoch.addingTimeInterval(10))
        let old = listener.generation
        read(&listener, 20, 70)
        listener.stop()
        listener.arm(baseline: snapshot(30, 50), now: epoch.addingTimeInterval(30))
        listener.finish(generation: old)
        XCTAssertEqual(listener.phase, .listening)
        XCTAssertNotNil(read(&listener, 40, 49))
    }
    func testStartupIsUnarmedEvenWithPersistedPriorReadings() {
        var old = OneShotListener()
        old.arm(baseline: snapshot(10, 90), now: epoch.addingTimeInterval(10))
        var restarted = OneShotListener(detectorState: old.detector.state)
        XCTAssertEqual(restarted.phase, .idle)
        XCTAssertNil(read(&restarted, 20, 0))
    }
    func testMissingOrStaleInitialQuotaWaitsForFreshBaseline() {
        var listener = OneShotListener()
        listener.arm(baseline: snapshot(10, 90), now: epoch.addingTimeInterval(500))
        XCTAssertEqual(listener.phase, .preparing)
        XCTAssertNil(read(&listener, 510, 5))
        XCTAssertEqual(listener.phase, .listening)
        XCTAssertNotNil(read(&listener, 520, 4.99))
    }
    func testCannotStartAnotherCycleDuringExecution() {
        var listener = OneShotListener()
        listener.arm(baseline: snapshot(10, 90), now: epoch.addingTimeInterval(10))
        read(&listener, 20, 80)
        let generation = listener.generation
        listener.arm(baseline: snapshot(30, 70), now: epoch.addingTimeInterval(30))
        XCTAssertEqual(listener.phase, .executing)
        XCTAssertEqual(listener.generation, generation)
    }
    func testPreStartInFlightReadingCannotTriggerOrEstablishBaseline() {
        var listener = OneShotListener()
        listener.arm(baseline: snapshot(10, 80), now: epoch.addingTimeInterval(20))
        XCTAssertEqual(listener.phase, .preparing)
        XCTAssertNil(read(&listener, 15, 10))
        XCTAssertEqual(listener.phase, .preparing)
        XCTAssertNil(read(&listener, 30, 10))
        XCTAssertEqual(listener.phase, .listening)
        XCTAssertNotNil(read(&listener, 40, 9))
    }

}
