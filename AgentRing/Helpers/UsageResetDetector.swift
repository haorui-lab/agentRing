import Foundation

enum UsageResetDetector {
    static let warningThreshold: Double = 90
    static let resetDropThreshold: Double = 30
    static let resetDateAdvanceThreshold: TimeInterval = 3600

    static func isReset(
        currentPct: Double,
        previousPct: Double,
        currentResetsAt: Date?,
        previousResetsAt: Date?,
        now: Date = Date()
    ) -> Bool {
        let previousWindowEnded = previousWindowHasEnded(
            previousResetsAt: previousResetsAt,
            now: now
        )

        if previousPct >= warningThreshold && (previousPct - currentPct) > resetDropThreshold {
            return previousWindowEnded
        }

        if let currentResetsAt, let previousResetsAt {
            let advance = currentResetsAt.timeIntervalSince(previousResetsAt)
            if advance > resetDateAdvanceThreshold
                && previousWindowEnded
                && (previousPct - currentPct) > resetDropThreshold {
                return true
            }
        }

        return false
    }

    static func previousWindowHasEnded(
        previousResetsAt: Date?,
        now: Date
    ) -> Bool {
        guard let previousResetsAt else { return true }
        return previousResetsAt.timeIntervalSince(now) <= resetDateAdvanceThreshold
    }
}
