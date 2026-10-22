//
//  AntigravityUsageData.swift
//  Agent Ring
//

import Foundation

// MARK: - 内部数据模型

/// Antigravity 使用量数据（应用内部使用的标准化结构）
struct AntigravityUsageData: Sendable {
    /// 当前凭证对应的 Google 账号（来自 oauth `id_token`）。
    /// 多账号切换后用于识别「展示的是谁的用量」，避免把旧账号数据当成新账号。
    let accountEmail: String?
    /// 5小时主窗口用量（Gemini 核心模型）
    let primary: LimitData?
    /// 7天/周级次窗口用量（Gemini 核心模型）
    let secondary: LimitData?
    /// 所有模型分组的详细额度列表
    let groups: [ModelGroup]

    struct LimitData: Sendable {
        /// 当前使用百分比 (0-100)
        let percentage: Double
        /// 剩余比例 (0.0 - 1.0)
        let remainingFraction: Double
        /// 重置时间
        let resetsAt: Date?
        /// 描述信息
        let description: String?
    }

    struct ModelGroup: Sendable {
        let displayName: String
        let description: String?
        let fiveHourLimit: LimitData?
        let weeklyLimit: LimitData?
    }

    /// 便捷访问 Gemini 核心模型组。
    /// 严格匹配 displayName 含 "gemini" 的组；找不到时返回 nil 而非回退到其他组——
    /// 错把 3P 数据标成 Gemini（假 100%）比缺数据更糟，缺数据时 UI 会自然隐藏该列。
    var geminiGroup: ModelGroup? {
        groups.first { $0.displayName.localizedCaseInsensitiveContains("gemini") }
    }

    /// 便捷访问 Claude 与 GPT 第三方模型组
    var thirdPartyGroup: ModelGroup? {
        groups.first { $0.displayName.localizedCaseInsensitiveContains("claude") || $0.displayName.localizedCaseInsensitiveContains("gpt") }
    }

    /// Gemini 5小时主窗口额度
    var geminiPrimary: LimitData? { geminiGroup?.fiveHourLimit ?? primary }
    /// Gemini 周级额度
    var geminiSecondary: LimitData? { geminiGroup?.weeklyLimit ?? secondary }

    /// Claude / GPT 5小时主窗口额度
    var thirdPartyPrimary: LimitData? { thirdPartyGroup?.fiveHourLimit }
    /// Claude / GPT 周级额度
    var thirdPartySecondary: LimitData? { thirdPartyGroup?.weeklyLimit }

    /// 附带账号身份（fetch 成功后由 API 层写入）。
    func withAccountEmail(_ email: String?) -> AntigravityUsageData {
        AntigravityUsageData(
            accountEmail: email,
            primary: primary,
            secondary: secondary,
            groups: groups
        )
    }
}

/// Antigravity 账号身份解析（oauth `id_token` / 切换检测）。独立于钥匙串，便于单测。
enum AntigravityAccountIdentity {
    /// 从 Google `id_token` JWT 取 email；缺失时退回 `sub`。
    static func email(fromIDToken token: String) -> String? {
        guard let payload = jwtPayload(token) else { return nil }
        if let email = payload["email"] as? String {
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let sub = payload["sub"] as? String {
            let trimmed = sub.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// 两个身份是否指向不同账号（都有值且大小写不敏感不等）。
    static func didSwitch(from previous: String?, to next: String?) -> Bool {
        guard let previous, let next else { return false }
        return previous.caseInsensitiveCompare(next) != .orderedSame
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension AntigravityUsageData.LimitData {
    func asUsageLimitData() -> UsageLimitData {
        UsageLimitData(percentage: percentage, resetsAt: resetsAt)
    }
}

// MARK: - API 响应模型

nonisolated struct AntigravityQuotaResponse: Codable, Sendable {
    let groups: [GroupResponse]?
    let description: String?

    // 兼容本地 ConnectRPC 包装：{"response": {"groups": [...]}}
    let response: InnerResponse?

    struct InnerResponse: Codable, Sendable {
        let groups: [GroupResponse]?
        let description: String?
    }

    struct GroupResponse: Codable, Sendable {
        let displayName: String?
        let description: String?
        let buckets: [BucketResponse]?
    }

    struct BucketResponse: Codable, Sendable {
        let bucketId: String?
        let displayName: String?
        let description: String?
        let window: String?
        let remainingFraction: Double?
        let resetTime: String?
    }

    var effectiveGroups: [GroupResponse] {
        response?.groups ?? groups ?? []
    }

    func toUsageData(accountEmail: String? = nil) -> AntigravityUsageData {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let backupFormatter = ISO8601DateFormatter()
        backupFormatter.formatOptions = [.withInternetDateTime]

        let parseDate: (String?) -> Date? = { dateString in
            guard let dateString else { return nil }
            return isoFormatter.date(from: dateString) ?? backupFormatter.date(from: dateString)
        }

        let parsedGroups: [AntigravityUsageData.ModelGroup] = effectiveGroups.map { group in
            var fiveHour: AntigravityUsageData.LimitData?
            var weekly: AntigravityUsageData.LimitData?

            for bucket in group.buckets ?? [] {
                let remaining = bucket.remainingFraction ?? 1.0
                let usedPercent = max(0.0, min(100.0, (1.0 - remaining) * 100.0))
                let resetsAt = parseDate(bucket.resetTime)
                let limit = AntigravityUsageData.LimitData(
                    percentage: usedPercent,
                    remainingFraction: remaining,
                    resetsAt: resetsAt,
                    description: bucket.description
                )

                let window = bucket.window?.lowercased() ?? ""
                let bucketId = bucket.bucketId?.lowercased() ?? ""
                let displayName = bucket.displayName?.lowercased() ?? ""

                let isFiveHour = window.contains("5h")
                    || window.contains("5 hour")
                    || bucketId.contains("5h")
                    || displayName.contains("5 hour")
                    || displayName.contains("five hour")
                    || displayName.contains("5小时")

                let isWeekly = window.contains("week")
                    || window.contains("7d")
                    || window.contains("7 day")
                    || bucketId.contains("week")
                    || bucketId.contains("7d")
                    || displayName.contains("week")
                    || displayName.contains("7 day")
                    || displayName.contains("7天")
                    || displayName.contains("周")

                if isFiveHour {
                    fiveHour = limit
                } else if isWeekly {
                    weekly = limit
                }
            }

            return AntigravityUsageData.ModelGroup(
                displayName: group.displayName ?? "Models",
                description: group.description,
                fiveHourLimit: fiveHour,
                weeklyLimit: weekly
            )
        }

        // 主菜单栏 primary/secondary 仅在能明确识别 Gemini 组时填充；
        // 找不到 Gemini 组时保持 nil，禁止回退到 3P 组（避免把 3P 用量错标成 Gemini）。
        let primaryGroup = parsedGroups.first { $0.displayName.localizedCaseInsensitiveContains("gemini") }

        return AntigravityUsageData(
            accountEmail: accountEmail,
            primary: primaryGroup?.fiveHourLimit,
            secondary: primaryGroup?.weeklyLimit,
            groups: parsedGroups
        )
    }
}
