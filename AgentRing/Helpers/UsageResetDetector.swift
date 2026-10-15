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

        // Legacy predicate (pre-fix): any resetsAt delta >1s with any pct drop.
        // False-positives when Cursor flips dashboard weekly end ↔ usage-summary
        // monthly end, or when two pools share that jump (two banners, ring flat).
        if let currentResetsAt, let previousResetsAt,
           abs(currentResetsAt.timeIntervalSince(previousResetsAt)) > 1,
           currentPct < previousPct {
            return true
        }

        return false
    }
}
