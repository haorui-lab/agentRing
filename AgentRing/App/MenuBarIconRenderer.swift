//
//  MenuBarIconRenderer.swift
//  Agent Ring
//

import SwiftUI
import AppKit

final class MenuBarIconRenderer {
    private let settings: UserSettings
    private let providerBrandIconSize: CGFloat = 16
    private let metricIconSize: CGFloat = 22
    private let extraIconSize: CGFloat = 18

    init(settings: UserSettings = .shared) {
        self.settings = settings
    }

    func createIcon(
        codexUsageData: CodexUsageData?,
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData? = nil,
        hasUpdate: Bool = false,
        button: NSStatusBarButton?
    ) -> NSImage {
        let isMonochrome = settings.iconStyleMode == .monochrome
        return buildIcon(
            codexUsageData: codexUsageData,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData,
            isMonochrome: isMonochrome,
            button: button
        )
    }

    private func buildIcon(
        codexUsageData: CodexUsageData?,
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData? = nil,
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage {
        let showingCodex = codexUsageData != nil
        let showingCursor = cursorUsageData != nil
        let showingAntigravity = antigravityUsageData != nil
        let ordered = settings.orderedActiveProviders(
            codexUsageData: codexUsageData,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )
        let showingMultiple = ordered.count > 1

        switch settings.iconDisplayMode {
        case .none:
            return createMenuBarDividerIcon(isMonochrome: isMonochrome)

        case .iconOnly:
            var brands: [NSImage] = []
            for provider in ordered {
                if let brand = createProviderBrandIcon(provider: provider, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                    brands.append(brand)
                }
            }
            guard !brands.isEmpty else {
                return createProviderBrandIcon(provider: .antigravity, isMonochrome: isMonochrome, size: providerBrandIconSize)
                    ?? createSimpleCircleIcon()
            }
            return brands.count == 1 ? brands[0] : combineIcons(brands, spacing: 3, height: providerBrandIconSize)

        case .percentageOnly, .both:
            var icons: [NSImage] = []
            let includeBrand = settings.iconDisplayMode == .both && !showingMultiple

            for provider in ordered {
                switch provider {
                case .codex:
                    if includeBrand, showingCodex,
                       let brand = createProviderBrandIcon(provider: .codex, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                        icons.append(brand)
                    }
                    if let codexUsageData {
                        // 菜单栏用量环始终走系统模板色（浅色栏黑 / 深色栏白）
                        icons.append(contentsOf: buildCodexCluster(
                            codex: codexUsageData,
                            isMonochrome: true,
                            button: button
                        ))
                    }
                case .cursor:
                    if includeBrand, showingCursor,
                       let brand = createProviderBrandIcon(provider: .cursor, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                        icons.append(brand)
                    }
                    if let cursorUsageData {
                        icons.append(contentsOf: buildCursorCluster(
                            cursor: cursorUsageData,
                            isMonochrome: true,
                            button: button
                        ))
                    }
                case .antigravity:
                    if includeBrand, showingAntigravity,
                       let brand = createProviderBrandIcon(provider: .antigravity, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                        icons.append(brand)
                    }
                    if let antigravityUsageData {
                        icons.append(contentsOf: buildAntigravityCluster(
                            antigravity: antigravityUsageData,
                            provider: .antigravity,
                            isMonochrome: true,
                            button: button
                        ))
                    }
                case .antigravityThird:
                    if includeBrand, showingAntigravity,
                       let brand = createProviderBrandIcon(provider: .antigravityThird, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                        icons.append(brand)
                    }
                    if let antigravityUsageData {
                        icons.append(contentsOf: buildAntigravityCluster(
                            antigravity: antigravityUsageData,
                            provider: .antigravityThird,
                            isMonochrome: true,
                            button: button
                        ))
                    }
                }
            }

            guard !icons.isEmpty else {
                return createEmptyPlaceholder(isMonochrome: true, button: button)
            }
            let combined = icons.count == 1 ? icons[0] : combineIcons(icons, spacing: 4, height: metricIconSize)
            combined.isTemplate = icons.allSatisfy(\.isTemplate)
            return combined
        }
    }

    private func buildCodexCluster(
        codex: CodexUsageData,
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> [NSImage] {
        let types = settings.getActiveCodexDisplayTypes(codexUsageData: codex, forMenuBar: true)
        let showPlaceholder = settings.displayMode == .custom
        var icons: [NSImage] = []

        let outerType: LimitType? = {
            if types.contains(.codexPrimary), codex.primary != nil { return .codexPrimary }
            if types.contains(.codexSecondary), codex.secondary != nil { return .codexSecondary }
            if types.contains(.codexPrimary) { return .codexPrimary }
            if types.contains(.codexSecondary) { return .codexSecondary }
            return nil
        }()

        if let outerType {
            let outerPercentage: Double? = {
                switch outerType {
                case .codexPrimary: return codex.primary?.percentage ?? (showPlaceholder ? 0 : nil)
                case .codexSecondary: return codex.secondary?.percentage ?? (showPlaceholder ? 0 : nil)
                default: return nil
                }
            }()

            if let outerPercentage {
                let innerPercentage: Double? = {
                    guard outerType == .codexPrimary, types.contains(.codexSecondary) else { return nil }
                    return codex.secondary?.percentage ?? (showPlaceholder ? 0 : nil)
                }()

                icons.append(createConcentricRingImage(
                    outerPercentage: UsageRingDisplay.displayedPercentage(
                        usedPercentage: outerPercentage,
                        showRemainingMode: settings.showRemainingMode
                    ),
                    innerPercentage: innerPercentage.map {
                        UsageRingDisplay.displayedPercentage(
                            usedPercentage: $0,
                            showRemainingMode: settings.showRemainingMode
                        )
                    },
                    outerColor: .black,
                    innerColor: NSColor.black.withAlphaComponent(0.78),
                    isMonochrome: true,
                    button: button
                ))
            }
        }

        if types.contains(.codexExtraUsage) {
            let percentage: Double?
            if let extra = codex.extraUsage, extra.enabled {
                percentage = extra.percentage
            } else if showPlaceholder {
                percentage = 0
            } else {
                percentage = nil
            }
            if let percentage {
                icons.append(ShapeIconRenderer.createHexagonIcon(
                    percentage: UsageRingDisplay.displayedPercentage(
                        usedPercentage: percentage,
                        showRemainingMode: settings.showRemainingMode
                    ),
                    isMonochrome: true,
                    button: button,
                    removeBackground: false,
                    colorOverride: nil
                ))
            }
        }

        return icons
    }

    private func buildCursorCluster(
        cursor: CursorUsageData,
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> [NSImage] {
        let types = settings.getActiveCursorDisplayTypes(cursorUsageData: cursor, forMenuBar: true)
        let showPlaceholder = settings.displayMode == .custom
        guard types.contains(.cursorIncluded) || types.contains(.cursorOnDemand) else { return [] }

        let outerPercentage = cursor.included?.percentage ?? (showPlaceholder && types.contains(.cursorIncluded) ? 0 : nil)
        let secondaryPercentage = cursor.secondary?.percentage ?? cursor.onDemand?.percentage
        let resolvedOuter = outerPercentage ?? (types.contains(.cursorOnDemand) ? secondaryPercentage : nil)
        guard let resolvedOuter else { return [] }

        let innerPercentage: Double? = {
            guard types.contains(.cursorIncluded), types.contains(.cursorOnDemand) else { return nil }
            return secondaryPercentage ?? (showPlaceholder ? 0 : nil)
        }()

        return [
            createConcentricRingImage(
                outerPercentage: UsageRingDisplay.displayedPercentage(
                    usedPercentage: resolvedOuter,
                    showRemainingMode: settings.showRemainingMode
                ),
                innerPercentage: innerPercentage.map {
                    UsageRingDisplay.displayedPercentage(
                        usedPercentage: $0,
                        showRemainingMode: settings.showRemainingMode
                    )
                },
                outerColor: .black,
                innerColor: NSColor.black.withAlphaComponent(0.78),
                isMonochrome: true,
                button: button
            )
        ]
    }

    private func buildAntigravityCluster(
        antigravity: AntigravityUsageData,
        provider: ProviderType,
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> [NSImage] {
        let types = settings.getActiveAntigravityDisplayTypes(
            antigravityUsageData: antigravity,
            forMenuBar: true,
            provider: provider
        )
        let showPlaceholder = settings.displayMode == .custom

        let primaryType = provider == .antigravity ? LimitType.antigravityPrimary : LimitType.antigravityThirdPartyPrimary
        let secondaryType = provider == .antigravity ? LimitType.antigravitySecondary : LimitType.antigravityThirdPartySecondary

        guard types.contains(primaryType) || types.contains(secondaryType) else { return [] }

        let outerPercentage: Double? = {
            if provider == .antigravity {
                return (antigravity.geminiPrimary?.percentage ?? antigravity.primary?.percentage) ?? (showPlaceholder && types.contains(primaryType) ? 0 : nil)
            } else {
                return antigravity.thirdPartyPrimary?.percentage ?? (showPlaceholder && types.contains(primaryType) ? 0 : nil)
            }
        }()
        guard let outerPercentage else { return [] }

        let innerPercentage: Double? = {
            guard types.contains(secondaryType) else { return nil }
            if provider == .antigravity {
                return (antigravity.geminiSecondary?.percentage ?? antigravity.secondary?.percentage) ?? (showPlaceholder ? 0 : nil)
            } else {
                return antigravity.thirdPartySecondary?.percentage ?? (showPlaceholder ? 0 : nil)
            }
        }()

        let outerColor: NSColor = isMonochrome ? .black : (
            provider == .antigravity ?
            UsageColorScheme.antigravityPrimaryColorAdaptive(outerPercentage, for: button) :
            UsageColorScheme.antigravityThirdPartyPrimaryColorAdaptive(outerPercentage, for: button)
        )
        let innerColor: NSColor = isMonochrome ? NSColor.black.withAlphaComponent(0.78) : (
            provider == .antigravity ?
            UsageColorScheme.antigravitySecondaryColorAdaptive(innerPercentage ?? 0, for: button) :
            UsageColorScheme.antigravityThirdPartySecondaryColorAdaptive(innerPercentage ?? 0, for: button)
        )

        return [
            createConcentricRingImage(
                outerPercentage: UsageRingDisplay.displayedPercentage(
                    usedPercentage: outerPercentage,
                    showRemainingMode: settings.showRemainingMode
                ),
                innerPercentage: innerPercentage.map {
                    UsageRingDisplay.displayedPercentage(
                        usedPercentage: $0,
                        showRemainingMode: settings.showRemainingMode
                    )
                },
                outerColor: outerColor,
                innerColor: innerColor,
                isMonochrome: isMonochrome,
                button: button
            )
        ]
    }

    private func createConcentricRingImage(
        outerPercentage: Double,
        innerPercentage: Double?,
        outerColor: NSColor,
        innerColor: NSColor,
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage {
        let pointSize = NSSize(width: metricIconSize, height: metricIconSize)
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2.0, 2.0)
        let pixels = NSSize(width: pointSize.width * scale, height: pointSize.height * scale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width),
            pixelsHigh: Int(pixels.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: pointSize)
        }
        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return NSImage(size: pointSize)
        }
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        context.imageInterpolation = .high

        let center = NSPoint(x: pointSize.width / 2, y: pointSize.height / 2)
        // 菜单栏适中厚度：微调更纤细精致，契合 macOS 现代菜单栏原生质感
        let hasInner = innerPercentage != nil
        let outerLineWidth: CGFloat = hasInner ? 2.8 : 3.0
        let innerLineWidth: CGFloat = 2.3
        let ringGap: CGFloat = 1.15
        let outerRadius = (pointSize.width / 2) - outerLineWidth / 2 - 0.6
        let innerRadius = outerRadius - outerLineWidth / 2 - ringGap - innerLineWidth / 2

        drawActivityRing(
            percentage: outerPercentage,
            center: center,
            radius: outerRadius,
            lineWidth: outerLineWidth,
            color: isMonochrome ? NSColor.black : outerColor,
            isInner: false,
            isMonochrome: isMonochrome
        )

        if let innerPercentage {
            drawActivityRing(
                percentage: innerPercentage,
                center: center,
                radius: innerRadius,
                lineWidth: innerLineWidth,
                color: isMonochrome ? NSColor.black.withAlphaComponent(0.78) : innerColor,
                isInner: true,
                isMonochrome: isMonochrome
            )
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        // 模板图随菜单栏自动变黑/白，和其他系统图标一致
        image.isTemplate = isMonochrome
        return image
    }

    /// 健身环：绘制进度弧，并在未填充区域以精致圆点虚线呈现底轨占位
    private func drawActivityRing(
        percentage: Double,
        center: NSPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        color: NSColor,
        isInner: Bool,
        isMonochrome: Bool
    ) {
        drawDottedTrack(
            progressPercentage: percentage,
            center: center,
            radius: radius,
            lineWidth: lineWidth,
            color: color,
            isInner: isInner,
            isMonochrome: isMonochrome
        )

        drawRingProgress(
            percentage: percentage,
            center: center,
            radius: radius,
            lineWidth: lineWidth,
            color: color
        )
    }

    /// 菜单栏圆点虚线底轨：将环形未填满的空闲部分以同心圆点标尺展示
    private func drawDottedTrack(
        progressPercentage: Double,
        center: NSPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        color: NSColor,
        isInner: Bool,
        isMonochrome: Bool
    ) {
        let clamped = min(100, max(0, progressPercentage))
        guard clamped < 99.5 else { return }

        let circumference = 2 * CGFloat.pi * radius
        let capAngle = (lineWidth / circumference) * 360.0
        let solidSpan = (CGFloat(clamped) / 100.0) * 360.0
        let clearance = capAngle * 0.65

        let slotCount = isInner ? 13 : 20
        let dotDiameter: CGFloat = isInner ? 1.15 : 1.35
        let dotRadius = dotDiameter / 2.0

        let dotColor: NSColor
        if isMonochrome {
            dotColor = NSColor.black.withAlphaComponent(isInner ? 0.30 : 0.38)
        } else {
            dotColor = color.withAlphaComponent(isInner ? 0.40 : 0.46)
        }
        dotColor.setFill()

        for i in 0..<slotCount {
            let slotAngle = CGFloat(i) * (360.0 / CGFloat(slotCount))
            let inSolid: Bool
            if clamped <= 0.5 {
                inSolid = false
            } else {
                inSolid = (slotAngle <= solidSpan + clearance) || (slotAngle >= 360.0 - clearance)
            }

            if !inSolid {
                let mathAngle = (90.0 - slotAngle) * CGFloat.pi / 180.0
                let dotCenter = NSPoint(
                    x: center.x + radius * cos(mathAngle),
                    y: center.y + radius * sin(mathAngle)
                )
                let dotRect = NSRect(
                    x: dotCenter.x - dotRadius,
                    y: dotCenter.y - dotRadius,
                    width: dotDiameter,
                    height: dotDiameter
                )
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
    }

    private func drawRingProgress(
        percentage: Double,
        center: NSPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        color: NSColor
    ) {
        let clamped = min(100, max(0, percentage))
        guard clamped > 0.5 else { return }

        let baseAngle = CGFloat(clamped) / 100 * 360
        let circumference = 2 * CGFloat.pi * radius
        let capAngle = (lineWidth / circumference) * 360

        let progressAngle: CGFloat
        let startAngle: CGFloat
        if clamped >= 100 {
            progressAngle = 360
            startAngle = 90
        } else {
            progressAngle = max(capAngle * 0.4, baseAngle - capAngle * min(1, CGFloat(clamped / 35)))
            startAngle = 90 - capAngle / 2
        }

        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: startAngle - progressAngle,
            clockwise: true
        )
        path.lineWidth = lineWidth
        path.lineCapStyle = clamped >= 99.5 ? .butt : .round
        color.setStroke()
        path.stroke()
    }

    private func createProviderBrandIcon(provider: ProviderType, isMonochrome: Bool, size: CGFloat) -> NSImage? {
        switch provider {
        case .codex:
            let iconName = isMonochrome ? "CodexMenuBarTemplate" : "CodexIcon"
            return ImageHelper.createSquareIcon(named: iconName, size: size, isTemplate: isMonochrome, sourceInset: isMonochrome ? 0 : 2)
        case .cursor:
            return ImageHelper.createCursorIcon(size: size, isTemplate: isMonochrome)
        case .antigravity, .antigravityThird:
            return ImageHelper.createAntigravityIcon(size: size, isTemplate: isMonochrome)
        }
    }

    private func createEmptyPlaceholder(isMonochrome: Bool, button: NSStatusBarButton?) -> NSImage {
        createConcentricRingImage(
            outerPercentage: 0,
            innerPercentage: nil,
            outerColor: NSColor.gray,
            innerColor: NSColor.gray,
            isMonochrome: isMonochrome,
            button: button
        )
    }

    private func createSimpleCircleIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12))
        NSColor.labelColor.setStroke()
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }


    private func combineIcons(_ icons: [NSImage], spacing: CGFloat, height: CGFloat) -> NSImage {
        let totalWidth = icons.reduce(0) { $0 + $1.size.width } + CGFloat(icons.count - 1) * spacing
        let image = NSImage(size: NSSize(width: totalWidth, height: height))
        image.lockFocus()
        var currentX: CGFloat = 0
        for icon in icons {
            let y = (height - icon.size.height) / 2
            icon.draw(at: NSPoint(x: currentX, y: y), from: NSRect(origin: .zero, size: icon.size), operation: .sourceOver, fraction: 1)
            currentX += icon.size.width + spacing
        }
        image.unlockFocus()
        return image
    }

    private func createMenuBarDividerIcon(isMonochrome: Bool) -> NSImage {
        let width: CGFloat = 5
        let image = NSImage(size: NSSize(width: width, height: extraIconSize))
        image.lockFocus()
        let linePath = NSBezierPath(rect: NSRect(x: (width - 1) / 2, y: 1, width: 1, height: extraIconSize - 2))
        let lineColor = isMonochrome ? NSColor.labelColor : NSColor.secondaryLabelColor
        NSGradient(colors: [
            lineColor.withAlphaComponent(0),
            lineColor.withAlphaComponent(0.55),
            lineColor.withAlphaComponent(0)
        ])?.draw(in: linePath, angle: 90)
        image.unlockFocus()
        if isMonochrome { image.isTemplate = true }
        return image
    }
}
