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
    @State private var justPushed = false

    var body: some View {
        SettingsPaneScroll {
            VStack(spacing: 16) {
                companionSyncCard
                hardwareSupportCard
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

                    // 连接状态指示与即时推流
                    HStack(spacing: 8) {
                        Circle()
                            .fill(bleService.connectedDeviceName != nil ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)

                        if let connected = bleService.connectedDeviceName {
                            Text("当前连接: \(connected)")
                                .font(.callout)
                                .foregroundColor(.primary)
                        } else {
                            Text("未连接副屏 (就绪搜索中)")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if bleService.connectedDeviceName != nil {
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

    // MARK: - 支持硬件与协议说明

    private var hardwareSupportCard: some View {
        SettingCard(
            icon: "display.2",
            iconColor: .secondary,
            title: "副屏支持与通信协议",
            hint: "副屏通过本地低功耗蓝牙 (BLE GATT) 串口直接接收推流数据，免配对、低功耗。"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cpu")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ESP32-P4 / ESP32-S3 LCD 彩屏副屏")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("支持 7 寸 (1024×600) / 4.3 寸等电容触摸屏，硬件 LVGL 渲染三色模型环、实时时钟及背光快捷控制。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .foregroundColor(.green)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Android 桌面悬浮副屏")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("支持闲置 Android 手机、墨水屏电子书作为桌面专属监控副屏。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundColor(.orange)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("传输协议与保活")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("采用 Nordic UART (NUS) 串口协议，15 秒静默 Ping 保活对时，单行紧凑 JSON 报文传输。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 开源副屏固件仓库

    private var openSourceCard: some View {
        SettingCard(
            icon: "chevron.left.forwardslash.chevron.right",
            iconColor: .secondary,
            title: "开源副屏固件与源码",
            hint: "所有副屏客户端代码均已在 GitHub 完全开源，支持自行克隆、编译与二次定制。"
        ) {
            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "https://github.com/haorui-lab/agentRing-ESP32-LCD") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text("ESP32 LCD 固件源码 (GitHub)")
                    }
                }
                .buttonStyle(.bordered)

                Button {
                    if let url = URL(string: "https://github.com/haorui-lab/agentRing-Android") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text("Android 副屏客户端 (GitHub)")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
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
