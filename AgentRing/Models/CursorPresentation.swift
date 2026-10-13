//
//  CursorPresentation.swift
//  Agent Ring
//
//  Presentation contract for Cursor usage: views read keys/kind here,
//  never raw membershipType. Built at the API boundary with the pools.
//

import Foundation

struct CursorPresentation: Sendable, Equatable {
    enum Cadence: String, Sendable, Equatable {
        case weekly
        case monthly
        case unknown
    }

    enum SecondaryKind: String, Sendable, Equatable {
        case apiModels
        case onDemandSpend
        case additionalUsageCredits
        case absent
    }

    /// Internal only — logging and tests. Views must not switch on this.
    enum BillingMode: String, Sendable, Equatable {
        case legacyCursor
        case xSubscription
    }

    let cadence: Cadence
    let membershipDisplayName: String
    let includedLabelKey: String
    let secondaryLabelKey: String?
    let secondaryKind: SecondaryKind
    let onDemandLabelKey: String?
    let billingMode: BillingMode
}

enum CursorPresentationBuilder {
    /// Localization keys shared with Localizable.strings.
    enum LabelKey {
        static let includedLegacy = "detail_row.cursor_included"
        static let secondaryApiModels = "detail_row.cursor_ondemand"
        static let includedWeekly = "detail_row.cursor_included_weekly"
        static let additionalUsage = "detail_row.cursor_additional_usage"
        static let onDemandSpend = "detail_row.cursor_ondemand_spend"
    }

    static func from(
        _ response: CursorUsageSummaryResponse,
        secondaryPool: CursorUsageData.LimitData?,
        onDemandPool: CursorUsageData.OnDemandData?,
        now: Date = Date()
    ) -> CursorPresentation {
        let cadence = inferCadence(
            start: CursorUsageMapper.parseISO8601(response.billingCycleStart),
            end: CursorUsageMapper.parseISO8601(response.billingCycleEnd),
            now: now
        )
        let membershipToken = normalizedMembershipToken(response.membershipType)
        let billingMode = inferBillingMode(membershipToken: membershipToken, cadence: cadence)
        let membershipDisplayName = displayName(forMembershipToken: membershipToken)

        switch billingMode {
        case .xSubscription:
            return xSubscriptionPresentation(
                cadence: cadence,
                membershipDisplayName: membershipDisplayName,
                secondaryPool: secondaryPool,
                onDemandPool: onDemandPool
            )
        case .legacyCursor:
            return legacyPresentation(
                cadence: cadence,
                membershipDisplayName: membershipDisplayName,
                secondaryPool: secondaryPool,
                onDemandPool: onDemandPool
            )
        }
    }

    // MARK: - Cadence / billing detection

    static func inferCadence(start: Date?, end: Date?, now: Date = Date()) -> CursorPresentation.Cadence {
        inferCadence(start: start, end: end, includedUsagePeriod: nil, now: now)
    }

    static func inferCadence(
        start: Date?,
        end: Date?,
        includedUsagePeriod: String?,
        now: Date = Date()
    ) -> CursorPresentation.Cadence {
        if let periodHint = cadenceFromIncludedUsagePeriod(includedUsagePeriod) {
            return periodHint
        }
        if let start, let end {
            let days = end.timeIntervalSince(start) / 86_400
            if days >= 5 && days <= 9 { return .weekly }
            if days >= 25 && days <= 35 { return .monthly }
            return .unknown
        }
        // Only an end date: estimate remaining window from now (weaker signal).
        if let end {
            let days = end.timeIntervalSince(now) / 86_400
            if days >= 0 && days <= 9 { return .weekly }
            if days >= 20 && days <= 35 { return .monthly }
        }
        return .unknown
    }

    /// Dashboard plan-info uses INCLUDED_USAGE_PERIOD_WEEKLY / _MONTHLY.
    static func cadenceFromIncludedUsagePeriod(_ raw: String?) -> CursorPresentation.Cadence? {
        guard let raw else { return nil }
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return nil }
        if upper.contains("WEEKLY") { return .weekly }
        if upper.contains("MONTHLY") { return .monthly }
        return nil
    }

    static func inferBillingMode(
        membershipToken: String?,
        cadence: CursorPresentation.Cadence
    ) -> CursorPresentation.BillingMode {
        inferBillingMode(
            membershipToken: membershipToken,
            cadence: cadence,
            isMerged: nil,
            includedUsagePeriod: nil
        )
    }

    static func inferBillingMode(
        membershipToken: String?,
        cadence: CursorPresentation.Cadence,
        isMerged: Bool?,
        includedUsagePeriod: String?
    ) -> CursorPresentation.BillingMode {
        // Dashboard plan-info: merged X billing or explicit weekly included period.
        if isMerged == true {
            return .xSubscription
        }
        if cadenceFromIncludedUsagePeriod(includedUsagePeriod) == .weekly {
            return .xSubscription
        }
        // Live Cursor API (2026-10): X Premium still returns a ~30d billingCycleSpan.
        // Unambiguous X tokens (plus/premium/super/x_*) → X presentation regardless of cadence.
        // Tokens that collide with classic Cursor plans (free/ultra) still need weekly cadence.
        // Unknown membership → legacyCursor.
        guard let token = membershipToken, !token.isEmpty else {
            return .legacyCursor
        }
        if isUnambiguousXSubscriptionMembershipToken(token) {
            return .xSubscription
        }
        if cadence == .weekly, isAmbiguousXSubscriptionMembershipToken(token) {
            return .xSubscription
        }
        return .legacyCursor
    }

    /// Tokens that classic Cursor never used as membershipType — safe without weekly cadence.
    static func isUnambiguousXSubscriptionMembershipToken(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        if token.hasPrefix("x_") || token.hasPrefix("x-") { return true }
        switch token {
        case "plus", "premium", "super":
            return true
        default:
            return false
        }
    }

    /// Tokens that also appear on classic Cursor plans — require weekly cadence.
    static func isAmbiguousXSubscriptionMembershipToken(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        switch token {
        case "free", "ultra":
            return true
        default:
            return false
        }
    }

    /// Any token that can select X presentation (unambiguous, or ambiguous+weekly).
    static func isXSubscriptionMembershipToken(_ token: String?) -> Bool {
        isUnambiguousXSubscriptionMembershipToken(token)
            || isAmbiguousXSubscriptionMembershipToken(token)
    }

    static func normalizedMembershipToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func displayName(forMembershipToken token: String?) -> String {
        guard let token else { return "Cursor" }
        let stripped: String = {
            if token.hasPrefix("x_") { return String(token.dropFirst(2)) }
            if token.hasPrefix("x-") { return String(token.dropFirst(2)) }
            return token
        }()
        switch stripped {
        case "free": return "Free"
        case "plus": return "Plus"
        case "premium": return "Premium"
        case "super": return "Super"
        case "ultra": return "Ultra"
        case "pro": return "Pro"
        case "pro_plus", "pro-plus", "proplus": return "Pro+"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "hobby": return "Hobby"
        case "free_trial", "freetrial", "trial": return "Trial"
        default:
            return stripped
                .split(whereSeparator: { $0 == "_" || $0 == "-" })
                .map { part in
                    guard let first = part.first else { return "" }
                    return String(first).uppercased() + part.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    // MARK: - Dashboard path

    static func fromDashboard(
        planName: String?,
        membershipToken: String?,
        cadence: CursorPresentation.Cadence,
        billingMode: CursorPresentation.BillingMode,
        secondaryPool: CursorUsageData.LimitData?,
        onDemandPool: CursorUsageData.OnDemandData?
    ) -> CursorPresentation {
        let membershipDisplayName: String = {
            if let planName, !planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Prefer the dashboard's display planName (e.g. "Premium") as-is when already titled.
                let trimmed = planName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == trimmed.lowercased() || trimmed == trimmed.uppercased() {
                    return displayName(forMembershipToken: membershipToken ?? trimmed.lowercased())
                }
                return trimmed
            }
            return displayName(forMembershipToken: membershipToken)
        }()

        switch billingMode {
        case .xSubscription:
            return xSubscriptionPresentation(
                cadence: cadence,
                membershipDisplayName: membershipDisplayName,
                secondaryPool: secondaryPool,
                onDemandPool: onDemandPool
            )
        case .legacyCursor:
            return legacyPresentation(
                cadence: cadence,
                membershipDisplayName: membershipDisplayName,
                secondaryPool: secondaryPool,
                onDemandPool: onDemandPool
            )
        }
    }

    // MARK: - Presentation variants

    private static func legacyPresentation(
        cadence: CursorPresentation.Cadence,
        membershipDisplayName: String,
        secondaryPool: CursorUsageData.LimitData?,
        onDemandPool: CursorUsageData.OnDemandData?
    ) -> CursorPresentation {
        if secondaryPool != nil {
            return CursorPresentation(
                cadence: cadence,
                membershipDisplayName: membershipDisplayName,
                includedLabelKey: LabelKey.includedLegacy,
                secondaryLabelKey: LabelKey.secondaryApiModels,
                secondaryKind: .apiModels,
                onDemandLabelKey: onDemandPool != nil ? LabelKey.onDemandSpend : nil,
                billingMode: .legacyCursor
            )
        }
        if onDemandPool != nil {
            return CursorPresentation(
                cadence: cadence,
                membershipDisplayName: membershipDisplayName,
                includedLabelKey: LabelKey.includedLegacy,
                secondaryLabelKey: LabelKey.onDemandSpend,
                secondaryKind: .onDemandSpend,
                onDemandLabelKey: LabelKey.onDemandSpend,
                billingMode: .legacyCursor
            )
        }
        return CursorPresentation(
            cadence: cadence,
            membershipDisplayName: membershipDisplayName,
            includedLabelKey: LabelKey.includedLegacy,
            secondaryLabelKey: nil,
            secondaryKind: .absent,
            onDemandLabelKey: nil,
            billingMode: .legacyCursor
        )
    }

    private static func xSubscriptionPresentation(
        cadence: CursorPresentation.Cadence,
        membershipDisplayName: String,
        secondaryPool: CursorUsageData.LimitData?,
        onDemandPool: CursorUsageData.OnDemandData?
    ) -> CursorPresentation {
        // Mapper clears apiPercent secondary for X; if a secondary pool is passed
        // anyway, treat it as Additional Usage rather than legacy Other Models.
        if secondaryPool != nil {
            return CursorPresentation(
                cadence: cadence,
                membershipDisplayName: membershipDisplayName,
                includedLabelKey: LabelKey.includedWeekly,
                secondaryLabelKey: LabelKey.additionalUsage,
                secondaryKind: .additionalUsageCredits,
                onDemandLabelKey: onDemandPool != nil ? LabelKey.additionalUsage : nil,
                billingMode: .xSubscription
            )
        }
        if onDemandPool != nil {
            return CursorPresentation(
                cadence: cadence,
                membershipDisplayName: membershipDisplayName,
                includedLabelKey: LabelKey.includedWeekly,
                secondaryLabelKey: LabelKey.additionalUsage,
                secondaryKind: .additionalUsageCredits,
                onDemandLabelKey: LabelKey.additionalUsage,
                billingMode: .xSubscription
            )
        }
        return CursorPresentation(
            cadence: cadence,
            membershipDisplayName: membershipDisplayName,
            includedLabelKey: LabelKey.includedWeekly,
            secondaryLabelKey: nil,
            secondaryKind: .absent,
            onDemandLabelKey: nil,
            billingMode: .xSubscription
        )
    }
}
