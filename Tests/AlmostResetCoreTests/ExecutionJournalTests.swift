import XCTest
@testable import AlmostResetCore

final class ExecutionJournalTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func files(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    }
    func testAppendProducesIndependentJSONLinesAndPrivatePermissions() async throws {
        let dir = try directory(); let journal = ExecutionJournal(directory: dir)
        let event = UUID()
        try await journal.append(ExecutionRecord(kind: "command.started", eventID: event, sessionID: "one", message: "第一行\n第二行"))
        try await journal.append(ExecutionRecord(kind: "command.acknowledged", eventID: event, sessionID: "one"))
        let file = try XCTUnwrap(files(dir).first)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(row["eventID"] as? String, event.uuidString)
            XCTAssertTrue((row["date"] as? String)?.contains(".") == true)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
    }
    func testRotationBoundsFileCountAndSize() async throws {
        let dir = try directory(); let journal = ExecutionJournal(directory: dir, maximumBytes: 1024, maximumFiles: 3)
        for i in 0..<12 { try await journal.append(ExecutionRecord(kind: "test", message: String(repeating: "x", count: 450), fields: ["sequence": "\(i)"])) }
        let logs = try files(dir)
        XCTAssertEqual(logs.count, 3)
        for file in logs { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1024) }
        let contents = try logs.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(contents.contains("\"sequence\":\"11\""))
    }
    func testRetentionPrunesExpiredLogsButNotUnrelatedFiles() async throws {
        let dir = try directory(); let journal = ExecutionJournal(directory: dir)
        let now = Date()
        try await journal.append(ExecutionRecord(kind: "old"), now: now.addingTimeInterval(-20 * 86400))
        try Data("keep".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try await journal.append(ExecutionRecord(kind: "new"), now: now)
        XCTAssertEqual(try files(dir).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }
    func testPromptAndCredentialsDoNotEnterLog() async throws {
        let dir = try directory(); let journal = ExecutionJournal(directory: dir)
        let prompt = "PRIVATE_PROMPT_123456"
        let rule = AutomationRule(selector: .sessions(["one"]), action: .continueSession(.init(model: "gpt-6-sol", prompt: prompt)))
        var record = ExecutionRecord(kind: "command.failed", message: "Bearer abcdefghijklmnop " + prompt,
            fields: ["error": "refresh_token=very-secret", "count": "1"], rules: [rule])
        record.sanitize(sensitiveTexts: [prompt])
        try await journal.append(record)
        let text = try String(contentsOf: XCTUnwrap(files(dir).first), encoding: .utf8)
        XCTAssertFalse(text.contains(prompt)); XCTAssertFalse(text.contains("abcdefghijklmnop")); XCTAssertFalse(text.contains("very-secret"))
        XCTAssertTrue(text.contains("gpt-6-sol")); XCTAssertTrue(text.contains("promptBytes"))
    }
    func testConcurrentWritersKeepWholeRecords() async throws {
        let dir = try directory()
        let first = ExecutionJournal(directory: dir); let second = ExecutionJournal(directory: dir)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let writer = index.isMultiple(of: 2) ? first : second
                    try await writer.append(ExecutionRecord(kind: "concurrent", fields: ["index": String(index)]))
                }
            }
            try await group.waitForAll()
        }
        let lines = try files(dir).flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
        XCTAssertEqual(lines.count, 40)
        for line in lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
    }
    func testUnsafeDirectoryIsRejected() async throws {
        let dir = try directory(); let path = dir.appendingPathComponent("file")
        try Data("original".utf8).write(to: path)
        let journal = ExecutionJournal(directory: path)
        do { try await journal.append(ExecutionRecord(kind: "test")); XCTFail("Should fail") }
        catch ExecutionJournalError.unsafePath { }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "original")
    }
}
