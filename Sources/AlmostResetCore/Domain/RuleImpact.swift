import Foundation

public struct RuleImpact: Equatable, Sendable {
    public let total: Int
    public let running: Int
    public let stopped: Int
    public let continued: Int
    public var affected: Int { stopped + continued }
    public var unaffected: Int { total - affected }

    public init(rules: [AutomationRule], sessions: [Session], now: Date = Date()) {
        let eligible = RuleInspection.sessions(for: .sessions(sessions.map(\.id)), in: sessions, now: now)
        let plan = RuleEngine.plan(rules: rules, sessions: eligible).filter { $0.unavailableReason == nil }
        total = eligible.count
        running = eligible.filter { $0.status == .running }.count
        stopped = plan.filter { if case .stop = $0.action { return true }; return false }.count
        continued = plan.count - stopped
    }
}
