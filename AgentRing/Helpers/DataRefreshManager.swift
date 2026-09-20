//
//  DataRefreshManager.swift
//  Agent Ring
//

import Foundation
import Combine
import OSLog
import AppKit

final class DataRefreshManager: ObservableObject {
    private let codexApiService = CodexAPIService()
    private let cursorApiService = CursorAPIService()
    private let antigravityApiService = AntigravityAPIService()
    private let timerManager = TimerManager()
    private let settings = UserSettings.shared

    @Published var codexUsageData: CodexUsageData?
    @Published var cursorUsageData: CursorUsageData?
    @Published var antigravityUsageData: AntigravityUsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var codexNeedsRelogin = false
    @Published private(set) var cursorNeedsRelogin = false
    @Published private(set) var antigravityNeedsRelogin = false
    let refreshState = RefreshState()

    private var lastCodexResetsAt: Date?
    private var lastCursorResetsAt: Date?
    private var lastAntigravityResetsAt: Date?
    private var lastManualRefreshTime: Date?
    private var lastAPIFetchTime: Date?
    private var refreshAnimationStartTime: Date?
    private let minimumAnimationDuration: TimeInterval = 1.0
    private var refreshActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var codexSessionExpiredNotified = false
    private var cursorSessionExpiredNotified = false
    private var antigravitySessionExpiredNotified = false
    private var pendingFetches = 0

    private var shouldFetchCodexUsage: Bool {
        #if DEBUG
        if shouldSuppressDebugCodexUsageForDisplayOptions {
            return false
        }
        return settings.debugModeEnabled || settings.hasValidCodexCredentials
        #else
        return settings.hasValidCodexCredentials
        #endif
    }

    private var shouldFetchCursorUsage: Bool {
        #if DEBUG
        return settings.debugModeEnabled || settings.hasValidCursorCredentials
        #else
        return settings.hasValidCursorCredentials
        #endif
    }

    private var shouldFetchAntigravityUsage: Bool {
        #if DEBUG
        return settings.debugModeEnabled || settings.hasValidAntigravityCredentials
        #else
        return settings.hasValidAntigravityCredentials
        #endif
    }

    private var shouldSuppressDebugCodexUsageForDisplayOptions: Bool {
        #if DEBUG
        return settings.debugModeEnabled
            && settings.displayMode == .custom
            && !settings.customDisplayMenuBarOnly
            && settings.customDisplayTypes.isEmpty
        #else
        return false
        #endif
    }

    private enum TimerID {
        static let mainRefresh = "mainRefresh"
        static let popoverRefresh = "popoverRefresh"
        static let codexResetVerify1 = "codexResetVerify1"
        static let codexResetVerify2 = "codexResetVerify2"
        static let codexResetVerify3 = "codexResetVerify3"
        static let codexTokenRefresh = "codexTokenRefresh"
    }

    init() {
        setupWakeObserver()
    }

    func fetchUsage() {
        let fetchCodex = shouldFetchCodexUsage
        let fetchCursor = shouldFetchCursorUsage
        let fetchAntigravity = shouldFetchAntigravityUsage

        guard fetchCodex || fetchCursor || fetchAntigravity else {
            isLoading = false
            clearCodexUsageState()
            clearCursorUsageState()
            clearAntigravityUsageState()
            errorMessage = UsageError.noCredentials.localizedDescription
            endRefreshAnimationWithMinimumDuration { }
            return
        }

        isLoading = true
        errorMessage = nil
        lastAPIFetchTime = Date()
        pendingFetches = (fetchCodex ? 1 : 0) + (fetchCursor ? 1 : 0) + (fetchAntigravity ? 1 : 0)

        if fetchCodex {
            fetchCodexUsage()
        }
        if fetchCursor {
            fetchCursorUsage()
        }
        if fetchAntigravity {
            fetchAntigravityUsage()
        }
    }

    private func fetchCodexUsage() {
        codexApiService.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.processCodexSuccess(data)
                case .failure(let error):
                    if case UsageError.unauthorized = error {
                        self.attemptTokenRefreshAndRetry()
                    } else {
                        self.errorMessage = error.localizedDescription
                        Logger.menuBar.info("Codex 请求失败: \(error.localizedDescription)")
                    }
                }
                self.noteFetchFinished()
            }
        }
    }

    private func fetchCursorUsage() {
        cursorApiService.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.processCursorSuccess(data)
                case .failure(let error):
                    if case UsageError.unauthorized = error {
                        self.markCursorNeedsRelogin()
                    } else {
                        Logger.menuBar.info("Cursor 请求失败: \(error.localizedDescription)")
                        if self.cursorUsageData == nil && self.codexUsageData == nil && self.antigravityUsageData == nil {
                            self.errorMessage = error.localizedDescription
                        }
                    }
                }
                self.noteFetchFinished()
            }
        }
    }

    private func fetchAntigravityUsage() {
        antigravityApiService.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.processAntigravitySuccess(data)
                case .failure(let error):
                    if case UsageError.unauthorized = error {
                        self.markAntigravityNeedsRelogin()
                    } else if case UsageError.noCredentials = error {
                        self.clearAntigravityUsageState()
                        Logger.menuBar.info("Antigravity 无可用凭证")
                    } else {
                        Logger.menuBar.info("Antigravity 请求失败: \(error.localizedDescription)")
                        if self.antigravityUsageData == nil && self.codexUsageData == nil && self.cursorUsageData == nil {
                            self.errorMessage = error.localizedDescription
                        }
                    }
                }
                self.noteFetchFinished()
            }
        }
    }

    private func noteFetchFinished() {
        pendingFetches = max(0, pendingFetches - 1)
        if pendingFetches == 0 {
            isLoading = false
            endRefreshAnimationWithMinimumDuration { }
        }
    }

    private func processCursorSuccess(_ data: CursorUsageData) {
        let previous = cursorUsageData
        cursorUsageData = data
        cursorNeedsRelogin = false
        if errorMessage == UsageError.sessionExpired.localizedDescription && !codexNeedsRelogin && !antigravityNeedsRelogin {
            errorMessage = nil
        }

        publishSmartMonitoringUtilizations()

        if settings.notificationsEnabled {
            NotificationManager.shared.checkAndNotify(cursorUsageData: data, previousData: previous)
        }

        lastCursorResetsAt = data.included?.resetsAt

        pushBluetoothSync()
    }

    private func processAntigravitySuccess(_ data: AntigravityUsageData) {
        antigravityUsageData = data
        antigravityNeedsRelogin = false
        if errorMessage == UsageError.sessionExpired.localizedDescription && !codexNeedsRelogin && !cursorNeedsRelogin {
            errorMessage = nil
        }

        publishSmartMonitoringUtilizations()
        lastAntigravityResetsAt = data.primary?.resetsAt

        pushBluetoothSync()
    }

    /// 蓝牙副屏：任一供应商数据更新后推送最新报文
    /// processXxxSuccess 都在主线程回调，这里同步捕获数据后 hop 到 MainActor 构造
    private func pushBluetoothSync() {
        guard settings.bluetoothSyncEnabled else { return }
        let codex = codexUsageData
        let cursor = cursorUsageData
        let antigravity = antigravityUsageData
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

    private func publishSmartMonitoringUtilizations() {
        var utilizations: [ProviderType: Double] = [:]
        if let codex = codexUsageData, let value = monitoringUtilization(for: codex) {
            utilizations[.codex] = value
        }
        if let value = cursorUsageData?.included?.percentage {
            utilizations[.cursor] = value
        }
        if let antigravity = antigravityUsageData,
           let value = monitoringUtilization(for: antigravity) {
            utilizations[.antigravity] = value
        }
        if !utilizations.isEmpty {
            settings.updateSmartMonitoringMode(providerUtilizations: utilizations)
        }
    }

    private func clearCursorUsageState() {
        cursorUsageData = nil
        lastCursorResetsAt = nil
    }

    private func clearAntigravityUsageState() {
        antigravityUsageData = nil
        lastAntigravityResetsAt = nil
    }

    private func resetCursorReloginState() {
        cursorNeedsRelogin = false
        cursorSessionExpiredNotified = false
    }

    private func resetAntigravityReloginState() {
        antigravityNeedsRelogin = false
        antigravitySessionExpiredNotified = false
    }

    private func markCursorNeedsRelogin() {
        cursorNeedsRelogin = true
        if !cursorSessionExpiredNotified {
            cursorSessionExpiredNotified = true
            if settings.notificationsEnabled {
                NotificationManager.shared.sendCursorSessionExpiredNotification()
            }
        }
        if codexUsageData == nil && antigravityUsageData == nil {
            errorMessage = UsageError.sessionExpired.localizedDescription
        }
        clearCursorUsageState()
    }

    private func markAntigravityNeedsRelogin() {
        antigravityNeedsRelogin = true
        AntigravityAPIService.invalidateCredentialsCache()
        if !antigravitySessionExpiredNotified {
            antigravitySessionExpiredNotified = true
            Logger.menuBar.notice("Antigravity 会话失效，需要重新登录 Antigravity 客户端")
        }
        if codexUsageData == nil && cursorUsageData == nil {
            errorMessage = UsageError.sessionExpired.localizedDescription
        }
        clearAntigravityUsageState()
    }

    private func clearCodexUsageState(clearError: Bool = true) {
        codexUsageData = nil
        if clearError {
            errorMessage = nil
        }
        lastCodexResetsAt = nil
        cancelCodexResetVerification()
    }

    private func monitoringUtilization(for codex: CodexUsageData) -> Double? {
        [
            codex.primary?.percentage,
            codex.secondary?.percentage,
            codex.extraUsage?.percentage
        ]
        .compactMap { $0 }
        .max()
    }

    private func monitoringUtilization(for antigravity: AntigravityUsageData) -> Double? {
        [
            antigravity.primary?.percentage,
            antigravity.secondary?.percentage
        ]
        .compactMap { $0 }
        .max()
    }

    func startRefreshing() {
        beginRefreshActivity()
        fetchUsage()
        restartTimer()
        startCodexTokenRefreshTimer()

        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.objectWillChange.send()
        }
        #endif
    }

    func stopRefreshing() {
        timerManager.invalidate(TimerID.mainRefresh)
        timerManager.invalidate(TimerID.codexTokenRefresh)
        endRefreshActivity()
    }

    func startPopoverRefreshTimer(updateHandler: @escaping () -> Void) {
        timerManager.schedule(TimerID.popoverRefresh, interval: 1.0, repeats: true) {
            updateHandler()
        }
    }

    func stopPopoverRefreshTimer() {
        timerManager.invalidate(TimerID.popoverRefresh)
    }

    private func restartTimer() {
        timerManager.invalidate(TimerID.mainRefresh)
        timerManager.schedule(TimerID.mainRefresh, interval: TimeInterval(settings.effectiveRefreshInterval), repeats: true) { [weak self] in
            self?.fetchUsage()
        }
    }

    private func startCodexTokenRefreshTimer() {
        timerManager.schedule(TimerID.codexTokenRefresh, interval: 10 * 60, repeats: true) { [weak self] in
            self?.codexApiService.proactivelyRefreshIfNeeded()
        }
    }

    private func beginRefreshActivity() {
        guard refreshActivity == nil else { return }
        refreshActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Periodic Codex usage data refresh"
        )
    }

    private func endRefreshActivity() {
        if let activity = refreshActivity {
            ProcessInfo.processInfo.endActivity(activity)
            refreshActivity = nil
        }
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.menuBar.debug("系统从睡眠唤醒，刷新用量")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.fetchUsage()
            }
        }
    }

    func refreshOnPopoverOpen() {
        let now = Date()

        if settings.refreshMode == .smart {
            let wasIdle = settings.currentMonitoringMode != .active
            settings.currentMonitoringMode = .active
            settings.unchangedCount = 0
            if wasIdle {
                restartTimer()
            }
        }

        if let lastFetch = lastAPIFetchTime,
           now.timeIntervalSince(lastFetch) < 30 {
            return
        }

        fetchUsage()
    }

    func handleManualRefresh() {
        let now = Date()
        if let lastManual = lastManualRefreshTime,
           now.timeIntervalSince(lastManual) < 10 {
            return
        }

        if settings.refreshMode == .smart {
            let wasIdle = settings.currentMonitoringMode != .active
            settings.currentMonitoringMode = .active
            settings.unchangedCount = 0
            if wasIdle {
                restartTimer()
            }
        }

        lastManualRefreshTime = now
        refreshAnimationStartTime = now
        let fetchCount = [shouldFetchCodexUsage, shouldFetchCursorUsage, shouldFetchAntigravityUsage]
            .filter { $0 }
            .count
        if fetchCount >= 2 {
            refreshState.refreshingProvider = nil
        } else if shouldFetchAntigravityUsage {
            refreshState.refreshingProvider = .antigravity
        } else if shouldFetchCursorUsage {
            refreshState.refreshingProvider = .cursor
        } else {
            refreshState.refreshingProvider = .codex
        }
        refreshState.isRefreshing = true
        refreshState.canRefresh = false
        resetCodexReloginState()
        resetCursorReloginState()
        resetAntigravityReloginState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.refreshState.canRefresh = true
        }

        fetchUsage()
    }

    private func processCodexSuccess(_ data: CodexUsageData) {
        let previousData = codexUsageData
        codexUsageData = data
        errorMessage = nil

        publishSmartMonitoringUtilizations()

        if settings.notificationsEnabled {
            NotificationManager.shared.checkAndNotify(codexUsageData: data, previousData: previousData)
        }

        let newCodexResetsAt = data.primary?.resetsAt
        if hasResetTimeChanged(from: lastCodexResetsAt, to: newCodexResetsAt) {
            cancelCodexResetVerification()
        } else if let resetsAt = newCodexResetsAt {
            scheduleCodexResetVerification(resetsAt: resetsAt)
        }
        lastCodexResetsAt = newCodexResetsAt

        pushBluetoothSync()
    }

    private func attemptTokenRefreshAndRetry() {
        guard !codexNeedsRelogin else {
            markCodexNeedsRelogin()
            return
        }

        if CodexAPIService.isOAuthRefreshToken(settings.codexSessionToken) {
            markCodexNeedsRelogin()
            return
        }

        Logger.menuBar.info("Codex accessToken 已过期，启动刷新链")
        attemptLevel1SSRRefresh()
    }

    private func attemptLevel1SSRRefresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            CodexTokenRefreshCoordinator.shared.refresh { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let freshAccessToken):
                    self.retryCodexWithAccessToken(freshAccessToken)
                case .failure:
                    self.attemptLevel2WebViewRefresh()
                }
            }
        }
    }

    private func attemptLevel2WebViewRefresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            CodexSilentRefreshCoordinator.shared.refresh { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.fetchUsage()
                case .failure:
                    self.markCodexNeedsRelogin()
                }
            }
        }
    }

    private func retryCodexWithAccessToken(_ accessToken: String) {
        isLoading = true
        codexApiService.fetchUsageWithAccessToken(accessToken) { [weak self] usageResult in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch usageResult {
                case .success(let data):
                    self.processCodexSuccess(data)
                case .failure:
                    self.attemptLevel2WebViewRefresh()
                }
            }
        }
    }

    private func resetCodexReloginState() {
        codexNeedsRelogin = false
        codexSessionExpiredNotified = false
    }

    private func markCodexNeedsRelogin() {
        codexNeedsRelogin = true
        if !codexSessionExpiredNotified {
            codexSessionExpiredNotified = true
            if settings.notificationsEnabled {
                NotificationManager.shared.sendCodexSessionExpiredNotification()
            }
        }
        errorMessage = UsageError.sessionExpired.localizedDescription
        clearCodexUsageState(clearError: false)
    }

    func handleAccountChanged(provider: ProviderType?) {
        if provider == nil || provider == .codex {
            resetCodexReloginState()
            codexApiService.clearAccessTokenCache()
            clearCodexUsageState()
        }
        if provider == nil || provider == .cursor {
            resetCursorReloginState()
            clearCursorUsageState()
        }
        if provider == nil || provider == .antigravity {
            resetAntigravityReloginState()
            AntigravityAPIService.invalidateCredentialsCache()
            clearAntigravityUsageState()
        }
        NotificationManager.shared.resetAllNotificationStates()
        if shouldFetchCodexUsage || shouldFetchCursorUsage || shouldFetchAntigravityUsage {
            fetchUsage()
        }
    }

    private func endRefreshAnimationWithMinimumDuration(completion: @escaping () -> Void) {
        guard let startTime = refreshAnimationStartTime else {
            refreshState.isRefreshing = false
            refreshState.refreshingProvider = nil
            completion()
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let remaining = minimumAnimationDuration - elapsed

        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.refreshState.isRefreshing = false
                self?.refreshState.refreshingProvider = nil
                completion()
            }
        } else {
            refreshState.isRefreshing = false
            refreshState.refreshingProvider = nil
            completion()
        }

        refreshAnimationStartTime = nil
    }

    private func hasResetTimeChanged(from oldTime: Date?, to newTime: Date?) -> Bool {
        if oldTime == nil && newTime == nil { return false }
        if (oldTime == nil) != (newTime == nil) { return true }
        if let oldTime, let newTime {
            return abs(oldTime.timeIntervalSince(newTime)) > 1.0
        }
        return false
    }

    private func cancelCodexResetVerification() {
        timerManager.invalidate(TimerID.codexResetVerify1)
        timerManager.invalidate(TimerID.codexResetVerify2)
        timerManager.invalidate(TimerID.codexResetVerify3)
    }

    private func scheduleCodexResetVerification(resetsAt: Date) {
        cancelCodexResetVerification()
        let timeUntilReset = resetsAt.timeIntervalSinceNow
        guard timeUntilReset > 0 else { return }

        timerManager.schedule(TimerID.codexResetVerify1, interval: timeUntilReset + 1, repeats: false) { [weak self] in
            self?.fetchUsage()
        }
        timerManager.schedule(TimerID.codexResetVerify2, interval: timeUntilReset + 10, repeats: false) { [weak self] in
            self?.fetchUsage()
        }
        timerManager.schedule(TimerID.codexResetVerify3, interval: timeUntilReset + 30, repeats: false) { [weak self] in
            self?.fetchUsage()
        }
    }

    func cleanup() {
        timerManager.invalidateAll()
        endRefreshActivity()
        antigravityApiService.cancelAllRequests()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    deinit {
        cleanup()
    }
}
