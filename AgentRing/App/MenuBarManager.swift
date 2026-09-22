//
//  MenuBarManager.swift
//  Agent Ring
//

import SwiftUI
import AppKit
import Combine
import OSLog

final class RefreshState: ObservableObject {
    @Published var isRefreshing = false
    @Published var refreshingProvider: ProviderType?
    @Published var canRefresh = true
    @Published var notificationMessage: String?
    @Published var notificationType: NotificationType = .loading

    enum NotificationType {
        case loading
        case updateAvailable
    }

    func isRefreshingProvider(_ provider: ProviderType) -> Bool {
        if provider == .antigravityThird {
            return isRefreshing && (refreshingProvider == nil || refreshingProvider == .antigravity || refreshingProvider == .antigravityThird)
        }
        return isRefreshing && (refreshingProvider == nil || refreshingProvider == provider)
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: 760, height: max(560, frameSize.height))
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        var targetFrame = newFrame
        targetFrame.size.width = 760
        targetFrame.origin.x = window.frame.origin.x
        window.setFrame(targetFrame, display: true, animate: true)
        return false
    }
}

final class MenuBarManager: ObservableObject {
    private let ui = MenuBarUI()
    private let dataManager = DataRefreshManager()
    private var settingsWindow: NSWindow?
    private let settingsWindowDelegate = SettingsWindowDelegate()
    @ObservedObject private var settings = UserSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var windowCloseObserver: NSObjectProtocol?
    private var languageChangeObserver: NSObjectProtocol?

    @Published var codexUsageData: CodexUsageData?
    @Published var cursorUsageData: CursorUsageData?
    @Published var antigravityUsageData: AntigravityUsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var codexNeedsRelogin = false
    @Published var cursorNeedsRelogin = false
    @Published var antigravityNeedsRelogin = false
    @Published var hasAvailableUpdate = false
    @Published var latestVersion: String?
    private var acknowledgedVersion: String?

    var refreshState: RefreshState {
        dataManager.refreshState
    }

    /// 蓝牙副屏：读取当前各 provider 数据（开关开启时立即推送用）
    var dataManagerForBluetooth: (codexData: CodexUsageData?, cursorData: CursorUsageData?, antigravityData: AntigravityUsageData?) {
        (codexUsageData, cursorUsageData, antigravityUsageData)
    }

    var shouldShowUpdateBadge: Bool {
        let releaseVersion = AppUpdateManager.shared.availableVersion ?? latestVersion
        guard hasAvailableUpdate || AppUpdateManager.shared.availableVersion != nil,
              let version = releaseVersion else { return false }
        return acknowledgedVersion != version
    }

    init() {
        ui.configureClickHandler(target: self, action: #selector(handleClick))
        setupDataBindings()
        setupSettingsObservers()
    }

    private func setupDataBindings() {
        dataManager.$codexUsageData
            .sink { [weak self] data in
                self?.codexUsageData = data
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        dataManager.$cursorUsageData
            .sink { [weak self] data in
                self?.cursorUsageData = data
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        dataManager.$antigravityUsageData
            .sink { [weak self] data in
                self?.antigravityUsageData = data
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        dataManager.$isLoading.assign(to: &$isLoading)
        dataManager.$errorMessage.assign(to: &$errorMessage)
        dataManager.$codexNeedsRelogin.assign(to: &$codexNeedsRelogin)
        dataManager.$cursorNeedsRelogin.assign(to: &$cursorNeedsRelogin)
        dataManager.$antigravityNeedsRelogin.assign(to: &$antigravityNeedsRelogin)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = ui.createStandardMenu(hasUpdate: hasAvailableUpdate, shouldShowBadge: shouldShowUpdateBadge, target: self)
        ui.statusItem.menu = menu
        ui.statusItem.button?.performClick(nil)
        ui.statusItem.menu = nil
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    fileprivate func handleMenuAction(_ action: UsageDetailView.MenuAction) {
        switch action {
        case .refresh:
            dataManager.handleManualRefresh()
        case .generalSettings:
            closePopover()
            openSettingsWindow(tab: 0)
        case .authSettings:
            closePopover()
            openSettingsWindow(tab: 1)
        case .checkForUpdates:
            closePopover()
            checkForUpdates()
        case .about:
            closePopover()
            openSettingsWindow(tab: 3)
        case .codexRelogin:
            closePopover()
            WebLoginWindowManager.shared.showCodexLoginWindow()
        case .cursorRelogin:
            closePopover()
            WebLoginWindowManager.shared.showCursorLoginWindow()
        case .antigravityRelogin:
            closePopover()
            openAuthSettings()
        case .quit:
            quitApp()
        }
    }

    private func setupSettingsObservers() {
        NotificationCenter.default.publisher(for: .settingsChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                self.ui.clearIconCache()
                self.updateMenuBarIcon()

                #if DEBUG
                self.dataManager.fetchUsage()
                if self.settings.simulateUpdateAvailable {
                    self.hasAvailableUpdate = true
                    self.latestVersion = "2.0.0"
                } else {
                    self.hasAvailableUpdate = false
                    self.latestVersion = nil
                }
                self.updateMenuBarIcon()
                #endif
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .refreshIntervalChanged)
            .sink { [weak self] _ in
                self?.dataManager.stopRefreshing()
                self?.dataManager.startRefreshing()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openSettings)
            .sink { [weak self] notification in
                let tab = notification.userInfo?["tab"] as? Int ?? 0
                self?.openSettingsWindow(tab: tab)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .accountChanged)
            .sink { [weak self] notification in
                guard let self else { return }
                let providerRaw = notification.userInfo?[Notification.UserInfoKey.provider] as? String
                let provider = providerRaw.flatMap { ProviderType(rawValue: $0) }
                self.ui.clearIconCache()
                self.dataManager.handleAccountChanged(provider: provider)
                self.updateMenuBarIcon()
            }
            .store(in: &cancellables)
    }

    @objc func togglePopover() {
        guard let button = ui.statusItem.button else { return }
        ui.popover.isShown ? closePopover() : openPopover(relativeTo: button)
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        dataManager.refreshOnPopoverOpen()
        ui.setPopoverContentSize(usageDetailContentSize())

        ui.setPopoverContent(UsageDetailHost(manager: self))

        ui.openPopover(relativeTo: button)
        startPopoverRefreshTimer()
    }

    private func usageDetailContentSize() -> NSSize {
        let activeProviders = settings.orderedActiveProviders(
            codexUsageData: codexUsageData,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )
        let activeProvidersCount = activeProviders.count
        let showsMultiple = activeProvidersCount > 1
        let baseHeight: CGFloat = showsMultiple ? 222 : 190
        let rowHeight: CGFloat = 26
        let spacing: CGFloat = 5

        let width: CGFloat = {
            switch activeProvidersCount {
            case 4...: return 1020
            case 3: return 860
            case 2: return 580
            default: return 320
            }
        }()
        let maxRowsPerProvider = [
            settings.getActiveCodexDisplayTypes(codexUsageData: codexUsageData).count,
            settings.getActiveCursorDisplayTypes(cursorUsageData: cursorUsageData).count,
            settings.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravity).count,
            settings.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravityThird).count
        ].max() ?? 0
        let hasAnyData = codexUsageData != nil || cursorUsageData != nil || antigravityUsageData != nil
        let rowCount = max(maxRowsPerProvider, hasAnyData || activeProvidersCount > 0 ? 1 : 0)
        let rowsHeight = CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * spacing
        return NSSize(width: width, height: baseHeight + rowsHeight)
    }

    private func closePopover() {
        ui.closePopover()
        dataManager.stopPopoverRefreshTimer()
    }

    private func updatePopoverContent() {
        objectWillChange.send()
    }

    private func startPopoverRefreshTimer() {
        dataManager.startPopoverRefreshTimer { [weak self] in
            self?.updatePopoverContent()
        }
    }

    func startRefreshing() {
        dataManager.startRefreshing()
    }

    @objc func openSettings() { openSettingsWindow(tab: 0) }
    @objc func openGeneralSettings() { openSettingsWindow(tab: 0) }
    @objc func openAuthSettings() { openSettingsWindow(tab: 1) }
    @objc func openBluetoothSettings() { openSettingsWindow(tab: 2) }
    @objc func openAbout() { openSettingsWindow(tab: 3) }

    @objc func switchCodexAccount(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        settings.switchToCodexAccount(account)
    }

    @objc func switchCursorAccount(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        settings.switchToCursorAccount(account)
    }

    @objc func checkForUpdates() {
        let versionToAcknowledge = AppUpdateManager.shared.availableVersion ?? latestVersion
        if let versionToAcknowledge {
            acknowledgedVersion = versionToAcknowledge
            objectWillChange.send()
            updateMenuBarIcon()
        }

        AppUpdateManager.shared.checkForUpdates(isUserInitiated: true)
    }

    func applyUpdateAvailable(version: String?) {
        hasAvailableUpdate = true
        latestVersion = version
        updateMenuBarIcon()
    }

    func applyUpdateNotFound() {
        hasAvailableUpdate = false
        latestVersion = nil
        updateMenuBarIcon()
    }

    private func openSettingsWindow(tab: Int) {
        if settingsWindow == nil {
            NSApp.setActivationPolicy(.regular)
            let hostingController = NSHostingController(rootView: SettingsView(initialTab: tab))
            hostingController.sizingOptions = []

            settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow?.title = L.Window.settingsTitle
            settingsWindow?.delegate = settingsWindowDelegate
            settingsWindow?.collectionBehavior = [.fullScreenNone]
            // 宽度严格锁定 760（对齐 macOS 系统设置，禁止任何方式调整宽度）；高度仍可按需微调
            settingsWindow?.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            settingsWindow?.minSize = NSSize(width: 760, height: 560)
            settingsWindow?.maxSize = NSSize(width: 760, height: 1200)
            settingsWindow?.setContentSize(NSSize(width: 760, height: 640))
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame AgentRing.SettingsWindow.v4")
            settingsWindow?.center()

            if let windowCloseObserver {
                NotificationCenter.default.removeObserver(windowCloseObserver)
            }

            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: settingsWindow,
                queue: .main
            ) { [weak self] _ in
                NSApp.setActivationPolicy(.accessory)
                self?.settingsWindow = nil
                if self?.settings.hasAnyValidCredentials == true && self?.codexUsageData == nil && self?.cursorUsageData == nil {
                    self?.startRefreshing()
                }
            }

            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: settingsWindow,
                queue: .main
            ) { [weak self] _ in
                #if DEBUG
                if UserSettings.shared.debugKeepDetailWindowOpen { return }
                #endif
                if self?.ui.popover.isShown == true {
                    self?.closePopover()
                }
            }

            if let languageChangeObserver {
                NotificationCenter.default.removeObserver(languageChangeObserver)
            }
            languageChangeObserver = NotificationCenter.default.addObserver(
                forName: .languageChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.settingsWindow?.title = L.Window.settingsTitle
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.settingsWindow?.center()
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
        }

        if ui.popover.isShown {
            closePopover()
        }
    }

    private func updateMenuBarIcon() {
        ui.updateMenuBarIcon(
            codexUsageData: codexUsageData,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData,
            hasUpdate: hasAvailableUpdate,
            shouldShowBadge: shouldShowUpdateBadge
        )
    }

    func cleanup() {
        dataManager.stopPopoverRefreshTimer()
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        if let languageChangeObserver {
            NotificationCenter.default.removeObserver(languageChangeObserver)
            self.languageChangeObserver = nil
        }
        cancellables.removeAll()
        ui.cleanup()
        dataManager.cleanup()
        settingsWindow?.close()
        settingsWindow = nil
    }

    deinit {
        cleanup()
    }
}

/// Hosts the popover so SwiftUI actually observes MenuBarManager publishes.
/// Manual `Binding(get: { self.x })` does not subscribe, so rings stayed at the first paint.
private struct UsageDetailHost: View {
    @ObservedObject var manager: MenuBarManager

    var body: some View {
        UsageDetailView(
            codexUsageData: $manager.codexUsageData,
            cursorUsageData: $manager.cursorUsageData,
            antigravityUsageData: $manager.antigravityUsageData,
            errorMessage: $manager.errorMessage,
            codexNeedsRelogin: Binding(get: { manager.codexNeedsRelogin }, set: { _ in }),
            cursorNeedsRelogin: Binding(get: { manager.cursorNeedsRelogin }, set: { _ in }),
            antigravityNeedsRelogin: Binding(get: { manager.antigravityNeedsRelogin }, set: { _ in }),
            refreshState: manager.refreshState,
            onMenuAction: { action in manager.handleMenuAction(action) },
            hasAvailableUpdate: $manager.hasAvailableUpdate,
            shouldShowUpdateBadge: Binding(get: { manager.shouldShowUpdateBadge }, set: { _ in })
        )
    }
}
