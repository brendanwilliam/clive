import Foundation
import Observation
import SwiftUI
import CliveCore

struct CLIShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

struct AppPreferences: Codable, Equatable {
    var allowsCellularConnections = false
    var defaultDirectoryPath = ""
    var shortcuts: [CLIShortcut] = []
    var connectionIndicators: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case allowsCellularConnections, defaultDirectoryPath, shortcuts, connectionIndicators
    }

    init(allowsCellularConnections: Bool = false, defaultDirectoryPath: String = "", shortcuts: [CLIShortcut] = [], connectionIndicators: [String: String] = [:]) {
        self.allowsCellularConnections = allowsCellularConnections
        self.defaultDirectoryPath = defaultDirectoryPath
        self.shortcuts = shortcuts
        self.connectionIndicators = connectionIndicators
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowsCellularConnections = try values.decodeIfPresent(Bool.self, forKey: .allowsCellularConnections) ?? false
        defaultDirectoryPath = try values.decodeIfPresent(String.self, forKey: .defaultDirectoryPath) ?? ""
        shortcuts = try values.decodeIfPresent([CLIShortcut].self, forKey: .shortcuts) ?? []
        connectionIndicators = try values.decodeIfPresent([String: String].self, forKey: .connectionIndicators) ?? [:]
    }
}

struct AppPreferencesStore {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Clive")
    }

    private var url: URL { rootURL.appending(path: "preferences.json") }

    func load() throws -> AppPreferences {
        try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url))
    }

    func save(_ preferences: AppPreferences) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

@MainActor @Observable final class AppPreferencesModel {
    var value: AppPreferences {
        didSet { try? store.save(value) }
    }

    private let store: AppPreferencesStore

    init(store: AppPreferencesStore = AppPreferencesStore()) {
        self.store = store
        value = (try? store.load()) ?? AppPreferences()
    }

    func addShortcut() {
        value.shortcuts.append(CLIShortcut(name: "New shortcut", command: ""))
    }

    func deleteShortcuts(at offsets: IndexSet) {
        value.shortcuts.remove(atOffsets: offsets)
    }

    func moveShortcuts(from offsets: IndexSet, to destination: Int) {
        value.shortcuts.move(fromOffsets: offsets, toOffset: destination)
    }

    func indicator(for mac: PairedMac) -> String {
        let saved = value.connectionIndicators[mac.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return String(saved.prefix(2)) }
        let words = mac.displayName.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let initials = words.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        return initials.isEmpty ? "⌘" : initials
    }

    func setIndicator(_ indicator: String, for mac: PairedMac) {
        value.connectionIndicators[mac.id] = String(indicator.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2))
    }
}
