import Foundation

// Cursor usage mapper + presentation builder checks against fixture JSON.
// Usage: Scripts/test-cursor-usage-mapper.sh

@main
struct CursorUsageMapperChecks {
    static func main() {
        let fixturesRoot = resolveFixturesRoot()

        checkLegacyProMonthly(fixturesRoot)
        checkXSubWeeklyPlus(fixturesRoot)
        checkXSubWeeklyPremiumOnDemand(fixturesRoot)
        checkXSubWeeklyUltra(fixturesRoot)
        checkAmbiguousOddCycle(fixturesRoot)
        checkAmbiguousPlusMonthly(fixturesRoot)
        checkCadenceHelpers()
        checkMembershipDisplayNames()

        print("All cursor usage mapper checks passed.")
    }

    // MARK: - Fixtures

    static func checkLegacyProMonthly(_ root: URL) {
        let usage = mapFixture(root, "legacy-pro-monthly.json")
        expect(usage.included?.percentage == 42.5, "legacy included uses autoPercentUsed")
        expect(usage.secondary?.percentage == 18.0, "legacy secondary uses apiPercentUsed")
        expect(usage.onDemand != nil, "legacy onDemand present")
        expect(abs((usage.onDemand?.percentage ?? -1) - 30.0) < 0.01, "legacy onDemand is 1500/5000 = 30%")
        expect(usage.presentation.billingMode == .legacyCursor, "legacy billingMode")
        expect(usage.presentation.cadence == .monthly, "legacy cadence monthly (~30d)")
        expect(usage.presentation.membershipDisplayName == "Pro", "legacy membershipDisplayName Pro")
        expect(
            usage.presentation.includedLabelKey == CursorPresentationBuilder.LabelKey.includedLegacy,
            "legacy included label key"
        )
        expect(
            usage.presentation.secondaryLabelKey == CursorPresentationBuilder.LabelKey.secondaryApiModels,
            "legacy secondary label is Other Models"
        )
        expect(usage.presentation.secondaryKind == .apiModels, "legacy secondaryKind apiModels")
        expect(
            usage.presentation.onDemandLabelKey == CursorPresentationBuilder.LabelKey.onDemandSpend,
            "legacy onDemand label key when spend present"
        )
    }

    static func checkXSubWeeklyPlus(_ root: URL) {
        let usage = mapFixture(root, "x-sub-weekly-plus.json")
        expect(usage.included?.percentage == 24.0, "x-sub plus included")
        expect(usage.secondary == nil, "x-sub plus has no apiPercent secondary")
        expect(usage.onDemand == nil, "x-sub plus fixture has no onDemand")
        expect(usage.presentation.billingMode == .xSubscription, "plus+weekly → xSubscription")
        expect(usage.presentation.cadence == .weekly, "plus cycle ~7d → weekly")
        expect(usage.presentation.membershipDisplayName == "Plus", "Plus display name")
        expect(
            usage.presentation.includedLabelKey == CursorPresentationBuilder.LabelKey.includedWeekly,
            "x-sub included uses weekly label key"
        )
        expect(usage.presentation.secondaryKind == .absent, "x-sub plus secondaryKind absent")
        expect(usage.presentation.secondaryLabelKey == nil, "x-sub plus no secondary label")
        expect(usage.presentation.onDemandLabelKey == nil, "x-sub plus no onDemand label")
    }

    static func checkXSubWeeklyPremiumOnDemand(_ root: URL) {
        let usage = mapFixture(root, "x-sub-weekly-premium-ondemand.json")
        expect(usage.included?.percentage == 67.5, "premium included")
        expect(usage.secondary == nil, "premium has no apiPercent")
        expect(usage.onDemand != nil, "premium onDemand present")
        expect(abs((usage.onDemand?.percentage ?? -1) - 40.0) < 0.01, "premium onDemand 800/2000 = 40%")
        expect(usage.presentation.billingMode == .xSubscription, "premium+weekly → xSubscription")
        expect(usage.presentation.cadence == .weekly, "premium cadence weekly")
        expect(usage.presentation.membershipDisplayName == "Premium", "Premium display name")
        expect(
            usage.presentation.includedLabelKey == CursorPresentationBuilder.LabelKey.includedWeekly,
            "premium included weekly label"
        )
        expect(usage.presentation.secondaryKind == .additionalUsageCredits, "premium secondaryKind additionalUsageCredits")
        expect(
            usage.presentation.secondaryLabelKey == CursorPresentationBuilder.LabelKey.additionalUsage,
            "premium secondary label Additional Usage"
        )
        expect(
            usage.presentation.onDemandLabelKey == CursorPresentationBuilder.LabelKey.additionalUsage,
            "premium onDemand label Additional Usage"
        )
    }

    static func checkXSubWeeklyUltra(_ root: URL) {
        let usage = mapFixture(root, "x-sub-weekly-ultra.json")
        expect(usage.presentation.billingMode == .xSubscription, "x_ultra+weekly → xSubscription")
        expect(usage.presentation.membershipDisplayName == "Ultra", "x_ultra strips to Ultra")
        expect(
            usage.presentation.includedLabelKey == CursorPresentationBuilder.LabelKey.includedWeekly,
            "ultra weekly included label"
        )
        expect(usage.presentation.secondaryKind == .absent, "ultra fixture secondary absent")
    }

    static func checkAmbiguousOddCycle(_ root: URL) {
        let usage = mapFixture(root, "ambiguous-odd-cycle.json")
        expect(usage.presentation.billingMode == .legacyCursor, "ambiguous odd cycle → legacy")
        expect(usage.presentation.cadence == .unknown, "15d cycle → unknown cadence")
        expect(
            usage.presentation.includedLabelKey == CursorPresentationBuilder.LabelKey.includedLegacy,
            "ambiguous keeps legacy included labels"
        )
        expect(usage.presentation.secondaryKind == .apiModels, "ambiguous still maps apiPercent to secondary")
        expect(usage.secondary?.percentage == 12.0, "ambiguous secondary percent")
    }

    static func checkAmbiguousPlusMonthly(_ root: URL) {
        let usage = mapFixture(root, "ambiguous-plus-monthly.json")
        // plus token alone is not enough — need weekly cadence
        expect(usage.presentation.billingMode == .legacyCursor, "plus+monthly → legacy (safer default)")
        expect(usage.presentation.cadence == .monthly, "plus monthly cadence")
        expect(
            usage.presentation.includedLabelKey == CursorPresentationBuilder.LabelKey.includedLegacy,
            "plus+monthly uses legacy included label"
        )
        expect(usage.presentation.secondaryKind == .absent, "plus monthly no secondary pool")
        expect(usage.presentation.membershipDisplayName == "Plus", "display name still Plus")
    }

    static func checkCadenceHelpers() {
        let cal = ISO8601DateFormatter()
        cal.formatOptions = [.withInternetDateTime]
        let start = cal.date(from: "2026-10-06T00:00:00Z")!
        let endWeekly = cal.date(from: "2026-10-13T00:00:00Z")!
        let endMonthly = cal.date(from: "2026-11-06T00:00:00Z")!
        let endOdd = cal.date(from: "2026-10-20T00:00:00Z")!

        expect(
            CursorPresentationBuilder.inferCadence(start: start, end: endWeekly) == .weekly,
            "helper 7d → weekly"
        )
        expect(
            CursorPresentationBuilder.inferCadence(start: start, end: endMonthly) == .monthly,
            "helper ~31d → monthly"
        )
        expect(
            CursorPresentationBuilder.inferCadence(start: start, end: endOdd) == .unknown,
            "helper 14d → unknown"
        )
    }

    static func checkMembershipDisplayNames() {
        expect(CursorPresentationBuilder.displayName(forMembershipToken: "pro") == "Pro", "pro → Pro")
        expect(CursorPresentationBuilder.displayName(forMembershipToken: "premium") == "Premium", "premium → Premium")
        expect(CursorPresentationBuilder.displayName(forMembershipToken: "x_super") == "Super", "x_super → Super")
        expect(CursorPresentationBuilder.displayName(forMembershipToken: "pro_plus") == "Pro+", "pro_plus → Pro+")
        expect(CursorPresentationBuilder.isXSubscriptionMembershipToken("ultra"), "ultra is X-tier")
        expect(CursorPresentationBuilder.isXSubscriptionMembershipToken("x_free"), "x_free is X-tier")
        expect(!CursorPresentationBuilder.isXSubscriptionMembershipToken("pro"), "pro is not X-tier token")
        expect(!CursorPresentationBuilder.isXSubscriptionMembershipToken(nil), "nil membership is not X-tier")
    }

    // MARK: - Helpers

    static func mapFixture(_ root: URL, _ name: String) -> CursorUsageData {
        let url = root.appendingPathComponent(name)
        do {
            let data = try Data(contentsOf: url)
            let response = try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
            return CursorUsageMapper.map(response, now: fixedNow())
        } catch {
            fputs("FAIL: could not load/decode \(name): \(error)\n", stderr)
            exit(1)
        }
    }

    static func fixedNow() -> Date {
        // Mid-window so remaining-day heuristics stay stable if used.
        let cal = ISO8601DateFormatter()
        cal.formatOptions = [.withInternetDateTime]
        return cal.date(from: "2026-10-10T12:00:00Z")!
    }

    static func resolveFixturesRoot() -> URL {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("Tests/Fixtures/cursor-usage"),
            cwd.appendingPathComponent("../Tests/Fixtures/cursor-usage")
        ]
        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        fputs("FAIL: could not find Tests/Fixtures/cursor-usage\n", stderr)
        exit(1)
    }

    static func expect(_ condition: Bool, _ name: String) {
        if !condition {
            fputs("FAIL: \(name)\n", stderr)
            exit(1)
        }
        print("PASS: \(name)")
    }
}
