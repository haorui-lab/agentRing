//
//  BluetoothSettingsView.swift
//  Agent Ring
//
//  独立蓝牙副屏设置页面
//

import SwiftUI
import AppKit

struct BluetoothSettingsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @ObservedObject private var bleService = BLESyncService.shared
    @ObservedObject private var classicService = BluetoothSyncService.shared
    @State private var justPushed = false

    var body: some View {
        SettingsPaneScroll {
            VStack(spacing: 16) {
                companionSyncCard
                openSourceCard
            }
        }
    }

    // MARK: - 主同步控制卡片

    private var companionSyncCard: some View {
        SettingCard(
            icon: "antenna.radiowaves.left.and.right",
            iconColor: .accentColor,
            title: L.SettingsBluetooth.section,
            hint: L.SettingsBluetooth.hint
        ) {
            VStack(alignment: .leading, spacing: 12) {
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

                    // 目标设备选择器
                    HStack(spacing: 8) {
                        Text("目标副屏:")
                            .font(.callout)

                        Picker("", selection: $settings.targetBLEDeviceName) {
                            Text("自动连接最近设备 (默认)").tag("")

                            ForEach(bleService.discoveredDevices) { device in
                                Text("\(device.name) (\(device.rssi) dBm)\(deviceTag(device.name))")
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

                    // 连接状态指示与即时推流（经典 + BLE 两路分别展示）
                    HStack(spacing: 8) {
                        Circle()
                            .fill(hasAnyConnection ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)

                        if hasAnyConnection {
                            ForEach(classicConnectionLines, id: \.self) { line in
                                Text(line)
                                    .font(.callout)
                                    .foregroundColor(.primary)
                            }
                            if let bleName = bleService.connectedDeviceName {
                                Text("BLE: \(bleName)")
                                    .font(.callout)
                                    .foregroundColor(.primary)
                            }
                        } else {
                            Text("未连接副屏 (就绪搜索中)")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if hasAnyConnection {
                            Button {
                                manualPushData()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: justPushed ? "checkmark" : "arrow.up.circle")
                                    Text(justPushed ? "已推送" : "立即推流")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(justPushed)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }

    // MARK: - 开源副屏项目

    private var openSourceCard: some View {
        SettingCard(
            icon: "display.2",
            iconColor: .secondary,
            title: "开源副屏项目",
            hint: "支持使用闲置的 Android 手机、平板，或 ESP32 硬件屏幕作为桌面副屏。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("配套的副屏客户端与固件均已开源，可按需下载安装或自行编译：")
                    .font(.callout)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    // Android 副屏（排在前面）
                    Link(destination: URL(string: "https://github.com/davidhoo/agentRing-Android")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                                .font(.system(size: 13))
                                .foregroundColor(.accentColor)

                            Text("Android 副屏客户端")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        )
                    }
                    .buttonStyle(.plain)

                    // ESP32 LCD 硬件副屏
                    Link(destination: URL(string: "https://github.com/haorui-lab/agentRing-ESP32-LCD")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                                .font(.system(size: 13))
                                .foregroundColor(.accentColor)

                            Text("ESP32 LCD 硬件副屏")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 连接状态汇总

    /// 设备在 Picker 里的通道/状态标注：经典已连 > BLE 已连 > 无标注
    private func deviceTag(_ name: String) -> String {
        if classicService.connectedClassicDeviceNames.contains(name) {
            return " [经典·已连接]"
        }
        if bleService.connectedDeviceName == name {
            return " [BLE·已连接]"
        }
        return ""
    }

    /// 经典已连接副屏的状态行（如 "经典: AgentRing-vivoX21A"）
    private var classicConnectionLines: [String] {
        classicService.connectedClassicDeviceNames.map { "经典: \($0)" }
    }

    /// 任一通道（经典或 BLE）有已连接副屏
    private var hasAnyConnection: Bool {
        !classicService.connectedClassicDeviceNames.isEmpty || bleService.connectedDeviceName != nil
    }

    // MARK: - 手动推流方法

    private func manualPushData() {
        guard let dataManager = (NSApp.delegate as? AppDelegate)?.menuBarManager?.dataManagerForBluetooth else {
            return
        }
        bleService.pushPayload(
            codexUsageData: dataManager.codexData,
            cursorUsageData: dataManager.cursorData,
            antigravityUsageData: dataManager.antigravityData
        )
        justPushed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            justPushed = false
        }
    }
}
