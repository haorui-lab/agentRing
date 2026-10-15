import Foundation

@main
struct UsageResetDetectionChecks {
    static func main() {
        checkSourceSwitchDoesNotReset()
        checkJitterDoesNotReset()
        checkDualPoolFalsePositiveDoesNotFireTwice()
        checkBackwardDateJumpDoesNotReset()
        checkMidWindowFallbackToZeroDoesNotReset()
        checkMidWindowHighWatermarkFallbackDoesNotReset()
        checkRealCycleRolloverResets()
        checkHighWatermarkCollapseResets()
        checkTinyDropWithoutDateChangeDoesNotReset()
        checkCrossFetchSourceBlocksComparison()
        checkSameFetchSourceAllowsComparison()
        print("All usage reset detection checks passed.")
    }

    static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if condition() {
            print("PASS: \(message)")
        } else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func checkSourceSwitchDoesNotReset() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let weeklyEnd = now.addingTimeInterval(3 * 86_400)
        let monthlyEnd = now.addingTimeInterval(20 * 86_400)
        let reset = UsageResetDetector.isReset(
            currentPct: 41.5,
            previousPct: 42.0,
            currentResetsAt: monthlyEnd,
            previousResetsAt: weeklyEnd,
            now: now
        )
        check(!reset, "weekly→monthly source switch with 0.5pt drop is not a reset")
    }

    static func checkJitterDoesNotReset() {
        let now = Date(timeIntervalSince1970: 1_792_483_310)
        let end = now.addingTimeInterval(2 * 86_400)
        let reset = UsageResetDetector.isReset(
            currentPct: 39.9,
            previousPct: 40.0,
            currentResetsAt: end.addingTimeInterval(2),
            previousResetsAt: end,
            now: now
        )
        check(!reset, "2s resetsAt jitter with 0.1pt drop is not a reset")
    }

    static func checkDualPoolFalsePositiveDoesNotFireTwice() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let weeklyEnd = now.addingTimeInterval(3 * 86_400)
        let monthlyEnd = now.addingTimeInterval(20 * 86_400)
        let included = UsageResetDetector.isReset(
            currentPct: 40.0,
            previousPct: 40.1,
            currentResetsAt: monthlyEnd,
            previousResetsAt: weeklyEnd,
            now: now
        )
        let onDemand = UsageResetDetector.isReset(
            currentPct: 10.0,
            previousPct: 10.2,
            currentResetsAt: monthlyEnd,
            previousResetsAt: weeklyEnd,
            now: now
        )
        let banners = (included ? 1 : 0) + (onDemand ? 1 : 0)
        check(banners == 0, "shared source-switch date jump must not fire two reset banners")
    }

    static func checkBackwardDateJumpDoesNotReset() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let weeklyEnd = now.addingTimeInterval(3 * 86_400)
        let monthlyEnd = now.addingTimeInterval(20 * 86_400)
        let reset = UsageResetDetector.isReset(
            currentPct: 41.0,
            previousPct: 42.0,
            currentResetsAt: weeklyEnd,
            previousResetsAt: monthlyEnd,
            now: now
        )
        check(!reset, "monthly→weekly backward date jump with tiny drop is not a reset")
    }

    static func checkMidWindowFallbackToZeroDoesNotReset() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let weeklyEnd = now.addingTimeInterval(4 * 86_400)
        let monthlyEnd = now.addingTimeInterval(18 * 86_400)
        let reset = UsageResetDetector.isReset(
            currentPct: 0.0,
            previousPct: 42.0,
            currentResetsAt: monthlyEnd,
            previousResetsAt: weeklyEnd,
            now: now
        )
        check(!reset, "mid-window dashboard→summary 42%→0% is not a reset")
    }

    static func checkMidWindowHighWatermarkFallbackDoesNotReset() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let weeklyEnd = now.addingTimeInterval(4 * 86_400)
        let monthlyEnd = now.addingTimeInterval(18 * 86_400)
        let reset = UsageResetDetector.isReset(
            currentPct: 0.0,
            previousPct: 92.0,
            currentResetsAt: monthlyEnd,
            previousResetsAt: weeklyEnd,
            now: now
        )
        check(!reset, "mid-window dashboard→summary 92%→0% is not a reset")
    }

    static func checkRealCycleRolloverResets() {
        let previousEnd = Date(timeIntervalSince1970: 1_700_000_000)
        let now = previousEnd.addingTimeInterval(60)
        let nextWeek = previousEnd.addingTimeInterval(7 * 86_400)
        let fromHigh = UsageResetDetector.isReset(
            currentPct: 5.0,
            previousPct: 85.0,
            currentResetsAt: nextWeek,
            previousResetsAt: previousEnd,
            now: now
        )
        let fromMid = UsageResetDetector.isReset(
            currentPct: 2.0,
            previousPct: 50.0,
            currentResetsAt: nextWeek,
            previousResetsAt: previousEnd,
            now: now
        )
        check(fromHigh, "real rollover 85%→5% with +7d advance is a reset")
        check(fromMid, "real rollover 50%→2% with +7d advance is a reset")
    }

    static func checkHighWatermarkCollapseResets() {
        let reset = UsageResetDetector.isReset(
            currentPct: 12.0,
            previousPct: 93.0,
            currentResetsAt: nil,
            previousResetsAt: nil
        )
        check(reset, "≥90% then drop >30pt without dates is still a reset")
    }

    static func checkTinyDropWithoutDateChangeDoesNotReset() {
        let now = Date(timeIntervalSince1970: 1_792_483_310)
        let end = now.addingTimeInterval(2 * 86_400)
        let reset = UsageResetDetector.isReset(
            currentPct: 41.0,
            previousPct: 42.0,
            currentResetsAt: end,
            previousResetsAt: end,
            now: now
        )
        check(!reset, "same resetsAt with 1pt drop is not a reset")
    }

    static func checkCrossFetchSourceBlocksComparison() {
        let allowed = CursorUsageNotificationPolicy.allowsComparison(
            current: .usageSummary,
            previous: .dashboard
        )
        check(!allowed, "dashboard→usage-summary must not compare for notifications")
        let reverse = CursorUsageNotificationPolicy.allowsComparison(
            current: .dashboard,
            previous: .usageSummary
        )
        check(!reverse, "usage-summary→dashboard must not compare for notifications")
    }

    static func checkSameFetchSourceAllowsComparison() {
        let first = CursorUsageNotificationPolicy.allowsComparison(
            current: .dashboard,
            previous: nil
        )
        let same = CursorUsageNotificationPolicy.allowsComparison(
            current: .dashboard,
            previous: .dashboard
        )
        check(first, "first sample with no previous still allows comparison")
        check(same, "same fetch source allows comparison")
    }
}
