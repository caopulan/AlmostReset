import XCTest
@testable import AlmostResetCore

final class RuleImpactTests: XCTestCase {
    func testRecentlyFinishedSessionIsActiveButNotRunning() {
        let now = Date()
        let session = Session(id: "recent", title: "recent", projectPath: "", status: .completed,
                              updatedAt: now.addingTimeInterval(-60))
        let impact = RuleImpact(rules: [], sessions: [session], now: now)
        XCTAssertEqual(impact.total, 1)
        XCTAssertEqual(impact.running, 0)
        XCTAssertEqual(impact.unaffected, 1)
        XCTAssertEqual(impact.stopped + impact.continued + impact.unaffected, impact.total)
        XCTAssertEqual(RuleImpact(rules: [], sessions: [session], now: now.addingTimeInterval(1801)).total, 0)
    }

    func testMixedConditionsUseAndPrecedenceAndRoundTrip() throws {
        let rows = [SessionCondition(field: .model, values: ["astra"]),
                    SessionCondition(field: .speed, values: ["fast"], joinWithPrevious: .any),
                    SessionCondition(field: .reasoning, values: ["high"], joinWithPrevious: .all)]
        let selector = SessionSelector.conditions(match: .all, conditions: rows)
        let restored = try JSONDecoder().decode(SessionSelector.self, from: JSONEncoder().encode(selector))
        let astra = Session(id: "a", title: "a", projectPath: "", model: "astra", reasoning: .low, speed: .normal)
        let fastHigh = Session(id: "b", title: "b", projectPath: "", model: "sol", reasoning: .high, speed: .fast)
        var fastLow = fastHigh; fastLow.reasoning = .low
        XCTAssertTrue(restored.matches(astra))
        XCTAssertTrue(restored.matches(fastHigh))
        XCTAssertFalse(restored.matches(fastLow))
    }
    func testImpactHonorsPriorityEligibilityCapabilitiesAndDeduplication() {
        let now = Date()
        func session(_ id: String, status: SessionStatus = .running, age: Double = 0, available: Bool = true) -> Session {
            Session(id: id, title: id, projectPath: "", status: status, updatedAt: now.addingTimeInterval(-age),
                    control: SessionControl(canInterrupt: available, canUpdateSettings: available, canSendPrompt: available))
        }
        let a = session("a")
        let sessions = [a, a, session("b"), session("c", available: false), session("d", status: .completed), session("old", status: .completed, age: 1801)]
        let rules = [AutomationRule(selector: .sessions(["a", "c"]), action: .stop),
                     AutomationRule(selector: .sessions(["a", "b"]), action: .continueSession(.init()))]
        let result = RuleImpact(rules: rules, sessions: sessions, now: now)
        XCTAssertEqual(result.total, 4)
        XCTAssertEqual(result.running, 3)
        XCTAssertEqual(result.stopped, 1)
        XCTAssertEqual(result.continued, 1)
        XCTAssertEqual(result.unaffected, 2)
    }
}
