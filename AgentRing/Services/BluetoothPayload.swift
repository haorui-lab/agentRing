//
//  BluetoothPayload.swift
//  Agent Ring
//
//  蓝牙副屏同步报文模型
//  协议见 docs 之外的《BLUETOOTH_PROTOCOL.md》：
//  每帧一个 JSON 对象 + '\n'，UTF-8，字段与 Popover 展示严格对齐。
//

import Foundation

// MARK: - 传输报文模型

/// 蓝牙同步根报文：`{ timestamp, providers: [...] }`
struct BluetoothSyncPayload: Codable, Sendable {
    /// Unix 时间戳（秒），副屏用于校验数据新鲜度
    let timestamp: Int
    /// 激活且按用户排序好的供应商数据
    let providers: [ProviderPayload]

    struct ProviderPayload: Codable, Sendable {
        /// "codex" / "cursor" / "antigravity" / "antigravity_third"
        let id: String
        /// 列顶部标题
        let name: String
        /// 外圈主环
        let primary: RingPayload
        /// 内圈次环；单环供应商为 nil
        let secondary: RingPayload?
        /// 胶囊行列表
        var rows: [RowPayload]

        init(id: String, name: String, primary: RingPayload, secondary: RingPayload?, rows: [RowPayload]) {
            self.id = id
            self.name = name
            self.primary = primary
            self.secondary = secondary
            self.rows = rows
        }
    }

    struct RingPayload: Codable, Sendable {
        /// 额度名称（如 "7天"、"Gemini 5小时"）
        let label: String
        /// 剩余百分比 0.0 ~ 100.0，驱动圆环弧长及中心大字
        let remainingPercent: Double
        /// 紧凑重置倒计时（如 "4d 14h"）
        let resetsAt: String?
        /// 辅助明细文本（如 Cursor 的 "120 / 500"）
        var remainingDetails: String?

        init(label: String, remainingPercent: Double, resetsAt: String?, remainingDetails: String? = nil) {
            self.label = label
            self.remainingPercent = remainingPercent
            self.resetsAt = resetsAt
            self.remainingDetails = remainingDetails
        }
    }

    struct RowPayload: Codable, Sendable {
        /// 左侧标签
        let label: String
        /// 中间加粗数值（"16%" 或余额 "$25.00"）
        let percent: String
        /// 右侧重置倒计时，无则 ""
        var reset: String

        init(label: String, percent: String, reset: String) {
            self.label = label
            self.percent = percent
            self.reset = reset
        }
    }

    /// 序列化为单行 JSON 文本（不含结尾换行）
    var encodedLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else {
            return ""
        }
        return line
    }
}

// MARK: - Payload 构造器

/// 把三家的用量数据统一转成蓝牙副屏报文。
/// 过滤规则与 Popover 智能显示一致：
/// - 无效窗口（0% 且无重置信息）不构造
/// - 未启用的 Credits 余额不生成 rows
@MainActor
enum BluetoothPayloadBuilder {

    /// 按用户设置顺序构造完整报文
    static func buildPayload(
        codexUsageData: CodexUsageData?,
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData?
    ) -> BluetoothSyncPayload {
        let settings = UserSettings.shared
        let ordered = settings.orderedActiveProviders(
            codexUsageData: codexUsageData,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )

        var providers: [BluetoothSyncPayload.ProviderPayload] = []
        for provider in ordered {
            switch provider {
            case .codex:
                if let payload = codexProvider(from: codexUsageData) {
                    providers.append(payload)
                }
            case .cursor:
                if let payload = cursorProvider(from: cursorUsageData) {
                    providers.append(payload)
                }
            case .antigravity:
                if let payload = antigravityProvider(from: antigravityUsageData, thirdParty: false) {
                    providers.append(payload)
                }
            case .antigravityThird:
                if let payload = antigravityProvider(from: antigravityUsageData, thirdParty: true) {
                    providers.append(payload)
                }
            }
        }

        return BluetoothSyncPayload(
            timestamp: Int(Date().timeIntervalSince1970),
            providers: providers
        )
    }

    // MARK: - Codex

    private static func codexProvider(from data: CodexUsageData?) -> BluetoothSyncPayload.ProviderPayload? {
        guard let data else { return nil }

        // 与 getActiveCodexDisplayTypes(.smart) 相同的有效性判定：
        // primary 始终有效（有窗口就构造），secondary 已在上游过滤无效窗口
        guard data.primary != nil || data.secondary != nil || data.extraUsage?.enabled == true else {
            return nil
        }

        let primary: BluetoothSyncPayload.RingPayload
        var secondary: BluetoothSyncPayload.RingPayload?
        var rows: [BluetoothSyncPayload.RowPayload] = []

        if let p = data.primary {
            primary = ring(label: L.DetailRow.fiveHour, percentage: p.percentage, resetsAt: p.resetsAt)
            rows.append(row(label: L.DetailRow.fiveHour, percentage: p.percentage, resetsAt: p.resetsAt))

            // 双环时 7 天作内环；仅剩 7 天时下面走 else-if 提升为主环，secondary 保持 nil
            if let s = data.secondary {
                secondary = ring(label: L.DetailRow.sevenDay, percentage: s.percentage, resetsAt: s.resetsAt)
                rows.append(row(label: L.DetailRow.sevenDay, percentage: s.percentage, resetsAt: s.resetsAt))
            }
        } else if let s = data.secondary {
            // 仅剩 7 天窗口（Plus 单窗口账号）：7 天提升为主环，secondary 必须为 nil，rows 补齐该行
            primary = ring(label: L.DetailRow.sevenDay, percentage: s.percentage, resetsAt: s.resetsAt)
            rows.append(row(label: L.DetailRow.sevenDay, percentage: s.percentage, resetsAt: s.resetsAt))
        } else {
            // 只有 credits：中心给 0 环
            primary = ring(label: L.DetailRow.extraUsage, percentage: data.extraUsage?.percentage ?? 0, resetsAt: nil)
        }

        // Credits：未启用不生成 rows（enabled == false 直接跳过）
        if let extra = data.extraUsage, extra.enabled {
            rows.append(creditsRow(from: extra))
        }

        return BluetoothSyncPayload.ProviderPayload(
            id: ProviderType.codex.rawValue,
            name: ProviderType.codex.displayName,
            primary: primary,
            secondary: secondary,
            rows: rows
        )
    }

    // MARK: - Cursor

    private static func cursorProvider(from data: CursorUsageData?) -> BluetoothSyncPayload.ProviderPayload? {
        guard let data, data.included != nil || data.secondary != nil || data.onDemand != nil else {
            return nil
        }

        let includedLabel = CursorUsageFormatter.includedTitle(from: data.presentation)
        let secondaryLabel = CursorUsageFormatter.rowTitle(for: .cursorOnDemand, presentation: data.presentation)

        var secondary: BluetoothSyncPayload.RingPayload?
        var rows: [BluetoothSyncPayload.RowPayload] = []

        if let api = data.secondary {
            secondary = ring(
                label: secondaryLabel,
                percentage: api.percentage,
                resetsAt: api.resetsAt,
                remainingDetails: nil
            )
        } else if let onDemand = data.onDemand {
            secondary = ring(
                label: secondaryLabel,
                percentage: onDemand.percentage,
                resetsAt: onDemand.resetsAt,
                remainingDetails: onDemandDetails(onDemand)
            )
        }

        if let api = data.secondary {
            rows.append(row(label: secondaryLabel, percentage: api.percentage, resetsAt: api.resetsAt))
        } else if let onDemand = data.onDemand {
            rows.append(row(
                label: secondaryLabel,
                percentage: onDemand.percentage,
                resetsAt: onDemand.resetsAt
            ))
        }

        // 主环：included（Cursor Models / weekly included 池）
        guard let included = data.included else {
            return nil
        }
        let primary = ring(
            label: includedLabel,
            percentage: included.percentage,
            resetsAt: included.resetsAt,
            remainingDetails: includedDetails(included)
        )
        rows.insert(
            row(label: includedLabel, percentage: included.percentage, resetsAt: included.resetsAt),
            at: 0
        )

        return BluetoothSyncPayload.ProviderPayload(
            id: ProviderType.cursor.rawValue,
            name: CursorUsageFormatter.columnBrandName(from: data.presentation),
            primary: primary,
            secondary: secondary,
            rows: rows
        )
    }

    // MARK: - Antigravity

    private static func antigravityProvider(
        from data: AntigravityUsageData?,
        thirdParty: Bool
    ) -> BluetoothSyncPayload.ProviderPayload? {
        guard let data else { return nil }

        let primaryData = thirdParty ? data.thirdPartyPrimary : data.geminiPrimary
        let secondaryData = thirdParty ? data.thirdPartySecondary : data.geminiSecondary
        let primaryLabel = thirdParty ? L.DetailRow.antigravityThirdPartyPrimary : L.DetailRow.antigravityGeminiPrimary
        let secondaryLabel = thirdParty ? L.DetailRow.antigravityThirdPartySecondary : L.DetailRow.antigravityGeminiSecondary
        let providerType: ProviderType = thirdParty ? .antigravityThird : .antigravity

        guard primaryData != nil || secondaryData != nil else { return nil }

        // 双环：5 小时在外、7 天在内；只有 7 天时 7 天作主环
        let primary: BluetoothSyncPayload.RingPayload
        var secondary: BluetoothSyncPayload.RingPayload?
        var rows: [BluetoothSyncPayload.RowPayload] = []

        if let p = primaryData {
            primary = ring(label: primaryLabel, percentage: p.percentage, resetsAt: p.resetsAt)
            rows.append(row(label: primaryLabel, percentage: p.percentage, resetsAt: p.resetsAt))

            // 双环时 7 天作内环；仅剩 7 天时走 else-if 提升为主环，secondary 保持 nil
            if let s = secondaryData {
                secondary = ring(label: secondaryLabel, percentage: s.percentage, resetsAt: s.resetsAt)
                rows.append(row(label: secondaryLabel, percentage: s.percentage, resetsAt: s.resetsAt))
            }
        } else if let s = secondaryData {
            primary = ring(label: secondaryLabel, percentage: s.percentage, resetsAt: s.resetsAt)
            rows.append(row(label: secondaryLabel, percentage: s.percentage, resetsAt: s.resetsAt))
        } else {
            return nil
        }

        return BluetoothSyncPayload.ProviderPayload(
            id: providerType.rawValue,
            name: providerType.displayName,
            primary: primary,
            secondary: secondary,
            rows: rows
        )
    }

    // MARK: - 单元构造

    private static func ring(
        label: String,
        percentage: Double,
        resetsAt: Date?,
        remainingDetails: String? = nil
    ) -> BluetoothSyncPayload.RingPayload {
        BluetoothSyncPayload.RingPayload(
            label: label,
            remainingPercent: max(0, min(100, 100 - percentage)),
            resetsAt: compactReset(resetsAt),
            remainingDetails: remainingDetails
        )
    }

    private static func row(
        label: String,
        percentage: Double,
        resetsAt: Date?,
        percentText: String? = nil
    ) -> BluetoothSyncPayload.RowPayload {
        let percentString = percentText ?? UsageRingDisplay.percentLabel(
            usedPercentage: percentage,
            showRemainingMode: UserSettings.shared.showRemainingMode
        )
        return BluetoothSyncPayload.RowPayload(
            label: label,
            percent: percentString,
            reset: compactReset(resetsAt) ?? ""
        )
    }

    private static func creditsRow(from extra: CodexExtraUsageData) -> BluetoothSyncPayload.RowPayload {
        BluetoothSyncPayload.RowPayload(
            label: L.DetailRow.extraUsage,
            percent: extra.formattedCompactAmount,
            reset: ""
        )
    }

    private static func compactReset(_ date: Date?) -> String? {
        guard let date else { return nil }
        return UsageLimitData(percentage: 0, resetsAt: date).formattedCompactRemaining
    }

    // MARK: - Cursor 明细文本

    private static func includedDetails(_ included: CursorUsageData.LimitData) -> String? {
        guard let used = included.used, let limit = included.limit, limit > 0 else { return nil }
        return "\(Int(used)) / \(Int(limit))"
    }

    private static func onDemandDetails(_ onDemand: CursorUsageData.OnDemandData) -> String? {
        "$\(String(format: "%.2f", onDemand.usedDollars)) / $\(String(format: "%.2f", onDemand.limitDollars))"
    }

    private static func onDemandPercentText(_ onDemand: CursorUsageData.OnDemandData) -> String {
        "$\(String(format: "%.2f", onDemand.usedDollars))"
    }
}
