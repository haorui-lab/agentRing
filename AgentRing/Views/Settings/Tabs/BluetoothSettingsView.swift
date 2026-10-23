//
//  BluetoothSettingsView.swift
//  Agent Ring
//
//  独立蓝牙副屏设置页面
//

import SwiftUI
import AppKit
import OSLog

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

                    HStack {
                        Text("副屏设备").font(.callout)
                        Spacer()
                        if bleService.isScanning { ProgressView().controlSize(.small) }
                        Button("扫描设备") { bleService.rescan() }
                            .disabled(bleService.isScanning)
                    }
                    .padding(.leading, 20)

                    Text("首次连接：LCD「连接管理」→「开始配对」会立即显示六位码。再点本机的「连接并配对」，在 macOS 系统配对框输入此码。")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.leading, 20)

                    ForEach(visibleBLEDevices) { device in
                        deviceRow(name: device.name, bleDevice: device)
                    }
                    ForEach(classicOnlyConnections, id: \.self) { name in
                        deviceRow(name: name, bleDevice: nil)
                    }
                    if visibleBLEDevices.isEmpty && classicOnlyConnections.isEmpty {
                        Text("尚未发现副屏，请确认设备已开机。")
                            .font(.caption).foregroundColor(.secondary).padding(.leading, 20)
                    }
                    Text("「忘记」仅停止此应用自动重连。换绑 Mac 请在 LCD 解除绑定；如系统保留旧配对，请在 macOS 蓝牙设置忽略该设备。")
                        .font(.caption).foregroundColor(.secondary).padding(.leading, 20)

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

    private func deviceRow(name: String, bleDevice: BLEDiscoveredDevice?) -> some View {
        let state = BluetoothDeviceConnectionState.resolve(
            classicConnected: BLEConnectionPolicy.usesClassicConnection(name: name, connectedNames: Set(classicService.connectedClassicDeviceNames)),
            bleConnected: bleDevice?.isConnected == true,
            connecting: bleDevice.map { bleService.connectingDeviceIDs.contains($0.id) } ?? false)
        let selected = bleDevice.map { bleService.selectedDevices[$0.id] != nil } ?? false
        let diagnostic = bleDevice.flatMap { bleService.deviceMessages[$0.id] }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout)
                    if state == .classicConnected {
                        Text("经典蓝牙 · SPP").font(.caption).foregroundColor(.secondary)
                    } else if let device = bleDevice {
                        Text("BLE · ID: \(device.id.uuidString.prefix(8)) · \(device.rssi == 0 ? (device.isConnected ? "信号未知" : "未发现") : "\(device.rssi) dBm")")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if state == .classicConnected || state == .bleConnected {
                    Button("已连接") {}.disabled(true)
                } else if state == .connecting {
                    ProgressView().controlSize(.small)
                    Button("连接中…") {}.disabled(true)
                } else if state.canConnectBLE, let device = bleDevice {
                    Button(selected ? "重连" : (BLEConnectionPolicy.requiresBinding(name: name) ? "连接并配对" : "连接")) {
                        bleService.connectDevice(device.id)
                    }
                }
                if let device = bleDevice, selected || state == .bleConnected {
                    Button(state == .classicConnected ? "忘记 BLE" : "忘记") { bleService.forgetDevice(device.id) }
                }
            }
            if let message = state.statusMessage(diagnostic: diagnostic) {
                Text(message).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.leading, 20)
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

    private var visibleBLEDevices: [BLEDiscoveredDevice] {
        var devices = bleService.discoveredDevices
        for (id, name) in bleService.selectedDevices where !devices.contains(where: { $0.id == id }) {
            devices.append(BLEDiscoveredDevice(id: id, name: name, rssi: 0, isConnected: false))
        }
        return devices.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
    }

    private var classicOnlyConnections: [String] {
        classicService.connectedClassicDeviceNames.filter { name in
            !visibleBLEDevices.contains { BLEConnectionPolicy.usesClassicConnection(name: $0.name, connectedNames: [name]) }
        }
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
        guard let dataManager = AppDelegate.shared?.menuBarManager?.dataManagerForBluetooth else {
            return
        }
        classicService.pushPayload(
            codexUsageData: dataManager.codexData,
            cursorUsageData: dataManager.cursorData,
            antigravityUsageData: dataManager.antigravityData
        )
        bleService.pushPayload(
            codexUsageData: dataManager.codexData,
            cursorUsageData: dataManager.cursorData,
            antigravityUsageData: dataManager.antigravityData
        )
        Logger.bluetooth.info("手动向经典蓝牙与 BLE 副屏推送当前用量")
        justPushed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            justPushed = false
        }
    }
}
