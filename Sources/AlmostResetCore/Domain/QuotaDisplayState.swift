import Foundation

/// Display-only cache. Cached readings must never be submitted to reset detection.
public struct QuotaDisplayState: Sendable {
    public private(set) var snapshot: QuotaSnapshot?
    public private(set) var isStale = false
    public init() {}

    @discardableResult public mutating func receive(_ reading: QuotaSnapshot?) -> Bool {
        guard let reading, reading.windows.contains(where: { $0.remainingPercent != nil }) else {
            markUnavailable()
            return false
        }
        snapshot = reading
        isStale = false
        return true
    }
    public mutating func markUnavailable() { isStale = true }
}

/// Bounded recovery for read-only refreshes while the listener is idle.
public struct RefreshRecovery: Sendable {
    private var attempts = 0
    public init() {}
    public mutating func nextDelay() -> TimeInterval? {
        let delays: [TimeInterval] = [2, 5]
        guard attempts < delays.count else { return nil }
        defer { attempts += 1 }
        return delays[attempts]
    }
    public mutating func reset() { attempts = 0 }
}
