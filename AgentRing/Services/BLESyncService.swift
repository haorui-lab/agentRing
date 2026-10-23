//
//  BLESyncService.swift
//  Agent Ring
//
//  蓝牙 BLE (Bluetooth Low Energy) GATT 副屏同步服务
//  支持 ESP32-P4、ESP32-S3、ESP32-C6、ESP32-C3 等仅支持 BLE 的现代硬件副屏
//  - 使用 CoreBluetooth 扫描外设名称前缀 "AgentRing"
//  - 仅连接用户选择的外设；LCD 完成系统加密配对和绑定握手后再推流
//  - 分包推送单行 JSON + '\n'
//  - 15 秒周期发送轻量 ping 保活
//

import Foundation
@preconcurrency import CoreBluetooth
import OSLog
import AppKit
import Combine

nonisolated public struct BLEDiscoveredDevice: Identifiable, Equatable {
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

nonisolated final class BLESyncService: NSObject, ObservableObject, @unchecked Sendable {
    // CoreBluetooth/session state is confined to queue; published snapshots are
    // written on main. SDK delegates are explicitly nonisolated for that queue.
    static let shared = BLESyncService()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.agentring.AgentRing", category: "Bluetooth")

    // MARK: - 协议常量与 UUID

    /// 副屏设备名前缀
    private static let deviceNamePrefix = "AgentRing"

    /// 标准 Nordic UART Service UUID 或 AgentRing BLE Service
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// TX / Write Characteristic (Client -> ESP32)
    static let rxCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// RX / Notify Characteristic (ESP32 -> Client)
    static let txCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    static let bindingCharUUID = CBUUID(string: "6E400004-B5A3-F393-E0A9-E50E24DCCA9E")

    // MARK: - 观察状态

    @MainActor @Published public private(set) var discoveredDevices: [BLEDiscoveredDevice] = []
    @MainActor @Published public private(set) var connectedDeviceName: String? = nil
    @MainActor @Published public private(set) var isScanning = false

    @MainActor @Published private(set) var selectedDevices: [UUID: String] = [:]
    @MainActor @Published private(set) var connectingDeviceIDs: Set<UUID> = []
    @MainActor @Published private(set) var deviceMessages: [UUID: String] = [:]
    private var classicDeviceNames: Set<String> = []
    private var savedDevices: [UUID: String] = [:]
    private var requestedDevices: Set<UUID> = []
    private var suspendedDevices: Set<UUID> = []
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var advertisedNames: [UUID: String] = [:]
    private var cancellingDevices: Set<UUID> = []
    private static let selectionKey = "bleSelectedDevicesV2"
    private var hostName = "Mac"

    // MARK: - 会话模型

    nonisolated private final class BLESession {
        let identifier: UUID
        let peripheral: CBPeripheral
        let advertisedName: String
        var rxCharacteristic: CBCharacteristic?
        var bindingCharacteristic: CBCharacteristic?
        var authorized = false
        var authenticationStarted = false
        var bindingHandshake = BLEBindingHandshake()
        let generation = UUID()
        var pendingChunks: [Data] = []
        var writingWithResponse = false
        var lastWriteTime: TimeInterval = 0
        /// 尚未完成特征发现的服务数；收齐后统一判定 GATT 是否可用
        var pendingServiceCount = 0

        var isReady: Bool {
            peripheral.state == .connected && rxCharacteristic != nil && authorized
        }

        var deviceName: String {
            advertisedName.isEmpty ? (peripheral.name ?? identifier.uuidString) : advertisedName
        }

        init(peripheral: CBPeripheral, name: String) {
            self.identifier = peripheral.identifier
            self.peripheral = peripheral
            self.advertisedName = name
        }
    }

    // MARK: - 状态

    private(set) var isRunning = false
    private var centralManager: CBCentralManager?
    private var sessions: [UUID: BLESession] = [:]
    private var lastPayloadLine: String?
    private var heartbeatTimer: Timer?
    private var scanTimeoutWorkItem: DispatchWorkItem?

    /// 失败设备冷却记录（peripheral UUID → 时间）
    /// 冷却期内 didDiscover 只更新列表、不自动 connect，防止反复粘死扫描窗口
    private var gattRejectCooldowns: [UUID: TimeInterval] = [:]
    private static let gattRejectCooldown: TimeInterval = 60

    /// GATT 服务发现超时看门狗：didConnect 后若回调一直不来，不能干等占坑
    private var gattDiscoveryTimeouts: [UUID: DispatchWorkItem] = [:]

    private let queue = DispatchQueue(label: "app.agentring.ble")

    // MARK: - 初始化

    private override init() {
        super.init()
        let stored = UserDefaults.standard.dictionary(forKey: Self.selectionKey) as? [String: String] ?? [:]
        savedDevices = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
        let snapshot = savedDevices
        Task { @MainActor in self.selectedDevices = snapshot }
    }

    private func mayConnect(_ id: UUID) -> Bool {
        isRunning && !cancellingDevices.contains(id) && BLEConnectionPolicy.mayConnect(
            id: id, selected: Set(savedDevices.keys), requested: requestedDevices, suspended: suspendedDevices,
            classicConnected: BLEConnectionPolicy.usesClassicConnection(
                name: advertisedNames[id] ?? savedDevices[id] ?? peripherals[id]?.name ?? "", connectedNames: classicDeviceNames))
    }

    private func message(_ text: String?, for id: UUID) {
        DispatchQueue.main.async { self.deviceMessages[id] = text }
    }

    private func saveSelection() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: savedDevices.map { ($0.key.uuidString, $0.value) }), forKey: Self.selectionKey)
        let snapshot = savedDevices
        DispatchQueue.main.async { self.selectedDevices = snapshot }
    }

    func updateClassicConnections(_ names: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let previousNames = self.classicDeviceNames
            self.classicDeviceNames = Set(names)
            for session in Array(self.sessions.values) where BLEConnectionPolicy.usesClassicConnection(
                name: session.deviceName, connectedNames: self.classicDeviceNames) {
                let id = session.identifier
                session.authorized = false
                self.requestedDevices.remove(id)
                self.sessions.removeValue(forKey: id)
                self.cancelGATTDiscoveryTimeout(identifier: id)
                self.cancellingDevices.insert(id)
                self.centralManager?.cancelPeripheralConnection(session.peripheral)
            }
            for (id, name) in self.advertisedNames {
                if BLEConnectionPolicy.usesClassicConnection(name: name, connectedNames: self.classicDeviceNames) {
                    self.requestedDevices.remove(id)
                    self.message("已通过经典蓝牙连接，无需 BLE 配对。", for: id)
                } else if BLEConnectionPolicy.usesClassicConnection(name: name, connectedNames: previousNames) {
                    self.message(nil, for: id)
                }
            }
            self.publishConnections()
        }
    }

    func connectDevice(_ id: UUID) {
        let label = BLEConnectionPolicy.hostLabel(Host.current().localizedName ?? "Mac")
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.hostName = label
            let name = self.advertisedNames[id] ?? self.savedDevices[id] ?? self.peripherals[id]?.name ?? ""
            guard !BLEConnectionPolicy.usesClassicConnection(name: name, connectedNames: self.classicDeviceNames) else {
                self.message("已通过经典蓝牙连接，无需 BLE 配对。", for: id)
                return
            }
            self.requestedDevices.insert(id)
            self.suspendedDevices.remove(id)
            self.gattRejectCooldowns.removeValue(forKey: id)
            if let peripheral = self.peripherals[id] { self.connect(peripheral) }
            else { self.startScanning() }
        }
    }

    func forgetDevice(_ id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.requestedDevices.remove(id)
            self.savedDevices.removeValue(forKey: id)
            self.suspendedDevices.insert(id)
            self.saveSelection()
            self.cancelGATTDiscoveryTimeout(identifier: id)
            if let session = self.sessions.removeValue(forKey: id) {
                session.authorized = false
                self.cancellingDevices.insert(id)
                self.centralManager?.cancelPeripheralConnection(session.peripheral)
            }
            self.publishConnections()
            self.message("已停止自动重连；屏幕绑定需在屏幕解除", for: id)
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard mayConnect(id), sessions[id] == nil else { return }
        if let rejectedAt = gattRejectCooldowns[id], Date().timeIntervalSince1970 - rejectedAt < Self.gattRejectCooldown { return }
        sessions[id] = BLESession(peripheral: peripheral, name: advertisedNames[id] ?? savedDevices[id] ?? peripheral.name ?? "")
        peripheral.delegate = self
        message("正在连接…", for: id)
        publishConnections()
        centralManager?.connect(peripheral, options: nil)
        beginGATTDiscoveryTimeout(identifier: id, duration: 12)
    }

    private func publishConnections() {
        let ready = sessions.values.filter(\.isReady)
        let ids = Set(ready.map(\.identifier))
        let connectingIDs = Set(sessions.values.filter { !$0.isReady }.map(\.identifier))
        let names = ready.map(\.deviceName).sorted().joined(separator: ", ")
        // Bonded peripherals may reconnect without advertising again. Keep their
        // live session in the list instead of showing a disconnected saved row.
        let connectedRows = ready.map {
            BLEDiscoveredDevice(id: $0.identifier, name: $0.deviceName, rssi: 0, isConnected: true)
        }
        DispatchQueue.main.async {
            self.connectedDeviceName = names.isEmpty ? nil : names
            self.connectingDeviceIDs = connectingIDs
            for index in self.discoveredDevices.indices {
                self.discoveredDevices[index].isConnected = ids.contains(self.discoveredDevices[index].id)
            }
            for row in connectedRows where !self.discoveredDevices.contains(where: { $0.id == row.id }) {
                self.discoveredDevices.append(row)
            }
        }
    }

    // MARK: - 控制接口

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
        let label = BLEConnectionPolicy.hostLabel(Host.current().localizedName ?? "Mac")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            self.hostName = label
            Self.logger.notice("BLE 同步启动，仅重连已选择的副屏")

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
            for identifier in Array(self.gattDiscoveryTimeouts.keys) {
                self.cancelGATTDiscoveryTimeout(identifier: identifier)
            }
            self.gattRejectCooldowns.removeAll()
            self.centralManager?.stopScan()
            for session in self.sessions.values {
                self.centralManager?.cancelPeripheralConnection(session.peripheral)
            }
            self.sessions.removeAll()
            self.publishConnections()
            self.requestedDevices.removeAll()
            self.lastPayloadLine = nil
            DispatchQueue.main.async {
                self.isScanning = false
                self.connectedDeviceName = nil
                self.discoveredDevices.removeAll()
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = nil
            }
            Self.logger.notice("BLE 蓝牙同步服务停止")
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
        Self.logger.info("扫描 BLE 副屏；未选择的设备仅展示")
        if let centralManager {
            for peripheral in centralManager.retrievePeripherals(withIdentifiers: Array(savedDevices.keys)) {
                peripherals[peripheral.identifier] = peripheral
                connect(peripheral)
            }
        }
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
        Self.logger.info("BLE 扫描结束")
    }

    private func write(line: String, to session: BLESession) {
        guard let char = session.rxCharacteristic else { return }
        let payloadWithNewline = line.hasSuffix("\n") ? line : line + "\n"
        guard let data = payloadWithNewline.data(using: .utf8) else { return }

        guard session.isReady else { return }
        let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let maxChunk = max(1, session.peripheral.maximumWriteValueLength(for: type))
        /* Queue complete frames; flow control prevents dropping or interleaving chunks. */
        guard session.pendingChunks.count < 256 else { return }
        for offset in stride(from: 0, to: data.count, by: maxChunk) {
            session.pendingChunks.append(data.subdata(in: offset..<min(offset + maxChunk, data.count)))
        }
        flushWrites(session)
    }

    private func flushWrites(_ session: BLESession) {
        guard session.isReady, let char = session.rxCharacteristic else { return }
        let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        while !session.pendingChunks.isEmpty {
            if type == .withoutResponse {
                guard session.peripheral.canSendWriteWithoutResponse else { return }
            } else {
                guard !session.writingWithResponse else { return }
                session.writingWithResponse = true
            }
            let chunk = session.pendingChunks.removeFirst()
            session.peripheral.writeValue(chunk, for: char, type: type)
            session.lastWriteTime = Date().timeIntervalSince1970
            if type == .withResponse { return }
        }
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

        // 后台搜寻未连接的已选择副屏，保留 1:N 重连能力
        // （用 centralManager.isScanning 判断 CB 真相，@Published isScanning 经主线程异步易脏读）
        if centralManager?.isScanning != true && centralManager?.state == .poweredOn {
            startScanning()
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
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        queue.async { [weak self] in
            guard let self else { return }
            if central.state == .poweredOn && self.isRunning {
                self.startScanning()
            } else if central.state != .poweredOn {
                Self.logger.notice("BLE 蓝牙未就绪 (state: \(central.state.rawValue))")
                self.stopScanning()
                for identifier in Array(self.gattDiscoveryTimeouts.keys) {
                    self.cancelGATTDiscoveryTimeout(identifier: identifier)
                }
                self.sessions.removeAll()
                self.cancellingDevices.removeAll()
                self.publishConnections()
                DispatchQueue.main.async {
                    self.connectedDeviceName = nil
                }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isRunning else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.localizedCaseInsensitiveContains(Self.deviceNamePrefix) else { return }

        let rssiVal = RSSI.intValue
        let uuid = peripheral.identifier
        let isConnected = sessions[uuid]?.isReady == true
        peripherals[uuid] = peripheral
        advertisedNames[uuid] = name

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 同名设备保持独立；UUID 只用于本机选择，不作为认证凭据。
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == uuid }) {
                self.discoveredDevices[idx] = BLEDiscoveredDevice(id: uuid, name: name, rssi: rssiVal, isConnected: isConnected)
            } else {
                self.discoveredDevices.append(BLEDiscoveredDevice(id: uuid, name: name, rssi: rssiVal, isConnected: isConnected))
                self.discoveredDevices.sort { $0.rssi > $1.rssi }
            }
        }

        guard mayConnect(uuid) else { return }

        // 冷却黑名单：近期被判定无 GATT 串口的设备不再自动连接，只保留在列表里
        // （显式指定目标名的设备也遵守冷却，避免对无 GATT 设备死磕）
        if let rejectedAt = gattRejectCooldowns[uuid],
           Date().timeIntervalSince1970 - rejectedAt < Self.gattRejectCooldown {
            let remaining = Int(Self.gattRejectCooldown - (Date().timeIntervalSince1970 - rejectedAt))
            Self.logger.notice("BLE 设备 [\(name)] 处于误连冷却期（剩余 \(remaining)s），跳过自动连接")
            return
        }
        gattRejectCooldowns.removeValue(forKey: uuid)

        connect(peripheral)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard mayConnect(peripheral.identifier), sessions[peripheral.identifier] != nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let name = peripheral.name ?? peripheral.identifier.uuidString
        Self.logger.notice("已连接 BLE 设备: \(name)，正在发现服务...")
        // 注意：此时还不能当「已连接副屏」用——GATT 串口未就绪，可能是误连的
        // 无 GATT 设备（如 Android 经典副屏）。等 didDiscoverCharacteristicsFor
        // 找到可写特征后才更新 connectedDeviceName。
        beginGATTDiscoveryTimeout(identifier: peripheral.identifier)
        peripheral.discoverServices([Self.serviceUUID])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard sessions[peripheral.identifier] != nil else { cancellingDevices.remove(peripheral.identifier); return }
        let name = peripheral.name ?? peripheral.identifier.uuidString
        Self.logger.warning("连接 BLE 副屏失败: \(name), error: \(String(describing: error))")
        let id = peripheral.identifier
        requestedDevices.remove(id)
        let suspend = BLEConnectionPolicy.shouldSuspendAfterFailure(selectedBefore: savedDevices[id] != nil, authenticationStarted: false)
        if suspend { suspendedDevices.insert(id) }
        else { gattRejectCooldowns[id] = Date().timeIntervalSince1970 }
        sessions.removeValue(forKey: id)
        cancellingDevices.remove(id)
        cancelGATTDiscoveryTimeout(identifier: id)
        message(suspend ? "连接失败，请在屏幕开启配对后重试" : "设备暂时不可用，等待自动重连", for: id)
        publishConnections()
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        let wasReady = sessions[id]?.authorized == true
        let authenticationStarted = sessions[id]?.authenticationStarted == true
        let wasCancelled = cancellingDevices.remove(id) != nil
        sessions.removeValue(forKey: id)
        cancelGATTDiscoveryTimeout(identifier: id)
        if isRunning && !wasReady && !wasCancelled && (requestedDevices.contains(id) || savedDevices[id] != nil) {
            requestedDevices.remove(id)
            let suspend = BLEConnectionPolicy.shouldSuspendAfterFailure(selectedBefore: savedDevices[id] != nil, authenticationStarted: authenticationStarted)
            if suspend { suspendedDevices.insert(id) }
            else { gattRejectCooldowns[id] = Date().timeIntervalSince1970 }
            message(suspend ? "未完成验证；在屏幕开启配对或解除旧绑定后重试" : "设备暂时不可用，等待自动重连", for: id)
        } else if wasReady {
            message("已断开，等待自动重连", for: id)
        }
        publishConnections()
        if isRunning, !wasCancelled { startScanning() }
    }

}

// MARK: - CBPeripheralDelegate

extension BLESyncService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isRunning, mayConnect(peripheral.identifier), let session = sessions[peripheral.identifier] else { return }

        // 服务发现失败：同一条拒绝路径，不能静默挂死
        if error != nil {
            Self.logger.notice("BLE 设备 [\(session.deviceName)] 服务发现失败: \(String(describing: error))，断开并冷却")
            rejectSession(session)
            return
        }

        let services = peripheral.services?.filter { $0.uuid == Self.serviceUUID } ?? []
        guard !services.isEmpty else {
            Self.logger.notice("BLE 设备 [\(session.deviceName)] 无 AgentRing UART 服务，判定为非串口设备，断开并冷却")
            rejectSession(session)
            return
        }

        // 只对 UART 服务做特征发现；收齐后再统一判定
        session.pendingServiceCount = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isRunning, mayConnect(peripheral.identifier), let session = sessions[peripheral.identifier] else { return }

        if error == nil, let characteristics = service.characteristics {
            session.rxCharacteristic = characteristics.first {
                $0.uuid == Self.rxCharUUID && ($0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write))
            }
            session.bindingCharacteristic = characteristics.first { $0.uuid == Self.bindingCharUUID }
        }
        session.pendingServiceCount = max(0, session.pendingServiceCount - 1)
        guard session.pendingServiceCount == 0 else { return }
        guard session.rxCharacteristic != nil else {
            rejectSession(session, reason: "未找到副屏数据通道")
            return
        }
        if let binding = session.bindingCharacteristic {
            guard binding.properties.contains(.read), binding.properties.contains(.write) else {
                rejectSession(session, reason: "绑定协议不完整，请升级固件")
                return
            }
            beginGATTDiscoveryTimeout(identifier: session.identifier, duration: 90)
            message("请在 Mac 系统配对框输入屏幕验证码", for: session.identifier)
            session.authenticationStarted = true
            // Explicitly ask the peripheral to initiate SMP. A protected read
            // alone can fail immediately on macOS without presenting pairing UI.
            peripheral.writeValue(Data("{\"type\":\"authenticate\"}".utf8), for: binding, type: .withResponse)
        } else if BLEConnectionPolicy.requiresBinding(name: session.deviceName) {
            rejectSession(session, reason: "此 LCD 固件不支持安全绑定，请升级固件")
        } else {
            finishAuthorization(session)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isRunning, mayConnect(peripheral.identifier), let session = sessions[peripheral.identifier],
              characteristic.uuid == Self.bindingCharUUID else { return }
        if let error {
            let detail = error as NSError
            Self.logger.warning("BLE identity read failed: domain=\(detail.domain, privacy: .public), code=\(detail.code)")
            if session.bindingHandshake.stage == .readIdentity &&
                BLEBindingHandshake.canWaitForEncryption(isATTError: detail.domain == CBATTErrorDomain, code: detail.code) {
                scheduleBindingRead(session)
            } else {
                rejectSession(session, reason: "系统配对未完成；请在屏幕开启配对后重试")
            }
            return
        }
        guard let data = characteristic.value, BLEConnectionPolicy.validBindingResponse(data),
              session.bindingHandshake.verifyIdentity() else {
            rejectSession(session, reason: "绑定协议校验失败，请升级固件后重试")
            return
        }
        guard let hello = try? JSONSerialization.data(withJSONObject: ["hostName": hostName]) else { return }
        peripheral.writeValue(hello, for: characteristic, type: .withResponse)
    }

    nonisolated private func scheduleBindingRead(_ session: BLESession) {
        let id = session.identifier
        let generation = session.generation
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.mayConnect(id), let current = self.sessions[id],
                  current.generation == generation, current.bindingHandshake.stage == .readIdentity,
                  let characteristic = current.bindingCharacteristic else { return }
            current.peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isRunning, mayConnect(peripheral.identifier), let session = sessions[peripheral.identifier] else { return }
        guard error == nil else {
            let detail = error! as NSError
            Self.logger.warning("BLE write failed: characteristic=\(characteristic.uuid.uuidString, privacy: .public), domain=\(detail.domain, privacy: .public), code=\(detail.code)")
            rejectSession(session, reason: "副屏拒绝写入；请检查屏幕绑定状态后重试")
            return
        }
        if characteristic.uuid == Self.bindingCharUUID {
            let previousStage = session.bindingHandshake.stage
            if session.bindingHandshake.acknowledgeWrite() {
                finishAuthorization(session)
            } else if previousStage == .requestSecurity {
                message("请在 macOS 系统配对框输入 LCD 已显示的六位码", for: session.identifier)
                scheduleBindingRead(session)
            }
        } else if characteristic.uuid == Self.rxCharUUID {
            session.writingWithResponse = false
            flushWrites(session)
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let session = sessions[peripheral.identifier] else { return }
        flushWrites(session)
    }

    nonisolated private func finishAuthorization(_ session: BLESession) {
        guard mayConnect(session.identifier) else { return }
        guard session.bindingCharacteristic == nil || session.bindingHandshake.stage == .ready else { return }
        session.authorized = true
        requestedDevices.remove(session.identifier)
        savedDevices[session.identifier] = session.deviceName
        saveSelection()
        cancelGATTDiscoveryTimeout(identifier: session.identifier)
        message(session.bindingCharacteristic == nil ? "已连接（旧协议）" : "已绑定，正在同步本机数据", for: session.identifier)
        publishConnections()
        pushInitialPayload(to: session)
    }

    /// 拒绝路径：记冷却黑名单、断开误连设备并清理会话
    /// cancelPeripheralConnection 的 didDisconnect 回调不保证到达，不能只依赖它重扫
    nonisolated private func rejectSession(_ session: BLESession, reason: String = "服务发现失败，请刷新后重试", suspend: Bool = true) {
        session.authorized = false
        requestedDevices.remove(session.identifier)
        if suspend { suspendedDevices.insert(session.identifier) }
        message(reason, for: session.identifier)
        gattRejectCooldowns[session.identifier] = Date().timeIntervalSince1970
        sessions.removeValue(forKey: session.identifier)
        cancelGATTDiscoveryTimeout(identifier: session.identifier)
        publishConnections()
        cancellingDevices.insert(session.identifier)
        session.peripheral.delegate = nil
        centralManager?.cancelPeripheralConnection(session.peripheral)
        // 失败后保留扫描能力，失败设备需用户明确重试。
        if isRunning, sessions.isEmpty, centralManager?.isScanning != true {
            Self.logger.notice("拒绝后恢复扫描")
            startScanning()
        }
    }

    // MARK: - GATT 发现超时看门狗

    /// didConnect 后武装：服务/特征发现回调若 6s 内不来，判定挂死走拒绝路径
    nonisolated private func beginGATTDiscoveryTimeout(identifier: UUID, duration: TimeInterval = 6) {
        cancelGATTDiscoveryTimeout(identifier: identifier)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let session = self.sessions[identifier] else { return }
            guard !session.isReady else { return }
            Self.logger.notice("BLE 设备 [\(session.deviceName)] 连接或验证超时，断开并等待手动重试")
            let suspend = BLEConnectionPolicy.shouldSuspendAfterFailure(
                selectedBefore: self.savedDevices[identifier] != nil, authenticationStarted: session.authenticationStarted)
            self.rejectSession(session, reason: suspend ? "连接或配对超时，请在屏幕开启配对后重试" : "设备暂时不可用，等待自动重连", suspend: suspend)
        }
        gattDiscoveryTimeouts[identifier] = work
        queue.asyncAfter(deadline: .now() + duration, execute: work)
    }

    nonisolated private func cancelGATTDiscoveryTimeout(identifier: UUID) {
        gattDiscoveryTimeouts[identifier]?.cancel()
        gattDiscoveryTimeouts.removeValue(forKey: identifier)
    }

    nonisolated private func pushInitialPayload(to session: BLESession) {
        if let line = lastPayloadLine {
            write(line: line, to: session)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let dataManager = AppDelegate.shared?.menuBarManager?.dataManagerForBluetooth else {
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
