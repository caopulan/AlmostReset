import Foundation

public struct CodexConfiguration: Codable, Equatable, Sendable {
    public var codexHome: String
    public var cliPath: String?
    public var controlSocketPath: String?
    public var useDesktopBridge: Bool
    public init(codexHome: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path,
                cliPath: String? = nil, controlSocketPath: String? = nil, useDesktopBridge: Bool = true) {
        self.codexHome = codexHome; self.cliPath = cliPath
        self.controlSocketPath = controlSocketPath; self.useDesktopBridge = useDesktopBridge
    }
}

public struct CodexModel: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var reasoningEfforts: [ReasoningEffort]
    public var speeds: [SessionSpeed]
    public var serviceTiers: [String: String]
    public init(id: String, displayName: String, reasoningEfforts: [ReasoningEffort],
                speeds: [SessionSpeed], serviceTiers: [String: String] = [:]) {
        self.id = id; self.displayName = displayName; self.reasoningEfforts = reasoningEfforts
        self.speeds = speeds; self.serviceTiers = serviceTiers
    }
}

public struct CodexConnection: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case desktop, sharedServer, readOnly, disconnected }
    public var status: Status
    public var title: String
    public var detail: String
    public var isControllable: Bool { status == .desktop || status == .sharedServer }
    public init(status: Status, title: String, detail: String) {
        self.status = status; self.title = title; self.detail = detail
    }
}

public struct CodexSnapshot: Sendable {
    public var sessions: [Session]
    public var quota: QuotaSnapshot?
    public var models: [CodexModel]
    public var connection: CodexConnection
    public var fetchedAt: Date
    public var warnings: [String]
    public init(sessions: [Session], quota: QuotaSnapshot?, models: [CodexModel],
                connection: CodexConnection, fetchedAt: Date = Date(), warnings: [String] = []) {
        self.sessions = sessions; self.quota = quota; self.models = models
        self.connection = connection; self.fetchedAt = fetchedAt; self.warnings = warnings
    }
}

public struct CodexActionReceipt: Codable, Sendable {
    public var sessionID: String
    public var action: String
    public var completedAt: Date
    public var detail: String
}

public enum CodexError: Error, LocalizedError {
    case unavailable(String), protocolError(String), rpc(String), timeout(String), unsupported(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let s), .protocolError(let s), .rpc(let s), .timeout(let s), .unsupported(let s): return s }
    }
}

extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func string(_ key: String) -> String? { self[key] as? String }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
    func number(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
}
