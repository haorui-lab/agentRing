//
//  UserSettings.swift
//  Agent Ring
//

import Foundation
import SwiftUI
import Combine
import ServiceManagement
import OSLog

// MARK: - Display Modes

enum IconDisplayMode: String, CaseIterable, Codable {
    case percentageOnly = "percentage_only"
    case iconOnly = "icon_only"
    case both = "both"
    case none = "no_display"

    var localizedName: String {
        switch self {
        case .percentageOnly: return L.Display.percentageOnly
        case .iconOnly: return L.Display.iconOnly
        case .both: return L.Display.both
        case .none: return L.Display.none
        }
    }
}

enum IconStyleMode: String, CaseIterable, Codable {
    case colorTranslucent = "color_translucent"
    case colorWithBackground = "color_with_background"
    case monochrome = "monochrome"

    var localizedName: String {
        switch self {
        case .colorTranslucent: return L.IconStyle.colorTranslucent
        case .colorWithBackground: return L.IconStyle.colorWithBackground
        case .monochrome: return L.IconStyle.monochrome
        }
    }

    var description: String {
        switch self {
        case .colorTranslucent: return L.IconStyle.colorTranslucentDesc
        case .colorWithBackground: return L.IconStyle.colorWithBackgroundDesc
        case .monochrome: return L.IconStyle.monochromeDesc
        }
    }
}

// MARK: - Refresh Modes

enum RefreshMode: String, CaseIterable, Codable {
    case smart = "smart"
    case fixed = "fixed"

    var localizedName: String {
        switch self {
        case .smart: return L.Refresh.smartMode
        case .fixed: return L.Refresh.fixedMode
        }
    }
}

enum RefreshInterval: Int, CaseIterable, Codable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var localizedName: String {
        switch self {
        case .oneMinute: return L.Refresh.oneMinute
        case .threeMinutes: return L.Refresh.threeMinutes
        case .fiveMinutes: return L.Refresh.fiveMinutes
        case .tenMinutes: return L.Refresh.tenMinutes
        }
    }
}

enum MonitoringMode: String, Codable {
    case active = "active"
    case idleShort = "idle_short"
    case idleMedium = "idle_medium"
    case idleLong = "idle_long"

    var interval: Int {
        switch self {
        case .active: return 60
        case .idleShort: return 180
        case .idleMedium: return 300
        case .idleLong: return 600
        }
    }
}

// MARK: - Limit Types

enum LimitType: String, CaseIterable, Codable {
    case codexPrimary = "codex_primary"
    case codexSecondary = "codex_secondary"
    case codexExtraUsage = "codex_extra_usage"
    case cursorIncluded = "cursor_included"
    case cursorOnDemand = "cursor_ondemand"
    case antigravityPrimary = "antigravity_primary"
    case antigravitySecondary = "antigravity_secondary"
    case antigravityThirdPartyPrimary = "antigravity_third_party_primary"
    case antigravityThirdPartySecondary = "antigravity_third_party_secondary"

    var provider: ProviderType {
        switch self {
        case .codexPrimary, .codexSecondary, .codexExtraUsage: return .codex
        case .cursorIncluded, .cursorOnDemand: return .cursor
        case .antigravityPrimary, .antigravitySecondary: return .antigravity
        case .antigravityThirdPartyPrimary, .antigravityThirdPartySecondary: return .antigravityThird
        }
    }

    var isCircular: Bool {
        self == .codexPrimary || self == .codexSecondary || self == .cursorIncluded || self == .cursorOnDemand || self == .antigravityPrimary || self == .antigravitySecondary || self == .antigravityThirdPartyPrimary || self == .antigravityThirdPartySecondary
    }

    var isRectangular: Bool { false }

    var isHexagonal: Bool {
        self == .codexExtraUsage
    }

    var usesDashedStyle: Bool {
        self == .codexSecondary || self == .antigravitySecondary || self == .antigravityThirdPartySecondary
    }

    var displayName: String {
        switch self {
        case .codexPrimary: return L.LimitTypes.codexPrimary
        case .codexSecondary: return L.LimitTypes.codexSecondary
        case .codexExtraUsage: return L.LimitTypes.codexExtraUsage
        case .cursorIncluded: return L.LimitTypes.cursorIncluded
        case .cursorOnDemand: return L.LimitTypes.cursorOnDemand
        case .antigravityPrimary: return L.LimitTypes.antigravityPrimary
        case .antigravitySecondary: return L.LimitTypes.antigravitySecondary
        case .antigravityThirdPartyPrimary: return L.LimitTypes.antigravityThirdPartyPrimary
        case .antigravityThirdPartySecondary: return L.LimitTypes.antigravityThirdPartySecondary
        }
    }

    /// Popover row label — shorter, no provider prefix (columns already scope by provider).
    var detailDisplayName: String {
        switch self {
        case .codexPrimary: return L.DetailRow.fiveHour
        case .codexSecondary: return L.DetailRow.sevenDay
        case .codexExtraUsage: return L.DetailRow.extraUsage
        case .cursorIncluded: return L.DetailRow.cursorIncluded
        case .cursorOnDemand: return L.DetailRow.cursorOnDemand
        case .antigravityPrimary: return L.DetailRow.antigravityGeminiPrimary
        case .antigravitySecondary: return L.DetailRow.antigravityGeminiSecondary
        case .antigravityThirdPartyPrimary: return L.DetailRow.antigravityThirdPartyPrimary
        case .antigravityThirdPartySecondary: return L.DetailRow.antigravityThirdPartySecondary
        }
    }
}

enum DisplayMode: String, CaseIterable, Codable {
    case smart = "smart"
    case custom = "custom"

    var localizedName: String {
        switch self {
        case .smart: return L.DisplayOptions.smartDisplay
        case .custom: return L.DisplayOptions.customDisplay
        }
    }
}

enum TimeFormatPreference: String, CaseIterable, Codable {
    case system = "system"
    case twelveHour = "twelve_hour"
    case twentyFourHour = "twenty_four_hour"

    var localizedName: String {
        switch self {
        case .system: return L.TimeFormat.system
        case .twelveHour: return L.TimeFormat.twelveHour
        case .twentyFourHour: return L.TimeFormat.twentyFourHour
        }
    }
}

enum AppAppearance: String, CaseIterable, Codable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var localizedName: String {
        switch self {
        case .system: return L.Appearance.system
        case .light: return L.Appearance.light
        case .dark: return L.Appearance.dark
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Codable {
    case english = "en"
    case chinese = "zh-Hans"

    var localizedName: String {
        switch self {
        case .english: return L.Language.english
        case .chinese: return L.Language.chinese
        }
    }

    var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en_US")
        case .chinese: return Locale(identifier: "zh_CN")
        }
    }
}

enum UsageDisplayValueMode: String, CaseIterable, Codable {
    case remaining = "remaining"
    case used = "used"

    var localizedName: String {
        switch self {
        case .remaining: return L.Usage.available
        case .used: return L.Usage.used
        }
    }
}

// MARK: - User Settings

final class UserSettings: ObservableObject {
    static let shared = UserSettings()

    private let defaults = UserDefaults.standard
    private let keychain = KeychainManager.shared

    @Published var codexAccounts: [Account] = [] {
        didSet { saveCodexAccounts() }
    }

    @Published var currentCodexAccountId: UUID? {
        didSet {
            let key = Self.currentCodexAccountIdKey
            if let id = currentCodexAccountId {
                defaults.set(id.uuidString, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    @Published var cursorAccounts: [Account] = [] {
        didSet { saveCursorAccounts() }
    }

    @Published var currentCursorAccountId: UUID? {
        didSet {
            let key = Self.currentCursorAccountIdKey
            if let id = currentCursorAccountId {
                defaults.set(id.uuidString, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    var currentCodexAccount: Account? {
        guard let id = currentCodexAccountId else { return codexAccounts.first }
        return codexAccounts.first { $0.id == id } ?? codexAccounts.first
    }

    var currentCursorAccount: Account? {
        guard let id = currentCursorAccountId else { return cursorAccounts.first }
        return cursorAccounts.first { $0.id == id } ?? cursorAccounts.first
    }

    var codexSessionToken: String {
        currentCodexAccount?.credentialToken ?? ""
    }

    var cursorSessionToken: String {
        currentCursorAccount?.credentialToken ?? ""
    }

    var hasValidCodexCredentials: Bool {
        !codexSessionToken.isEmpty
    }

    var hasValidCursorCredentials: Bool {
        !cursorSessionToken.isEmpty
    }

    /// Antigravity 是否纳入监控（用户开关；默认开启，真正能否拉取取决于系统凭证）
    @Published var antigravityEnabled: Bool {
        didSet {
            defaults.set(antigravityEnabled, forKey: "antigravityEnabled")
            if antigravityEnabled {
                ensureDefaultAntigravityDisplayTypesForCustomMode()
            }
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
            postAccountChanged(provider: .antigravity)
        }
    }

    /// 本机能否读到 Antigravity 通行凭证（钥匙串 / oauth 文件）
    var hasValidAntigravityCredentials: Bool {
        guard antigravityEnabled else { return false }
        #if DEBUG
        if debugModeEnabled { return true }
        #endif
        return AntigravityAPIService.credentialsAvailable()
    }

    var hasAnyValidCredentials: Bool {
        hasValidCodexCredentials || hasValidCursorCredentials || hasValidAntigravityCredentials
    }

    var hasValidCredentials: Bool {
        hasAnyValidCredentials
    }

    var isMultiProviderActive: Bool {
        #if DEBUG
        if debugModeEnabled {
            return true
        }
        #endif
        let activeCount = [
            hasValidCodexCredentials,
            hasValidCursorCredentials,
            hasValidAntigravityCredentials
        ].filter { $0 }.count
        return activeCount >= 2
    }

    @Published var iconDisplayMode: IconDisplayMode {
        didSet {
            defaults.set(iconDisplayMode.rawValue, forKey: "iconDisplayMode")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var iconStyleMode: IconStyleMode {
        didSet {
            defaults.set(iconStyleMode.rawValue, forKey: "iconStyleMode")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var refreshMode: RefreshMode {
        didSet {
            defaults.set(refreshMode.rawValue, forKey: "refreshMode")
            NotificationCenter.default.post(name: .refreshIntervalChanged, object: nil)
        }
    }

    @Published var refreshInterval: Int {
        didSet {
            defaults.set(refreshInterval, forKey: "refreshInterval")
            NotificationCenter.default.post(name: .refreshIntervalChanged, object: nil)
        }
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var timeFormatPreference: TimeFormatPreference {
        didSet {
            defaults.set(timeFormatPreference.rawValue, forKey: "timeFormatPreference")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var displayMode: DisplayMode {
        didSet {
            defaults.set(displayMode.rawValue, forKey: "displayMode")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var customDisplayTypes: Set<LimitType> {
        didSet {
            defaults.set(customDisplayTypes.map(\.rawValue), forKey: "customDisplayTypes")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var customDisplayMenuBarOnly: Bool {
        didSet {
            defaults.set(customDisplayMenuBarOnly, forKey: "customDisplayMenuBarOnly")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var usageDisplayValueMode: UsageDisplayValueMode {
        didSet {
            defaults.set(usageDisplayValueMode.rawValue, forKey: "usageDisplayValueMode")
            defaults.set(usageDisplayValueMode == .remaining, forKey: "showRemainingMode")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var showRemainingMode: Bool {
        get { usageDisplayValueMode == .remaining }
        set { usageDisplayValueMode = newValue ? .remaining : .used }
    }

    @Published var providerOrder: [ProviderType] {
        didSet {
            defaults.set(providerOrder.map(\.rawValue), forKey: "providerOrder")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var shouldShowCustomPlaceholderInPopover: Bool {
        displayMode == .custom && !customDisplayMenuBarOnly
    }

    @Published var isFirstLaunch: Bool {
        didSet { defaults.set(isFirstLaunch, forKey: "isFirstLaunch") }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    /// 蓝牙副屏同步开关（默认关闭；开启后向已配对的 agentRing-Android 副屏推送用量）
    @Published var bluetoothSyncEnabled: Bool {
        didSet {
            defaults.set(bluetoothSyncEnabled, forKey: "bluetoothSyncEnabled")
            if bluetoothSyncEnabled {
                BluetoothSyncService.shared.start()
                // 开启即推：不等下一次轮询，把当前已有数据立即发一帧
                postBluetoothImmediatePush()
            } else {
                BluetoothSyncService.shared.stop()
            }
        }
    }

    private func postBluetoothImmediatePush() {
        let dataManager = (NSApp.delegate as? AppDelegate)?.menuBarManager?.dataManagerForBluetooth
        let codex = dataManager?.codexData
        let cursor = dataManager?.cursorData
        let antigravity = dataManager?.antigravityData
        // pushPayload 是 MainActor，从设置页切换开关必然在主线程，直接 hop
        Task { @MainActor in
            BluetoothSyncService.shared.pushPayload(
                codexUsageData: codex,
                cursorUsageData: cursor,
                antigravityUsageData: antigravity
            )
            BLESyncService.shared.pushPayload(
                codexUsageData: codex,
                cursorUsageData: cursor,
                antigravityUsageData: antigravity
            )
        }
    }

    /// 自动检查更新开关（默认开启，由 Sparkle 每小时调度，安装需用户确认）
    @Published var autoUpdateEnabled: Bool {
        didSet {
            defaults.set(autoUpdateEnabled, forKey: "autoUpdateEnabled")
            defaults.set(autoUpdateEnabled, forKey: "SUEnableAutomaticChecks")
            NotificationCenter.default.post(name: .autoUpdateSettingChanged, object: nil)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchStatus else { return }
            launchAtLogin ? enableLaunchAtLogin() : disableLaunchAtLogin()
        }
    }

    @Published var launchAtLoginStatus: SMAppService.Status = .notRegistered
    private var isSyncingLaunchStatus = false

    #if DEBUG
    @Published var debugModeEnabled: Bool {
        didSet {
            defaults.set(debugModeEnabled, forKey: "debugModeEnabled")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var debugCodexPrimaryPercentage: Double {
        didSet {
            defaults.set(debugCodexPrimaryPercentage, forKey: "debugCodexPrimaryPercentage")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var debugCodexSecondaryPercentage: Double {
        didSet {
            defaults.set(debugCodexSecondaryPercentage, forKey: "debugCodexSecondaryPercentage")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var debugCodexExtraUsagePercentage: Double {
        didSet {
            defaults.set(debugCodexExtraUsagePercentage, forKey: "debugCodexExtraUsagePercentage")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var debugCursorIncludedPercentage: Double {
        didSet {
            defaults.set(debugCursorIncludedPercentage, forKey: "debugCursorIncludedPercentage")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var debugCursorOnDemandPercentage: Double {
        didSet {
            defaults.set(debugCursorOnDemandPercentage, forKey: "debugCursorOnDemandPercentage")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var debugCursorOnDemandLimit: Double {
        didSet {
            defaults.set(debugCursorOnDemandLimit, forKey: "debugCursorOnDemandLimit")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var simulateUpdateAvailable: Bool {
        didSet {
            defaults.set(simulateUpdateAvailable, forKey: "simulateUpdateAvailable")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var debugShowAllShapesIndividually: Bool {
        didSet {
            defaults.set(debugShowAllShapesIndividually, forKey: "debugShowAllShapesIndividually")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published var debugKeepDetailWindowOpen: Bool {
        didSet { defaults.set(debugKeepDetailWindowOpen, forKey: "debugKeepDetailWindowOpen") }
    }
    #endif

    var lastUtilization: Double?
    var lastUtilizationByProvider: [ProviderType: Double] = [:]
    var unchangedCount = 0
    var currentMonitoringMode: MonitoringMode = .active

    var appLocale: Locale { language.locale }

    var effectiveRefreshInterval: Int {
        refreshMode == .smart ? currentMonitoringMode.interval : refreshInterval
    }

    private static var currentCodexAccountIdKey: String {
        #if DEBUG
        return "DEBUG_currentCodexAccountId"
        #else
        return "currentCodexAccountId"
        #endif
    }

    private static var currentCursorAccountIdKey: String {
        #if DEBUG
        return "DEBUG_currentCursorAccountId"
        #else
        return "currentCursorAccountId"
        #endif
    }

    private init() {
        LegacyBundleMigration.runIfNeeded()

        let loadedCodexAccounts = keychain.loadCodexAccounts() ?? keychain.loadAccounts() ?? []
        let mappedCodexAccounts = loadedCodexAccounts.map { account in
            var copy = account
            copy.provider = .codex
            return copy
        }
        codexAccounts = mappedCodexAccounts

        if let idString = defaults.string(forKey: Self.currentCodexAccountIdKey),
           let id = UUID(uuidString: idString) {
            currentCodexAccountId = id
        } else {
            currentCodexAccountId = mappedCodexAccounts.first?.id
        }

        let loadedCursorAccounts = (keychain.loadCursorAccounts() ?? []).map { account -> Account in
            var copy = account
            copy.provider = .cursor
            return copy
        }
        cursorAccounts = loadedCursorAccounts
        if let idString = defaults.string(forKey: Self.currentCursorAccountIdKey),
           let id = UUID(uuidString: idString) {
            currentCursorAccountId = id
        } else {
            currentCursorAccountId = loadedCursorAccounts.first?.id
        }

        iconDisplayMode = defaults.string(forKey: "iconDisplayMode").flatMap(IconDisplayMode.init(rawValue:)) ?? .percentageOnly
        iconStyleMode = defaults.string(forKey: "iconStyleMode").flatMap(IconStyleMode.init(rawValue:)) ?? .colorTranslucent
        refreshMode = defaults.string(forKey: "refreshMode").flatMap(RefreshMode.init(rawValue:)) ?? .smart

        let savedRefreshInterval = defaults.integer(forKey: "refreshInterval")
        refreshInterval = savedRefreshInterval > 0 ? savedRefreshInterval : 180

        language = Self.detectSystemLanguage()
        // 外观与时间一律跟随系统，忽略历史手动值
        appearance = .system
        timeFormatPreference = .system
        defaults.set(AppAppearance.system.rawValue, forKey: "appearance")
        defaults.set(TimeFormatPreference.system.rawValue, forKey: "timeFormatPreference")
        // 显示模式固定为智能，设置页已移除手动切换
        displayMode = .smart
        defaults.set(DisplayMode.smart.rawValue, forKey: "displayMode")
        customDisplayMenuBarOnly = false
        defaults.set(false, forKey: "customDisplayMenuBarOnly")

        let savedRemaining = defaults.object(forKey: "showRemainingMode") as? Bool ?? true
        if let raw = defaults.string(forKey: "usageDisplayValueMode"), let mode = UsageDisplayValueMode(rawValue: raw) {
            usageDisplayValueMode = mode
        } else {
            usageDisplayValueMode = savedRemaining ? .remaining : .used
        }

        if let rawValues = defaults.array(forKey: "customDisplayTypes") as? [String] {
            let migrated = rawValues.compactMap(LimitType.init(rawValue:))
            customDisplayTypes = migrated.isEmpty ? [.codexPrimary, .codexSecondary] : Set(migrated)
        } else {
            customDisplayTypes = [.codexPrimary, .codexSecondary]
        }

        if let rawValues = defaults.array(forKey: "providerOrder") as? [String] {
            let saved = rawValues.compactMap(ProviderType.init(rawValue:))
            var result = saved
            for p in ProviderType.allCases {
                if !result.contains(p) {
                    result.append(p)
                }
            }
            providerOrder = result
        } else {
            providerOrder = ProviderType.allCases
        }

        if !defaults.bool(forKey: "hasLaunched") {
            isFirstLaunch = true
            defaults.set(true, forKey: "hasLaunched")
        } else {
            isFirstLaunch = false
        }

        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        bluetoothSyncEnabled = defaults.bool(forKey: "bluetoothSyncEnabled")
        autoUpdateEnabled = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool
            ?? defaults.object(forKey: "autoUpdateEnabled") as? Bool ?? true
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        // 缺省开启：只要本机有 Antigravity 凭证就自动当一等公民监控
        if defaults.object(forKey: "antigravityEnabled") == nil {
            antigravityEnabled = true
        } else {
            antigravityEnabled = defaults.bool(forKey: "antigravityEnabled")
        }

        #if DEBUG
        debugModeEnabled = defaults.bool(forKey: "debugModeEnabled")
        debugCodexPrimaryPercentage = defaults.object(forKey: "debugCodexPrimaryPercentage") as? Double ?? 42.0
        debugCodexSecondaryPercentage = defaults.object(forKey: "debugCodexSecondaryPercentage") as? Double ?? 58.0
        debugCodexExtraUsagePercentage = defaults.object(forKey: "debugCodexExtraUsagePercentage") as? Double ?? 35.0
        debugCursorIncludedPercentage = defaults.object(forKey: "debugCursorIncludedPercentage") as? Double ?? 67.0
        debugCursorOnDemandPercentage = defaults.object(forKey: "debugCursorOnDemandPercentage") as? Double ?? 20.0
        debugCursorOnDemandLimit = defaults.object(forKey: "debugCursorOnDemandLimit") as? Double ?? 1000.0
        simulateUpdateAvailable = defaults.bool(forKey: "simulateUpdateAvailable")
        debugShowAllShapesIndividually = defaults.bool(forKey: "debugShowAllShapesIndividually")
        debugKeepDetailWindowOpen = defaults.bool(forKey: "debugKeepDetailWindowOpen")
        #endif

        // init 赋值不会触发 didSet，全部存储属性就绪后再补自定义显示默认勾选
        if antigravityEnabled {
            ensureDefaultAntigravityDisplayTypesForCustomMode()
        }

        syncLaunchAtLoginStatus()
        applyAppearance()
    }

    private static func detectSystemLanguage() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        // 仅支持简体中文；繁体及其他语言一律回退 English
        if preferred.hasPrefix("zh-Hans") || preferred.hasPrefix("zh-CN") || preferred == "zh" {
            return .chinese
        }
        return .english
    }

    func applyAppearance() {
        DispatchQueue.main.async {
            // 跟随系统：置 nil，让 AppKit 原生跟着系统外观走
            switch self.appearance {
            case .system:
                NSApp.appearance = nil
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
            case .dark:
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    func resetToDefaults() {
        appearance = .system
        iconDisplayMode = .percentageOnly
        iconStyleMode = .colorTranslucent
        refreshMode = .smart
        refreshInterval = 180
        language = Self.detectSystemLanguage()
        timeFormatPreference = .system
        displayMode = .smart
        usageDisplayValueMode = .remaining
        providerOrder = ProviderType.allCases
        customDisplayTypes = [.codexPrimary, .codexSecondary]
        customDisplayMenuBarOnly = false
        notificationsEnabled = true
        bluetoothSyncEnabled = false
        autoUpdateEnabled = true
        resetSmartMonitoringState()
    }

    func setProviderOrder(_ newOrder: [ProviderType]) {
        var updated = newOrder
        for p in ProviderType.allCases {
            if !updated.contains(p) {
                updated.append(p)
            }
        }
        if providerOrder != updated {
            providerOrder = updated
        }
    }

    func orderedActiveProviders(
        codexUsageData: CodexUsageData? = nil,
        cursorUsageData: CursorUsageData? = nil,
        antigravityUsageData: AntigravityUsageData? = nil
    ) -> [ProviderType] {
        var active: Set<ProviderType> = []
        if hasValidCodexCredentials || codexUsageData != nil {
            active.insert(.codex)
        }
        if hasValidCursorCredentials || cursorUsageData != nil {
            active.insert(.cursor)
        }
        if hasValidAntigravityCredentials || antigravityUsageData != nil {
            active.insert(.antigravity)
            if antigravityUsageData?.thirdPartyPrimary != nil || antigravityUsageData?.thirdPartySecondary != nil || antigravityEnabled {
                active.insert(.antigravityThird)
            }
        }
        return providerOrder.filter { active.contains($0) }
    }

    func isValidSessionKey(_ key: String) -> Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && key.count >= 20 && key.count <= 5000
    }

    func updateSmartMonitoringMode(currentUtilization: Double) {
        updateSmartMonitoringMode(providerUtilizations: [.codex: currentUtilization])
    }

    func updateSmartMonitoringMode(providerUtilizations: [ProviderType: Double]) {
        guard refreshMode == .smart, !providerUtilizations.isEmpty else { return }

        if hasProviderUtilizationChanged(providerUtilizations) {
            switchToActiveMode()
        } else {
            handleNoChange()
        }

        for (provider, utilization) in providerUtilizations {
            lastUtilizationByProvider[provider] = utilization
        }
        lastUtilization = providerUtilizations[.codex] ?? providerUtilizations.values.first
    }

    private func hasProviderUtilizationChanged(_ current: [ProviderType: Double]) -> Bool {
        current.contains { provider, utilization in
            guard let last = lastUtilizationByProvider[provider] else { return false }
            return abs(utilization - last) > 0.01
        }
    }

    private func switchToActiveMode() {
        guard currentMonitoringMode != .active else { return }
        Logger.settings.debug("检测到使用变化，切换到活跃模式")
        currentMonitoringMode = .active
        unchangedCount = 0
        NotificationCenter.default.post(name: .refreshIntervalChanged, object: nil)
    }

    private func handleNoChange() {
        unchangedCount += 1
        let nextMode: MonitoringMode?
        switch currentMonitoringMode {
        case .active: nextMode = unchangedCount >= 3 ? .idleShort : nil
        case .idleShort: nextMode = unchangedCount >= 6 ? .idleMedium : nil
        case .idleMedium: nextMode = unchangedCount >= 12 ? .idleLong : nil
        case .idleLong: nextMode = nil
        }
        guard let nextMode else { return }
        currentMonitoringMode = nextMode
        unchangedCount = 0
        NotificationCenter.default.post(name: .refreshIntervalChanged, object: nil)
    }

    func resetSmartMonitoringState() {
        lastUtilization = nil
        lastUtilizationByProvider.removeAll()
        unchangedCount = 0
        currentMonitoringMode = .active
    }

    private func saveCodexAccounts() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.keychain.saveCodexAccounts(self.codexAccounts)
        }
    }

    private func saveCursorAccounts() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.keychain.saveCursorAccounts(self.cursorAccounts)
        }
    }

    @discardableResult
    func addCodexAccount(_ account: Account) -> Account {
        let stableId = account.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existingIndex = codexAccounts.firstIndex { existing in
            if !stableId.isEmpty {
                return existing.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == stableId
                    || existing.credentialToken == account.credentialToken
            }
            return existing.credentialToken == account.credentialToken
        }

        if let index = existingIndex {
            codexAccounts[index].credentialToken = account.credentialToken
            codexAccounts[index].accountIdentifier = account.accountIdentifier
            codexAccounts[index].accountName = account.accountName
            codexAccounts[index].provider = .codex
            if currentCodexAccountId == nil {
                currentCodexAccountId = codexAccounts[index].id
            }
            Logger.settings.notice("更新 Codex 账户: \(self.codexAccounts[index].displayName)")
            postAccountChanged()
            return codexAccounts[index]
        }

        var storedAccount = account
        storedAccount.provider = .codex
        codexAccounts.append(storedAccount)
        if codexAccounts.count == 1 {
            currentCodexAccountId = storedAccount.id
        }
        ensureDefaultCodexDisplayTypesForCustomMode()
        Logger.settings.notice("添加 Codex 账户: \(storedAccount.displayName)")
        postAccountChanged()
        return storedAccount
    }

    func removeCodexAccount(_ account: Account) {
        guard let index = codexAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        let wasCurrent = currentCodexAccountId == account.id
        codexAccounts.remove(at: index)
        NotificationManager.shared.resetNotificationStates(for: .codex, accountId: account.id)
        if wasCurrent {
            currentCodexAccountId = codexAccounts.first?.id
            postAccountChanged()
        }
        Logger.settings.notice("删除 Codex 账户: \(account.displayName)")
    }

    func switchToCodexAccount(_ account: Account) {
        guard account.id != currentCodexAccountId else { return }
        guard codexAccounts.contains(where: { $0.id == account.id }) else { return }
        currentCodexAccountId = account.id
        Logger.settings.notice("切换到 Codex 账户: \(account.displayName)")
        postAccountChanged()
    }

    func updateCodexAccount(_ account: Account, alias: String?) {
        guard let index = codexAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        codexAccounts[index].alias = alias
        Logger.settings.notice("更新 Codex 账户别名: \(self.codexAccounts[index].displayName)")
    }

    func silentlyUpdateCurrentCodexSessionToken(_ token: String) {
        guard let id = currentCodexAccountId,
              let index = codexAccounts.firstIndex(where: { $0.id == id }),
              codexAccounts[index].credentialToken != token else { return }
        codexAccounts[index].credentialToken = token
        Logger.settings.notice("Codex session-token 已静默更新")
    }

    @discardableResult
    func addCursorAccount(_ account: Account) -> Account {
        let stableId = account.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existingIndex = cursorAccounts.firstIndex { existing in
            if !stableId.isEmpty {
                return existing.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == stableId
                    || existing.credentialToken == account.credentialToken
            }
            return existing.credentialToken == account.credentialToken
        }

        if let index = existingIndex {
            cursorAccounts[index].credentialToken = account.credentialToken
            cursorAccounts[index].accountIdentifier = account.accountIdentifier
            cursorAccounts[index].accountName = account.accountName
            cursorAccounts[index].provider = .cursor
            if currentCursorAccountId == nil {
                currentCursorAccountId = cursorAccounts[index].id
            }
            postAccountChanged(provider: .cursor)
            return cursorAccounts[index]
        }

        var storedAccount = account
        storedAccount.provider = .cursor
        cursorAccounts.append(storedAccount)
        if cursorAccounts.count == 1 {
            currentCursorAccountId = storedAccount.id
        }
        ensureDefaultCursorDisplayTypesForCustomMode()
        postAccountChanged(provider: .cursor)
        return storedAccount
    }

    func removeCursorAccount(_ account: Account) {
        guard let index = cursorAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        let wasCurrent = currentCursorAccountId == account.id
        cursorAccounts.remove(at: index)
        NotificationManager.shared.resetNotificationStates(for: .cursor, accountId: account.id)
        if wasCurrent {
            currentCursorAccountId = cursorAccounts.first?.id
            postAccountChanged(provider: .cursor)
        }
    }

    func switchToCursorAccount(_ account: Account) {
        guard account.id != currentCursorAccountId else { return }
        guard cursorAccounts.contains(where: { $0.id == account.id }) else { return }
        currentCursorAccountId = account.id
        postAccountChanged(provider: .cursor)
    }

    func updateCursorAccount(_ account: Account, alias: String?) {
        guard let index = cursorAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        cursorAccounts[index].alias = alias
    }

    private func postAccountChanged() {
        postAccountChanged(provider: .codex)
    }

    private func postAccountChanged(provider: ProviderType) {
        NotificationCenter.default.post(
            name: .accountChanged,
            object: nil,
            userInfo: [Notification.UserInfoKey.provider: provider.rawValue]
        )
    }

    private func ensureDefaultCodexDisplayTypesForCustomMode() {
        guard displayMode == .custom else { return }
        let codexTypes: Set<LimitType> = [.codexPrimary, .codexSecondary, .codexExtraUsage]
        guard customDisplayTypes.isDisjoint(with: codexTypes) else { return }
        customDisplayTypes.formUnion([.codexPrimary, .codexSecondary])
    }

    private func ensureDefaultCursorDisplayTypesForCustomMode() {
        guard displayMode == .custom else { return }
        let cursorTypes: Set<LimitType> = [.cursorIncluded, .cursorOnDemand]
        guard customDisplayTypes.isDisjoint(with: cursorTypes) else { return }
        customDisplayTypes.insert(.cursorIncluded)
    }

    private func ensureDefaultAntigravityDisplayTypesForCustomMode() {
        guard displayMode == .custom else { return }
        let agyTypes: Set<LimitType> = [.antigravityPrimary, .antigravitySecondary, .antigravityThirdPartyPrimary, .antigravityThirdPartySecondary]
        guard customDisplayTypes.isDisjoint(with: agyTypes) else { return }
        customDisplayTypes.formUnion([.antigravityPrimary, .antigravitySecondary])
    }

    func getActiveDisplayTypes(codexUsageData: CodexUsageData? = nil, forMenuBar: Bool = false) -> [LimitType] {
        getActiveCodexDisplayTypes(codexUsageData: codexUsageData, forMenuBar: forMenuBar)
    }

    func getActiveCodexDisplayTypes(codexUsageData: CodexUsageData? = nil, forMenuBar: Bool = false) -> [LimitType] {
        let effectiveMode: DisplayMode = displayMode == .custom && customDisplayMenuBarOnly && !forMenuBar ? .smart : displayMode

        switch effectiveMode {
        case .smart:
            guard let codexUsageData else { return [] }
            var types: [LimitType] = []
            if codexUsageData.primary != nil {
                types.append(.codexPrimary)
            }
            if codexUsageData.secondary != nil {
                types.append(.codexSecondary)
            }
            if codexUsageData.extraUsage?.enabled == true {
                types.append(.codexExtraUsage)
            }
            return types

        case .custom:
            return LimitType.allCases.filter { customDisplayTypes.contains($0) && $0.provider == .codex }
        }
    }

    func getActiveCursorDisplayTypes(cursorUsageData: CursorUsageData? = nil, forMenuBar: Bool = false) -> [LimitType] {
        let effectiveMode: DisplayMode = displayMode == .custom && customDisplayMenuBarOnly && !forMenuBar ? .smart : displayMode

        switch effectiveMode {
        case .smart:
            guard let cursorUsageData else { return [] }
            var types: [LimitType] = []
            if cursorUsageData.included != nil {
                types.append(.cursorIncluded)
            }
            // Prefer Other Models (api) when present; otherwise fall back to paid on-demand.
            if cursorUsageData.apiModels != nil || cursorUsageData.onDemand != nil {
                types.append(.cursorOnDemand)
            }
            return types

        case .custom:
            return LimitType.allCases.filter { customDisplayTypes.contains($0) && $0.provider == .cursor }
        }
    }

    func getActiveAntigravityDisplayTypes(
        antigravityUsageData: AntigravityUsageData? = nil,
        forMenuBar: Bool = false,
        provider: ProviderType = .antigravity
    ) -> [LimitType] {
        let effectiveMode: DisplayMode = displayMode == .custom && customDisplayMenuBarOnly && !forMenuBar ? .smart : displayMode

        switch effectiveMode {
        case .smart:
            guard let antigravityUsageData else { return [] }
            var types: [LimitType] = []
            if provider == .antigravity {
                if antigravityUsageData.geminiPrimary != nil {
                    types.append(.antigravityPrimary)
                }
                if antigravityUsageData.geminiSecondary != nil {
                    types.append(.antigravitySecondary)
                }
            } else if provider == .antigravityThird {
                if antigravityUsageData.thirdPartyPrimary != nil {
                    types.append(.antigravityThirdPartyPrimary)
                }
                if antigravityUsageData.thirdPartySecondary != nil {
                    types.append(.antigravityThirdPartySecondary)
                }
            }
            return types

        case .custom:
            return LimitType.allCases.filter { customDisplayTypes.contains($0) && $0.provider == provider }
        }
    }

    func canUseColoredTheme() -> Bool {
        !customDisplayTypes.isEmpty
    }

    private func enableLaunchAtLogin() {
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: "launchAtLogin")
            syncLaunchAtLoginStatus()
        } catch {
            handleLaunchAtLoginError(error, operation: "enable")
        }
    }

    private func disableLaunchAtLogin() {
        let currentStatus = SMAppService.mainApp.status
        guard currentStatus != .notRegistered && currentStatus != .notFound else {
            defaults.set(false, forKey: "launchAtLogin")
            syncLaunchAtLoginStatus()
            return
        }

        do {
            try SMAppService.mainApp.unregister()
            defaults.set(false, forKey: "launchAtLogin")
            syncLaunchAtLoginStatus()
        } catch {
            handleLaunchAtLoginError(error, operation: "disable")
        }
    }

    private func handleLaunchAtLoginError(_ error: Error, operation: String) {
        Logger.settings.error("开机启动操作失败: \(error.localizedDescription)")
        isSyncingLaunchStatus = true
        DispatchQueue.main.async {
            self.launchAtLogin = operation == "disable"
            self.isSyncingLaunchStatus = false
            self.syncLaunchAtLoginStatus()
        }
        NotificationCenter.default.post(
            name: .launchAtLoginError,
            object: nil,
            userInfo: ["error": error, "operation": operation]
        )
    }

    func syncLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        DispatchQueue.main.async {
            self.launchAtLoginStatus = status
            let isActuallyEnabled = status == .enabled
            if self.launchAtLogin != isActuallyEnabled {
                self.isSyncingLaunchStatus = true
                self.defaults.set(isActuallyEnabled, forKey: "launchAtLogin")
                self.launchAtLogin = isActuallyEnabled
                self.isSyncingLaunchStatus = false
            }
        }
    }
}
