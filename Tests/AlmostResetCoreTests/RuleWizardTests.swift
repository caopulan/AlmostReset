import XCTest
@testable import AlmostResetCore

final class RuleWizardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(_ effort: ReasoningEffort? = nil, status: SessionStatus = .idle, age: TimeInterval = 0) -> Session {
        Session(id: "session", title: "Task", projectPath: "/workspace", reasoning: effort, status: status, updatedAt: now.addingTimeInterval(-age))
    }
    func testReasoningMoreThanIsStrictAndOrdered() {
        let condition = SessionCondition(field: .reasoning, values: ["high"], comparison: .moreThan)
        for effort in ReasoningEffort.allCases {
            XCTAssertEqual(condition.matches(session(effort)), [.xhigh, .max, .ultra].contains(effort))
        }
        XCTAssertFalse(condition.matches(session(nil)))
        XCTAssertFalse(SessionCondition(field: .reasoning, values: ["ultra"], comparison: .moreThan).matches(session(.ultra)))
        XCTAssertTrue(SessionCondition(field: .reasoning, values: ["none"], comparison: .moreThan).matches(session(.minimal)))
    }
    func testInvalidGreaterThanDoesNotMatch() {
        XCTAssertFalse(SessionCondition(field: .model, values: ["high"], comparison: .moreThan).matches(session(.ultra)))
        XCTAssertFalse(SessionCondition(field: .reasoning, values: ["low", "high"], comparison: .moreThan).matches(session(.ultra)))
        XCTAssertFalse(SessionCondition(field: .reasoning, values: ["future-level"], comparison: .moreThan).matches(session(.ultra)))
    }
    func testLegacyConditionDefaultsToEqualityWithoutLosingIdentity() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "field": "reasoning", "values": ["high"]])
        let condition = try JSONDecoder().decode(SessionCondition.self, from: data)
        XCTAssertEqual(condition.id, id)
        XCTAssertEqual(condition.comparison, .equals)
        XCTAssertTrue(condition.matches(session(.high)))
        XCTAssertFalse(condition.matches(session(.xhigh)))
        let greater = SessionCondition(field: .reasoning, values: ["high"], comparison: .moreThan)
        XCTAssertEqual(try JSONDecoder().decode(SessionCondition.self, from: JSONEncoder().encode(greater)), greater)
    }
    func testRunningPlusThirtyMinuteBoundary() {
        XCTAssertTrue(session(status: .running, age: 100_000).isRecentOrRunning(at: now))
        XCTAssertTrue(session(status: .completed, age: 1799).isRecentOrRunning(at: now))
        XCTAssertTrue(session(status: .idle, age: 1800).isRecentOrRunning(at: now))
        XCTAssertFalse(session(status: .idle, age: 1801).isRecentOrRunning(at: now))
        XCTAssertFalse(session(status: .waiting, age: 4000).isRecentOrRunning(at: now))
        XCTAssertFalse(session(age: -60).isRecentOrRunning(at: now))
        XCTAssertTrue(SessionScope.recent.includes(session(age: 1200), now: now))
        XCTAssertFalse(SessionScope.recent.includes(session(age: 3600), now: now))
    }
    func testEqualityAndGreaterThanCanCombineWithSpeed() {
        var candidate = session(.max, status: .running)
        candidate.speed = .fast
        let selector = SessionSelector.conditions(match: .all, conditions: [
            SessionCondition(field: .reasoning, values: ["high"], comparison: .moreThan),
            SessionCondition(field: .speed, values: ["fast", "ultrafast"])
        ])
        XCTAssertTrue(selector.matches(candidate))
        candidate.speed = .normal
        XCTAssertFalse(selector.matches(candidate))
    }
    func testChineseAndEnglishStringsAndCompactDescriptions() {
        XCTAssertEqual(UIStrings.value("Next", language: .chinese), "下一步")
        XCTAssertEqual(UIStrings.value("Next", language: .english), "Next")
        XCTAssertEqual(UIStrings.value("continue", language: .chinese), "继续")
        XCTAssertEqual(UIStrings.value("continue", language: .english), "continue")
        XCTAssertLessThan(UIStrings.value("Pick exact tasks", language: .chinese).count, 10)
        XCTAssertLessThan(UIStrings.value("Match tasks automatically", language: .chinese).count, 10)
        for key in ["Rules", "Sessions", "Settings", "Stop", "Next", "Back", "Create rule", "more than", "Match preview"] {
            XCTAssertNotEqual(UIStrings.value(key, language: .chinese), key)
        }
    }
    func testVersionOneRulesMigrateAndNewDocumentsPreventSilentDowngrades() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rule = AutomationRule(name: "Existing", selector: .conditions(match: .all, conditions: [SessionCondition(field: .reasoning, values: ["high"])]), action: .stop)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let file = directory.appendingPathComponent("state.json")
        try encoder.encode(PersistentAppState(schemaVersion: 1, rules: [rule])).write(to: file)
        let store = AppPersistence(directory: directory)
        let migrated = try await store.load()
        XCTAssertEqual(migrated.rules, [rule])
        XCTAssertEqual(migrated.schemaVersion, 3)
        try await store.save(migrated)
        let serialized = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(serialized["schemaVersion"] as? Int, 3)
    }

}
