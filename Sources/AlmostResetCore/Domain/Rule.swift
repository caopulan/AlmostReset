import Foundation

public enum ConditionMatch: String, Codable, CaseIterable, Sendable { case all, any }
public enum ConditionComparison: String, Codable, CaseIterable, Sendable { case equals, moreThan }
public enum SessionField: String, Codable, CaseIterable, Sendable { case project, model, reasoning, speed, status }
public enum SessionScope: String, Codable, CaseIterable, Sendable {
    case running, active, all, recent

    public func includes(_ session: Session, now: Date = Date()) -> Bool {
        switch self {
        case .running: return session.status == .running
        case .active: return session.status.isActive
        case .all: return true
        case .recent: return session.isRecentOrRunning(at: now)
        }
    }
}

public struct SessionCondition: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var field: SessionField
    public var values: [String]
    public var comparison: ConditionComparison
    public var joinWithPrevious: ConditionMatch?

    public init(id: UUID = UUID(), field: SessionField, values: [String], comparison: ConditionComparison = .equals, joinWithPrevious: ConditionMatch? = nil) {
        self.id = id
        self.field = field
        self.values = values
        self.comparison = comparison
        self.joinWithPrevious = joinWithPrevious
    }

    private enum CodingKeys: String, CodingKey { case id, field, values, comparison, joinWithPrevious }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        field = try container.decode(SessionField.self, forKey: .field)
        values = try container.decode([String].self, forKey: .values)
        joinWithPrevious = try container.decodeIfPresent(ConditionMatch.self, forKey: .joinWithPrevious)
        comparison = try container.decodeIfPresent(ConditionComparison.self, forKey: .comparison) ?? .equals
    }

    public func matches(_ session: Session) -> Bool {
        if comparison == .moreThan {
            guard field == .reasoning, values.count == 1,
                  let threshold = ReasoningEffort(rawValue: values[0].lowercased()),
                  let current = session.reasoning else { return false }
            return current.rank > threshold.rank
        }
        let actual: String?
        switch field {
        case .project: actual = session.projectPath.isEmpty ? nil : session.projectPath
        case .model: actual = session.model
        case .reasoning: actual = session.reasoning?.rawValue
        case .speed: actual = session.speed?.rawValue
        case .status: actual = session.status == .unknown ? nil : session.status.rawValue
        }
        guard let actual, !actual.isEmpty else { return false }
        return values.contains { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if field == .project {
                return URL(fileURLWithPath: actual).standardizedFileURL.path ==
                    URL(fileURLWithPath: trimmed).standardizedFileURL.path
            }
            return actual.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}

public enum SessionSelector: Codable, Equatable, Sendable {
    case sessions([String])
    case conditions(match: ConditionMatch, conditions: [SessionCondition])

    public func matches(_ session: Session) -> Bool {
        switch self {
        case .sessions(let ids): return ids.contains(session.id)
        case .conditions(let match, let conditions):
            guard !conditions.isEmpty else { return false }
            // AND binds more tightly than OR. Missing connectors retain legacy semantics.
            var group = conditions[0].matches(session)
            var result = false
            for condition in conditions.dropFirst() {
                let value = condition.matches(session)
                if (condition.joinWithPrevious ?? match) == .all { group = group && value }
                else { result = result || group; group = value }
            }
            return result || group
        }
    }
}

public struct ContinuationSettings: Codable, Equatable, Sendable {
    public var model: String?
    public var reasoning: ReasoningEffort?
    public var speed: SessionSpeed?
    public var prompt: String

    public init(model: String? = nil, reasoning: ReasoningEffort? = nil,
                speed: SessionSpeed? = nil, prompt: String = "继续") {
        self.model = model
        self.reasoning = reasoning
        self.speed = speed
        self.prompt = prompt
    }

    public var effectivePrompt: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "继续" : trimmed
    }

    public var changesSettings: Bool { model != nil || reasoning != nil || speed != nil }
}

public enum SessionAction: Codable, Equatable, Sendable {
    case stop
    case continueSession(ContinuationSettings)
}

public struct AutomationRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var selector: SessionSelector
    public var action: SessionAction
    public var scope: SessionScope

    public init(id: UUID = UUID(), name: String = "", enabled: Bool = true,
                selector: SessionSelector, action: SessionAction, scope: SessionScope = .running) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.selector = selector
        self.action = action
        self.scope = scope
    }

    public func matches(_ session: Session) -> Bool {
        enabled && scope.includes(session) && selector.matches(session)
    }
}

public struct PlannedSessionAction: Identifiable, Codable, Equatable, Sendable {
    public var session: Session
    public var ruleID: UUID
    public var ruleName: String
    public var action: SessionAction
    public var id: String { session.id }

    public init(session: Session, ruleID: UUID, ruleName: String, action: SessionAction) {
        self.session = session
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.action = action
    }

    public var unavailableReason: String? {
        switch action {
        case .stop:
            guard session.control.canInterrupt else {
                return session.control.unavailableReason ?? "This session cannot be interrupted from this connection."
            }
        case .continueSession(let settings):
            if session.status == .running && !session.control.canInterrupt {
                return session.control.unavailableReason ?? "This running session cannot be interrupted from this connection."
            }
            guard session.control.canSendPrompt else {
                return session.control.unavailableReason ?? "This session cannot receive prompts from this connection."
            }
            if settings.changesSettings && !session.control.canUpdateSettings {
                return session.control.unavailableReason ?? "This session's settings cannot be changed from this connection."
            }
        }
        return nil
    }
}

public enum RuleEngine {
    /// The first enabled matching rule owns a session, even if its action is unavailable.
    /// A lower-priority rule must never silently replace the user's chosen action.
    public static func plan(rules: [AutomationRule], sessions: [Session]) -> [PlannedSessionAction] {
        let grouped = Dictionary(grouping: sessions, by: \.id)
        var seen = Set<String>()
        let uniqueSessions = sessions.compactMap { candidate -> Session? in
            guard seen.insert(candidate.id).inserted, let versions = grouped[candidate.id],
                  let newestDate = versions.map(\.updatedAt).max() else { return nil }
            let newest = versions.filter { $0.updatedAt == newestDate }
            // An ambiguous duplicate must not revive a completed session or apply stale settings.
            guard let session = newest.first, newest.allSatisfy({ $0 == session }) else { return nil }
            return session
        }
        var claimed = Set<String>()
        var result: [PlannedSessionAction] = []
        for (index, rule) in rules.enumerated() where rule.enabled {
            for session in uniqueSessions where !claimed.contains(session.id) && rule.matches(session) {
                claimed.insert(session.id)
                result.append(PlannedSessionAction(session: session, ruleID: rule.id, ruleName: "#\(index + 1)", action: rule.action))
            }
        }
        return result
    }
}
