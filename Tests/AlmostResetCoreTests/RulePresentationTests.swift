import XCTest
@testable import AlmostResetCore

final class RulePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(_ id: String, model: String = "gpt-6-astra", speed: SessionSpeed = .fast,
                         status: SessionStatus = .running, age: TimeInterval = 0) -> Session {
        Session(id: id, title: id, projectPath: "/workspace/project", model: model, reasoning: .high,
                speed: speed, status: status, updatedAt: now.addingTimeInterval(-age))
    }
    func testStopAstraPresetUsesExactModelAndStop() {
        let preset = RulePreset.stopAstra.configuration()
        XCTAssertEqual(preset.match, .all)
        XCTAssertEqual(preset.action, .stop)
        let selector = SessionSelector.conditions(match: preset.match, conditions: preset.conditions)
        XCTAssertTrue(selector.matches(session("a")))
        XCTAssertFalse(selector.matches(session("b", model: "gpt-6.1-sol")))
        XCTAssertFalse(selector.matches(session("c", model: "gpt-6-sol")))
    }
    func testFastToStandardPresetPreservesModelAndReasoning() throws {
        let preset = RulePreset.standardFastSessions.configuration(prompt: "continue")
        guard case .continueSession(let action) = preset.action else { return XCTFail("Expected continuation") }
        XCTAssertNil(action.model); XCTAssertNil(action.reasoning)
        XCTAssertEqual(action.speed, .normal); XCTAssertEqual(action.prompt, "continue")
        let selector = SessionSelector.conditions(match: preset.match, conditions: preset.conditions)
        XCTAssertTrue(selector.matches(session("fast", model: "gpt-6-sol")))
        XCTAssertFalse(selector.matches(session("standard", speed: .normal)))
        XCTAssertFalse(selector.matches(session("ultrafast", speed: .ultrafast)))
    }
    func testAstraToSolUsesSixSolNotSixPointOneAndXhigh() {
        let preset = RulePreset.astraToSol.configuration()
        guard case .continueSession(let action) = preset.action else { return XCTFail("Expected continuation") }
        XCTAssertEqual(action.model, "gpt-6-sol")
        XCTAssertEqual(action.reasoning, .xhigh)
        XCTAssertNil(action.speed)
        XCTAssertEqual(action.prompt, "继续")
        XCTAssertEqual(preset.conditions.first?.values, ["gpt-6-astra"])
    }
    func testPresetsAreIndependentEditableDrafts() {
        let original = RulePreset.astraToSol.configuration()
        var edited = RulePreset.astraToSol.configuration()
        XCTAssertTrue(original.matchesDraft(match: edited.match, conditions: edited.conditions, action: edited.action))
        edited.conditions[0].values = ["gpt-6.1-sol"]
        XCTAssertFalse(original.matchesDraft(match: edited.match, conditions: edited.conditions, action: edited.action))
        XCTAssertEqual(RulePreset.astraToSol.configuration().conditions[0].values, ["gpt-6-astra"])
    }
    func testHoverCountIncludesRunningAndRecentButNotOlderSessions() {
        let selector = SessionSelector.conditions(match: .all, conditions: [SessionCondition(field: .model, values: ["gpt-6-astra"])])
        let matches = RuleInspection.sessions(for: selector, in: [
            session("running", age: 9000), session("recent", status: .idle, age: 1500),
            session("boundary", status: .completed, age: 1800), session("old", status: .completed, age: 1801),
            session("different", model: "gpt-6-sol"), session("running", age: 9000)
        ], now: now)
        XCTAssertEqual(matches.map(\.id), ["running", "recent", "boundary"])
    }
    func testExplicitSelectorAndDuplicateFreshness() {
        let selector = SessionSelector.sessions(["a", "b"])
        let old = session("a", age: 4000)
        let newer = session("a", status: .completed, age: 1900)
        XCTAssertTrue(RuleInspection.sessions(for: selector, in: [old, newer, session("c")], now: now).isEmpty)
        XCTAssertEqual(RuleInspection.sessions(for: selector, in: [session("b", status: .idle, age: 10)], now: now).map(\.id), ["b"])
    }
    func testRuleCanBeCreatedWithoutANameAndPlanUsesPriorityReference() {
        let rule = AutomationRule(selector: .sessions(["a"]), action: .stop)
        XCTAssertEqual(rule.name, "")
        let disabled = AutomationRule(name: "legacy", enabled: false, selector: .sessions(["a"]), action: .stop)
        let plan = RuleEngine.plan(rules: [disabled, rule], sessions: [session("a")])
        XCTAssertEqual(plan.first?.ruleName, "#2")
    }
}
