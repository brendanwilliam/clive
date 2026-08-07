import Foundation

public actor TrustStore {
    private let url: URL
    private var devices: [PairedDevice]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            devices = try JSONDecoder().decode([PairedDevice].self, from: Data(contentsOf: url))
        } else {
            devices = []
        }
    }

    public func all() -> [PairedDevice] { devices.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending } }

    public func device(id: String) -> PairedDevice? { devices.first { $0.id == id } }

    public func upsert(_ device: PairedDevice) throws {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        try persist()
    }

    public func revoke(id: String) throws -> Bool {
        let oldCount = devices.count
        devices.removeAll { $0.id == id }
        guard devices.count != oldCount else { return false }
        try persist()
        return true
    }

    private func persist() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(devices)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
