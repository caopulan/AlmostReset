import Foundation

public enum ListenerPhase: String, Sendable {
    case idle, preparing, listening, executing, completed
}

/// Owns the armed interval. Claiming an event consumes it synchronously, before
/// persistence or asynchronous session commands, so a second refresh cannot repeat it.
public struct OneShotListener: Sendable {
    public private(set) var phase: ListenerPhase = .idle
    public private(set) var generation: UInt64 = 0
    private var armedAt: Date?
    public private(set) var detector: ResetDetector
    public var isListening: Bool { phase == .preparing || phase == .listening }

    public init(detectorState: ResetDetectorState = .init()) {
        detector = ResetDetector(state: detectorState)
    }

    public mutating func arm(baseline: QuotaSnapshot?, now: Date = Date()) {
        guard phase != .executing else { return }
        generation &+= 1
        detector.requireNewBaseline()
        armedAt = now
        phase = .preparing
        if let baseline { _ = observe(baseline, now: now) }
    }

    public mutating func stop() {
        generation &+= 1
        phase = .idle
    }

    public mutating func observe(_ snapshot: QuotaSnapshot, now: Date = Date()) -> QuotaResetEvent? {
        guard isListening else { return nil }
        if phase == .preparing, let armedAt, snapshot.fetchedAt < armedAt { return nil }
        let event = detector.ingest(snapshot, now: now)
        if let event {
            phase = .executing
            return event
        }
        if ResetDetector.hasValidReading(snapshot, now: now), detector.state.lastFetchedAt == snapshot.fetchedAt {
            phase = .listening
        }
        return nil
    }

    public mutating func finish(generation completedGeneration: UInt64) {
        guard phase == .executing, completedGeneration == generation else { return }
        phase = .completed
    }
}
