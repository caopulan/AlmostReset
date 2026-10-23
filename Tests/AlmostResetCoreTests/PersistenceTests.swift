import XCTest
@testable import AlmostResetCore

final class PersistenceTests: XCTestCase {
    func testRoundTripPreservesOrderedRulesCheckpointsAndBoundedLogs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppPersistence(directory: directory, maximumLogEntries: 2)
        let empty = try await store.load()
        XCTAssertTrue(empty.rules.isEmpty)
        let first = AutomationRule(name: "First", selector: .sessions(["session-a"]), action: .stop)
        let second = AutomationRule(name: "Second", selector: .conditions(match: .all, conditions: [
            SessionCondition(field: .speed, values: ["fast", "ultrafast"])
        ]), action: .continueSession(ContinuationSettings(reasoning: .low, speed: .normal, prompt: "continue")))
        let logs = (0..<3).map { AutomationLogEntry(date: Date(timeIntervalSince1970: Double($0)), kind: .info, message: "Outcome \($0)") }
        let state = PersistentAppState(rules: [first, second],
                                       resetState: ResetDetectorState(handledBoundaryIDs: ["boundary-a"]), logs: logs)
        try await store.save(state)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.rules, [first, second])
        XCTAssertEqual(loaded.resetState.handledBoundaryIDs, ["boundary-a"])
        XCTAssertEqual(loaded.logs.map(\.message), ["Outcome 1", "Outcome 2"])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptDataIsReportedAndPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.json")
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: url)
        let store = AppPersistence(directory: directory)
        do {
            _ = try await store.load()
            XCTFail("Corrupt persistence must surface its decoding error")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testUnknownSchemaDoesNotSilentlyOverwriteData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppPersistence(directory: directory)
        do {
            try await store.save(PersistentAppState(schemaVersion: 99))
            XCTFail("Newer schema must be rejected")
        } catch PersistenceError.unsupportedSchema(let version) {
            XCTAssertEqual(version, 99)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    }
}
