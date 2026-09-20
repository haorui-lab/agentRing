//
//  BLESyncService.swift
//  Agent Ring
//
//  蓝牙 BLE (Bluetooth Low Energy) GATT 副屏同步服务
//  支持 ESP32-P4、ESP32-S3、ESP32-C6、ESP32-C3 等仅支持 BLE 的现代硬件副屏
//  - 使用 CoreBluetooth 扫描外设名称前缀 "AgentRing"
//  - 自动连接、协商 MTU 并发现 UART / AgentRing GATT 串口服务
//  - 分包推送单行 JSON + '\n'
//  - 15 秒周期发送轻量 ping 保活
//

import Foundation
import CoreBluetooth
import OSLog
import AppKit

final class BLESyncService: NSObject {
    static let shared = BLESyncService()

    // MARK: - 协议常量与 UUID

    /// 副屏设备名前缀
    private static let deviceNamePrefix = "AgentRing"

    /// 标准 Nordic UART Service UUID 或 AgentRing BLE Service
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// TX / Write Characteristic (Client -> ESP32)
    static let rxCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// RX / Notify Characteristic (ESP32 -> Client)
    static let txCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    // MARK: - 会话模型

    private final class BLESession {
        let identifier: UUID
        let peripheral: CBPeripheral
        var rxCharacteristic: CBCharacteristic?
        var lastWriteTime: TimeInterval = 0

        var isReady: Bool {
            peripheral.state == .connected && rxCharacteristic != nil
        }

        var deviceName: String {
            peripheral.name ?? identifier.uuidString
        }

        init(peripheral: CBPeripheral) {
            self.identifier = peripheral.identifier
            self.peripheral = peripheral
        }
    }

    // MARK: - 状态

    private(set) var isRunning = false
    private var centralManager: CBCentralManager?
    private var sessions: [UUID: BLESession] = [:]
    private var lastPayloadLine: String?
    private var heartbeatTimer: Timer?

    private let queue = DispatchQueue(label: "app.agentring.ble")

    // MARK: - 初始化

    private override init() {
        super.init()
    }

    // MARK: - 控制接口

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            Logger.bluetooth.notice("BLE 蓝牙同步服务启动 (CoreBluetooth)")

            if self.centralManager == nil {
                self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
            } else if self.centralManager?.state == .poweredOn {
                self.startScanning()
            }
            self.scheduleHeartbeatTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.centralManager?.stopScan()
            for session in self.sessions.values {
                self.centralManager?.cancelPeripheralConnection(session.peripheral)
            }
            self.sessions.removeAll()
            DispatchQueue.main.async {
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = nil
            }
            Logger.bluetooth.notice("BLE 蓝牙同步服务停止")
        }
    }

    // MARK: - 数据推送

    func push(line: String) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.lastPayloadLine = line
            for session in self.sessions.values where session.isReady {
                self.write(line: line, to: session)
            }
        }
    }

    @MainActor
    func pushPayload(
        codexUsageData: CodexUsageData?,
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData?
    ) {
        let payload = BluetoothPayloadBuilder.buildPayload(
            codexUsageData: codexUsageData,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )
        let line = payload.encodedLine
        guard !line.isEmpty else { return }
        push(line: line)
    }

    // MARK: - 内部扫描与发送

    private func startScanning() {
        guard centralManager?.state == .poweredOn else { return }
        Logger.bluetooth.info("开始扫描 BLE 副屏设备 (前缀: \(Self.deviceNamePrefix))")
        // 允许扫描包含任意服务或通过广播名过滤
        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func write(line: String, to session: BLESession) {
        guard let char = session.rxCharacteristic else { return }
        let payloadWithNewline = line.hasSuffix("\n") ? line : line + "\n"
        guard let data = payloadWithNewline.data(using: .utf8) else { return }

        // 获取当前外设支持的最大包长 (通常 20 ~ 512 字节)
        let maxChunk = session.peripheral.maximumWriteValueLength(for: .withoutResponse)
        var offset = 0

        while offset < data.count {
            let chunkSize = min(maxChunk, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + chunkSize))
            session.peripheral.writeValue(chunk, for: char, type: .withoutResponse)
            offset += chunkSize
        }

        session.lastWriteTime = Date().timeIntervalSince1970
        Logger.bluetooth.debug("已向 BLE 副屏 [\(session.deviceName)] 发送数据帧 (\(data.count) bytes)")
    }

    private func scheduleHeartbeatTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.queue.async { self?.sendHeartbeat() }
            }
        }
    }

    private func sendHeartbeat() {
        guard isRunning else { return }
        let timestamp = Int(Date().timeIntervalSince1970)
        let ping = "{\"type\":\"ping\",\"timestamp\":\(timestamp)}\n"

        for session in sessions.values where session.isReady {
            let now = Date().timeIntervalSince1970
            if now - session.lastWriteTime >= 15 {
                write(line: ping, to: session)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLESyncService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        queue.async { [weak self] in
            guard let self else { return }
            if central.state == .poweredOn && self.isRunning {
                self.startScanning()
            } else if central.state != .poweredOn {
                Logger.bluetooth.notice("BLE 蓝牙未就绪 (state: \(central.state.rawValue))")
                self.sessions.removeAll()
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.localizedCaseInsensitiveContains(Self.deviceNamePrefix) else { return }

        Logger.bluetooth.notice("发现 AgentRing BLE 副屏设备: \(name) [\(peripheral.identifier.uuidString)]")

        let session = BLESession(peripheral: peripheral)
        sessions[peripheral.identifier] = session
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Logger.bluetooth.notice("已连接 BLE 副屏: \(peripheral.name ?? peripheral.identifier.uuidString)，正在发现服务...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Logger.bluetooth.warning("连接 BLE 副屏失败: \(peripheral.name ?? ""), error: \(String(describing: error))")
        sessions.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Logger.bluetooth.notice("BLE 副屏已断开连接: \(peripheral.name ?? "")")
        sessions.removeValue(forKey: peripheral.identifier)
        if isRunning {
            startScanning()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLESyncService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, error == nil else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics, error == nil else { return }
        guard let session = sessions[peripheral.identifier] else { return }

        for char in characteristics {
            // 支持写入的特征值作为 RX 端口
            if char.properties.contains(.writeWithoutResponse) || char.properties.contains(.write) {
                session.rxCharacteristic = char
                Logger.bluetooth.notice("BLE 副屏 [\(session.deviceName)] 串口就绪，准备推送数据")

                // 发送缓存数据或立即构造最新数据推送
                self.pushInitialPayload(to: session)
                break
            }
        }
    }

    private func pushInitialPayload(to session: BLESession) {
        if let line = lastPayloadLine {
            write(line: line, to: session)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let dataManager = (NSApp.delegate as? AppDelegate)?.menuBarManager?.dataManagerForBluetooth else {
                return
            }
            self?.pushPayload(
                codexUsageData: dataManager.codexData,
                cursorUsageData: dataManager.cursorData,
                antigravityUsageData: dataManager.antigravityData
            )
        }
    }
}
