import Foundation

/// Presets are editable drafts. Canonical model IDs are exact; never substitute
/// a newer model or treat Ultrafast as Fast without the user's choice.
public enum RulePreset: String, CaseIterable, Identifiable, Sendable {
    case stopAstra, standardFastSessions, astraToSol
    public var id: String { rawValue }
    public func configuration(prompt: String = "继续") -> RulePresetConfiguration {
        switch self {
        case .stopAstra:
            return RulePresetConfiguration(conditions: [SessionCondition(field: .model, values: ["gpt-6-astra"])], action: .stop)
        case .standardFastSessions:
            return RulePresetConfiguration(conditions: [SessionCondition(field: .speed, values: [SessionSpeed.fast.rawValue])],
                action: .continueSession(ContinuationSettings(speed: .normal, prompt: prompt)))
        case .astraToSol:
            return RulePresetConfiguration(conditions: [SessionCondition(field: .model, values: ["gpt-6-astra"])],
                action: .continueSession(ContinuationSettings(model: "gpt-6-sol", reasoning: .xhigh, prompt: prompt)))
        }
    }
}

public struct RulePresetConfiguration: Equatable, Sendable {
    public var match: ConditionMatch = .all
    public var conditions: [SessionCondition]
    public var action: SessionAction
    public init(conditions: [SessionCondition], action: SessionAction) {
        self.conditions = conditions; self.action = action
    }
    public func matchesDraft(match: ConditionMatch, conditions: [SessionCondition], action: SessionAction) -> Bool {
        self.match == match && self.action == action && self.conditions.count == conditions.count &&
        zip(self.conditions, conditions).allSatisfy { left, right in
            left.field == right.field && left.comparison == right.comparison && Set(left.values) == Set(right.values)
        }
    }
}

public enum RuleInspection {
    /// Counts selector matches in the requested display window. Disabled rules
    /// still have candidates; execution scope and first-match priority are separate.
    public static func sessions(for selector: SessionSelector, in sessions: [Session], now: Date = Date()) -> [Session] {
        Dictionary(grouping: sessions, by: \.id).values.compactMap { versions -> Session? in
            guard let latest = versions.map(\.updatedAt).max() else { return nil }
            let candidates = versions.filter { $0.updatedAt == latest }
            guard let session = candidates.first, candidates.allSatisfy({ $0 == session }),
                  session.isRecentOrRunning(at: now), selector.matches(session) else { return nil }
            return session
        }.sorted { left, right in
            if (left.status == .running) != (right.status == .running) { return left.status == .running }
            if left.projectPath != right.projectPath { return left.projectPath.localizedStandardCompare(right.projectPath) == .orderedAscending }
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            return left.id < right.id
        }
    }
}
