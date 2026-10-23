import Foundation

/// Device names are labels. Only explicit selection permits a connection;
/// LCDs additionally require the secure binding characteristic before data flows.
nonisolated enum BLEConnectionPolicy {
    static func mayConnect(id: UUID, selected: Set<UUID>, requested: Set<UUID>, suspended: Set<UUID>, classicConnected: Bool = false) -> Bool {
        !classicConnected && (selected.contains(id) || requested.contains(id)) && !suspended.contains(id)
    }

    // Name correlation suppresses a redundant transport; it never authorizes
    // BLE data or replaces the LCD's cryptographic identity check.
    static func usesClassicConnection(name: String, connectedNames: Set<String>) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !key.isEmpty && connectedNames.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
    }

    static func shouldSuspendAfterFailure(selectedBefore: Bool, authenticationStarted: Bool) -> Bool {
        !selectedBefore || authenticationStarted
    }

    static func requiresBinding(name: String) -> Bool {
        name.localizedCaseInsensitiveContains("LCD") || name.localizedCaseInsensitiveContains("ESP32")
    }

    static func validBindingResponse(_ data: Data) -> Bool {
        struct Response: Decodable { let `protocol`: Int; let deviceId: String }
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else { return false }
        return value.protocol == 2 && value.deviceId.count == 12 &&
            value.deviceId.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (65...70).contains($0.value) }
    }

    static func hostLabel(_ name: String) -> String {
        var result = ""
        for character in name where !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            guard result.utf8.count + String(character).utf8.count <= 64 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Mac" : result
    }
}

/// Security-request acknowledgement is not authentication. A validated identity
/// and a separate acknowledged host-label write are required before quota data.
nonisolated struct BLEBindingHandshake {
    enum Stage { case requestSecurity, readIdentity, writeHostName, ready }
    private(set) var stage: Stage = .requestSecurity

    mutating func acknowledgeWrite() -> Bool {
        switch stage {
        case .requestSecurity: stage = .readIdentity; return false
        case .writeHostName: stage = .ready; return true
        case .readIdentity, .ready: return false
        }
    }

    mutating func verifyIdentity() -> Bool {
        guard stage == .readIdentity else { return false }
        stage = .writeHostName
        return true
    }

    static func canWaitForEncryption(isATTError: Bool, code: Int) -> Bool {
        isATTError && (code == 5 || code == 15) // Insufficient Authentication / Encryption
    }
}

/// Resolve the actual transport before showing BLE diagnostics or actions.
nonisolated enum BluetoothDeviceConnectionState {
    case classicConnected, bleConnected, connecting, disconnected

    static func resolve(classicConnected: Bool, bleConnected: Bool, connecting: Bool) -> Self {
        if classicConnected { return .classicConnected }
        if bleConnected { return .bleConnected }
        return connecting ? .connecting : .disconnected
    }

    var canConnectBLE: Bool { self == .disconnected }

    func statusMessage(diagnostic: String?) -> String? {
        switch self {
        case .classicConnected: return "已通过经典蓝牙连接，无需 BLE 配对。"
        case .bleConnected: return "已通过 BLE 连接，正在同步本机数据"
        case .connecting: return diagnostic ?? "正在连接…"
        case .disconnected: return diagnostic
        }
    }
}
