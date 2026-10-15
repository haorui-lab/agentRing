import Foundation

enum UsageResetDetector {
    static let warningThreshold: Double = 90
    static let resetDropThreshold: Double = 30
    static let resetDateAdvanceThreshold: TimeInterval = 3600

    static func isReset(
        currentPct: Double,
        previousPct: Double,
        currentResetsAt: Date?,
        previousResetsAt: Date?
    ) -> Bool {
        if previousPct >= warningThreshold && (previousPct - currentPct) > resetDropThreshold {
            return true
        }

        if let currentResetsAt, let previousResetsAt {
            let advance = currentResetsAt.timeIntervalSince(previousResetsAt)
            if advance > resetDateAdvanceThreshold
                && (previousPct - currentPct) > resetDropThreshold {
                return true
            }
        }

        return false
    }
}
