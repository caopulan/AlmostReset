import Foundation

public struct QuotaWindow: Identifiable, Codable, Equatable, Sendable {
    public var limitID: String
    public var windowDurationMins: Int?
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var label: String?

    public init(limitID: String, windowDurationMins: Int? = nil, usedPercent: Double? = nil,
                resetsAt: Date? = nil, label: String? = nil) {
        self.limitID = limitID
        self.windowDurationMins = windowDurationMins
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.label = label
    }

    public var id: String { "\(limitID.utf8.count):\(limitID):\(windowDurationMins.map(String.init) ?? "unknown")" }

    public var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        return 100 - usedPercent
    }

    public var displayName: String {
        if let label, !label.isEmpty { return label }
        guard let minutes = windowDurationMins else { return limitID }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    /// A stable account identity from the authenticated source, never a credential.
    public var accountID: String
    /// Distinguishes the owning host or connection. Changes establish a new baseline.
    public var sourceID: String
    public var fetchedAt: Date
    public var windows: [QuotaWindow]

    public init(accountID: String, sourceID: String, fetchedAt: Date = Date(), windows: [QuotaWindow]) {
        self.accountID = accountID
        self.sourceID = sourceID
        self.fetchedAt = fetchedAt
        self.windows = windows
    }
}
