import Foundation

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none, minimal, low, medium, high, xhigh, max, ultra

    public var rank: Int { Self.allCases.firstIndex(of: self)! }
}

public enum SessionSpeed: String, Codable, CaseIterable, Sendable {
    case normal, fast, ultrafast
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case running, waiting, idle, completed, unknown

    public var isActive: Bool { self == .running || self == .waiting }
}

public struct SessionControl: Codable, Equatable, Sendable {
    public var canInterrupt: Bool
    public var canUpdateSettings: Bool
    public var canSendPrompt: Bool
    public var unavailableReason: String?

    public init(canInterrupt: Bool = false, canUpdateSettings: Bool = false,
                canSendPrompt: Bool = false, unavailableReason: String? = nil) {
        self.canInterrupt = canInterrupt
        self.canUpdateSettings = canUpdateSettings
        self.canSendPrompt = canSendPrompt
        self.unavailableReason = unavailableReason
    }

    public static func readOnly(_ reason: String) -> SessionControl {
        SessionControl(unavailableReason: reason)
    }

    public var isAvailable: Bool { canInterrupt || canUpdateSettings || canSendPrompt }
}

public struct Session: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var projectPath: String
    public var model: String?
    public var reasoning: ReasoningEffort?
    public var speed: SessionSpeed?
    public var status: SessionStatus
    public var activeTurnID: String?
    public var updatedAt: Date
    public var control: SessionControl

    public init(id: String, title: String, projectPath: String,
                model: String? = nil, reasoning: ReasoningEffort? = nil,
                speed: SessionSpeed? = nil, status: SessionStatus = .unknown,
                activeTurnID: String? = nil, updatedAt: Date = Date(),
                control: SessionControl = SessionControl()) {
        self.id = id
        self.title = title
        self.projectPath = projectPath
        self.model = model
        self.reasoning = reasoning
        self.speed = speed
        self.status = status
        self.activeTurnID = activeTurnID
        self.updatedAt = updatedAt
        self.control = control
    }

    /// A running session stays selectable regardless of its last persisted timestamp.
    /// Other sessions expire after thirty minutes; future or absent timestamps are not activity.
    public func isRecentOrRunning(at now: Date = Date()) -> Bool {
        if status == .running { return true }
        let age = now.timeIntervalSince(updatedAt)
        return age >= 0 && age <= 30 * 60 && updatedAt.timeIntervalSince1970 > 0
    }

    public var projectName: String {
        projectPath.isEmpty ? "Unknown project" : URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public var deepLink: URL? {
        URL(string: "codex://threads/\(id)")
    }

    public func matchesSearch(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let searchable = [id, title, projectPath, model ?? "", reasoning?.rawValue ?? "", speed?.rawValue ?? ""]
            .joined(separator: " ")
        return terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
    }
}

public enum SessionReferenceError: Error, LocalizedError {
    case invalidReference

    public var errorDescription: String? { "Enter a session UUID or a codex://threads/… link." }
}

public enum SessionReference {
    /// Accepts the thread URL copied from Codex or the bare thread UUID.
    public static func sessionID(from input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: value) != nil { return value.lowercased() }
        guard let url = URL(string: value), url.scheme?.lowercased() == "codex",
              url.host?.lowercased() == "threads", url.user == nil, url.password == nil,
              url.port == nil else { throw SessionReferenceError.invalidReference }
        let components = url.path.split(separator: "/")
        guard components.count == 1, UUID(uuidString: String(components[0])) != nil else {
            throw SessionReferenceError.invalidReference
        }
        return String(components[0]).lowercased()
    }
}
