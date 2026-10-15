//
//  UsageResetDetector.swift
//  Agent Ring
//
//  Pure reset detection for usage notifications. Kept free of
//  UserNotifications so Scripts/test-usage-reset-detection.sh can compile it.
//

import Foundation

enum UsageResetDetector {
    static let warningThreshold: Double = 90
    static let resetDropThreshold: Double = 30
    /// Real cycle rollover moves the end date forward by hours or days.
    /// Sub-second parse jitter and source switches that move the date
    /// backward or sideways must not count.
    static let resetDateAdvanceThreshold: TimeInterval = 3600

    /// Decide whether a refresh looks like a quota reset for one limit pool.
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
