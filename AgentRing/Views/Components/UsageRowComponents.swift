//
//  UsageRowComponents.swift
//  Agent Ring
//

import SwiftUI

// MARK: - Detail Usage Ring Helpers

struct UsageRingTrimRange: Equatable {
    let from: CGFloat
    let to: CGFloat
}

enum UsageRingDisplay {
    static func clampedPercentage(_ percentage: Double) -> Double {
        min(100, max(0, percentage))
    }

    static func remainingPercentage(usedPercentage: Double) -> Double {
        100 - clampedPercentage(usedPercentage)
    }

    static func displayedPercentage(usedPercentage: Double, showRemainingMode: Bool) -> Double {
        let used = clampedPercentage(usedPercentage)
        return showRemainingMode ? remainingPercentage(usedPercentage: used) : used
    }

    /// One shared rounding rule so the big ring and detail rows never disagree.
    /// 遵循业界标准临界保护（有效阈值 0.2%，与圆环 0.002 阈值同步）：
    /// - < 0.2% 视为 0%（避免极小浮点残差误报 1%）
    /// - 0.2% ~ 1.0% 保底显示 1%（实质微量额度保底）
    /// - 99.0% ~ 99.8% 封顶显示 99%（实质微量消耗封顶）
    /// - > 99.8% 视为 100%（极小消耗不扣为 99%）
    static func percentLabel(usedPercentage: Double, showRemainingMode: Bool) -> String {
        let displayed = displayedPercentage(
            usedPercentage: usedPercentage,
            showRemainingMode: showRemainingMode
        )
        let rounded: Int = {
            if displayed < 0.2 { return 0 }
            if displayed < 1.0 { return 1 }
            if displayed >= 99.0 && displayed <= 99.8 { return 99 }
            if displayed > 99.8 { return 100 }
            return Int(displayed.rounded())
        }()
        return "\(rounded)%"
    }

    static func usedFraction(_ usedPercentage: Double) -> CGFloat {
        CGFloat(clampedPercentage(usedPercentage) / 100.0)
    }

    static func displayedTrimRange(usedPercentage: Double, showRemainingMode: Bool) -> UsageRingTrimRange {
        let used = usedFraction(usedPercentage)

        if showRemainingMode {
            // 剩余模式：从 12 点起填充「还剩多少」，满环=额度充足，空环=用尽
            return UsageRingTrimRange(from: 0, to: 1 - used)
        }

        return UsageRingTrimRange(from: 0, to: used)
    }

    /// 圆环未填充区间的弧线范围（用于 Dashboard 半透明底轨/灰圈占位）。
    /// 无论「剩余」还是「已使用」模式，未填满的扇区均以半透明底轨补全成整圆。
    static func trackTrimRange(usedPercentage: Double, showRemainingMode: Bool) -> UsageRingTrimRange? {
        let displayedRange = displayedTrimRange(
            usedPercentage: usedPercentage,
            showRemainingMode: showRemainingMode
        )
        guard displayedRange.to < 0.998 else { return nil }
        return UsageRingTrimRange(from: displayedRange.to, to: 1)
    }

    /// 兼容保留原方法名，指向统一的底轨计算
    static func usedPortionTrimRange(usedPercentage: Double, showRemainingMode: Bool) -> UsageRingTrimRange? {
        trackTrimRange(usedPercentage: usedPercentage, showRemainingMode: showRemainingMode)
    }

    // MARK: - 额度告急分级

    /// 百分比文本的告急状态分级（语义基于「额度剩余」：剩余 <=20% 警告、<=5% 紧急）
    enum UrgencyLevel {
        case normal
        case warning
        case critical

        /// 显示值语义随模式反转：剩余模式显示剩余（低=告急），已用模式显示已用（高=告急）
        static func from(usedPercentage: Double, showRemainingMode: Bool) -> UrgencyLevel {
            let used = clampedPercentage(usedPercentage)
            let remaining = 100 - used
            if remaining <= 5 { return .critical }
            if remaining <= 20 { return .warning }
            return .normal
        }
    }
}

// MARK: - Ring Sweep

/// 剩余/已用模式切换时的一次性外侧扫光。
struct DetailUsageRingSweep: View {
    let trigger: Int
    let diameter: CGFloat
    let lineWidth: CGFloat
    let color: Color

    @State private var rotation: Double = -90
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.18)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [
                        color.opacity(0.0),
                        color.opacity(0.35),
                        color.opacity(0.9),
                        color.opacity(0.85),
                        color.opacity(0.0)
                    ]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(rotation))
            .opacity(opacity)
            .scaleEffect(opacity > 0 ? 1.03 : 0.98)
            .allowsHitTesting(false)
            .onChange(of: trigger) { newValue in
                guard newValue > 0 else { return }
                runSweep()
            }
    }

    private func runSweep() {
        rotation = -90
        opacity = 1

        withAnimation(.easeOut(duration: 0.45)) {
            rotation = 270
            opacity = 0
        }
    }
}

// MARK: - Animation Type Hint View

/// 动画类型切换提示（长按圆环后显示）
struct AnimationTypeHintView: View {
    let animationTypeName: String

    private let rainbowColors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: rainbowColors, startPoint: .leading, endPoint: .trailing)
                )
            Text(L.LoadingAnimation.current(animationTypeName))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(
                    LinearGradient(colors: rainbowColors, startPoint: .leading, endPoint: .trailing)
                )
        }
        .padding(.horizontal, 12)
        .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: - Provider Divider

/// 多厂商列之间的竖向分隔线：系统语义色 separatorColor，自动适配深浅色与增强对比度；
/// 上下两端用 mask 渐隐，避免与顶部标题/底部留白硬碰
struct ProviderDivider: View {
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: height)
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

// MARK: - Limit Row List

/// 明细行列表：行间用系统原生 Divider，分隔线属于列表排版职责，不下放到单行组件
@ViewBuilder
func limitRows<Row: View>(for types: [LimitType], @ViewBuilder row: @escaping (LimitType) -> Row) -> some View {
    VStack(spacing: 0) {
        ForEach(Array(types.enumerated()), id: \.element) { index, type in
            if index > 0 {
                Divider()
                    .padding(.horizontal, 2)
            }
            row(type)
        }
    }
}

// MARK: - Unified Limit Row Component

/// 行布局常量：行组件与弹窗高度公式共用一份，防止两边各自维护漂移
enum UnifiedLimitRowMetrics {
    static let verticalPadding: CGFloat = 4
    /// 12pt 字体的实际行高
    static let textLineHeight: CGFloat = 15
    /// 行间 Divider 的渲染厚度
    static let interRowDividerHeight: CGFloat = 1

    // 数值列固定通道宽度：所有行共用同一绝对基准，内容长短不一、
    // 剩余/重置模式切换都不会让百分比列漂移（规范 24 节数值列对齐）
    /// 百分比列通道宽：容纳 12pt semibold 的 "100%"
    static let percentageColumnWidth: CGFloat = 36
    /// 数值列通道宽：容纳 12pt 等宽数字的最长 "00h 00m" / "9/20 14:30"
    static let valueColumnWidth: CGFloat = 64

    static var rowHeight: CGFloat {
        textLineHeight + verticalPadding * 2
    }

    /// rowCount 行（含行间分隔线）的总高度
    static func textHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * interRowDividerHeight
    }
}

/// 统一的额度明细行组件：列表式布局，靠排版而不是胶囊卡片表达层级（HIG 列表密度规范）
struct UnifiedLimitRow: View {
    let type: LimitType
    var codexData: CodexUsageData? = nil
    var cursorData: CursorUsageData? = nil
    var antigravityData: AntigravityUsageData? = nil
    let showRemainingMode: Bool

    var body: some View {
        HStack(spacing: 4) {
            // 类型名：弹性宽度，超长尾部截断，把剩余空间让给数值列
            Text(limitName)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)

            Spacer(minLength: 4)

            // 百分比：固定通道右对齐，所有行的百分号钉在同一条垂直线上（规范 24 节）
            // 额度告急时文字变橙/变红（语义状态色，规范 12.4），字号字重不动以保住对齐通道
            Text(percentageLabel)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(percentageColor)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .frame(width: UnifiedLimitRowMetrics.percentageColumnWidth, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)

            // 剩余时间/额度：固定通道右对齐，模式切换时列边界稳定不横跳
            Text(displayValue)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .frame(width: UnifiedLimitRowMetrics.valueColumnWidth, alignment: .trailing)
                .layoutPriority(1)
                .id(showRemainingMode ? "remaining" : "reset")
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
        }
        .padding(.vertical, UnifiedLimitRowMetrics.verticalPadding)
        .padding(.horizontal, 2)
    }

    // MARK: - Computed Properties

    private var limitName: String {
        if let cursorData, type == .cursorIncluded || type == .cursorOnDemand {
            return CursorUsageFormatter.rowTitle(for: type, presentation: cursorData.presentation)
        }
        return type.detailDisplayName
    }


    private var percentageLabel: String {
        guard let percentageValue else { return "—" }
        return UsageRingDisplay.percentLabel(
            usedPercentage: percentageValue,
            showRemainingMode: showRemainingMode
        )
    }

    /// 额度告急分级颜色：常规 primary，剩余≤20% 橙色警告，剩余≤5% 红色紧急
    /// （系统语义色，深浅色模式自动适配；字号字重不动，三列对齐通道不受影响）
    private var percentageColor: Color {
        guard let percentageValue else { return .primary }
        switch UsageRingDisplay.UrgencyLevel.from(usedPercentage: percentageValue, showRemainingMode: showRemainingMode) {
        case .normal: return .primary
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    private var percentageValue: Double? {
        switch type {
        case .codexPrimary: return codexData?.primary?.percentage
        case .codexSecondary: return codexData?.secondary?.percentage
        case .codexExtraUsage: return codexData?.extraUsage?.percentage
        case .cursorIncluded: return cursorData?.included?.percentage
        case .cursorOnDemand: return cursorData?.secondary?.percentage ?? cursorData?.onDemand?.percentage
        case .antigravityPrimary: return antigravityData?.geminiPrimary?.percentage ?? antigravityData?.primary?.percentage
        case .antigravitySecondary: return antigravityData?.geminiSecondary?.percentage ?? antigravityData?.secondary?.percentage
        case .antigravityThirdPartyPrimary: return antigravityData?.thirdPartyPrimary?.percentage
        case .antigravityThirdPartySecondary: return antigravityData?.thirdPartySecondary?.percentage
        }
    }

    private var displayValue: String {
        switch type {
        case .codexPrimary:
            guard let limitData = codexData?.primary?.asUsageLimitData() else { return "-" }
            return showRemainingMode ? limitData.formattedCompactRemaining : detailCompactResetTime(limitData)

        case .codexSecondary:
            guard let limitData = codexData?.secondary?.asUsageLimitData() else { return "-" }
            return showRemainingMode ? limitData.formattedCompactRemainingWithMinutes : limitData.formattedCompactResetDateWithMinutes

        case .codexExtraUsage:
            guard let extra = codexData?.extraUsage else { return "-" }
            return showRemainingMode ? extra.formattedDetailRemainingAmount : extra.formattedDetailCompactAmount

        case .cursorIncluded:
            guard let included = cursorData?.included else { return "-" }
            let limitData = UsageLimitData(percentage: included.percentage, resetsAt: included.resetsAt)
            return showRemainingMode ? limitData.formattedCompactRemainingWithMinutes : limitData.formattedCompactResetDateWithMinutes

        case .cursorOnDemand:
            if let secondary = cursorData?.secondary {
                let limitData = UsageLimitData(percentage: secondary.percentage, resetsAt: secondary.resetsAt)
                return showRemainingMode ? limitData.formattedCompactRemainingWithMinutes : limitData.formattedCompactResetDateWithMinutes
            }
            guard let onDemand = cursorData?.onDemand else { return "-" }
            if showRemainingMode {
                let remaining = max(0, onDemand.limitDollars - onDemand.usedDollars)
                return L.ExtraUsage.remainingAmount(remaining)
            }
            return L.ExtraUsage.usageAmount(onDemand.usedDollars, onDemand.limitDollars)

        case .antigravityPrimary:
            guard let limitData = (antigravityData?.geminiPrimary ?? antigravityData?.primary)?.asUsageLimitData() else { return "-" }
            return showRemainingMode ? limitData.formattedCompactRemaining : detailCompactResetTime(limitData)

        case .antigravitySecondary:
            guard let limitData = (antigravityData?.geminiSecondary ?? antigravityData?.secondary)?.asUsageLimitData() else { return "-" }
            return showRemainingMode ? limitData.formattedCompactRemainingWithMinutes : limitData.formattedCompactResetDateWithMinutes

        case .antigravityThirdPartyPrimary:
            guard let limitData = antigravityData?.thirdPartyPrimary?.asUsageLimitData() else { return "-" }
            return showRemainingMode ? limitData.formattedCompactRemaining : detailCompactResetTime(limitData)

        case .antigravityThirdPartySecondary:
            guard let limitData = antigravityData?.thirdPartySecondary?.asUsageLimitData() else { return "-" }
            return showRemainingMode ? limitData.formattedCompactRemainingWithMinutes : limitData.formattedCompactResetDateWithMinutes
        }
    }

    private func detailCompactResetTime(_ limitData: UsageLimitData) -> String {
        limitData.formattedCompactResetDateWithMinutes
    }
}
