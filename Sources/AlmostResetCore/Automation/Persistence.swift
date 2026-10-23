import Foundation

public enum AutomationLogKind: String, Codable, Sendable {
    case reset, planned, succeeded, failed, skipped, info
}

public struct AutomationLogEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: AutomationLogKind
    public var message: String
    public var eventID: UUID?
    public var sessionID: String?
    public var ruleID: UUID?

    public init(id: UUID = UUID(), date: Date = Date(), kind: AutomationLogKind,
                message: String, eventID: UUID? = nil, sessionID: String? = nil, ruleID: UUID? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.message = message
        self.eventID = eventID
        self.sessionID = sessionID
        self.ruleID = ruleID
    }
}

public struct PersistentAppState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var rules: [AutomationRule]
    public var resetState: ResetDetectorState
    public var logs: [AutomationLogEntry]

    public init(schemaVersion: Int = 3, rules: [AutomationRule] = [],
                resetState: ResetDetectorState = ResetDetectorState(), logs: [AutomationLogEntry] = []) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.resetState = resetState
        self.logs = logs
    }
}

public enum PersistenceError: Error, LocalizedError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "AlmostReset data version \(version) is not supported by this app."
        }
    }
}

/// Stores only rules, reset checkpoints, and concise action outcomes. Never store credentials
/// or copied session transcripts here. A failed read is surfaced without overwriting the file.
public actor AppPersistence {
    public let directory: URL
    private let fileURL: URL
    private let maximumLogEntries: Int

    public init(directory: URL? = nil, maximumLogEntries: Int = 500) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlmostReset", isDirectory: true)
        self.fileURL = self.directory.appendingPathComponent("state.json")
        self.maximumLogEntries = max(1, maximumLogEntries)
    }

    public func load() throws -> PersistentAppState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return PersistentAppState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var state = try decoder.decode(PersistentAppState.self, from: Data(contentsOf: fileURL))
        guard (1...3).contains(state.schemaVersion) else { throw PersistenceError.unsupportedSchema(state.schemaVersion) }
        // Version 3 adds per-row boolean connectors; older apps must reject them.
        state.schemaVersion = 3
        return state
    }

    /// Persist the detector checkpoint before invoking external actions. A crash then cannot
    /// repeat a destructive action. An unfinished execution remains visible in the audit log.
    public func save(_ state: PersistentAppState) throws {
        guard state.schemaVersion == 3 else { throw PersistenceError.unsupportedSchema(state.schemaVersion) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var bounded = state
        bounded.logs = Array(state.logs.suffix(maximumLogEntries))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bounded).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func appendLog(_ entry: AutomationLogEntry) throws {
        var state = try load()
        state.logs.append(entry)
        try save(state)
    }
}
