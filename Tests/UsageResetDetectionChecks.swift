import Foundation

// Behavioral checks for UsageResetDetector.
// Usage: Scripts/test-usage-reset-detection.sh
//
// Repro (user report): Cursor "用量已重置" twice while ring/percentage unchanged.
// Cause under test: resetsAt source oscillation + tiny pct noise, checked for
// both included and on-demand pools in one refresh.

@main
struct UsageResetDetectionChecks {
    static func main() {
        checkSourceSwitchDoesNotReset()
        checkJitterDoesNotReset()
        checkDualPoolFalsePositiveDoesNotFireTwice()
        checkBackwardDateJumpDoesNotReset()
        checkRealCycleRolloverResets()
        checkHighWatermarkCollapseResets()
        checkTinyDropWithoutDateChangeDoesNotReset()
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

    /// Dashboard weekly end → usage-summary monthly end, ring barely moved.
    static func checkSourceSwitchDoesNotReset() {
        let weeklyEnd = Date(timeIntervalSince1970: 1_792_483_310)
        let monthlyEnd = weeklyEnd.addingTimeInterval(20 * 86_400)
        let reset = UsageResetDetector.isReset(
            currentPct: 41.5,
            previousPct: 42.0,
            currentResetsAt: monthlyEnd,
            previousResetsAt: weeklyEnd
        )
        check(!reset, "weekly→monthly source switch with 0.5pt drop is not a reset")
    }

    static func checkJitterDoesNotReset() {
        let end = Date(timeIntervalSince1970: 1_792_483_310)
        let reset = UsageResetDetector.isReset(
            currentPct: 39.9,
            previousPct: 40.0,
            currentResetsAt: end.addingTimeInterval(2),
            previousResetsAt: end
        )
        check(!reset, "2s resetsAt jitter with 0.1pt drop is not a reset")
    }

    /// One refresh checks included + onDemand; both must stay quiet when ring is flat.
    static func checkDualPoolFalsePositiveDoesNotFireTwice() {
        let weeklyEnd = Date(timeIntervalSince1970: 1_792_483_310)
        let monthlyEnd = weeklyEnd.addingTimeInterval(20 * 86_400)
        let included = UsageResetDetector.isReset(
            currentPct: 40.0,
            previousPct: 40.1,
            currentResetsAt: monthlyEnd,
            previousResetsAt: weeklyEnd
        )
        let onDemand = UsageResetDetector.isReset(
            currentPct: 10.0,
            previousPct: 10.2,
            currentResetsAt: monthlyEnd,
            previousResetsAt: weeklyEnd
        )
        let banners = (included ? 1 : 0) + (onDemand ? 1 : 0)
        check(banners == 0, "shared source-switch date jump must not fire two reset banners")
    }

    static func checkBackwardDateJumpDoesNotReset() {
        let weeklyEnd = Date(timeIntervalSince1970: 1_792_483_310)
        let monthlyEnd = weeklyEnd.addingTimeInterval(20 * 86_400)
        let reset = UsageResetDetector.isReset(
            currentPct: 41.0,
            previousPct: 42.0,
            currentResetsAt: weeklyEnd,
            previousResetsAt: monthlyEnd
        )
        check(!reset, "monthly→weekly backward date jump with tiny drop is not a reset")
    }

    static func checkRealCycleRolloverResets() {
        let previousEnd = Date(timeIntervalSince1970: 1_700_000_000)
        let nextWeek = previousEnd.addingTimeInterval(7 * 86_400)
        let fromHigh = UsageResetDetector.isReset(
            currentPct: 5.0,
            previousPct: 85.0,
            currentResetsAt: nextWeek,
            previousResetsAt: previousEnd
        )
        let fromMid = UsageResetDetector.isReset(
            currentPct: 2.0,
            previousPct: 50.0,
            currentResetsAt: nextWeek,
            previousResetsAt: previousEnd
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
        let end = Date(timeIntervalSince1970: 1_792_483_310)
        let reset = UsageResetDetector.isReset(
            currentPct: 41.0,
            previousPct: 42.0,
            currentResetsAt: end,
            previousResetsAt: end
        )
        check(!reset, "same resetsAt with 1pt drop is not a reset")
    }
}
