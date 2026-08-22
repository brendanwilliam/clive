import Foundation
import Observation
import SwiftUI
import CliveCore
import UIKit
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
    var connectionIndicators: [String: String] = [:]
    var connectionIndicatorColors: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case allowsCellularConnections, defaultDirectoryPath, shortcuts, newTerminalDefaultShortcutID, connectionIndicators, connectionIndicatorColors
    }

    init(allowsCellularConnections: Bool = false, shortcuts: [CLIShortcut] = [], newTerminalDefaultShortcutID: UUID? = nil, connectionIndicators: [String: String] = [:], connectionIndicatorColors: [String: String] = [:]) {
        self.allowsCellularConnections = allowsCellularConnections
        self.shortcuts = shortcuts; self.newTerminalDefaultShortcutID = newTerminalDefaultShortcutID
        normalizeDefaultSelection()
        self.connectionIndicators = connectionIndicators
        self.connectionIndicatorColors = connectionIndicatorColors
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowsCellularConnections = try values.decodeIfPresent(Bool.self, forKey: .allowsCellularConnections) ?? false
        shortcuts = try values.decodeIfPresent([CLIShortcut].self, forKey: .shortcuts) ?? []
        newTerminalDefaultShortcutID = try values.decodeIfPresent(UUID.self, forKey: .newTerminalDefaultShortcutID)
        connectionIndicators = try values.decodeIfPresent([String: String].self, forKey: .connectionIndicators) ?? [:]
        connectionIndicatorColors = try values.decodeIfPresent([String: String].self, forKey: .connectionIndicatorColors) ?? [:]
        normalizeDefaultSelection()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(allowsCellularConnections, forKey: .allowsCellularConnections)
        try values.encode(shortcuts, forKey: .shortcuts)
        try values.encodeIfPresent(newTerminalDefaultShortcutID, forKey: .newTerminalDefaultShortcutID)
        try values.encode(connectionIndicators, forKey: .connectionIndicators)
        try values.encode(connectionIndicatorColors, forKey: .connectionIndicatorColors)
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

    func indicatorColor(for mac: PairedMac) -> Color {
        Color(hex: value.connectionIndicatorColors[mac.id] ?? "") ?? .accentColor
    }

    func setIndicatorColor(_ color: Color, for mac: PairedMac) {
        guard let components = UIColor(color).cgColor.components else { return }
        let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
        if components.count >= 4 {
            (red, green, blue, alpha) = (components[0], components[1], components[2], components[3])
        } else {
            (red, green, blue, alpha) = (components[0], components[0], components[0], components.count > 1 ? components[1] : 1)
        }
        value.connectionIndicatorColors[mac.id] = String(format: "#%02X%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255), Int(alpha * 255))
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

private extension Color {
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 8, let rgba = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgba >> 24) & 0xff) / 255,
            green: Double((rgba >> 16) & 0xff) / 255,
            blue: Double((rgba >> 8) & 0xff) / 255,
            opacity: Double(rgba & 0xff) / 255
        )
    }
}
