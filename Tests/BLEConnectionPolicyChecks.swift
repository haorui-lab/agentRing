import Foundation

@main struct BLEConnectionPolicyChecks {
    static func main() {
        let owner = UUID(), other = UUID()
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }
        check(!BLEConnectionPolicy.mayConnect(id: owner, selected: [], requested: [], suspended: []), "Discovery must never authorize connection")
        check(BLEConnectionPolicy.mayConnect(id: owner, selected: [], requested: [owner], suspended: []), "Explicit first connection")
        check(BLEConnectionPolicy.mayConnect(id: owner, selected: [owner], requested: [], suspended: []), "Previously selected owner reconnects")
        check(!BLEConnectionPolicy.mayConnect(id: other, selected: [owner], requested: [], suspended: []), "Other UUID does not inherit selection")
        check(!BLEConnectionPolicy.mayConnect(id: owner, selected: [owner], requested: [owner], suspended: [owner]), "Failed pairing requires manual retry")
        check(!BLEConnectionPolicy.shouldSuspendAfterFailure(selectedBefore: true, authenticationStarted: false), "Powered-off selected display keeps retrying")
        check(BLEConnectionPolicy.shouldSuspendAfterFailure(selectedBefore: true, authenticationStarted: true), "Authentication cancellation cannot create a prompt loop")
        check(BLEConnectionPolicy.shouldSuspendAfterFailure(selectedBefore: false, authenticationStarted: false), "Failed first selection needs a manual retry")
        check(!BLEConnectionPolicy.mayConnect(id: owner, selected: [owner], requested: [owner], suspended: [], classicConnected: true), "Connected classic transport blocks a duplicate BLE connection")
        check(BLEConnectionPolicy.usesClassicConnection(name: " AgentRing-vivoX21A ", connectedNames: ["agentring-vivoX21A"]), "Correlate the advertised name with active classic transport")
        check(!BLEConnectionPolicy.usesClassicConnection(name: "AgentRing-LCD-C361", connectedNames: ["AgentRing-vivoX21A"]), "Classic Android never suppresses another LCD")
        let classicState = BluetoothDeviceConnectionState.resolve(classicConnected: true, bleConnected: false, connecting: false)
        check(classicState == .classicConnected && !classicState.canConnectBLE, "Classic connected row cannot offer BLE pairing")
        check(classicState.statusMessage(diagnostic: "服务发现失败") == "已通过经典蓝牙连接，无需 BLE 配对。", "Stale BLE error is hidden when classic is connected")
        check(BluetoothDeviceConnectionState.resolve(classicConnected: true, bleConnected: false, connecting: true) == .classicConnected, "Classic success supersedes a redundant pending BLE attempt")
        check(BluetoothDeviceConnectionState.resolve(classicConnected: false, bleConnected: true, connecting: false).statusMessage(diagnostic: "服务发现失败") == "已通过 BLE 连接，正在同步本机数据", "BLE success supersedes a stale diagnostic")
        let connectingState = BluetoothDeviceConnectionState.resolve(classicConnected: false, bleConnected: false, connecting: true)
        check(connectingState == .connecting && !connectingState.canConnectBLE, "Connecting button cannot be clicked repeatedly")
        check(BluetoothDeviceConnectionState.resolve(classicConnected: false, bleConnected: false, connecting: false).canConnectBLE, "Disconnected LCD remains connectable")
        var handshake = BLEBindingHandshake()
        check(!handshake.verifyIdentity(), "Cannot verify identity before requesting security")
        check(!handshake.acknowledgeWrite() && handshake.stage == .readIdentity, "Request ACK never authorizes data")
        check(!handshake.acknowledgeWrite(), "Duplicate request ACK never authorizes data")
        check(handshake.verifyIdentity() && handshake.stage == .writeHostName, "Identity must be validated before host write")
        check(handshake.acknowledgeWrite() && handshake.stage == .ready, "Host write ACK completes handshake")
        check(!handshake.acknowledgeWrite(), "Duplicate host ACK cannot complete handshake twice")
        check(BLEBindingHandshake.canWaitForEncryption(isATTError: true, code: 5), "Wait for authentication")
        check(BLEBindingHandshake.canWaitForEncryption(isATTError: true, code: 15), "Wait for encryption")
        check(!BLEBindingHandshake.canWaitForEncryption(isATTError: false, code: 5), "Do not retry unrelated errors")
        check(!BLEBindingHandshake.canWaitForEncryption(isATTError: true, code: 12), "Weak key is rejected")
        for name in ["AgentRing-LCD-7331", "AgentRing-ESP32-LCD", "AgentRing-esp32"] {
            check(BLEConnectionPolicy.requiresBinding(name: name), "LCD must not downgrade")
        }
        check(!BLEConnectionPolicy.requiresBinding(name: "AgentRing-Android"), "Legacy manually selected BLE display remains compatible")
        for json in ["{}", "{\"protocol\":1,\"deviceId\":\"AABBCCDDEEFF\"}", "{\"protocol\":2,\"deviceId\":\"name\"}", "{\"protocol\":2,\"deviceId\":\"GGHHCCDDEEFF\"}"] {
            check(!BLEConnectionPolicy.validBindingResponse(Data(json.utf8)), "Reject unsupported or malformed handshake")
        }
        check(BLEConnectionPolicy.validBindingResponse(Data("{\"protocol\":2,\"deviceId\":\"AABBCCDDEEFF\"}".utf8)), "Accept protocol v2 device identity")
        let label = BLEConnectionPolicy.hostLabel(String(repeating: "郝瑞的 Mac", count: 30) + "\n\u{0000}")
        check(label.utf8.count <= 64 && !label.contains("\n"), "Host labels remain valid bounded UTF-8")
        check(BLEConnectionPolicy.hostLabel("\n\r") == "Mac", "Empty sanitized label has a fallback")
        print("PASS: BLE selection, retries, handshake stages, security waits, classic/BLE row states, LCD downgrade and UTF-8 labels")
    }
}
