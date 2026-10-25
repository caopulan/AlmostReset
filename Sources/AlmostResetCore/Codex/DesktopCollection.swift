import Foundation

/// Distinguishes a negative ownership reply from a reply that never arrived.
struct DesktopOwnerDiscovery {
    var pending: [String: String]
    private(set) var owners: [String: String] = [:]
    private(set) var issues: [String: String] = [:]

    mutating func receive(_ response: [String: Any]) {
        guard let requestID = response.string("requestId"), let threadID = pending.removeValue(forKey: requestID) else { return }
        if response.string("resultType") == "success", response.string("method") == "thread-owner-discovery",
           let owner = response.string("handledByClientId") {
            owners[threadID] = owner
        } else if response.string("error") != "no-client-found" {
            issues[threadID] = "Owner discovery failed: " + (response.string("error") ?? "incompatible response")
        }
    }
    mutating func finish() {
        for threadID in pending.values { issues[threadID] = "Owner discovery timed out; live state is unknown." }
        pending.removeAll()
    }
}

public enum SessionCollection {
    /// Preserve candidate metadata for diagnostics, never stale authority to execute.
    public static func unavailable(_ fallback: Session, previous: Session?, reason: String) -> Session {
        var session = fallback
        if let previous {
            session.model = previous.model ?? session.model
            session.reasoning = previous.reasoning ?? session.reasoning
            session.speed = previous.speed ?? session.speed
        }
        session.status = .unknown
        session.activeTurnID = nil
        session.control = .readOnly(reason)
        return session
    }

    public static func auditCandidates(rules: [AutomationRule], previous: [Session], current: [Session], now: Date = Date()) -> Set<String> {
        Set((previous + current).filter { session in
            (session.isRecentOrRunning(at: now) || session.status == .unknown) && rules.contains { $0.enabled && $0.selector.matches(session) }
        }.map(\.id))
    }
}

struct DesktopOwnerSynchronization {
    var ready: [String: String] = [:]
    var issues: [String: String] = [:]
    static func collect(owners: [String: String], synchronize: (String, String) throws -> Void) -> Self {
        var result = Self()
        for (owner, threadIDs) in Dictionary(grouping: owners.keys, by: { owners[$0]! }) {
            do {
                try synchronize(threadIDs.sorted()[0], owner)
                for id in threadIDs { result.ready[id] = owner }
            } catch {
                for id in threadIDs { result.issues[id] = "Live synchronization failed: " + error.localizedDescription }
            }
        }
        return result
    }
}
