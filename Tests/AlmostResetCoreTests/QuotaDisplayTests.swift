import XCTest
@testable import AlmostResetCore

final class QuotaDisplayTests: XCTestCase {
    private func reading(_ used: Double?, account: String = "a") -> QuotaSnapshot {
        QuotaSnapshot(accountID: account, sourceID: "local", fetchedAt: Date(timeIntervalSince1970: 100),
                      windows: [QuotaWindow(limitID: "codex", usedPercent: used)])
    }
    func testFailureKeepsOriginalValueAndTimestampUntilRecovery() {
        var state = QuotaDisplayState()
        let good = reading(17)
        XCTAssertTrue(state.receive(good))
        XCTAssertFalse(state.receive(nil))
        XCTAssertEqual(state.snapshot, good)
        XCTAssertTrue(state.isStale)
        XCTAssertFalse(state.receive(reading(.nan)))
        XCTAssertEqual(state.snapshot, good)
        XCTAssertTrue(state.receive(reading(18)))
        XCTAssertEqual(state.snapshot?.windows.first?.remainingPercent, 82)
        XCTAssertFalse(state.isStale)
    }
    func testInitialFailureDoesNotInventUsageAndAccountSwitchReplacesCache() {
        var state = QuotaDisplayState()
        XCTAssertFalse(state.receive(nil)); XCTAssertNil(state.snapshot)
        XCTAssertTrue(state.receive(reading(17)))
        XCTAssertTrue(state.receive(reading(50, account: "b")))
        XCTAssertEqual(state.snapshot?.accountID, "b")
        XCTAssertEqual(state.snapshot?.windows.first?.remainingPercent, 50)
        state.markUnavailable()
        XCTAssertTrue(state.isStale)
    }
    func testReadRecoveryIsBoundedAndResetsAfterSuccess() {
        var recovery = RefreshRecovery()
        XCTAssertEqual(recovery.nextDelay(), 2)
        XCTAssertEqual(recovery.nextDelay(), 5)
        XCTAssertNil(recovery.nextDelay())
        XCTAssertNil(recovery.nextDelay())
        recovery.reset()
        XCTAssertEqual(recovery.nextDelay(), 2)
    }
}
