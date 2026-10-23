import XCTest
@testable import AlmostResetCore

final class RuleEngineTests: XCTestCase {
    private func session(_ id: String = "session-a", model: String? = "model-a",
                         reasoning: ReasoningEffort? = .xhigh, speed: SessionSpeed? = .fast,
                         status: SessionStatus = .running) -> Session {
        Session(id: id, title: "Implement search", projectPath: "/workspace/AlmostReset",
                model: model, reasoning: reasoning, speed: speed, status: status,
                activeTurnID: status == .running ? "turn-a" : nil,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                control: SessionControl(canInterrupt: true, canUpdateSettings: true, canSendPrompt: true))
    }

    func testFirstMatchingRuleWinsAndDuplicateSessionsProduceOneAction() {
        let first = AutomationRule(name: "Stop selected", selector: .sessions(["session-a"]), action: .stop)
        let second = AutomationRule(name: "Reduce fast", selector: .conditions(match: .all, conditions: [
            SessionCondition(field: .speed, values: ["fast", "ultrafast"])
        ]), action: .continueSession(ContinuationSettings(reasoning: .low, speed: .normal)))
        let plan = RuleEngine.plan(rules: [first, second], sessions: [session(), session()])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.ruleID, first.id)
        XCTAssertEqual(plan.first?.action, .stop)
    }

    func testDisabledRuleDoesNotBlockLowerPriorityRule() {
        let first = AutomationRule(name: "Disabled", enabled: false, selector: .sessions(["session-a"]), action: .stop)
        let second = AutomationRule(name: "Continue", selector: .sessions(["session-a"]),
                                    action: .continueSession(ContinuationSettings()))
        XCTAssertEqual(RuleEngine.plan(rules: [first, second], sessions: [session()]).first?.ruleID, second.id)
    }

    func testExecutionPlanPreservesRulePriorityRegardlessOfSessionSort() {
        let first = AutomationRule(name: "Priority", selector: .sessions(["session-b"]), action: .stop)
        let second = AutomationRule(name: "Other", selector: .sessions(["session-a"]), action: .stop)
        XCTAssertEqual(RuleEngine.plan(rules: [first, second], sessions: [session("session-a"), session("session-b")])
            .map(\.session.id), ["session-b", "session-a"])
    }

    func testNewestCompletedDuplicateDoesNotGetRestarted() {
        let stale = session()
        var completed = session(status: .completed)
        completed.updatedAt = stale.updatedAt.addingTimeInterval(10)
        let rule = AutomationRule(name: "Continue", selector: .sessions([stale.id]),
                                  action: .continueSession(ContinuationSettings()))
        XCTAssertTrue(RuleEngine.plan(rules: [rule], sessions: [stale, completed]).isEmpty)
        completed.updatedAt = stale.updatedAt
        XCTAssertTrue(RuleEngine.plan(rules: [rule], sessions: [stale, completed]).isEmpty)
    }

    func testAndOrAndMultiValueConditions() {
        let effort = SessionCondition(field: .reasoning, values: ["xhigh", "ultra"])
        let speed = SessionCondition(field: .speed, values: ["fast", "ultrafast"])
        let both = SessionSelector.conditions(match: .all, conditions: [effort, speed])
        let either = SessionSelector.conditions(match: .any, conditions: [effort, speed])
        XCTAssertTrue(both.matches(session()))
        XCTAssertFalse(both.matches(session(reasoning: .low)))
        XCTAssertTrue(either.matches(session(reasoning: .low)))
        XCTAssertFalse(either.matches(session(reasoning: .low, speed: .normal)))
        XCTAssertFalse(SessionSelector.conditions(match: .all, conditions: []).matches(session()))
    }

    func testMissingConfigurationNeverMatchesAnExplicitValue() {
        let unknown = session(model: nil, reasoning: nil, speed: nil, status: .unknown)
        for field in [SessionField.model, .reasoning, .speed, .status] {
            XCTAssertFalse(SessionCondition(field: field, values: ["", "unknown", "nil"]).matches(unknown))
        }
    }

    func testDefaultScopeDoesNotRestartFinishedOrWaitingSessions() {
        let rule = AutomationRule(name: "Continue selected", selector: .sessions(["session-a"]),
                                  action: .continueSession(ContinuationSettings()))
        XCTAssertTrue(RuleEngine.plan(rules: [rule], sessions: [session(status: .completed)]).isEmpty)
        XCTAssertTrue(RuleEngine.plan(rules: [rule], sessions: [session(status: .waiting)]).isEmpty)
        var explicitlyAll = rule
        explicitlyAll.scope = .all
        XCTAssertEqual(RuleEngine.plan(rules: [explicitlyAll], sessions: [session(status: .completed)]).count, 1)
    }

    func testProjectConditionUsesFullPathNotAmbiguousFolderName() {
        XCTAssertTrue(SessionCondition(field: .project, values: ["/workspace/AlmostReset/"]).matches(session()))
        XCTAssertFalse(SessionCondition(field: .project, values: ["/other/AlmostReset"]).matches(session()))
    }

    func testUnavailableActionDoesNotFallThroughToAnotherRule() {
        var readOnly = session()
        readOnly.control = .readOnly("Owner unavailable")
        let first = AutomationRule(name: "Stop", selector: .sessions([readOnly.id]), action: .stop)
        let fallback = AutomationRule(name: "Continue", selector: .sessions([readOnly.id]),
                                      action: .continueSession(ContinuationSettings()))
        let result = RuleEngine.plan(rules: [first, fallback], sessions: [readOnly])
        XCTAssertEqual(result.first?.ruleID, first.id)
        XCTAssertEqual(result.first?.unavailableReason, "Owner unavailable")
    }

    func testContinueRequiresAllNecessaryCapabilities() {
        var item = session()
        item.control = SessionControl(canInterrupt: false, canUpdateSettings: true, canSendPrompt: true)
        let rule = AutomationRule(name: "Continue", selector: .sessions([item.id]),
                                  action: .continueSession(ContinuationSettings(reasoning: .low)))
        XCTAssertNotNil(RuleEngine.plan(rules: [rule], sessions: [item]).first?.unavailableReason)
        item.control.canInterrupt = true
        XCTAssertNil(RuleEngine.plan(rules: [rule], sessions: [item]).first?.unavailableReason)
    }

    func testDeepLinksAndBareUUIDsResolve() throws {
        let id = "01a1699c-2688-7330-b7b7-1b4ae265a3e6"
        XCTAssertEqual(try SessionReference.sessionID(from: "codex://threads/\(id)?view=review"), id)
        XCTAssertEqual(try SessionReference.sessionID(from: " \(id.uppercased()) "), id)
        XCTAssertThrowsError(try SessionReference.sessionID(from: "https://example.com/\(id)"))
        XCTAssertThrowsError(try SessionReference.sessionID(from: "codex://threads/\(id)/extra"))
        XCTAssertThrowsError(try SessionReference.sessionID(from: "codex://threads/invalid"))
    }

    func testSearchAndPromptFallback() {
        XCTAssertTrue(session().matchesSearch("almostreset XHIGH"))
        XCTAssertFalse(session().matchesSearch("unrelated"))
        XCTAssertEqual(ContinuationSettings(prompt: " \n ").effectivePrompt, "继续")
        XCTAssertEqual(ContinuationSettings(prompt: " continue ").effectivePrompt, "continue")
    }
}
