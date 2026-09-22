//
//  GeneralSettingsView.swift
//  Agent Ring
//

import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @ObservedObject private var updateManager = AppUpdateManager.shared
    @ObservedObject private var bleService = BLESyncService.shared
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        SettingsPaneScroll {
            VStack(spacing: 16) {
                usageDisplayCard
                refreshCard
                notificationCard
                bluetoothCard
                launchCard
                updateCard
                resetCard
            }
        }
        .onAppear {
            settings.syncLaunchAtLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launchAtLoginError)) { notification in
            handleLaunchError(notification)
        }
        .alert(L.LaunchAtLogin.errorTitle, isPresented: $showErrorAlert) {
            Button(L.Update.okButton, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var usageDisplayCard: some View {
        SettingCard(
            icon: "chart.bar.xaxis",
            iconColor: .secondary,
            title: L.SettingsGeneral.usageDisplaySection,
            hint: settings.showRemainingMode ? L.SettingsGeneral.usageDisplayRemainingHint : L.SettingsGeneral.usageDisplayUsedHint
        ) {
            radioGroup(
                selection: $settings.usageDisplayValueMode,
                values: UsageDisplayValueMode.allCases
            ) { $0.localizedName }
        }
    }

    private var refreshCard: some View {
        SettingCard(
            icon: "clock.arrow.trianglehead.2.counterclockwise.rotate.90",
            iconColor: .secondary,
            title: L.SettingsGeneral.refreshSection,
            hint: settings.refreshMode == .smart ? L.SettingsGeneral.refreshHintSmart : L.SettingsGeneral.refreshHintFixed
        ) {
            VStack(alignment: .leading, spacing: 12) {
                radioGroup(selection: $settings.refreshMode, values: RefreshMode.allCases) { $0.localizedName }

                if settings.refreshMode == .fixed {
                    HStack {
                        Text(L.SettingsGeneral.refreshInterval)
                            .foregroundColor(.secondary)

                        Picker("", selection: $settings.refreshInterval) {
                            ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                                Text(interval.localizedName).tag(interval.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }

    private var notificationCard: some View {
        SettingCard(
            icon: "bell.badge",
            iconColor: .secondary,
            title: L.SettingsNotification.section,
            hint: L.SettingsNotification.hint
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.notificationsEnabled) {
                    Text(L.SettingsNotification.enable)
                }
                .toggleStyle(.checkbox)
                .focusable(false)

                Text(L.SettingsNotification.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }

    private var bluetoothCard: some View {
        SettingCard(
            icon: "antenna.radiowaves.left.and.right",
            iconColor: .secondary,
            title: L.SettingsBluetooth.section,
            hint: L.SettingsBluetooth.hint
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $settings.bluetoothSyncEnabled) {
                    Text(L.SettingsBluetooth.enable)
                }
                .toggleStyle(.checkbox)
                .focusable(false)

                Text(L.SettingsBluetooth.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)

                if settings.bluetoothSyncEnabled {
                    Divider()
                        .padding(.vertical, 2)
                        .padding(.leading, 20)

                    HStack(spacing: 8) {
                        Text("目标副屏:")
                            .font(.callout)

                        Picker("", selection: $settings.targetBLEDeviceName) {
                            Text("自动连接 (推荐)").tag("")

                            ForEach(bleService.discoveredDevices) { device in
                                Text("\(device.name) (\(device.rssi) dBm)\(device.isConnected ? " [已连接]" : "")")
                                    .tag(device.name)
                            }

                            if !settings.targetBLEDeviceName.isEmpty &&
                               !bleService.discoveredDevices.contains(where: { $0.name == settings.targetBLEDeviceName }) {
                                Text("\(settings.targetBLEDeviceName) (未发现)").tag(settings.targetBLEDeviceName)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)

                        if bleService.isScanning {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Button {
                                bleService.rescan()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("刷新附近设备")
                        }
                    }
                    .padding(.leading, 20)

                    if let connected = bleService.connectedDeviceName {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                            Text("当前连接: \(connected)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 20)
                    }
                }
            }
        }
    }

    private var launchCard: some View {
        SettingCard(
            icon: "power",
            iconColor: .secondary,
            title: L.SettingsGeneral.launchSection,
            hint: statusText
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $settings.launchAtLogin) {
                    Text(L.SettingsGeneral.launchAtLogin)
                }
                .toggleStyle(.checkbox)
                .focusable(false)

                HStack(spacing: 6) {
                    Circle()
                        .fill(launchStatusColor)
                        .frame(width: 8, height: 8)

                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 20)
            }
        }
    }

    private var updateCard: some View {
        SettingCard(
            icon: "arrow.triangle.2.circlepath.circle",
            iconColor: .secondary,
            title: L.SettingsUpdate.sectionTitle,
            hint: L.SettingsUpdate.hint
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $settings.autoUpdateEnabled) {
                    Text(L.SettingsUpdate.autoUpdate)
                }
                .toggleStyle(.checkbox)
                .focusable(false)

                Text(L.SettingsUpdate.autoUpdateHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)

                HStack(spacing: 12) {
                    Button(action: {
                        updateManager.checkForUpdates(isUserInitiated: true)
                    }) {
                        if updateManager.isChecking {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 14, height: 14)
                                Text(L.SettingsUpdate.checking)
                            }
                        } else {
                            Text(L.SettingsUpdate.checkNow)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(updateManager.isChecking || updateManager.isDownloading)

                    if let message = updateManager.lastCheckMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let lastTime = updateManager.lastCheckTime {
                        Text(L.SettingsUpdate.lastChecked(TimeFormatHelper.formatTimeOnly(lastTime)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)

                if updateManager.isDownloading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                        Text(L.SettingsUpdate.downloading)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var resetCard: some View {
        SettingCard(
            icon: "arrow.counterclockwise",
            iconColor: .secondary,
            title: L.SettingsGeneral.resetSection,
            hint: L.SettingsGeneral.resetHint
        ) {
            Button(L.SettingsGeneral.resetButton) {
                settings.resetToDefaults()
            }
            .buttonStyle(.bordered)
        }
    }

    private var launchStatusColor: Color {
        switch settings.launchAtLoginStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered: return .secondary
        case .notFound: return .red
        @unknown default: return .secondary
        }
    }

    private var statusText: String {
        switch settings.launchAtLoginStatus {
        case .enabled: return L.LaunchAtLogin.statusEnabled
        case .requiresApproval: return L.LaunchAtLogin.statusRequiresApproval
        case .notRegistered: return L.LaunchAtLogin.statusDisabled
        case .notFound: return L.LaunchAtLogin.statusNotFound
        @unknown default: return L.LaunchAtLogin.statusDisabled
        }
    }

    private func handleLaunchError(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let error = userInfo["error"] as? Error,
              let operation = userInfo["operation"] as? String else {
            return
        }

        let operationType = operation == "enable" ? L.LaunchAtLogin.errorEnable : L.LaunchAtLogin.errorDisable
        errorMessage = "\(operationType)\n\n\(error.localizedDescription)"
        showErrorAlert = true
    }

    private func radioGroup<T: Hashable, S: Sequence>(
        selection: Binding<T>,
        values: S,
        title: @escaping (T) -> String
    ) -> some View where S.Element == T {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(values), id: \.self) { value in
                Button {
                    selection.wrappedValue = value
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selection.wrappedValue == value ? "circle.inset.filled" : "circle")
                            .font(.body)
                            .foregroundColor(selection.wrappedValue == value ? .accentColor : .secondary)
                            .frame(width: 16)
                        Text(title(value))
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
    }

}
