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
import Combine

public struct BLEDiscoveredDevice: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public var isConnected: Bool

    public init(id: UUID, name: String, rssi: Int, isConnected: Bool) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.isConnected = isConnected
    }
}

final class BLESyncService: NSObject, ObservableObject {
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

    // MARK: - 观察状态

    @Published public private(set) var discoveredDevices: [BLEDiscoveredDevice] = []
    @Published public private(set) var connectedDeviceName: String? = nil
    @Published public private(set) var isScanning = false

    /// 目标设备名称过滤（若为空或 "auto"，则连接任意带 AgentRing 前缀的外设）
    private var targetDeviceName: String = ""

    // MARK: - 会话模型

    private final class BLESession {
        let identifier: UUID
        let peripheral: CBPeripheral
        var rxCharacteristic: CBCharacteristic?
        var lastWriteTime: TimeInterval = 0
        /// 尚未完成特征发现的服务数；收齐后统一判定 GATT 是否可用
        var pendingServiceCount = 0

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
    private var scanTimeoutWorkItem: DispatchWorkItem?

    /// 误连无 GATT 串口设备的冷却黑名单（peripheral UUID → 拉黑时间）
    /// 冷却期内 didDiscover 只更新列表、不自动 connect，防止反复粘死扫描窗口
    private var gattRejectCooldowns: [UUID: TimeInterval] = [:]
    private static let gattRejectCooldown: TimeInterval = 60

    private let queue = DispatchQueue(label: "app.agentring.ble")

    // MARK: - 初始化

    private override init() {
        super.init()
    }

    // MARK: - 控制接口

    func setTargetDeviceName(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.targetDeviceName != trimmed else { return }
            self.targetDeviceName = trimmed
            Logger.bluetooth.info("BLE 目标设备更改为: [\(trimmed.isEmpty ? "自动连接" : trimmed)]")

            // 若指定了目标设备，主动断开当前连接的非目标设备
            // （与 didDiscover 目标过滤一致用模糊匹配，避免子串目标名误断已连上的正确设备）
            if !trimmed.isEmpty {
                for session in self.sessions.values {
                    if !session.deviceName.localizedCaseInsensitiveContains(trimmed) {
                        Logger.bluetooth.notice("断开非目标设备: \(session.deviceName)")
                        self.centralManager?.cancelPeripheralConnection(session.peripheral)
                    }
                }
            }

            if self.isRunning && self.centralManager?.state == .poweredOn {
                self.startScanning()
            }
        }
    }

    func rescan() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.stopScanning()
            DispatchQueue.main.async {
                self.discoveredDevices.removeAll(where: { !$0.isConnected })
            }
            self.startScanning()
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            self.targetDeviceName = UserSettings.shared.targetBLEDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.bluetooth.notice("BLE 蓝牙同步服务启动 (CoreBluetooth), 目标设备: [\(self.targetDeviceName.isEmpty ? "自动连接" : self.targetDeviceName)]")

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
            self.scanTimeoutWorkItem?.cancel()
            self.scanTimeoutWorkItem = nil
            self.centralManager?.stopScan()
            for session in self.sessions.values {
                self.centralManager?.cancelPeripheralConnection(session.peripheral)
            }
            self.sessions.removeAll()
            DispatchQueue.main.async {
                self.isScanning = false
                self.connectedDeviceName = nil
                self.discoveredDevices.removeAll()
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

    private func startScanning(duration: TimeInterval = 6.0) {
        guard centralManager?.state == .poweredOn else { return }
        scanTimeoutWorkItem?.cancel()
        DispatchQueue.main.async { self.isScanning = true }
        Logger.bluetooth.info("开始扫描 BLE 副屏设备 (前缀: \(Self.deviceNamePrefix), 目标: \(self.targetDeviceName.isEmpty ? "全部" : self.targetDeviceName))")
        // 不按 Service UUID 过滤：Android 副屏的 BLE 广播只带本地名称、不含
        // 任何 Service UUID，按 UUID 过滤会导致其永远无法被发现（v0.1.13 回归）。
        // 无关设备由 didDiscover 中的名称前缀守卫过滤。
        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopScanning()
        }
        scanTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func stopScanning() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        centralManager?.stopScan()
        DispatchQueue.main.async {
            self.isScanning = false
        }
        Logger.bluetooth.info("BLE 扫描结束 (共发现 \(self.discoveredDevices.count) 台设备)")
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

        // 若当前未连接任何设备，且不在扫描中，则自动触发后台搜寻
        if sessions.isEmpty && !isScanning && centralManager?.state == .poweredOn {
            startScanning()
            return
        }

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
                self.stopScanning()
                self.sessions.removeAll()
                DispatchQueue.main.async {
                    self.connectedDeviceName = nil
                }
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

        let rssiVal = RSSI.intValue
        let uuid = peripheral.identifier
        let isConnected = (peripheral.state == .connected)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 按照设备广播名去重，防止 Android 等设备因 RPA 地址轮转产生多条同名重复项
            if let idx = self.discoveredDevices.firstIndex(where: { $0.name == name || $0.id == uuid }) {
                self.discoveredDevices[idx] = BLEDiscoveredDevice(id: uuid, name: name, rssi: rssiVal, isConnected: isConnected)
            } else {
                self.discoveredDevices.append(BLEDiscoveredDevice(id: uuid, name: name, rssi: rssiVal, isConnected: isConnected))
                self.discoveredDevices.sort { $0.rssi > $1.rssi }
            }
        }

        // 目标过滤：如果指定了设备名，则只连接名称包含目标的设备
        // （模糊匹配：Android 广播名可能带后缀，如 AgentRing-NX513J 与用户填写的子串）
        if !targetDeviceName.isEmpty {
            guard name.localizedCaseInsensitiveContains(targetDeviceName) else {
                return
            }
        }

        // 冷却黑名单：近期被判定无 GATT 串口的设备不再自动连接，只保留在列表里
        // （显式指定目标名的设备也遵守冷却，避免对无 GATT 设备死磕）
        if let rejectedAt = gattRejectCooldowns[uuid],
           Date().timeIntervalSince1970 - rejectedAt < Self.gattRejectCooldown {
            return
        }
        gattRejectCooldowns.removeValue(forKey: uuid)

        if sessions[uuid] == nil {
            Logger.bluetooth.notice("发现匹配的 AgentRing BLE 副屏设备: \(name) [\(uuid.uuidString), RSSI: \(rssiVal)]")
            let session = BLESession(peripheral: peripheral)
            sessions[uuid] = session
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? peripheral.identifier.uuidString
        Logger.bluetooth.notice("已连接 BLE 设备: \(name)，正在发现服务...")
        // 注意：此时还不能当「已连接副屏」用——GATT 串口未就绪，可能是误连的
        // 无 GATT 设备（如 Android 经典副屏）。等 didDiscoverCharacteristicsFor
        // 找到可写特征后才更新 connectedDeviceName。
        stopScanning()
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? peripheral.identifier.uuidString
        Logger.bluetooth.warning("连接 BLE 副屏失败: \(name), error: \(String(describing: error))")
        sessions.removeValue(forKey: peripheral.identifier)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier || $0.name == name }) {
                self.discoveredDevices[idx].isConnected = false
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? peripheral.identifier.uuidString
        Logger.bluetooth.notice("BLE 副屏已断开连接: \(name)")
        sessions.removeValue(forKey: peripheral.identifier)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.connectedDeviceName == name {
                self.connectedDeviceName = nil
            }
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier || $0.name == name }) {
                self.discoveredDevices[idx].isConnected = false
            }
        }
        if isRunning, sessions.isEmpty {
            startScanning()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLESyncService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let session = sessions[peripheral.identifier] else { return }

        // 服务发现失败：同一条拒绝路径，不能静默挂死
        if error != nil {
            Logger.bluetooth.info("BLE 设备 [\(session.deviceName)] 服务发现失败: \(String(describing: error))，断开并冷却")
            rejectSession(session)
            return
        }

        let services = peripheral.services?.filter { $0.uuid == Self.serviceUUID } ?? []
        guard !services.isEmpty else {
            Logger.bluetooth.info("BLE 设备 [\(session.deviceName)] 无 AgentRing UART 服务，判定为非串口设备，断开并冷却")
            rejectSession(session)
            return
        }

        // 只对 UART 服务做特征发现；收齐后再统一判定
        session.pendingServiceCount = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let session = sessions[peripheral.identifier] else { return }

        // 特征发现失败也计入"该服务收齐"，避免计数永不归零挂死
        if let characteristics = error == nil ? service.characteristics : nil {
            for char in characteristics {
                // 支持写入的特征值作为 RX 端口
                if char.properties.contains(.writeWithoutResponse) || char.properties.contains(.write) {
                    session.rxCharacteristic = char
                    Logger.bluetooth.notice("BLE 副屏 [\(session.deviceName)] 串口就绪，准备推送数据")
                    markConnected(session)
                    self.pushInitialPayload(to: session)
                    return
                }
            }
        }

        session.pendingServiceCount = max(0, session.pendingServiceCount - 1)
        if session.pendingServiceCount == 0 && session.rxCharacteristic == nil {
            // 所有服务发现收齐仍无可写特征：误连设备，断开 + 冷却 + 重扫
            Logger.bluetooth.notice("BLE 设备 [\(session.deviceName)] 未发现可写 GATT 特征（误连），断开并继续扫描")
            rejectSession(session)
        }
    }

    /// 拒绝路径：记冷却黑名单、断开误连设备并清理会话；重扫统一由 didDisconnect 触发
    private func rejectSession(_ session: BLESession) {
        gattRejectCooldowns[session.identifier] = Date().timeIntervalSince1970
        sessions.removeValue(forKey: session.identifier)
        let deviceName = session.deviceName
        session.peripheral.delegate = nil
        centralManager?.cancelPeripheralConnection(session.peripheral)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.connectedDeviceName == deviceName {
                self.connectedDeviceName = nil
            }
        }
    }

    /// GATT 串口就绪：此刻才标记为已连接副屏
    private func markConnected(_ session: BLESession) {
        let name = session.deviceName
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectedDeviceName = name
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == session.identifier || $0.name == name }) {
                self.discoveredDevices[idx].isConnected = true
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
