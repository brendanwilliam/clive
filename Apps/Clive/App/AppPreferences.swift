import Foundation
import Observation
import SwiftUI
import CliveCore
import WidgetKit

struct CLIShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String, command: String = "") {
        self.id = id
        self.name = name
        self.command = command
    }

    private enum CodingKeys: String, CodingKey { case id, name, command, workingDirectory }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(command, forKey: .command)
    }
}

struct AppPreferences: Codable, Equatable {
    var allowsCellularConnections = false
    var shortcuts: [CLIShortcut] = []
    var newTerminalDefaultShortcutID: UUID?

    private enum CodingKeys: String, CodingKey {
        case allowsCellularConnections, defaultDirectoryPath, shortcuts, newTerminalDefaultShortcutID, connectionIndicators, connectionIndicatorColors
    }

    init(allowsCellularConnections: Bool = false, shortcuts: [CLIShortcut] = [], newTerminalDefaultShortcutID: UUID? = nil) {
        self.allowsCellularConnections = allowsCellularConnections
        self.shortcuts = shortcuts; self.newTerminalDefaultShortcutID = newTerminalDefaultShortcutID
        normalizeDefaultSelection()
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowsCellularConnections = try values.decodeIfPresent(Bool.self, forKey: .allowsCellularConnections) ?? false
        shortcuts = try values.decodeIfPresent([CLIShortcut].self, forKey: .shortcuts) ?? []
        newTerminalDefaultShortcutID = try values.decodeIfPresent(UUID.self, forKey: .newTerminalDefaultShortcutID)
        normalizeDefaultSelection()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(allowsCellularConnections, forKey: .allowsCellularConnections)
        try values.encode(shortcuts, forKey: .shortcuts)
        try values.encodeIfPresent(newTerminalDefaultShortcutID, forKey: .newTerminalDefaultShortcutID)
    }

    mutating func normalizeDefaultSelection() {
        guard let selected = newTerminalDefaultShortcutID else { return }
        if !shortcuts.contains(where: { $0.id == selected && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            newTerminalDefaultShortcutID = nil
        }
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
        var sanitized = preferences
        sanitized.normalizeDefaultSelection()
        try JSONEncoder().encode(sanitized).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

@MainActor @Observable final class AppPreferencesModel {
    var value: AppPreferences {
        didSet {
            try? store.save(value)
            WidgetShortcutStore.save(value.shortcuts)
        }
    }

    private let store: AppPreferencesStore

    init(store: AppPreferencesStore = AppPreferencesStore()) {
        self.store = store
        value = (try? store.load()) ?? AppPreferences()
        WidgetShortcutStore.save(value.shortcuts)
    }

    func addShortcut() {
        value.shortcuts.append(CLIShortcut(name: "New shortcut", command: ""))
    }

    @discardableResult
    func saveShortcut(name: String, command: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return false }
        let duplicate = value.shortcuts.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(name) == .orderedSame ||
            $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == command
        }
        guard !duplicate else { return false }
        value.shortcuts.append(CLIShortcut(name: name, command: command))
        return true
    }

    func deleteShortcuts(at offsets: IndexSet) {
        let removed = Set(offsets.compactMap { value.shortcuts.indices.contains($0) ? value.shortcuts[$0].id : nil })
        value.shortcuts.remove(atOffsets: offsets)
        if let selected = value.newTerminalDefaultShortcutID, removed.contains(selected) { value.newTerminalDefaultShortcutID = nil }
    }

    func deleteShortcut(id: UUID) {
        guard let index = value.shortcuts.firstIndex(where: { $0.id == id }) else { return }
        deleteShortcuts(at: IndexSet(integer: index))
    }

    func updateShortcut(id: UUID, name: String, command: String) {
        guard let index = value.shortcuts.firstIndex(where: { $0.id == id }) else { return }
        value.shortcuts[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.shortcuts[index].command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        value.normalizeDefaultSelection()
    }

    func moveShortcuts(from offsets: IndexSet, to destination: Int) {
        value.shortcuts.move(fromOffsets: offsets, toOffset: destination)
    }

}

enum WidgetShortcutStore {
    static let key = "widget.shortcuts"

    static func choices(for shortcuts: [CLIShortcut]) -> [[String: String]] {
        shortcuts.compactMap { shortcut -> [String: String]? in
            let name = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = shortcut.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || command.isEmpty ? nil : ["id": shortcut.id.uuidString, "name": name]
        }
    }

    static func save(_ shortcuts: [CLIShortcut]) {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CliveAppGroup") as? String,
              let defaults = UserDefaults(suiteName: group) else { return }
        defaults.set(choices(for: shortcuts), forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: "CliveResumeWidget")
    }
}
