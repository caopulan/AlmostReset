import Foundation
import SwiftUI
import Combine
import ServiceManagement
import AlmostResetCore

enum AppPage: String, CaseIterable {
    case rules = "Rules", sessions = "Sessions", activity = "Activity", settings = "Settings"
    var symbol: String {
        switch self { case .rules: return "slider.horizontal.3"; case .sessions: return "folder"; case .activity: return "clock"; case .settings: return "gearshape" }
    }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var pendingRuleID: UUID?
    @Published var presentedRuleID: UUID?
    @Published var page: AppPage = .rules
    @Published var language: AppLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .chinese {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }
    @Published var sessions: [Session] = []
    @Published var models: [CodexModel] = []
    @Published private var quotaDisplay = QuotaDisplayState()
    var quota: QuotaSnapshot? { quotaDisplay.snapshot }
    var isQuotaStale: Bool { quotaDisplay.isStale }
    @Published var connection = CodexConnection(status: .disconnected, title: "Connecting", detail: "")
    @Published var rules: [AutomationRule] = []
    @Published var logs: [AutomationLogEntry] = []
    @Published var isRefreshing = false
    @Published var isExecuting = false
    @Published var isInstallingUpdate = false
    @Published private(set) var isSavingRules = false
    @Published var activeEventID: UUID?
    @Published var errorMessage: String?
    @Published var storageError: String?
    @Published private(set) var canEditRules = false
    @Published var warnings: [String] = []
    @Published var lastRefresh: Date?
    @Published var lastUsageAndSessionsRefresh: Date?
    @Published private(set) var listener = OneShotListener()
    @Published var resolvedCLIPath: String?
    @Published var connectionChecked = false
    @Published var isReconnecting = false
    @Published var runSucceeded = 0
    @Published var runFailed = 0
    @Published var runMatched = 0
    var monitoring: Bool { listener.isListening }
    var canStart: Bool { canEditRules && storageError == nil && !isExecuting && !isReconnecting && !isInstallingUpdate && resolvedCLIPath != nil }
    @Published var pollInterval: Double
    @Published var cliPath: String
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    let updates = AppUpdater()
    private var service: CodexService
    private let persistence = AppPersistence()
    private var didStart = false
    private var persistenceReady = false
    private var connectionGeneration = 0
    private var searchGeneration = 0
    private var pollingTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recovery = RefreshRecovery()
    private var lastRefreshFailure: String?
    private var saveTask: Task<Void, Never>?

    init() {
        let savedInterval = UserDefaults.standard.double(forKey: "pollInterval")
        pollInterval = [15.0, 30, 60, 120].contains(savedInterval) ? savedInterval : 30
        let configuredPath = UserDefaults.standard.string(forKey: "cliPath") ?? ""
        cliPath = configuredPath
        service = CodexService(configuration: CodexConfiguration(cliPath: configuredPath.isEmpty ? nil : configuredPath))
    }

    var mainWindows: [QuotaWindow] {
        let windows = quota?.windows ?? []
        let main = windows.filter { $0.limitID == "codex" }
        return (main.isEmpty ? windows : main).sorted { ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max) }
    }
    var remainingLabel: String {
        guard let value = mainWindows.compactMap(\.remainingPercent).min() else { return "—" }
        return "\(Int(value.rounded(.down)))%"
    }
    var selectableSessions: [Session] { sessions.filter { $0.isRecentOrRunning() } }
    var runningSessions: [Session] { sessions.filter { $0.status == .running } }
    var plannedActions: [PlannedSessionAction] { RuleEngine.plan(rules: rules, sessions: sessions) }
    var statusColor: Color { connection.isControllable ? .green : (connection.status == .readOnly ? .orange : .secondary) }

    func start() async {
        guard !didStart else { return }
        didStart = true
        do {
            let saved = try await persistence.load()
            rules = saved.rules; logs = saved.logs; listener = OneShotListener(detectorState: saved.resetState)
            persistenceReady = true; canEditRules = true
            // Listening is always explicitly armed; legacy persistent monitoring is retired.
            UserDefaults.standard.removeObject(forKey: "monitoring")
        } catch { storageError = "Cannot load saved rules: \(error.localizedDescription)" }
        updates.start(app: self)
        await refresh()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(self.pollInterval)) } catch { return }
                if Task.isCancelled { return }
                // Display refresh is independent of the one-shot action listener.
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing, !isExecuting, !isInstallingUpdate else { return }
        isRefreshing = true
        // A SwiftUI .task is cancelled when its window/popover disappears. The
        // application owns this read so closing a view cannot cancel recovery.
        await Task { await self.performRefresh() }.value
    }

    private func performRefresh() async {
        let generation = connectionGeneration
        let backend = service
        defer { isRefreshing = false }
        do {
            resolvedCLIPath = try CodexService.resolveExecutable(cliPath.isEmpty ? nil : cliPath)
            let snapshot = try await backend.refresh()
            guard generation == connectionGeneration else { return }
            let previousSessions = sessions
            sessions = snapshot.sessions
            let hasFreshQuota = quotaDisplay.receive(snapshot.quota)
            models = snapshot.models; connection = snapshot.connection
            if hasFreshQuota { lastUsageAndSessionsRefresh = snapshot.fetchedAt }
            lastRefresh = snapshot.fetchedAt; warnings = snapshot.warnings
            errorMessage = snapshot.collectionIssues.isEmpty ? nil : LF("%d sessions have unconfirmed live state", snapshot.collectionIssues.count)
            connectionChecked = true
            guard hasFreshQuota, let freshQuota = snapshot.quota else {
                errorMessage = snapshot.warnings.first(where: { $0.hasPrefix("Usage:") }) ?? L("Usage unavailable")
                recordRefreshFailure(errorMessage ?? "Usage unavailable")
                scheduleReadRecovery()
                return
            }
            if lastRefreshFailure != nil {
                lastRefreshFailure = nil
                logs.append(AutomationLogEntry(kind: .info, message: "Usage refresh recovered"))
                persist()
            }
            recovery.reset()
            recoveryTask?.cancel(); recoveryTask = nil
            guard persistenceReady else { return }
            if let event = listener.observe(freshQuota) {
                await executeReset(event, previousSessions: previousSessions, snapshot: snapshot)
            } else if listener.isListening {
                persist()
            }
        } catch {
            guard generation == connectionGeneration else { return }
            quotaDisplay.markUnavailable()
            connectionChecked = true
            errorMessage = error.localizedDescription
            connection = CodexConnection(status: .disconnected, title: "Disconnected", detail: error.localizedDescription)
            recordRefreshFailure(error.localizedDescription)
            scheduleReadRecovery()
        }
    }

    private func recordRefreshFailure(_ message: String) {
        guard lastRefreshFailure != message else { return }
        lastRefreshFailure = message
        logs.append(AutomationLogEntry(kind: .failed, message: "Usage refresh failed: " + String(message.prefix(1_000))))
        persist()
    }

    private func scheduleReadRecovery() {
        guard !listener.isListening, !isReconnecting, let delay = recovery.nextDelay() else { return }
        recoveryTask?.cancel()
        let generation = connectionGeneration
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, generation == self.connectionGeneration, !self.isExecuting else { return }
            await self.refresh()
        }
    }

    var canInstallAppUpdate: Bool {
        UpdateInstallationPolicy.canInstall(listening: listener.isListening, executing: isExecuting,
            refreshing: isRefreshing, reconnecting: isReconnecting, storageReady: persistenceReady && storageError == nil, writingRules: isSavingRules)
    }
    func prepareForAppUpdate() async -> Bool {
        guard canInstallAppUpdate else { return false }
        guard await checkpoint() else { return false }
        return canInstallAppUpdate
    }

    func startListening() {
        guard canStart, !listener.isListening else { return }
        runSucceeded = 0; runFailed = 0; runMatched = 0
        listener.arm(baseline: nil)
        logs.append(AutomationLogEntry(kind: .info, message: "One-time listening started"))
        persist()
        let generation = listener.generation
        Task {
            while isRefreshing {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard listener.isListening, listener.generation == generation else { return }
            await refresh()
        }
    }

    func stopListening() {
        guard listener.isListening || isExecuting else { return }
        listener.stop()
        logs.append(AutomationLogEntry(kind: .info, message: "Listening stopped"))
        persist()
    }

    private func executeReset(_ event: QuotaResetEvent, previousSessions: [Session], snapshot: CodexSnapshot) async {
        isExecuting = true
        activeEventID = event.id
        let generation = listener.generation
        let backend = service
        let eventRules = rules
        var collected = snapshot
        var auditIDs = SessionCollection.auditCandidates(rules: eventRules, previous: previousSessions, current: snapshot.sessions)
        var recoveryIDs = Set(previousSessions.filter { session in eventRules.contains { $0.matches(session) } }.map(\.id))
        recoveryIDs.formUnion(auditIDs.intersection(snapshot.collectionIssues.keys))
        defer {
            isExecuting = false; activeEventID = nil
            listener.finish(generation: generation)
        }
        let changes = event.windows.map { window in
            let before = window.previous.remainingPercent.map { String(format: "%g", $0) } ?? "—"
            let after = window.current.remainingPercent.map { String(format: "%g", $0) } ?? "—"
            return "\(window.current.limitID == "codex" ? window.current.friendlyName : window.current.displayName) \(before)% → \(after)%"
        }.joined(separator: "; ")
        logs.append(AutomationLogEntry(kind: .reset, message: "Quota increased · " + changes, eventID: event.id))
        // Persist the consumed event before read-only recovery or any mutations.
        guard await checkpoint() else { runFailed = 1; return }
        if !collected.collectionIssues.isEmpty || !recoveryIDs.subtracting(collected.liveSessionIDs).isEmpty {
            logs.append(AutomationLogEntry(kind: .info, message: LF("Collection incomplete: %d unresolved; rechecking before planning", collected.collectionIssues.count), eventID: event.id))
            do {
                let retry = try await backend.refreshForReset(accountID: event.accountID, sourceID: event.sourceID)
                auditIDs.formUnion(SessionCollection.auditCandidates(rules: eventRules, previous: collected.sessions, current: retry.sessions))
                collected = retry
                recoveryIDs.formUnion(auditIDs.intersection(retry.collectionIssues.keys))
            } catch {
                logs.append(AutomationLogEntry(kind: .failed, message: L("Collection retry failed") + ": " + error.localizedDescription, eventID: event.id))
                runFailed = 1; _ = await checkpoint(); return
            }
        }
        var finalSessions = Dictionary(collected.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in previousSessions where auditIDs.contains(session.id) && finalSessions[session.id] == nil {
            finalSessions[session.id] = SessionCollection.unavailable(session, previous: session, reason: "Session absent from refreshed catalog.")
            collected.collectionIssues[session.id] = "Session absent from refreshed catalog."
        }
        let recoveryDeadline = Date().addingTimeInterval(30)
        for id in recoveryIDs.subtracting(collected.liveSessionIDs).sorted() {
            guard listener.phase == .executing, generation == listener.generation else { break }
            guard Date() < recoveryDeadline else { collected.collectionIssues[id] = "Targeted collection recovery exceeded its time budget."; continue }
            do {
                let recovered = try await backend.resolve(deepLink: "codex://threads/" + id)
                guard recovered.control.isAvailable else { throw CodexError.unavailable(recovered.control.unavailableReason ?? "No live owner") }
                finalSessions[id] = recovered
                collected.liveSessionIDs.insert(id)
                collected.collectionIssues.removeValue(forKey: id)
            } catch { collected.collectionIssues[id] = error.localizedDescription }
        }
        sessions = Array(finalSessions.values).sorted { $0.updatedAt > $1.updatedAt }
        let plan = RuleEngine.plan(rules: eventRules, sessions: sessions)
        runMatched = plan.count
        let plannedIDs = Set(plan.map(\.id))
        logs.append(AutomationLogEntry(kind: .info, message: LF("Collection: %d catalog, %d live, %d unresolved, %d planned", sessions.count, collected.liveSessionIDs.count, collected.collectionIssues.count, plan.count), eventID: event.id))
        for id in auditIDs.sorted() {
            guard let session = finalSessions[id] else { continue }
            let config = [session.status.rawValue, session.model ?? "unknown", session.reasoning?.rawValue ?? "unknown", session.speed?.rawValue ?? "unknown"].joined(separator: " · ")
            let excluded: String
            if let rule = eventRules.first(where: { $0.enabled && $0.selector.matches(session) }), !rule.scope.includes(session) {
                excluded = LF("Outside rule scope (%@): %@", rule.scope.rawValue, session.status.rawValue)
            } else { excluded = L("Current settings no longer match the enabled rules") }
            let reason = collected.collectionIssues[id] ?? (plannedIDs.contains(id) ? L("Included in reset plan") : excluded)
            logs.append(AutomationLogEntry(kind: plannedIDs.contains(id) ? .info : .skipped,
                message: session.title + " · " + config + " · " + reason, eventID: event.id, sessionID: id))
        }
        if !collected.collectionIssues.isEmpty {
            runFailed += 1
            logs.append(AutomationLogEntry(kind: .failed, message: LF("Live collection remains incomplete for %d sessions", collected.collectionIssues.count), eventID: event.id))
        }
        for item in plan {
            logs.append(AutomationLogEntry(kind: .planned, message: "\(item.ruleName) → \(item.session.title)", eventID: event.id, sessionID: item.session.id, ruleID: item.ruleID))
        }
        // The event has already consumed this listening cycle. Save it before any mutation.
        guard await checkpoint() else { runFailed = max(1, plan.count); return }
        for item in plan {
            guard listener.phase == .executing, generation == listener.generation,
                  rules.contains(where: { $0.id == item.ruleID && $0.enabled && $0.action == item.action && $0.matches(item.session) }) else {
                runFailed += 1
                logs.append(AutomationLogEntry(kind: .skipped, message: "\(item.session.title) · Rule changed or monitoring paused", eventID: event.id, sessionID: item.session.id, ruleID: item.ruleID))
                continue
            }
            if let reason = item.unavailableReason {
                runFailed += 1
                logs.append(AutomationLogEntry(kind: .skipped, message: "\(item.session.title) · \(reason)", eventID: event.id, sessionID: item.session.id, ruleID: item.ruleID))
            } else {
                do {
                    let receipt = try await backend.execute(action: item.action, session: item.session, matching: rules.first { $0.id == item.ruleID })
                    runSucceeded += 1
                    logs.append(AutomationLogEntry(kind: .succeeded, message: "\(item.session.title) · \(receipt.detail)", eventID: event.id, sessionID: item.session.id, ruleID: item.ruleID))
                } catch {
                    runFailed += 1
                    logs.append(AutomationLogEntry(kind: .failed, message: "\(item.session.title) · \(error.localizedDescription)", eventID: event.id, sessionID: item.session.id, ruleID: item.ruleID))
                }
            }
            guard await checkpoint() else { runFailed += 1; return }
        }
        logs.append(AutomationLogEntry(kind: .info, message: "One-time listening completed", eventID: event.id))
        _ = await checkpoint()
    }

    func saveRule(_ rule: AutomationRule) async -> Bool {
        guard !isInstallingUpdate else { return false }
        isSavingRules = true
        defer { isSavingRules = false }
        guard persistenceReady else { storageError = "Saved data is unavailable. Your existing rules have been preserved."; return false }
        let previousRules = rules
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        if await checkpoint() { return true }
        rules = previousRules
        return false
    }
    func deleteRule(_ id: UUID) { guard !isInstallingUpdate else { return }; rules.removeAll { $0.id == id }; persist() }
    func duplicateRule(_ rule: AutomationRule) {
        guard !isInstallingUpdate else { return }
        var copy = rule; copy.id = UUID(); copy.enabled = false
        rules.append(copy); persist()
    }
    func toggleRule(_ id: UUID, _ enabled: Bool) {
        guard !isInstallingUpdate else { return }
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled; persist()
    }
    func moveRule(_ id: UUID, direction: Int) {
        guard !isInstallingUpdate else { return }
        guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + direction) else { return }
        rules.swapAt(index, index + direction); persist()
    }
    func moveRule(_ draggedID: UUID, before target: UUID) {
        guard !isInstallingUpdate else { return }
        guard draggedID != target, let start = rules.firstIndex(where: { $0.id == draggedID }), let end = rules.firstIndex(where: { $0.id == target }) else { return }
        rules.move(fromOffsets: IndexSet(integer: start), toOffset: end > start ? end + 1 : end); persist()
    }
    func filteredSessions(query: String, runningOnly: Bool, now: Date = Date()) -> [Session] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = try? SessionReference.sessionID(from: trimmed)
        return sessions.filter { session in
            session.isRecentOrRunning(at: now) && (!runningOnly || session.status == .running) && (reference.map { session.id == $0 } ?? session.matchesSearch(trimmed))
        }
    }
    func searchSessions(_ query: String) async {
        guard query.count >= 2 else { return }
        searchGeneration += 1
        let requestGeneration = searchGeneration
        let connection = connectionGeneration
        do {
            let result = try await service.searchSessions(query)
            guard !Task.isCancelled, requestGeneration == searchGeneration, connection == connectionGeneration else { return }
            mergeSessions(result)
        }
        catch { errorMessage = "Search failed: \(error.localizedDescription)" }
    }
    @discardableResult func resolveSession(_ link: String) async -> Bool {
        let connection = connectionGeneration
        do {
            let result = try await service.resolve(deepLink: link)
            guard !Task.isCancelled, connection == connectionGeneration else { return false }
            mergeSessions([result])
            return true
        }
        catch { errorMessage = error.localizedDescription; return false }
    }
    private func mergeSessions(_ items: [Session]) {
        var byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for item in items {
            if let existing = byID[item.id], existing.updatedAt > item.updatedAt { continue }
            byID[item.id] = item
        }
        sessions = byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }
    func reconnect() async {
        guard !isReconnecting, !isInstallingUpdate else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        if listener.isListening { stopListening() }
        while isRefreshing || isExecuting {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        connectionGeneration += 1
        recoveryTask?.cancel(); recoveryTask = nil; recovery.reset()
        quotaDisplay = QuotaDisplayState(); lastUsageAndSessionsRefresh = nil
        UserDefaults.standard.set(cliPath, forKey: "cliPath")
        resolvedCLIPath = nil; connectionChecked = false
        service = CodexService(configuration: CodexConfiguration(cliPath: cliPath.isEmpty ? nil : cliPath))
        await refresh()
    }
    func useAutomaticCLI() async {
        cliPath = ""
        await reconnect()
    }
    func updatePreferences() {
        UserDefaults.standard.set(pollInterval, forKey: "pollInterval")
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { errorMessage = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    private var state: PersistentAppState { PersistentAppState(rules: rules, resetState: listener.detector.state, logs: Array(logs.suffix(500))) }
    private func persist() {
        guard persistenceReady else { return }
        let snapshot = state; let previous = saveTask
        saveTask = Task { [weak self, persistence] in
            await previous?.value
            do { try await persistence.save(snapshot) }
            catch { self?.storageError = "Cannot save: \(error.localizedDescription)"; self?.listener.stop() }
        }
    }
    private func checkpoint() async -> Bool {
        await saveTask?.value
        do { try await persistence.save(state); return true }
        catch { storageError = "Actions paused: cannot save reset checkpoint. \(error.localizedDescription)"; return false }
    }
}

extension QuotaWindow {
    var friendlyName: String {
        switch windowDurationMins { case 300: return "5-hour"; case 10080: return "Weekly"; default: return displayName }
    }
}
