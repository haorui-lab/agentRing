//
//  BluetoothSyncService.swift
//  Agent Ring
//
//  蓝牙副屏同步服务（RFCOMM SPP 客户端，支持 1:N 多副屏连接池）
//  行为规范见《BLUETOOTH_PROTOCOL.md》：
//  - 遍历系统已配对设备，按名称前缀 "AgentRing" 识别所有副屏设备
//  - 并行维护多台副屏的独立 DisplaySession
//  - 通过 SDP 查询 SPP UUID (0x1101) 拿到 RFCOMM 通道
//  - 10 秒周期重连；单设备连接超时 8 秒；断开后安全释放对应设备并重试
//  - 数据广播：用量变化时向所有已连接的副屏通道发送每帧单行 JSON + '\n'
//

import Foundation
import IOBluetooth
import OSLog
import AppKit

final class BluetoothSyncService: NSObject {
    static let shared = BluetoothSyncService()

    // MARK: - 协议常量

    /// SPP 标准 16-bit UUID 0x1101
    private static let sppUUID16: UInt16 = 0x1101
    /// 副屏设备名前缀
    private static let deviceNamePrefix = "AgentRing"
    /// 重连周期（协议规定 10 秒）
    private static let reconnectInterval: TimeInterval = 10
    /// 单次连接尝试超时（协议规定 8 秒）
    private static let connectTimeout: TimeInterval = 8
    /// RFCOMM 预备通道（SDP 不可用时的兜底，协议规定默认 Channel 5）
    private static let fallbackChannelID: UInt8 = 5

    /// 协议第 2.2 节：已知副屏 MAC 地址（Nubia Z9 mini 副屏）
    private static let knownDisplayMAC = "D8:55:A3:41:24:86"

    // MARK: - 副屏会话模型

    /// 独立副屏设备的连接与会话状态
    private final class DisplaySession {
        let address: String
        var device: IOBluetoothDevice
        var channel: IOBluetoothRFCOMMChannel?
        var isConnecting = false
        var isQueryingSDP = false
        var lastWriteTime: TimeInterval = 0
        var connectTimeoutWorkItem: DispatchWorkItem?

        var isConnected: Bool {
            channel?.isOpen() == true
        }

        var deviceName: String {
            device.nameOrAddress ?? device.name ?? address
        }

        init(device: IOBluetoothDevice, address: String) {
            self.device = device
            self.address = address
        }
    }

    // MARK: - 状态

    private(set) var isRunning = false

    /// 多副屏连接池，Key 为标准化的设备地址（去掉分隔符，小写）
    private var sessions: [String: DisplaySession] = [:]

    private var reconnectTimer: Timer?
    private var lastPayloadLine: String?
    private var sdpQueryCompletions: [String: (BluetoothRFCOMMChannelID?) -> Void] = [:]
    private var wakeObserver: NSObjectProtocol?

    private let queue = DispatchQueue(label: "app.agentring.bluetooth")

    // MARK: - 生命周期

    private override init() {
        super.init()
    }

    /// 启动同步服务：立即尝试连接所有副屏并开始周期重连
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            Logger.bluetooth.notice("蓝牙同步服务启动（1:N 多副屏模式）")
            self.setupWakeObserver()
            self.scheduleReconnectTimer(fireImmediately: true)
        }
    }

    /// 停止同步服务：关闭所有通道、释放资源、取消定时器
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.removeWakeObserver()
            self.teardownAll()
            self.sessions.removeAll()
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = nil
            Logger.bluetooth.notice("蓝牙同步服务停止")
        }
    }

    // MARK: - 休眠唤醒监听

    private func setupWakeObserver() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wakeObserver == nil else { return }
            self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSystemWake()
            }
        }
    }

    private func removeWakeObserver() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let observer = self.wakeObserver else { return }
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.wakeObserver = nil
        }
    }

    private func handleSystemWake() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            Logger.bluetooth.notice("系统从睡眠唤醒，重置所有副屏蓝牙链路并立即发起重连")
            self.teardownAll()
            self.scheduleReconnectTimer(fireImmediately: true)
        }
    }

    // MARK: - 数据推送

    /// 广播推送一帧用量报文；向所有已连接的副屏发送，未连接时缓存
    func push(line: String) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.lastPayloadLine = line
            for session in self.sessions.values where session.isConnected {
                self.write(line: line, to: session)
            }
        }
    }

    /// 副屏通道建立成功后调用：补发最近一帧；若尚未缓存帧（冷启动先连上、数据后到），主动拉当前数据
    private func pushInitialPayload(to session: DisplaySession) {
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

    /// 便捷入口：直接构造并广播推送完整报文
    /// payload 构造依赖 MainActor 的本地化文本，统一在主线程完成后再入队发送
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

    // MARK: - 连接池管理

    private func scheduleReconnectTimer(fireImmediately: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconnectTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: Self.reconnectInterval, repeats: true) { [weak self] _ in
                self?.queue.async { self?.attemptConnect() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.reconnectTimer = timer
            if fireImmediately {
                self.queue.async { self.attemptConnect() }
            }
        }
    }

    private func attemptConnect() {
        guard isRunning else { return }

        let candidates = findPairedDisplayDevices()
        if candidates.isEmpty {
            Logger.bluetooth.debug("未发现已配对的 AgentRing 副屏设备")
        }

        let candidateAddresses = Set(candidates.compactMap { Self.normalizeAddress($0.addressString) })

        // 清理已从系统取消配对的过期设备会话
        for (addr, session) in sessions where !candidateAddresses.contains(addr) {
            Logger.bluetooth.info("设备 [\(session.deviceName)] 已从配对列表中移除，释放会话")
            teardown(session: session)
            sessions.removeValue(forKey: addr)
        }

        let now = Date().timeIntervalSince1970

        for device in candidates {
            guard let rawAddr = device.addressString else { continue }
            let addr = Self.normalizeAddress(rawAddr)
            guard !addr.isEmpty else { continue }

            let session: DisplaySession
            if let existing = sessions[addr] {
                session = existing
                session.device = device
            } else {
                session = DisplaySession(device: device, address: addr)
                sessions[addr] = session
            }

            if session.isConnected, let channel = session.channel {
                // 已连接：检测空闲心跳，若超过 15 秒未写入则发送轻量 ping 保活
                if now - session.lastWriteTime >= 15 {
                    sendHeartbeat(to: session, channel: channel)
                }
            } else if session.isConnecting {
                Logger.bluetooth.debug("副屏 [\(session.deviceName)] 正在连接中，跳过重复调度")
            } else {
                connect(session: session)
            }
        }
    }

    private func connect(session: DisplaySession) {
        session.isConnecting = true
        session.isQueryingSDP = false
        teardownChannel(session: session)

        Logger.bluetooth.info("尝试连接副屏: \(session.deviceName) (\(session.device.addressString ?? session.address))")

        beginConnectTimeout(for: session)

        querySDP(for: session) { [weak self] channelID in
            guard let self else { return }
            self.queue.async {
                guard self.isRunning, session.isConnecting else { return }
                self.cancelConnectTimeout(for: session)

                let resolved = channelID ?? Self.fallbackChannelID
                if channelID == nil {
                    Logger.bluetooth.notice("副屏 [\(session.deviceName)] SDP 未查询到 SPP 通道，回退预备通道 \(Self.fallbackChannelID)")
                }
                self.openChannel(for: session, channelID: resolved)
            }
        }
    }

    /// 发送轻量心跳保活帧，防止底层蓝牙芯片因静默休眠或超时断开
    private func sendHeartbeat(to session: DisplaySession, channel: IOBluetoothRFCOMMChannel) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let pingJson = "{\"type\":\"ping\",\"timestamp\":\(timestamp)}"
        let data = Data((pingJson + "\n").utf8)
        let status = writeRaw(data, to: channel)
        if status == kIOReturnSuccess {
            session.lastWriteTime = Date().timeIntervalSince1970
            Logger.bluetooth.debug("副屏 [\(session.deviceName)] 已发送蓝牙保活心跳 (ping)")
        } else {
            Logger.bluetooth.info("副屏 [\(session.deviceName)] 发送心跳失败: \(status, privacy: .public)，释放连接")
            teardown(session: session)
        }
    }

    /// 遍历已配对设备：返回所有名称前缀符合或已知 MAC 的副屏设备（支持多副屏）
    private func findPairedDisplayDevices() -> [IOBluetoothDevice] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let normalizedKnownAddr = Self.normalizeAddress(Self.knownDisplayMAC)
        return paired.filter { device in
            let name = (device.nameOrAddress ?? device.name ?? "")
            if name.localizedCaseInsensitiveContains(Self.deviceNamePrefix) {
                return true
            }
            let normalizedDeviceAddr = Self.normalizeAddress(device.addressString)
            return !normalizedKnownAddr.isEmpty && normalizedDeviceAddr == normalizedKnownAddr
        }
    }

    /// 查询设备 SDP 记录，解析 SPP 服务的 RFCOMM 通道号
    private func querySDP(for session: DisplaySession, completion: @escaping (BluetoothRFCOMMChannelID?) -> Void) {
        // 已有缓存的服务记录：直接取通道
        if let record = session.device.getServiceRecord(for: IOBluetoothSDPUUID.uuid16(Self.sppUUID16)) {
            var channelID: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                completion(channelID)
                return
            }
        }

        session.isQueryingSDP = true
        sdpQueryCompletions[session.address] = completion

        let result = session.device.performSDPQuery(self, uuids: [IOBluetoothSDPUUID.uuid16(Self.sppUUID16)])
        if result != kIOReturnSuccess {
            Logger.bluetooth.info("副屏 [\(session.deviceName)] SDP 查询发起失败: \(result, privacy: .public)")
            finishSDPQuery(for: session, channelID: nil)
        }
    }

    private func finishSDPQuery(for session: DisplaySession, channelID: BluetoothRFCOMMChannelID?) {
        session.isQueryingSDP = false
        let completion = sdpQueryCompletions.removeValue(forKey: session.address)
        completion?(channelID)
    }

    private func openChannel(for session: DisplaySession, channelID: BluetoothRFCOMMChannelID) {
        var channel: IOBluetoothRFCOMMChannel?
        let result = session.device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: self)
        if result == kIOReturnSuccess, let channel {
            handleChannelConnected(session: session, channel: channel, channelID: channelID)
            return
        }

        Logger.bluetooth.info("副屏 [\(session.deviceName)] 同步打开 RFCOMM 通道返回: \(result, privacy: .public)，尝试异步打开通道 \(channelID)...")
        beginConnectTimeout(for: session)
        let asyncStatus = session.device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        if asyncStatus != kIOReturnSuccess {
            Logger.bluetooth.info("副屏 [\(session.deviceName)] 异步发起 RFCOMM 通道失败: \(asyncStatus, privacy: .public)")
            teardown(session: session)
        }
    }

    private func handleChannelConnected(
        session: DisplaySession,
        channel: IOBluetoothRFCOMMChannel,
        channelID: BluetoothRFCOMMChannelID
    ) {
        session.isConnecting = false
        cancelConnectTimeout(for: session)
        session.channel = channel
        Logger.bluetooth.notice("副屏 [\(session.deviceName)] RFCOMM 通道已建立 (channel \(channelID))")

        pushInitialPayload(to: session)
    }

    private func teardownChannel(session: DisplaySession) {
        if let channel = session.channel {
            if channel.isOpen() {
                channel.close()
            }
            _ = channel.setDelegate(nil)
        }
        session.channel = nil
    }

    private func teardown(session: DisplaySession) {
        teardownChannel(session: session)
        cancelConnectTimeout(for: session)
        session.isConnecting = false
        session.isQueryingSDP = false
        sdpQueryCompletions.removeValue(forKey: session.address)
    }

    private func teardownAll() {
        for session in sessions.values {
            teardown(session: session)
        }
    }

    // MARK: - 超时看门狗

    private func beginConnectTimeout(for session: DisplaySession) {
        cancelConnectTimeout(for: session)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard session.channel?.isOpen() != true else { return }
            Logger.bluetooth.info("副屏 [\(session.deviceName)] 连接超时（\(Int(Self.connectTimeout))s），释放并等待下轮重连")
            self.teardown(session: session)
        }
        session.connectTimeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.connectTimeout, execute: work)
    }

    private func cancelConnectTimeout(for session: DisplaySession) {
        session.connectTimeoutWorkItem?.cancel()
        session.connectTimeoutWorkItem = nil
    }

    // MARK: - 写入

    /// RFCOMM 写入：writeSync 需要 UnsafeMutableRawPointer，统一走这里
    private func writeRaw(_ chunk: Data, to channel: IOBluetoothRFCOMMChannel) -> IOReturn {
        var mutable = chunk
        let count = UInt16(chunk.count)
        return mutable.withUnsafeMutableBytes { mutable in
            channel.writeSync(mutable.baseAddress, length: count)
        }
    }

    private func write(line: String, to session: DisplaySession) {
        guard let channel = session.channel, channel.isOpen() else { return }
        let data = Data((line + "\n").utf8)
        guard !data.isEmpty else { return }

        let mtu = Int(channel.getMTU())
        if mtu > 0 && data.count > mtu {
            // RFCOMM 单次写入不得超过 MTU；报文按 MTU 分段
            var offset = 0
            var segments = 0
            while offset < data.count {
                let end = min(offset + mtu, data.count)
                let chunk = data.subdata(in: offset..<end)
                let status = writeRaw(chunk, to: channel)
                if status != kIOReturnSuccess {
                    Logger.bluetooth.error("副屏 [\(session.deviceName)] 蓝牙写入分段失败: \(status, privacy: .public)")
                    teardown(session: session)
                    return
                }
                offset = end
                segments += 1
                if offset < data.count {
                    usleep(15_000) // 15ms 让出底层 RFCOMM credit
                }
            }
            session.lastWriteTime = Date().timeIntervalSince1970
            Logger.bluetooth.debug("副屏 [\(session.deviceName)] 蓝牙写入 \(data.count) 字节（分 \(segments) 段）")
            return
        }

        let status = writeRaw(data, to: channel)
        if status == kIOReturnSuccess {
            session.lastWriteTime = Date().timeIntervalSince1970
            Logger.bluetooth.debug("副屏 [\(session.deviceName)] 蓝牙写入 \(data.count) 字节")
        } else {
            Logger.bluetooth.error("副屏 [\(session.deviceName)] 蓝牙写入失败: \(status, privacy: .public)")
            teardown(session: session)
        }
    }

    // MARK: - 辅助方法

    private static func normalizeAddress(_ address: String?) -> String {
        (address ?? "").filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    private func session(for device: IOBluetoothDevice?) -> DisplaySession? {
        guard let device else { return nil }
        let normalized = Self.normalizeAddress(device.addressString)
        if let session = sessions[normalized] {
            return session
        }
        return sessions.values.first { $0.device === device }
    }

    private func session(for channel: IOBluetoothRFCOMMChannel?) -> DisplaySession? {
        guard let channel else { return nil }
        if let addr = channel.getDevice()?.addressString {
            let normalized = Self.normalizeAddress(addr)
            if let session = sessions[normalized] {
                return session
            }
        }
        return sessions.values.first { $0.channel === channel }
    }
}

// MARK: - SDP 查询回调

extension BluetoothSyncService {
    /// SDP 查询完成回调（informal protocol，必须 @objc 暴露给 ObjC runtime 才会被调用）
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let session = self.session(for: device), session.isQueryingSDP else { return }

            guard status == kIOReturnSuccess else {
                Logger.bluetooth.info("副屏 [\(session.deviceName)] SDP 查询失败: \(status, privacy: .public)")
                self.finishSDPQuery(for: session, channelID: nil)
                return
            }
            guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID.uuid16(Self.sppUUID16)) else {
                self.finishSDPQuery(for: session, channelID: nil)
                return
            }
            var channelID: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                self.finishSDPQuery(for: session, channelID: channelID)
            } else {
                self.finishSDPQuery(for: session, channelID: nil)
            }
        }
    }
}

// MARK: - 通道回调

extension BluetoothSyncService: IOBluetoothRFCOMMChannelDelegate {
    /// 异步打开通道完成回调
    @objc func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let session = self.session(for: channel) else { return }

            self.cancelConnectTimeout(for: session)
            guard status == kIOReturnSuccess, let channel else {
                Logger.bluetooth.info("副屏 [\(session.deviceName)] 异步打开 RFCOMM 通道失败: \(status, privacy: .public)")
                self.teardown(session: session)
                return
            }
            self.handleChannelConnected(session: session, channel: channel, channelID: channel.getID())
        }
    }

    /// 通道被远端/系统关闭：释放对应设备资源，等待下轮重连
    @objc func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let session = self.session(for: channel) else { return }
            Logger.bluetooth.notice("副屏 [\(session.deviceName)] RFCOMM 通道已断开")
            self.teardown(session: session)
        }
    }
}
