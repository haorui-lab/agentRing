import Foundation

nonisolated public struct BLEDiscoveredDevice: Identifiable, Equatable, Sendable {
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

nonisolated struct ClassicDisplayConnection: Identifiable, Equatable, Sendable {
    let id: String // Normalized paired device address
    let name: String
}

/// Retain advertisements across short scan windows while bounding the lifetime
/// of both the discovery row and its CoreBluetooth peripheral reference.
nonisolated struct BLEDiscoveryCache<Peripheral> {
    static var lifetime: TimeInterval { 60 }

    struct Entry {
        let row: BLEDiscoveredDevice
        let peripheral: Peripheral
        let lastSeen: Date
    }

    private var entries: [UUID: Entry] = [:]
    subscript(id: UUID) -> Entry? { entries[id] }
    var rows: [UUID: BLEDiscoveredDevice] { entries.mapValues(\.row) }

    mutating func record(_ peripheral: Peripheral, id: UUID, name: String, rssi: Int, at time: Date) {
        let row = BLEDiscoveredDevice(id: id, name: name, rssi: rssi, isConnected: false)
        entries[id] = Entry(row: row, peripheral: peripheral, lastSeen: time)
    }

    mutating func removeStale(before cutoff: Date, keeping inUse: Set<UUID>) -> Set<UUID> {
        let expired = Set(entries.compactMap { id, entry in
            entry.lastSeen < cutoff && !inUse.contains(id) ? id : nil
        })
        for id in expired { entries.removeValue(forKey: id) }
        return expired
    }
}

nonisolated struct BluetoothDeviceList {
    let bleDevices: [BLEDiscoveredDevice]
    let classicConnections: [ClassicDisplayConnection]
    let savedBLEUsingClassic: [BLEDiscoveredDevice]

    init(discovered: [BLEDiscoveredDevice], selected: [UUID: String], classic: [ClassicDisplayConnection]) {
        let names = Set(classic.map(\.name))
        classicConnections = classic
        var rows = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        for (id, name) in selected where rows[id] == nil {
            rows[id] = BLEDiscoveredDevice(id: id, name: name, rssi: 0, isConnected: false)
        }
        // An SPP connection supplies its own row. Same-name advertisements
        // cannot identify it. Keep saved BLE entries accessible for forgetting.
        let sorted = rows.values.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
        bleDevices = sorted.filter { !BLEConnectionPolicy.usesClassicConnection(name: $0.name, connectedNames: names) }
        savedBLEUsingClassic = sorted.filter {
            selected[$0.id] != nil && BLEConnectionPolicy.usesClassicConnection(name: $0.name, connectedNames: names)
        }
    }
}
