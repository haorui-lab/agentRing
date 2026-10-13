//
//  CursorUsageData.swift
//  Agent Ring
//

import Foundation
import OSLog

struct CursorUsageData: Sendable {
    /// Cursor Models / weekly included pool (`autoPercentUsed`) — primary dashboard bar.
    let included: LimitData?
    /// Secondary pool (`apiPercentUsed` when present) — renamed from apiModels.
    let secondary: LimitData?
    /// Paid on-demand / additional-usage spend, when Cursor exposes a dollar cap.
    let onDemand: OnDemandData?
    /// Raw API membership token — for logging only; views use `presentation`.
    let membershipType: String?
    let billingCycleEnd: Date?
    /// View-facing labels and cadence; built at the API boundary.
    let presentation: CursorPresentation

    struct LimitData: Sendable {
        let percentage: Double
        let resetsAt: Date?
        let used: Double?
        let limit: Double?
    }

    struct OnDemandData: Sendable {
        let percentage: Double
        let usedCents: Double
        let limitCents: Double
        let resetsAt: Date?

        var usedDollars: Double { usedCents / 100 }
        var limitDollars: Double { limitCents / 100 }
    }
}

nonisolated struct CursorUsageSummaryResponse: Codable, Sendable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let isUnlimited: Bool?
    let individualUsage: CursorUsageBucket?
    let teamUsage: CursorUsageBucket?
    let autoModelSelectedDisplayMessage: String?
    let namedModelSelectedDisplayMessage: String?

    struct CursorUsageBucket: Codable, Sendable {
        let plan: PlanUsage?
        let overall: MoneyUsage?
        let onDemand: MoneyUsage?
        let pooled: MoneyUsage?
    }

    struct PlanUsage: Codable, Sendable {
        let enabled: Bool?
        let used: FlexibleNumber?
        let limit: FlexibleNumber?
        let remaining: FlexibleNumber?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    struct MoneyUsage: Codable, Sendable {
        let enabled: Bool?
        let used: FlexibleNumber?
        let limit: FlexibleNumber?
        let remaining: FlexibleNumber?
    }

    struct FlexibleNumber: Codable, Sendable {
        let value: Double?

        init(_ value: Double?) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = nil
            } else if let intValue = try? container.decode(Int.self) {
                value = Double(intValue)
            } else if let doubleValue = try? container.decode(Double.self) {
                value = doubleValue
            } else if let stringValue = try? container.decode(String.self) {
                value = Double(stringValue)
            } else {
                value = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value {
                try container.encode(value)
            } else {
                try container.encodeNil()
            }
        }
    }

    func toUsageData(now: Date = Date()) -> CursorUsageData {
        let usage = CursorUsageMapper.map(self, now: now)
        let plan = individualUsage?.plan
        Logger.api.info(
            "Cursor map unlimited=\(self.isUnlimited ?? false, privacy: .public) total=\(plan?.totalPercentUsed ?? -1, privacy: .public) auto=\(plan?.autoPercentUsed ?? -1, privacy: .public) api=\(plan?.apiPercentUsed ?? -1, privacy: .public) included=\(usage.included?.percentage ?? -1, privacy: .public) secondary=\(usage.secondary?.percentage ?? -1, privacy: .public) onDemand=\(usage.onDemand?.percentage ?? -1, privacy: .public) mode=\(usage.presentation.billingMode.rawValue, privacy: .public) cadence=\(usage.presentation.cadence.rawValue, privacy: .public)"
        )
        return usage
    }
}

nonisolated struct CursorAuthMeResponse: Codable, Sendable {
    let email: String?
    let name: String?
    let id: FlexibleID?

    struct FlexibleID: Codable, Sendable {
        let value: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let stringValue = try? container.decode(String.self) {
                value = stringValue
            } else if let intValue = try? container.decode(Int.self) {
                value = String(intValue)
            } else {
                value = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value {
                try container.encode(value)
            } else {
                try container.encodeNil()
            }
        }
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return "Cursor"
    }

    var identifier: String {
        if let email, !email.isEmpty { return email }
        return id?.value ?? displayName
    }
}

enum CursorUsageMapper {
    static func map(_ response: CursorUsageSummaryResponse, now: Date = Date()) -> CursorUsageData {
        let cycleEnd = parseISO8601(response.billingCycleEnd)
        let included = includedLimit(from: response, cycleEnd: cycleEnd)
        let secondary = secondaryLimit(from: response, cycleEnd: cycleEnd)
        let onDemand = onDemandLimit(from: response, cycleEnd: cycleEnd)
        let presentation = CursorPresentationBuilder.from(
            response,
            secondaryPool: secondary,
            onDemandPool: onDemand,
            now: now
        )

        return CursorUsageData(
            included: included,
            secondary: secondary,
            onDemand: onDemand,
            membershipType: response.membershipType,
            billingCycleEnd: cycleEnd,
            presentation: presentation
        )
    }

    static func includedLimit(from response: CursorUsageSummaryResponse, cycleEnd: Date?) -> CursorUsageData.LimitData? {
        let plan = response.individualUsage?.plan
        if let percentage = includedPercentage(from: response) {
            return CursorUsageData.LimitData(
                percentage: percentage,
                resetsAt: cycleEnd,
                used: plan?.used?.value ?? response.individualUsage?.overall?.used?.value,
                limit: plan?.limit?.value ?? response.individualUsage?.overall?.limit?.value
            )
        }

        // Unlimited with no numeric pools: keep a ring so the column does not vanish.
        if response.isUnlimited == true {
            return CursorUsageData.LimitData(percentage: 0, resetsAt: cycleEnd, used: nil, limit: nil)
        }

        return nil
    }

    static func secondaryLimit(from response: CursorUsageSummaryResponse, cycleEnd: Date?) -> CursorUsageData.LimitData? {
        guard let api = response.individualUsage?.plan?.apiPercentUsed else { return nil }
        return CursorUsageData.LimitData(
            percentage: clampPercent(api),
            resetsAt: cycleEnd,
            used: nil,
            limit: nil
        )
    }

    /// Prefer Cursor Models (`autoPercentUsed`) to match the spending dashboard primary bar.
    /// Fall back to composite total, then other numeric signals.
    static func includedPercentage(from response: CursorUsageSummaryResponse) -> Double? {
        if let plan = response.individualUsage?.plan {
            if let auto = plan.autoPercentUsed {
                return clampPercent(auto)
            }
            if let total = plan.totalPercentUsed {
                return clampPercent(total)
            }
            if let api = plan.apiPercentUsed {
                return clampPercent(api)
            }
            if let used = plan.used?.value, let limit = plan.limit?.value, limit > 0 {
                return clampPercent(used / limit * 100)
            }
        }

        if let overall = response.individualUsage?.overall, let limit = moneyLimit(overall) {
            return limit.percentage
        }

        if let pooled = response.teamUsage?.pooled, let limit = moneyLimit(pooled) {
            return limit.percentage
        }

        return percentageFromDisplayMessages(response)
    }

    static func onDemandLimit(from response: CursorUsageSummaryResponse, cycleEnd: Date?) -> CursorUsageData.OnDemandData? {
        let candidates = [
            response.individualUsage?.onDemand,
            response.teamUsage?.onDemand
        ].compactMap { $0 }

        for block in candidates {
            guard block.enabled != false else { continue }
            guard let used = block.used?.value else { continue }
            guard let limit = block.limit?.value, limit > 0 else { continue }
            let percentage = min(100, max(0, used / limit * 100))
            return CursorUsageData.OnDemandData(
                percentage: percentage,
                usedCents: used,
                limitCents: limit,
                resetsAt: cycleEnd
            )
        }
        return nil
    }

    private static func moneyLimit(_ block: CursorUsageSummaryResponse.MoneyUsage) -> CursorUsageData.LimitData? {
        guard let used = block.used?.value, let limit = block.limit?.value, limit > 0 else {
            return nil
        }
        return CursorUsageData.LimitData(
            percentage: clampPercent(used / limit * 100),
            resetsAt: nil,
            used: used,
            limit: limit
        )
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func percentageFromDisplayMessages(_ response: CursorUsageSummaryResponse) -> Double? {
        let percents = [
            parsePercent(from: response.autoModelSelectedDisplayMessage),
            parsePercent(from: response.namedModelSelectedDisplayMessage)
        ].compactMap { $0 }
        return percents.max()
    }

    private static func parsePercent(from message: String?) -> Double? {
        guard let message, let idx = message.firstIndex(of: "%") else { return nil }
        let before = message[..<idx]
        var digits = ""
        for character in before.reversed() {
            if character.isNumber || character == "." {
                digits.insert(character, at: digits.startIndex)
            } else if !digits.isEmpty {
                break
            }
        }
        guard let value = Double(digits) else { return nil }
        return clampPercent(value)
    }

    static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
    }
}
