import XCTest
@testable import AlmostResetCore

final class ResetDetectorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func time(_ offset: Double) -> Date { epoch.addingTimeInterval(offset) }
    private func window(_ used: Double?, reset: Double? = 100_000, minutes: Int? = 300, limit: String = "codex") -> QuotaWindow {
        QuotaWindow(limitID: limit, windowDurationMins: minutes, usedPercent: used, resetsAt: reset.map(time))
    }
    private func snapshot(_ at: Double, _ windows: [QuotaWindow], account: String = "a", source: String = "local") -> QuotaSnapshot {
        QuotaSnapshot(accountID: account, sourceID: source, fetchedAt: time(at), windows: windows)
    }
    @discardableResult private func read(_ detector: inout ResetDetector, at: Double, _ windows: [QuotaWindow]) -> QuotaResetEvent? {
        detector.ingest(snapshot(at, windows), now: time(at))
    }
    func testAnyIncreaseBeforeExpectedDeadlineTriggers() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(75)])
        let event = read(&detector, at: 20, [window(5, reset: 200_000)])
        XCTAssertEqual(event?.windows.first?.evidence, .allowanceIncrease)
        XCTAssertEqual(event?.windows.first?.previous.remainingPercent, 25)
        XCTAssertEqual(event?.windows.first?.current.remainingPercent, 95)
    }
    func testFractionalIncreaseHasNoMinimumThreshold() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(50)])
        XCTAssertNotNil(read(&detector, at: 20, [window(49.999)]))
    }
    func testSameEarlierOrMissingResetTimeDoesNotBlockIncrease() {
        for reset: Double? in [100_000, 20, nil] {
            var detector = ResetDetector()
            read(&detector, at: 10, [window(90)])
            XCTAssertNotNil(read(&detector, at: 20, [window(89, reset: reset)]))
        }
    }
    func testMissingDurationStillComparesTheSameIdentifiedWindow() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(70, reset: nil, minutes: nil)])
        XCTAssertNotNil(read(&detector, at: 20, [window(60, reset: nil, minutes: nil)]))
    }
    func testTimeMovingAloneAndUnchangedOrDecreasingRemainingDoNotTrigger() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(70, reset: 15)])
        XCTAssertNil(read(&detector, at: 20, [window(70, reset: 200_000)]))
        XCTAssertNil(read(&detector, at: 30, [window(71)]))
        XCTAssertNotNil(read(&detector, at: 40, [window(70.9)]))
    }
    func testLongGapDoesNotSilentlyDiscardAnArmedBaseline() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(70)])
        XCTAssertNotNil(read(&detector, at: 10_000, [window(20)]))
    }
    func testMissingAndInvalidReadingsDoNotOverwriteTheLastValidReading() {
        for invalid: Double? in [nil, .nan, .infinity, -1, 101] {
            var detector = ResetDetector()
            read(&detector, at: 10, [window(70)])
            XCTAssertNil(read(&detector, at: 20, [window(invalid)]))
            XCTAssertNotNil(read(&detector, at: 30, [window(69)]))
        }
    }
    func testTemporaryMissingWindowAndNewWindow() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(80)])
        XCTAssertNil(read(&detector, at: 20, [window(0, limit: "new-pool")]))
        XCTAssertNotNil(read(&detector, at: 30, [window(70)]))
    }
    func testAccountAndSourceChangesEstablishBaselines() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(80)])
        XCTAssertNil(detector.ingest(snapshot(20, [window(0)], account: "b"), now: time(20)))
        XCTAssertNil(detector.ingest(snapshot(30, [window(0)], source: "other"), now: time(30)))
    }
    func testAllPoolsAndSimultaneousWindowsProduceOneEvent() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(70), window(80, minutes: 10_080), window(90, limit: "model-pool")])
        let event = read(&detector, at: 20, [window(69), window(79, minutes: 10_080), window(89, limit: "model-pool")])
        XCTAssertEqual(event?.windows.count, 3)
        XCTAssertEqual(Set(event?.windows.map(\.windowID) ?? []).count, 3)
    }
    func testRepeatedOutOfOrderStaleAndFutureSnapshotsDoNotDuplicateEvents() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(80)])
        XCTAssertNotNil(read(&detector, at: 20, [window(20)]))
        XCTAssertNil(read(&detector, at: 20, [window(20)]))
        XCTAssertNil(read(&detector, at: 19, [window(10)]))
        XCTAssertNil(detector.ingest(snapshot(30, [window(10)]), now: time(500)))
        XCTAssertNil(detector.ingest(snapshot(500, [window(10)]), now: time(30)))
        XCTAssertNil(read(&detector, at: 40, [window(20)]))
    }
    func testPersistedDetectorCanCompareWithoutDroppingItsBaseline() throws {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(80)])
        let state = try JSONDecoder().decode(ResetDetectorState.self, from: JSONEncoder().encode(detector.state))
        var restored = ResetDetector(state: state)
        XCTAssertNotNil(read(&restored, at: 20, [window(20)]))
        restored.requireNewBaseline()
        XCTAssertNil(read(&restored, at: 30, [window(0)]))
    }
    func testConflictingDuplicatesAndEmptyIdentityCannotCreateAnEvent() {
        var detector = ResetDetector()
        read(&detector, at: 10, [window(80)])
        XCTAssertNil(read(&detector, at: 20, [window(1), window(90)]))
        XCTAssertNil(detector.ingest(snapshot(30, [window(0)], account: ""), now: time(30)))
        XCTAssertNotNil(read(&detector, at: 40, [window(70)]))
    }
    func testRemainingPercentRejectsInvalidNumbers() {
        XCTAssertNil(window(nil).remainingPercent)
        XCTAssertNil(window(-1).remainingPercent)
        XCTAssertNil(window(101).remainingPercent)
        XCTAssertNil(window(.nan).remainingPercent)
        XCTAssertEqual(window(56).remainingPercent, 44)
    }
}
