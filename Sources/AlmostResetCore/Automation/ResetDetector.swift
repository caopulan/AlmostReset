import Foundation

public enum ResetEvidence: String, Codable, Sendable {
    case allowanceIncrease
    case advancedBoundary
    case substantialUsageDrop
}

public struct QuotaResetWindow: Identifiable, Codable, Equatable, Sendable {
    public var windowID: String
    public var previous: QuotaWindow
    public var current: QuotaWindow
    public var boundaryID: String
    public var evidence: ResetEvidence
    public var id: String { boundaryID }
}

public struct QuotaResetEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var accountID: String
    public var sourceID: String
    public var detectedAt: Date
    /// Every window detected in a single refresh belongs to one event; plan actions once.
    public var windows: [QuotaResetWindow]

    public init(id: UUID = UUID(), accountID: String, sourceID: String,
                detectedAt: Date, windows: [QuotaResetWindow]) {
        self.id = id
        self.accountID = accountID
        self.sourceID = sourceID
        self.detectedAt = detectedAt
        self.windows = windows
    }
}

public struct QuotaObservation: Codable, Equatable, Sendable {
    public var window: QuotaWindow
    public var fetchedAt: Date
    /// Remains nil when this boundary was already expired at startup or reconnection.
    public var boundaryFirstObservedAt: Date?
}

public struct ResetDetectorState: Codable, Equatable, Sendable {
    public var activeContextID: String?
    public var lastFetchedAt: Date?
    public var observations: [String: QuotaObservation]
    public var handledBoundaryIDs: [String]
    public var handledBatchIDs: [String]

    public init(activeContextID: String? = nil, lastFetchedAt: Date? = nil,
                observations: [String: QuotaObservation] = [:], handledBoundaryIDs: [String] = [],
                handledBatchIDs: [String] = []) {
        self.activeContextID = activeContextID
        self.lastFetchedAt = lastFetchedAt
        self.observations = observations
        self.handledBoundaryIDs = handledBoundaryIDs
        self.handledBatchIDs = handledBatchIDs
    }

    private enum CodingKeys: String, CodingKey {
        case activeContextID, lastFetchedAt, observations, handledBoundaryIDs, handledBatchIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeContextID = try container.decodeIfPresent(String.self, forKey: .activeContextID)
        lastFetchedAt = try container.decodeIfPresent(Date.self, forKey: .lastFetchedAt)
        observations = try container.decodeIfPresent([String: QuotaObservation].self, forKey: .observations) ?? [:]
        handledBoundaryIDs = try container.decodeIfPresent([String].self, forKey: .handledBoundaryIDs) ?? []
        handledBatchIDs = try container.decodeIfPresent([String].self, forKey: .handledBatchIDs) ?? []
    }
}

/// Every increase in remaining quota is a reset. Deadlines and drop thresholds
/// never participate in the comparison. Missing/invalid data is not a zero reading.
public struct ResetDetector: Sendable {
    public private(set) var state: ResetDetectorState
    public var maximumSnapshotAge: TimeInterval

    public init(state: ResetDetectorState = ResetDetectorState(), maximumSnapshotAge: TimeInterval = 180) {
        self.state = state
        self.maximumSnapshotAge = maximumSnapshotAge
    }

    public mutating func requireNewBaseline() {
        state.activeContextID = nil
        state.lastFetchedAt = nil
        state.observations = [:]
    }

    public static func hasValidReading(_ snapshot: QuotaSnapshot, now: Date = Date(), maximumAge: TimeInterval = 180) -> Bool {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        return !snapshot.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !snapshot.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            age >= -30 && age <= maximumAge && snapshot.windows.contains { !$0.limitID.isEmpty && validUsage($0.usedPercent) != nil }
    }

    public mutating func ingest(_ snapshot: QuotaSnapshot, now: Date = Date()) -> QuotaResetEvent? {
        guard Self.hasValidReading(snapshot, now: now, maximumAge: maximumSnapshotAge) else { return nil }
        let context = "\(snapshot.accountID.utf8.count):\(snapshot.accountID)|\(snapshot.sourceID.utf8.count):\(snapshot.sourceID)"
        let changedAccount = context != state.activeContextID
        if !changedAccount, let last = state.lastFetchedAt, snapshot.fetchedAt <= last { return nil }
        if changedAccount {
            state.observations = [:]
            state.activeContextID = context
        }
        let unique = Dictionary(grouping: snapshot.windows, by: \.id).values.compactMap { $0.count == 1 ? $0[0] : nil }
        var increases: [QuotaResetWindow] = []
        for current in unique {
            guard !current.limitID.isEmpty, let after = Self.validUsage(current.usedPercent) else { continue }
            if let previous = state.observations[current.id],
               let before = Self.validUsage(previous.window.usedPercent), after < before {
                let eventKey = "\(context)|\(current.id)|\(previous.fetchedAt.timeIntervalSince1970)|\(snapshot.fetchedAt.timeIntervalSince1970)"
                increases.append(QuotaResetWindow(windowID: current.id, previous: previous.window, current: current,
                                                  boundaryID: eventKey, evidence: .allowanceIncrease))
                state.handledBoundaryIDs.append(eventKey)
            }
            state.observations[current.id] = QuotaObservation(window: current, fetchedAt: snapshot.fetchedAt, boundaryFirstObservedAt: nil)
        }
        state.lastFetchedAt = snapshot.fetchedAt
        if state.handledBoundaryIDs.count > 512 { state.handledBoundaryIDs = Array(state.handledBoundaryIDs.suffix(512)) }
        guard !increases.isEmpty else { return nil }
        return QuotaResetEvent(accountID: snapshot.accountID, sourceID: snapshot.sourceID,
                               detectedAt: snapshot.fetchedAt, windows: increases.sorted { $0.windowID < $1.windowID })
    }

    private static func validUsage(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}
