import Foundation
import CryptoKit

public actor CodexService {
    public let configuration: CodexConfiguration
    private var reader: AppServerClient?
    private var bridge: DesktopBridge?
    private var catalog: [CodexModel] = []
    private var shared = false
    private var modelCatalogFetchedAt: Date?
    private var lastAccountID: String?
    private var lastConnection = CodexConnection(status: .disconnected, title: "Disconnected", detail: "Connect to local Codex.")

    public init(configuration: CodexConfiguration = .init()) { self.configuration = configuration }

    public func refresh(searchTerm: String? = nil) async throws -> CodexSnapshot {
        do { return try refreshConnected(searchTerm: searchTerm) }
        catch { reader = nil; bridge = nil; throw error }
    }

    private func refreshConnected(searchTerm: String?) throws -> CodexSnapshot {
        try Task.checkCancellation()
        let client = try connectReader()
        var warnings: [String] = []
        var quota: QuotaSnapshot?
        do {
            quota = try readQuota(client)
            if quota?.accountID != lastAccountID { catalog = []; lastAccountID = quota?.accountID }
        } catch { warnings.append("Usage: \(error.localizedDescription)") }
        if catalog.isEmpty || Date().timeIntervalSince(modelCatalogFetchedAt ?? .distantPast) > 300 {
            do { catalog = try readModels(client); modelCatalogFetchedAt = Date() }
            catch { warnings.append("Models: \(error.localizedDescription)") }
        }
        if configuration.useDesktopBridge && !shared && bridge == nil {
            do { bridge = try DesktopBridge(home: configuration.codexHome) }
            catch { warnings.append(error.localizedDescription) }
        }
        var threads: [[String: Any]] = []; var cursor: String?; var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var params: [String: Any] = ["limit": 200, "sortKey": "updated_at", "useStateDbOnly": true]
            if let searchTerm, !searchTerm.isEmpty { params["searchTerm"] = searchTerm }
            if let cursor { params["cursor"] = cursor }
            let page = try client.request("thread/list", params)
            threads.append(contentsOf: page.array("data"))
            cursor = page.string("nextCursor")
            if let cursor, !seen.insert(cursor).inserted { throw CodexError.protocolError("Codex repeated a thread-list cursor.") }
        } while cursor != nil
        var owners: [String: String] = [:]
        if let bridge {
            do { owners = try bridge.owners(of: threads.compactMap { $0.string("id") }) }
            catch { warnings.append("Live discovery: \(error.localizedDescription)"); self.bridge = nil }
        }
        var sessions = threads.map(Self.decodeThread)
        var bridgeFailures = 0
        if let bridge {
            let indices = sessions.enumerated().reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
            do {
                let missing = try bridge.snapshots(owners: owners) { id, state in
                    if let index = indices[id] { sessions[index] = Self.decodeDesktop(state, fallback: sessions[index]) }
                }
                bridgeFailures = missing.count
            } catch {
                warnings.append("Live snapshots: \(error.localizedDescription)")
                self.bridge = nil
            }
        } else if shared {
            for (index, thread) in threads.enumerated() where thread.object("status").string("type") != "notLoaded" {
                try Task.checkCancellation()
                if sessions[index].status.isActive {
                    let response = try client.request("thread/read", ["threadId": sessions[index].id, "includeTurns": true])
                    sessions[index] = Self.decodeThread(response.object("thread"))
                }
                sessions[index].control = SessionControl(canInterrupt: sessions[index].status.isActive, canUpdateSettings: true,
                    canSendPrompt: thread["canAcceptDirectInput"] as? Bool != false)
            }
        }
        if bridgeFailures > 0 { warnings.append("Live state unavailable for \(bridgeFailures) sessions. Their actions are disabled."); self.bridge = nil }
        lastConnection = CodexConnection(status: shared ? .sharedServer : (bridge == nil ? .readOnly : .desktop),
            title: shared ? "Shared App Server" : (bridge == nil ? "Codex · Read only" : "Codex Desktop"),
            detail: shared ? "Connected to the configured control socket." : (bridge == nil ? "Usage and saved sessions are available. Open Codex Desktop to control its sessions." : "Connected through the local Desktop bridge. Protocol compatibility is checked on every request."))
        return CodexSnapshot(sessions: sessions, quota: quota, models: catalog, connection: lastConnection, warnings: warnings)
    }

    /// Search only the session catalog; typing never performs an account or model refresh.
    public func searchSessions(_ query: String) async throws -> [Session] {
        do {
            try Task.checkCancellation()
            let client = try connectReader()
            var result: [Session] = []; var cursor: String?; var cursors = Set<String>()
            repeat {
                try Task.checkCancellation()
                var params: [String: Any] = ["limit": 200, "sortKey": "updated_at", "useStateDbOnly": true, "searchTerm": query]
                if let cursor { params["cursor"] = cursor }
                let page = try client.request("thread/list", params)
                let threads = page.array("data")
                let owners = try bridge?.owners(of: threads.compactMap { $0.string("id") }) ?? [:]
                for thread in threads {
                    try Task.checkCancellation()
                    var session = Self.decodeThread(thread)
                    if let bridge, let owner = owners[session.id] {
                        session = Self.decodeDesktop(try bridge.snapshot(threadID: session.id, owner: owner), fallback: session)
                    }
                    result.append(session)
                }
                cursor = page.string("nextCursor")
                if let cursor, !cursors.insert(cursor).inserted { throw CodexError.protocolError("Codex repeated a search cursor.") }
            } while cursor != nil
            return result
        } catch { reader = nil; bridge = nil; throw error }
    }

    public func resolve(deepLink: String) async throws -> Session {
        do { return try resolveConnected(deepLink: deepLink) }
        catch { reader = nil; bridge = nil; throw error }
    }

    private func resolveConnected(deepLink: String) throws -> Session {
        let id = try SessionReference.sessionID(from: deepLink)
        let client = try connectReader()
        let thread = try client.request("thread/read", ["threadId": id, "includeTurns": shared]).object("thread")
        var session = Self.decodeThread(thread)
        if configuration.useDesktopBridge && !shared {
            if bridge == nil { bridge = try DesktopBridge(home: configuration.codexHome) }
            if let bridge, let owner = try bridge.owner(of: id) { session = Self.decodeDesktop(try bridge.snapshot(threadID: id, owner: owner), fallback: session) }
        } else if shared && thread.object("status").string("type") != "notLoaded" {
            session.control = SessionControl(canInterrupt: session.status.isActive, canUpdateSettings: true, canSendPrompt: true)
        }
        return session
    }

    public func execute(_ planned: PlannedSessionAction) async throws -> CodexActionReceipt {
        try await execute(action: planned.action, session: planned.session)
    }

    public func execute(action: SessionAction, session: Session) async throws -> CodexActionReceipt {
        do { return try executeConnected(action: action, session: session) }
        catch { reader = nil; bridge = nil; throw error }
    }

    private func executeConnected(action: SessionAction, session: Session) throws -> CodexActionReceipt {
        let client = try connectReader()
        // Never trust a cached ownership claim when an automation fires.
        if !shared {
            guard configuration.useDesktopBridge else { throw CodexError.unavailable("Desktop control is disabled.") }
            if bridge == nil { bridge = try DesktopBridge(home: configuration.codexHome) }
            guard let bridge, let owner = try bridge.owner(of: session.id) else {
                throw CodexError.unavailable("This session has no connected Desktop owner. Open it in Codex before running the rule.")
            }
            let state = try bridge.snapshot(threadID: session.id, owner: owner)
            let current = Self.decodeDesktop(state, fallback: session)
            guard current.control.canSendPrompt || current.control.canInterrupt else {
                throw CodexError.unavailable(current.control.unavailableReason ?? "This session is not controllable.")
            }
            try Self.checkPlannedTurn(session, current)
            switch action {
            case .stop:
                try bridge.stop(threadID: session.id, owner: owner, expectedTurnID: current.activeTurnID)
                return receipt(session, "stop", "Stopped the turn and paused its goal. Queued messages were preserved.")
            case .continueSession(let settings):
                let changes = try makeSettings(settings, current: current, state: state)
                if current.status.isActive { try bridge.stop(threadID: session.id, owner: owner, expectedTurnID: current.activeTurnID) }
                if !changes.isEmpty { try bridge.update(threadID: session.id, owner: owner, settings: changes) }
                // Verify the settings before delivering input. Do not retry input automatically.
                let updated = try bridge.snapshot(threadID: session.id, owner: owner)
                try Self.verify(settings, in: Self.decodeDesktop(updated, fallback: current))
                try bridge.start(threadID: session.id, owner: owner, settings: changes, prompt: settings.effectivePrompt)
                return receipt(session, "continue", "Updated settings and delivered the continuation prompt.")
            }
        }
        let thread = try client.request("thread/read", ["threadId": session.id, "includeTurns": true]).object("thread")
        guard thread.object("status").string("type") != "notLoaded" else {
            throw CodexError.unavailable("This session is not loaded by the connected App Server. AlmostReset will not claim another server's session.")
        }
        let current = Self.decodeThread(thread)
        try Self.checkPlannedTurn(session, current)
        switch action {
        case .stop:
            try stopShared(client, current)
            return receipt(session, "stop", "Interrupted the active turn and paused its goal.")
        case .continueSession(let settings):
            let changes = try makeSettings(settings, current: current, state: nil)
            if current.status.isActive { try stopShared(client, current) }
            if !changes.isEmpty {
                var params = changes; params["threadId"] = session.id
                _ = try client.request("thread/settings/update", params)
            }
            var params = changes; params["threadId"] = session.id
            params["input"] = [["type": "text", "text": settings.effectivePrompt, "text_elements": []]]
            params["clientUserMessageId"] = UUID().uuidString.lowercased()
            _ = try client.request("turn/start", params)
            return receipt(session, "continue", "Updated settings and delivered the continuation prompt.")
        }
    }

    private static func checkPlannedTurn(_ planned: Session, _ current: Session) throws {
        if planned.status.isActive {
            guard current.status.isActive, let expected = planned.activeTurnID,
                  expected == current.activeTurnID else {
                throw CodexError.unavailable("The planned turn completed or changed. The action was skipped.")
            }
        } else if current.status.isActive {
            throw CodexError.unavailable("A new turn started after this action was planned. The action was skipped.")
        }
    }

    private func receipt(_ session: Session, _ action: String, _ detail: String) -> CodexActionReceipt {
        CodexActionReceipt(sessionID: session.id, action: action, completedAt: Date(), detail: detail)
    }

    private func stopShared(_ client: AppServerClient, _ session: Session) throws {
        if let turnID = session.activeTurnID { _ = try client.request("turn/interrupt", ["threadId": session.id, "turnId": turnID]) }
        // Report goal-pause failures explicitly; an interrupted turn alone does not
        // guarantee that automatic goal execution has stopped.
        let goal = try client.request("thread/goal/get", ["threadId": session.id])
        if let value = goal["goal"] as? [String: Any], value.string("status") == "active" {
            _ = try client.request("thread/goal/set", ["threadId": session.id, "status": "paused", "origin": "user"])
        }

    }

    private func connectReader() throws -> AppServerClient {
        if let reader { return reader }
        let executable = try Self.resolveExecutable(configuration.cliPath)
        let socket = configuration.controlSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let useSocket = socket.flatMap { $0.isEmpty ? nil : $0 }
        let client = try AppServerClient(executable: executable, home: configuration.codexHome, socket: useSocket)
        shared = useSocket != nil; reader = client; return client
    }

    public static func resolveExecutable(_ configured: String?) throws -> String {
        let fm = FileManager.default
        var candidates: [String] = []
        if let configured, !configured.isEmpty { candidates = [configured] }
        else {
            candidates = [fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
                "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/Codex.app/Contents/Resources/codex"]
            candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        }
        guard let executable = candidates.first(where: fm.isExecutableFile(atPath:)) else {
            throw CodexError.unavailable("Codex CLI was not found. Install Codex or choose its executable in Settings.")
        }
        return executable
    }

    private func readQuota(_ client: AppServerClient) throws -> QuotaSnapshot? {
        let response = try client.request("account/rateLimits/read")
        var identity = response.string("accountId")
        if identity == nil {
            let account = try client.request("account/read", ["refreshToken": false]).object("account")
            if let email = account.string("email"), !email.isEmpty {
                identity = "account:" + SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
        guard let identity, !identity.isEmpty else { return nil }
        let buckets = response.object("rateLimitsByLimitId")
        var windows: [QuotaWindow] = []
        let values: [(String, [String: Any])] = buckets.isEmpty ? [(response.object("rateLimits").string("limitId") ?? "codex", response.object("rateLimits"))] : buckets.compactMap { key, value in (value as? [String: Any]).map { (key, $0) } }
        for (id, bucket) in values.sorted(by: { $0.0 < $1.0 }) {
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any] else { continue }
                let duration = window.number("windowDurationMins").map(Int.init)
                let label: String?
                if let duration {
                    let time = duration % 1440 == 0 ? "\(duration / 1440)d" : duration % 60 == 0 ? "\(duration / 60)h" : "\(duration)m"
                    label = id == "codex" ? time : "\(bucket.string("limitName") ?? id) · \(time)"
                } else { label = bucket.string("limitName") ?? id }
                windows.append(QuotaWindow(limitID: id, windowDurationMins: duration, usedPercent: window.number("usedPercent"), resetsAt: window.number("resetsAt").map(Date.init(timeIntervalSince1970:)), label: label))
            }
        }
        return QuotaSnapshot(accountID: identity, sourceID: "local:" + URL(fileURLWithPath: configuration.codexHome).standardizedFileURL.path, windows: windows)
    }

    private func readModels(_ client: AppServerClient) throws -> [CodexModel] {
        let response = try client.request("model/list", ["includeHidden": false])
        return response.array("data").map { model in
            var tiers: [String: String] = [SessionSpeed.normal.rawValue: "default"]
            for tier in model.array("serviceTiers") {
                if let id = tier.string("id"), let speed = Self.speed(id) { tiers[speed.rawValue] = id }
            }
            for id in model["additionalSpeedTiers"] as? [String] ?? [] {
                if let speed = Self.speed(id), tiers[speed.rawValue] == nil { tiers[speed.rawValue] = speed == .fast ? "priority" : id }
            }
            let id = model.string("model") ?? model.string("id") ?? ""
            return CodexModel(id: id, displayName: model.string("displayName") ?? id,
                reasoningEfforts: model.array("supportedReasoningEfforts").compactMap { $0.string("reasoningEffort").flatMap(ReasoningEffort.init(rawValue:)) },
                speeds: SessionSpeed.allCases.filter { tiers[$0.rawValue] != nil }, serviceTiers: tiers)
        }.filter { !$0.id.isEmpty }
    }

    private func makeSettings(_ settings: ContinuationSettings, current: Session, state: [String: Any]?) throws -> [String: Any] {
        if catalog.isEmpty { catalog = try readModels(connectReader()) }
        let modelID = settings.model ?? current.model
        guard let model = catalog.first(where: { $0.id == modelID }) else { throw CodexError.unsupported("The session's model is not available in the current Codex catalog.") }
        if let effort = settings.reasoning, !model.reasoningEfforts.contains(effort) { throw CodexError.unsupported("\(model.displayName) does not support \(effort.rawValue) reasoning.") }
        if let speed = settings.speed, !model.speeds.contains(speed) { throw CodexError.unsupported("\(model.displayName) does not support \(speed.rawValue) speed.") }
        if settings.model != nil {
            if settings.reasoning == nil, let effort = current.reasoning, !model.reasoningEfforts.contains(effort) {
                throw CodexError.unsupported("\(model.displayName) cannot keep \(effort.rawValue) reasoning. Choose a supported reasoning level before running this rule.")
            }
            if settings.speed == nil, let speed = current.speed, !model.speeds.contains(speed) {
                throw CodexError.unsupported("\(model.displayName) cannot keep \(speed.rawValue) speed. Choose a supported speed before running this rule.")
            }
        }
        var result: [String: Any] = [:]
        if let model = settings.model { result["model"] = model }
        if let reasoning = settings.reasoning { result["effort"] = reasoning.rawValue }
        if let speed = settings.speed { result["serviceTier"] = model.serviceTiers[speed.rawValue] ?? "default" }
        // Desktop's collaboration mode takes precedence over model/effort. Preserve its
        // mode and instructions while updating exactly the fields the user requested.
        if settings.model != nil || settings.reasoning != nil,
           var collaboration = state?["latestCollaborationMode"] as? [String: Any] {
            var values = collaboration.object("settings")
            if let model = settings.model { values["model"] = model }
            if let effort = settings.reasoning { values["reasoning_effort"] = effort.rawValue }
            collaboration["settings"] = values; result["collaborationMode"] = collaboration
        }
        return result
    }

    private static func verify(_ expected: ContinuationSettings, in actual: Session) throws {
        if let model = expected.model, model != actual.model { throw CodexError.protocolError("Model settings were not confirmed. No prompt was sent.") }
        if let reasoning = expected.reasoning, reasoning != actual.reasoning { throw CodexError.protocolError("Reasoning settings were not confirmed. No prompt was sent.") }
        if let speed = expected.speed, speed != actual.speed { throw CodexError.protocolError("Speed settings were not confirmed. No prompt was sent.") }
    }

    static func speed(_ tier: String?) -> SessionSpeed? {
        switch tier?.lowercased() {
        case "default", "standard", "normal", "flex": return .normal
        case "priority", "fast": return .fast
        case "ultrafast", "ultra_fast", "ultra-fast": return .ultrafast
        default: return nil
        }
    }

    static func decodeThread(_ thread: [String: Any]) -> Session {
        let active = thread.array("turns").last(where: { $0.string("status") == "inProgress" })
        let status: SessionStatus
        switch thread.object("status").string("type") {
        case "active":
            let flags = thread.object("status")["activeFlags"] as? [String] ?? []
            status = flags.contains(where: { $0 == "waitingOnApproval" || $0 == "waitingOnUserInput" }) ? .waiting : .running
        case "idle": status = .idle
        default: status = .unknown
        }
        return Session(id: thread.string("id") ?? "", title: thread.string("name") ?? thread.string("preview") ?? "Untitled session",
            projectPath: thread.string("cwd") ?? "", model: thread.string("model"),
            reasoning: thread.string("reasoningEffort").flatMap(ReasoningEffort.init(rawValue:)),
            speed: speed(thread.string("serviceTier")), status: status, activeTurnID: active?.string("id"),
            updatedAt: Date(timeIntervalSince1970: thread.number("updatedAt") ?? 0),
            control: .readOnly("Open this session in Codex Desktop to connect its owner."))
    }

    static func decodeDesktop(_ state: [String: Any], fallback: Session) -> Session {
        var session = fallback
        let settings = state.object("latestThreadSettings")
        let collaboration = state.object("latestCollaborationMode").object("settings")
        session.title = state.string("title") ?? session.title
        session.projectPath = state.string("cwd") ?? session.projectPath
        session.model = collaboration.string("model") ?? settings.string("model") ?? state.string("latestModel") ?? session.model
        session.reasoning = (collaboration.string("reasoning_effort") ?? settings.string("effort") ?? state.string("latestReasoningEffort")).flatMap(ReasoningEffort.init(rawValue:))
        session.speed = speed(settings.string("serviceTier"))
        if let updated = state.number("updatedAt") { session.updatedAt = Date(timeIntervalSince1970: updated / 1000) }
        var turns = state.array("turns")
        turns += state.object("turnHistory").object("history").object("entitiesByKey").values.compactMap { $0 as? [String: Any] }
        let active = turns.filter { $0.string("status") == "inProgress" }.max { ($0.number("turnStartedAtMs") ?? 0) < ($1.number("turnStartedAtMs") ?? 0) }
        session.activeTurnID = active?.string("turnId")
        if active != nil || state.object("threadRuntimeStatus").string("type") == "active" {
            session.status = state.array("requests").isEmpty ? .running : .waiting
        } else { session.status = .idle }
        let subagent = state.string("agentNickname") != nil || state.string("threadSource") == "subagent"
        session.control = SessionControl(canInterrupt: !subagent, canUpdateSettings: !subagent, canSendPrompt: !subagent,
            unavailableReason: subagent ? "This subagent is controlled by its parent session." : nil)
        return session
    }
}
