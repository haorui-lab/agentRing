//
//  BluetoothSyncService.swift
//  Agent Ring
//
//  蓝牙副屏同步服务（RFCOMM SPP 客户端）
//  行为规范见《BLUETOOTH_PROTOCOL.md》：
//  - 遍历系统已配对设备，按名称前缀 "AgentRing" 识别副屏
//  - 通过 SDP 查询 SPP UUID (0x1101) 拿到 RFCOMM 通道
//  - 10 秒周期重连；连接超时 8 秒；断开后安全释放并重试
//  - 每帧单行 JSON + '\n' UTF-8 写入
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

    // MARK: - 状态

    private(set) var isRunning = false
    private var isConnecting = false
    private var lastWriteTime: TimeInterval = 0

    private var rfcommChannel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var reconnectTimer: Timer?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var lastPayloadLine: String?
    /// 正在进行 SDP 查询的设备地址，防止重复发起
    private var queryingAddress: String?
    private var sdpQueryCompletion: ((BluetoothRFCOMMChannelID?) -> Void)?
    private var wakeObserver: NSObjectProtocol?

    private let queue = DispatchQueue(label: "app.agentring.bluetooth")

    // MARK: - 生命周期

    private override init() {
        super.init()
    }

    /// 启动同步服务：立即尝试连接并开始周期重连
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            Logger.bluetooth.notice("蓝牙同步服务启动")
            self.setupWakeObserver()
            self.scheduleReconnectTimer(fireImmediately: true)
        }
    }

    /// 停止同步服务：关闭通道、释放资源、取消定时器
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.removeWakeObserver()
            self.teardownConnection()
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
            Logger.bluetooth.notice("系统从睡眠唤醒，重置副屏蓝牙链路并立即发起重连")
            self.teardownConnection()
            self.scheduleReconnectTimer(fireImmediately: true)
        }
    }

    // MARK: - 数据推送

    /// 推送一帧用量报文；未连接时缓存，连接成功后补发
    func push(line: String) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.lastPayloadLine = line
            guard let channel = self.rfcommChannel, channel.isOpen() else { return }
            self.write(line: line, to: channel)
        }
    }

    /// 通道建立成功后调用：若还没有任何缓存帧（冷启动先连上、数据后到），主动拉当前数据补一帧
    private func pushIfNoCache() {
        guard lastPayloadLine == nil else { return }
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

    /// 便捷入口：直接构造并推送完整报文
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

    // MARK: - 连接管理

    private func scheduleReconnectTimer(fireImmediately: Bool = false) {
        // 定时器需挂在主 RunLoop；回调再切回自有队列
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

        // 若已连接：检测空闲心跳，若超过 15 秒未写入则发送轻量 ping 保活
        if let channel = rfcommChannel, channel.isOpen() {
            let now = Date().timeIntervalSince1970
            if now - lastWriteTime >= 15 {
                sendHeartbeat(to: channel)
            }
            return
        }

        // 若已有连接正在建立中，避免 10s 定时器并发重入与通道冲突
        guard !isConnecting else {
            Logger.bluetooth.debug("已有连接流程正在进行中，跳过本次重连调度")
            return
        }

        isConnecting = true
        teardownConnection(resetConnecting: false)

        guard let device = findPairedDisplayDevice() else {
            Logger.bluetooth.debug("未发现已配对的 AgentRing 副屏设备")
            isConnecting = false
            return
        }
        self.device = device

        Logger.bluetooth.info("尝试连接副屏: \(device.name ?? "unknown") (\(device.addressString))")

        // 不显式 openConnection：performSDPQuery / openRFCOMMChannelSync 底层会自动建基带，
        // 显式同步调用在设备睡眠时会卡死串行队列；连接超时由看门狗兜底
        beginConnectTimeout()

        querySDP(for: device) { [weak self] channelID in
            guard let self else { return }
            self.cancelConnectTimeout()
            guard self.isRunning else {
                self.isConnecting = false
                return
            }

            let resolved = channelID ?? Self.fallbackChannelID
            if channelID == nil {
                Logger.bluetooth.notice("SDP 未查询到 SPP 通道，回退预备通道 \(Self.fallbackChannelID)")
            }
            self.openChannel(on: device, channelID: resolved)
        }
    }

    /// 发送轻量心跳保活帧，防止底层蓝牙芯片因静默休眠或超时断开
    private func sendHeartbeat(to channel: IOBluetoothRFCOMMChannel) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let pingJson = "{\"type\":\"ping\",\"timestamp\":\(timestamp)}"
        let data = Data((pingJson + "\n").utf8)
        let status = writeRaw(data, to: channel)
        if status == kIOReturnSuccess {
            lastWriteTime = Date().timeIntervalSince1970
            Logger.bluetooth.debug("已发送蓝牙保活心跳 (ping)")
        } else {
            Logger.bluetooth.info("发送心跳失败: \(status, privacy: .public)，释放连接")
            teardownConnection()
        }
    }

    /// 遍历已配对设备：名称前缀或已知 MAC 匹配（协议第 2.2 节，名字未拉取到时靠 MAC 兜底）
    /// IOBluetooth 的 addressString 格式为 "00-11-22-33-44-55"（带连字符），统一去除分隔符比对
    private func findPairedDisplayDevice() -> IOBluetoothDevice? {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.first { device in
            let name = (device.nameOrAddress ?? device.name ?? "")
            if name.localizedCaseInsensitiveContains(Self.deviceNamePrefix) {
                return true
            }
            let normalizedDeviceAddr = (device.addressString ?? "").filter { $0.isLetter || $0.isNumber }
            let normalizedKnownAddr = Self.knownDisplayMAC.filter { $0.isLetter || $0.isNumber }
            return normalizedDeviceAddr.caseInsensitiveCompare(normalizedKnownAddr) == .orderedSame
        }
    }

    /// 查询设备 SDP 记录，解析 SPP 服务的 RFCOMM 通道号
    private func querySDP(for device: IOBluetoothDevice, completion: @escaping (BluetoothRFCOMMChannelID?) -> Void) {
        // 已有缓存的服务记录：直接取通道
        if let record = device.getServiceRecord(for: IOBluetoothSDPUUID.uuid16(Self.sppUUID16)) {
            let pointer = channelIDStorage
            if record.getRFCOMMChannelID(pointer) == kIOReturnSuccess {
                completion(pointer[0])
                return
            }
        }

        guard queryingAddress == nil else {
            // 上一轮查询还没回来，直接放弃本次（下个重连周期再试）
            sdpQueryCompletion = completion
            return
        }
        queryingAddress = device.addressString
        sdpQueryCompletion = completion

        let result = device.performSDPQuery(self, uuids: [IOBluetoothSDPUUID.uuid16(Self.sppUUID16)])
        if result != kIOReturnSuccess {
            Logger.bluetooth.info("SDP 查询发起失败: \(result, privacy: .public)")
            finishSDPQuery(channelID: nil)
        }
    }

    /// getRFCOMMChannelID 需要 UnsafeMutablePointer，Swift 侧的存储桩
    private lazy var channelIDStorage: UnsafeMutablePointer<BluetoothRFCOMMChannelID> = {
        UnsafeMutablePointer<BluetoothRFCOMMChannelID>.allocate(capacity: 1)
    }()

    private func finishSDPQuery(channelID: BluetoothRFCOMMChannelID?) {
        queryingAddress = nil
        let completion = sdpQueryCompletion
        sdpQueryCompletion = nil
        completion?(channelID)
    }

    private func openChannel(on device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) {
        var channel: IOBluetoothRFCOMMChannel?
        // delegate 直接传入，确保断开回调从一开始就挂上
        let result = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: self)
        if result == kIOReturnSuccess, let channel {
            isConnecting = false
            cancelConnectTimeout()
            rfcommChannel = channel
            Logger.bluetooth.notice("副屏 RFCOMM 通道已建立 (channel \(channelID))")

            // 连接成功：补发最近一帧；无缓存帧则主动拉当前数据
            if let line = lastPayloadLine {
                write(line: line, to: channel)
            } else {
                pushIfNoCache()
            }
            return
        }

        Logger.bluetooth.info("打开 RFCOMM 通道返回: \(result, privacy: .public)")
        isConnecting = false
        teardownConnection()
    }

    private func teardownConnection(resetConnecting: Bool = true) {
        if let channel = rfcommChannel {
            if channel.isOpen() {
                channel.close()
            }
            _ = channel.setDelegate(nil)
        }
        rfcommChannel = nil
        device = nil
        queryingAddress = nil
        sdpQueryCompletion = nil
        cancelConnectTimeout()
        if resetConnecting {
            isConnecting = false
        }
    }

    // MARK: - 超时看门狗

    private func beginConnectTimeout() {
        cancelConnectTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.rfcommChannel?.isOpen() != true else { return }
            Logger.bluetooth.info("副屏连接超时（\(Int(Self.connectTimeout))s），释放并等待下轮重连")
            self.teardownConnection()
        }
        connectTimeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.connectTimeout, execute: work)
    }

    private func cancelConnectTimeout() {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
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

    private func write(line: String, to channel: IOBluetoothRFCOMMChannel) {
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
                    Logger.bluetooth.error("蓝牙写入分段失败: \(status, privacy: .public)")
                    teardownConnection()
                    return
                }
                offset = end
                segments += 1
                if offset < data.count {
                    usleep(15_000) // 15ms 让出底层 RFCOMM credit
                }
            }
            lastWriteTime = Date().timeIntervalSince1970
            Logger.bluetooth.debug("蓝牙写入 \(data.count) 字节（分 \(segments) 段）")
            return
        }

        let status = writeRaw(data, to: channel)
        if status == kIOReturnSuccess {
            lastWriteTime = Date().timeIntervalSince1970
            Logger.bluetooth.debug("蓝牙写入 \(data.count) 字节")
        } else {
            Logger.bluetooth.error("蓝牙写入失败: \(status, privacy: .public)")
            teardownConnection()
        }
    }
}

// MARK: - SDP 查询回调
// IOBluetoothDevice 的异步回调是 informal protocol（IOBluetoothDeviceAsyncCallbacks），
// 无正式协议名，直接实现 selector 即可。

extension BluetoothSyncService {
    /// SDP 查询完成回调（informal protocol，必须 @objc 暴露给 ObjC runtime 才会被调用）
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        queue.async { [weak self] in
            guard let self else { return }
            guard status == kIOReturnSuccess else {
                Logger.bluetooth.info("SDP 查询失败: \(status, privacy: .public)")
                self.finishSDPQuery(channelID: nil)
                return
            }
            guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID.uuid16(Self.sppUUID16)) else {
                self.finishSDPQuery(channelID: nil)
                return
            }
            let channelID = self.channelIDStorage
            if record.getRFCOMMChannelID(channelID) == kIOReturnSuccess {
                self.finishSDPQuery(channelID: channelID[0])
            } else {
                self.finishSDPQuery(channelID: nil)
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
            self.cancelConnectTimeout()
            self.isConnecting = false
            guard status == kIOReturnSuccess, let channel else {
                Logger.bluetooth.info("异步打开 RFCOMM 通道失败: \(status, privacy: .public)")
                self.teardownConnection()
                return
            }
            self.rfcommChannel = channel
            Logger.bluetooth.notice("副屏 RFCOMM 通道已建立 (异步 channel \(channel.getID()))")
            if let line = self.lastPayloadLine {
                self.write(line: line, to: channel)
            } else {
                self.pushIfNoCache()
            }
        }
    }

    /// 通道被远端/系统关闭：释放资源，等待下轮重连
    @objc func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        queue.async { [weak self] in
            guard let self else { return }
            Logger.bluetooth.notice("副屏 RFCOMM 通道已断开")
            self.teardownConnection()
        }
    }
}
