import Foundation

/// Adapter for Codex Desktop's versioned, same-user client coordination socket.
/// Registers its own AlmostReset identity. It never impersonates a desktop client,
/// claims thread ownership, writes the state database, or attaches to private stdio.
final class DesktopBridge {
    private let transport: JSONTransport
    private var clientID = "initializing-client"
    private(set) var collectionIssues: [String: String] = [:]
    init(home: String) throws {
        transport = try JSONTransport(socketPath: URL(fileURLWithPath: home).appendingPathComponent("ipc/ipc.sock").path)
        let response = try request("initialize", version: 0, params: ["clientType": "AlmostReset"])
        guard let id = response.object("result").string("clientId") else { throw CodexError.protocolError("Codex Desktop did not assign a client identity.") }
        clientID = id
    }

    func owner(of threadID: String) throws -> String? {
        let response = try request("thread-owner-discovery", version: 1, params: ["hostId": "local", "conversationId": threadID], allowMissing: true)
        return response.string("handledByClientId")
    }

    /// Discovery requests are independent; batch them so thousands of saved sessions
    /// do not incur one full desktop event-loop round trip each.
    func owners(of threadIDs: [String]) throws -> [String: String] {
        collectionIssues = [:]
        var pending: [String: String] = [:]
        for threadID in threadIDs {
            let requestID = UUID().uuidString
            pending[requestID] = threadID
            try transport.send(["type": "request", "requestId": requestID, "sourceClientId": clientID,
                "method": "thread-owner-discovery", "version": 1, "timeoutMs": 10_000,
                "params": ["hostId": "local", "conversationId": threadID]])
        }
        // Wait through the router's ten-second discovery window. A missing reply
        // is not evidence that a thread has no owner.
        var discovery = DesktopOwnerDiscovery(pending: pending)
        let deadline = Date().addingTimeInterval(12)
        while !discovery.pending.isEmpty {
            let response: [String: Any]
            do { response = try transport.receive(deadline: deadline) }
            catch CodexError.timeout { break }
            if try respondToDiscovery(response) { continue }
            discovery.receive(response)
        }
        discovery.finish()
        collectionIssues.merge(discovery.issues, uniquingKeysWith: { _, new in new })
        return discovery.owners
    }

    func snapshots(owners: [String: String], onSnapshot: (String, [String: Any]) -> Void) throws -> Set<String> {
        guard !owners.isEmpty else { return [] }
        let synchronization = DesktopOwnerSynchronization.collect(owners: owners) { threadID, owner in
            _ = try request("thread-follower-read-model-settings", version: 1,
                            params: ["conversationId": threadID], target: owner)
        }
        let ready = synchronization.ready
        collectionIssues.merge(synchronization.issues, uniquingKeysWith: { _, new in new })
        for (threadID, owner) in ready { try follow(threadID: threadID, owner: owner, following: true) }
        defer { for (threadID, owner) in ready { try? follow(threadID: threadID, owner: owner, following: false) } }
        var pending = Set(ready.keys)
        let deadline = Date().addingTimeInterval(12)
        while !pending.isEmpty {
            let event: [String: Any]
            do { event = try transport.receive(deadline: deadline) }
            catch CodexError.timeout { break }
            if try respondToDiscovery(event) { continue }
            let params = event.object("params")
            guard event.string("method") == "thread-stream-state-changed", event.number("version") == 11,
                  let threadID = params.string("conversationId"), pending.contains(threadID),
                  event.string("sourceClientId") == owners[threadID], params.object("change").string("type") == "snapshot" else { continue }
            let state = params.object("change").object("conversationState")
            guard state.string("id") == threadID else {
                collectionIssues[threadID] = "Codex Desktop returned a mismatched session snapshot."
                pending.remove(threadID)
                continue
            }
            pending.remove(threadID)
            collectionIssues.removeValue(forKey: threadID)
            // The caller extracts metadata immediately; conversation content is never persisted.
            onSnapshot(threadID, state)
        }
        for threadID in pending { collectionIssues[threadID] = "Live snapshot timed out; state is unknown." }
        return Set(owners.keys).subtracting(ready.keys).union(pending)
    }

    func snapshot(threadID: String, owner: String) throws -> [String: Any] {
        // An owner-acknowledged barrier consumes any older snapshots buffered from
        // the previous subscription before requesting a fresh one for an action.
        _ = try request("thread-follower-read-model-settings", version: 1,
                        params: ["conversationId": threadID], target: owner)
        try follow(threadID: threadID, owner: owner, following: true)
        defer { try? follow(threadID: threadID, owner: owner, following: false) }
        let deadline = Date().addingTimeInterval(8)
        while true {
            let event = try transport.receive(deadline: deadline)
            if try respondToDiscovery(event) { continue }
            guard event.string("method") == "thread-stream-state-changed",
                  event.number("version") == 11,
                  event.string("sourceClientId") == owner,
                  event.object("params").string("conversationId") == threadID,
                  event.object("params").object("change").string("type") == "snapshot" else { continue }
            let state = event.object("params").object("change").object("conversationState")
            guard state.string("id") == threadID else { throw CodexError.protocolError("Codex Desktop returned a snapshot for a different session.") }
            return state
        }
    }

    func stop(threadID: String, owner: String, expectedTurnID: String?) throws {
        // Omitting expectedTurnId uses Desktop's full user-stop path, including
        // goal pause and descendant cleanup. A turn-scoped stop skips goal pause.
        let params: [String: Any] = ["conversationId": threadID, "mode": "user-stop"]
        let response = try request("thread-follower-interrupt-turn", version: 3, params: params, target: owner)
        let result = response.object("result")
        guard result["ok"] as? Bool == true else { throw CodexError.protocolError("Codex Desktop did not confirm the stop.") }
        if let error = result.string("goalPauseError") { throw CodexError.rpc("Turn interrupted, but its automatic goal could not be paused: \(error)") }
    }

    func update(threadID: String, owner: String, settings: [String: Any]) throws {
        let response = try request("thread-follower-update-thread-settings", version: 2,
            params: ["conversationId": threadID, "threadSettings": settings], target: owner)
        guard response.object("result")["applied"] as? Bool == true else {
            throw CodexError.rpc("Codex Desktop did not apply the requested settings.")
        }
    }

    func start(threadID: String, owner: String, settings: [String: Any], prompt: String) throws {
        var request = settings
        request["threadId"] = threadID
        request["clientUserMessageId"] = UUID().uuidString.lowercased()
        request["input"] = [["type": "text", "text": prompt, "text_elements": []]]
        let response = try self.request("thread-follower-start-turn", version: 2, params: [
            "conversationId": threadID,
            "turnStart": ["request": request, "context": ["inheritThreadSettings": true]]
        ], target: owner, timeout: 30)
        guard response.object("result")["result"] != nil else {
            throw CodexError.protocolError("Codex Desktop did not confirm the continuation. Check the session before retrying.")
        }
    }

    private func follow(threadID: String, owner: String, following: Bool) throws {
        try transport.send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                            "sourceClientId": clientID, "targetClientIds": [owner],
                            "params": ["conversationId": threadID, "hostId": "local", "following": following]])
    }

    private func request(_ method: String, version: Int, params: [String: Any], target: String? = nil,
                         timeout: TimeInterval = 8, allowMissing: Bool = false) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
                                      "method": method, "version": version, "params": params, "timeoutMs": Int(timeout * 1000)]
        if let target { message["targetClientId"] = target }
        try transport.send(message)
        let deadline = Date().addingTimeInterval(timeout + 1)
        while true {
            let response = try transport.receive(deadline: deadline)
            if try respondToDiscovery(response) { continue }
            guard response.string("requestId") == id else { continue }
            if response.string("resultType") == "error" {
                if allowMissing && response.string("error") == "no-client-found" { return [:] }
                throw CodexError.rpc("Codex Desktop: \(response.string("error") ?? "request failed")")
            }
            guard response.string("resultType") == "success", response.string("method") == method else {
                throw CodexError.protocolError("Codex Desktop returned an incompatible response for \(method).")
            }
            return response
        }
    }

    private func respondToDiscovery(_ message: [String: Any]) throws -> Bool {
        guard message.string("type") == "client-discovery-request" else { return false }
        try transport.send(["type": "client-discovery-response", "requestId": message["requestId"] ?? "",
                            "response": ["canHandle": false]])
        return true
    }
}
