import Foundation
import Darwin
import CryptoKit

public struct AuditSession: Codable, Sendable {
    public let id: String
    public let title: String
    public let projectPath: String
    public let status: SessionStatus
    public let model: String?
    public let reasoning: ReasoningEffort?
    public let speed: SessionSpeed?
    public let activeTurnID: String?
    public let updatedAt: Date
    public let controllable: Bool
    public let canInterrupt: Bool
    public let canUpdateSettings: Bool
    public let canSendPrompt: Bool
    public let controlReason: String?
    public let liveConfirmed: Bool?
    public init(_ session: Session, liveConfirmed: Bool? = nil) {
        self.liveConfirmed = liveConfirmed
        id = session.id; title = AuditPrivacy.clean(session.title, limit: 512)
        projectPath = AuditPrivacy.clean(session.projectPath, limit: 1024)
        status = session.status; model = session.model; reasoning = session.reasoning
        speed = session.speed; activeTurnID = session.activeTurnID; updatedAt = session.updatedAt
        controllable = session.control.isAvailable
        canInterrupt = session.control.canInterrupt; canUpdateSettings = session.control.canUpdateSettings
        canSendPrompt = session.control.canSendPrompt
        controlReason = session.control.unavailableReason.map { AuditPrivacy.clean($0) }
    }
}

public struct AuditAction: Codable, Sendable {
    public let kind: String
    public let model: String?
    public let reasoning: ReasoningEffort?
    public let speed: SessionSpeed?
    public let promptBytes: Int?
    public let promptSHA256: String?
    public init(_ action: SessionAction) {
        switch action {
        case .stop: kind = "stop"; model = nil; reasoning = nil; speed = nil; promptBytes = nil; promptSHA256 = nil
        case .continueSession(let settings):
            kind = "continue"; model = settings.model; reasoning = settings.reasoning
            speed = settings.speed; promptBytes = settings.effectivePrompt.utf8.count
            promptSHA256 = SHA256.hash(data: Data(settings.effectivePrompt.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

public struct AuditRule: Codable, Sendable {
    public let id: UUID
    public let enabled: Bool
    public let scope: SessionScope
    public let selector: SessionSelector
    public let action: AuditAction
    public init(_ rule: AutomationRule) {
        id = rule.id; enabled = rule.enabled; scope = rule.scope
        selector = rule.selector; action = AuditAction(rule.action)
    }
}

public struct ExecutionRecord: Codable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var date = Date()
    public var runID: UUID?
    public var appVersion: String?
    public var kind: String
    public var eventID: UUID?
    public var sessionID: String?
    public var ruleID: UUID?
    public var message: String?
    public var fields: [String: String]
    public var sessions: [AuditSession]
    public var rules: [AuditRule]
    public var quotaChanges: [QuotaResetWindow] = []
    public init(kind: String, eventID: UUID? = nil, sessionID: String? = nil, ruleID: UUID? = nil,
                message: String? = nil, fields: [String: String] = [:], sessions: [Session] = [], rules: [AutomationRule] = []) {
        self.kind = kind; self.eventID = eventID; self.sessionID = sessionID; self.ruleID = ruleID
        self.message = message; self.fields = fields
        self.sessions = sessions.map { AuditSession($0) }; self.rules = rules.map(AuditRule.init)
    }
    public mutating func sanitize(sensitiveTexts: [String] = []) {
        message = message.map { AuditPrivacy.clean($0, sensitiveTexts: sensitiveTexts) }
        fields = Dictionary(uniqueKeysWithValues: fields.map { key, value in
            let sensitive = ["error", "message", "reason", "warning", "issue"].contains { key.lowercased().contains($0) }
            return (key, AuditPrivacy.clean(value, sensitiveTexts: sensitive ? sensitiveTexts : []))
        })
    }
}

public enum AuditPrivacy {
    public static func clean(_ text: String, sensitiveTexts: [String] = [], limit: Int = 4096) -> String {
        var value = text
        for secret in sensitiveTexts where !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "[redacted]") }
        for pattern in ["(?i)Bearer\\s+[A-Za-z0-9._~+/=-]+", "sk-[A-Za-z0-9_-]{16,}", "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "(?i)(?:access_token|refresh_token|id_token|api_key|password)[\\\"'\\s:=]+[^\\s\\\"',;&}]+"] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(value.prefix(limit))
    }
}

public enum ExecutionJournalError: Error, LocalizedError {
    case unsafePath, recordTooLarge, io(Int32)
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "Execution log location is not a regular file or directory."
        case .recordTooLarge: return "Execution log record exceeded the file size limit."
        case .io(let code): return "Execution log I/O failed: " + String(cString: strerror(code))
        }
    }
}

/// Append-only JSONL, bounded to eight 4 MiB files / fourteen days by default.
/// The interprocess lock covers rotation and appending, including updater overlap.
public actor ExecutionJournal {
    public let directory: URL
    private let maximumBytes: Int
    private let maximumFiles: Int
    private let retentionDays: Int
    public init(directory: URL? = nil, maximumBytes: Int = 4 * 1024 * 1024, maximumFiles: Int = 8, retentionDays: Int = 14) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AlmostReset", isDirectory: true)
        self.maximumBytes = max(1024, maximumBytes); self.maximumFiles = max(1, maximumFiles); self.retentionDays = max(1, retentionDays)
    }
    public func append(_ record: ExecutionRecord, now: Date = Date()) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            guard try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else { throw ExecutionJournalError.unsafePath }
        } else { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lock = open(directory.appendingPathComponent(".execution.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ExecutionJournalError.io(errno) }
        defer { _ = flock(lock, LOCK_UN); Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw ExecutionJournalError.io(errno) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer(); try container.encode(formatter.string(from: date))
        }
        var sanitized = record; sanitized.sanitize()
        var data = try encoder.encode(sanitized); data.append(10)
        guard data.count <= maximumBytes else { throw ExecutionJournalError.recordTooLarge }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        let file = directory.appendingPathComponent("execution-\(day).jsonl")
        if fm.fileExists(atPath: file.path) {
            let attributes = try fm.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ExecutionJournalError.unsafePath }
            if (attributes[.size] as? NSNumber)?.intValue ?? 0 > maximumBytes - data.count {
                try fm.moveItem(at: file, to: directory.appendingPathComponent("execution-\(day)-\(UUID().uuidString).jsonl"))
            }
        }
        let fd = open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ExecutionJournalError.io(errno) }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw ExecutionJournalError.io(errno) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ExecutionJournalError.io(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ExecutionJournalError.io(errno) }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix("execution-") && $0.pathExtension == "jsonl" }
        var retained: [(URL, Date)] = []
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        for url in files {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let dateText = String(url.lastPathComponent.dropFirst("execution-".count).prefix(10))
            guard let date = formatter.date(from: dateText) else { continue }
            if date < cutoff && url != file { try fm.removeItem(at: url) }
            else { retained.append((url, values.contentModificationDate ?? .distantPast)) }
        }
        retained.sort { a, b in
            if a.0 == b.0 { return false }
            if a.0 == file { return true }; if b.0 == file { return false }
            return a.1 > b.1
        }
        for item in retained.dropFirst(maximumFiles) { try fm.removeItem(at: item.0) }
    }
}
