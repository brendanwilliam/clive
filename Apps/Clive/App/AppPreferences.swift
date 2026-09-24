import Foundation
import Observation
import SwiftUI
import CliveCore
import WidgetKit

private struct PreferenceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(
    in decoder: Decoder,
    allowed: Set<String>
) throws {
    let values = try decoder.container(keyedBy: PreferenceCodingKey.self)
    let unknown = values.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown preference field")
        )
    }
}

struct CLIShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String, command: String = "") {
        self.id = id
        self.name = name
        self.command = command
    }

    private enum CodingKeys: String, CodingKey { case id, name, command }
    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: ["id", "name", "command"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        command = try values.decode(String.self, forKey: .command)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(command, forKey: .command)
    }
}

enum ShortcutCommandPresentation {
    static let defaultMaximumLength = 48

    static func subtitle(for command: String, maximumLength: Int = defaultMaximumLength) -> String {
        let normalized = command
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > maximumLength, maximumLength > 1 else { return normalized }
        return String(normalized.prefix(maximumLength - 1)) + "…"
    }
}

enum TerminalThemePreset: String, Codable, CaseIterable, Hashable, Identifiable {
    case cliveDark
    case dracula
    case solarizedDark
    case solarizedLight
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .cliveDark: return "Clive Dark"
        case .dracula: return "Dracula"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .custom: return "Custom"
        }
    }
}

struct TerminalColorPreference: Codable, Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    static let white = TerminalColorPreference(red: 255, green: 255, blue: 255)
    static let black = TerminalColorPreference(red: 0, green: 0, blue: 0)
    static let cliveANSIPalette: [TerminalColorPreference] = palette([
        0x000000, 0xC23621, 0x25BC24, 0xADAD27,
        0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
        0x818383, 0xFC391F, 0x31E722, 0xEAEC23,
        0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
    ])

    private static func palette(_ values: [UInt32]) -> [TerminalColorPreference] {
        values.map { TerminalColorPreference(hex: $0) }
    }
}

struct AppPreferences: Codable, Equatable {
    var allowsCellularConnections = false
    var shortcuts: [CLIShortcut] = []
    var newTerminalDefaultShortcutID: UUID?
    var terminalTheme: TerminalThemePreset = .cliveDark
    var customTerminalForeground = TerminalColorPreference.white
    var customTerminalBackground = TerminalColorPreference.black
    var customTerminalPalette = TerminalColorPreference.cliveANSIPalette

    private enum CodingKeys: String, CodingKey {
        case allowsCellularConnections, shortcuts, newTerminalDefaultShortcutID
        case terminalTheme, customTerminalForeground, customTerminalBackground, customTerminalPalette
    }

    init(
        allowsCellularConnections: Bool = false,
        shortcuts: [CLIShortcut] = [],
        newTerminalDefaultShortcutID: UUID? = nil,
        terminalTheme: TerminalThemePreset = .cliveDark,
        customTerminalForeground: TerminalColorPreference = .white,
        customTerminalBackground: TerminalColorPreference = .black,
        customTerminalPalette: [TerminalColorPreference] = TerminalColorPreference.cliveANSIPalette
    ) {
        self.allowsCellularConnections = allowsCellularConnections
        self.shortcuts = shortcuts
        self.newTerminalDefaultShortcutID = newTerminalDefaultShortcutID
        self.terminalTheme = terminalTheme
        self.customTerminalForeground = customTerminalForeground
        self.customTerminalBackground = customTerminalBackground
        self.customTerminalPalette = customTerminalPalette
        normalizeDefaultSelection()
        normalizeTerminalPalette()
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            in: decoder,
            allowed: [
                "allowsCellularConnections", "shortcuts", "newTerminalDefaultShortcutID",
                "terminalTheme", "customTerminalForeground", "customTerminalBackground", "customTerminalPalette"
            ]
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowsCellularConnections = try values.decode(Bool.self, forKey: .allowsCellularConnections)
        shortcuts = try values.decode([CLIShortcut].self, forKey: .shortcuts)
        newTerminalDefaultShortcutID = try values.decodeIfPresent(UUID.self, forKey: .newTerminalDefaultShortcutID)
        terminalTheme = try values.decodeIfPresent(TerminalThemePreset.self, forKey: .terminalTheme) ?? .cliveDark
        customTerminalForeground = try values.decodeIfPresent(TerminalColorPreference.self, forKey: .customTerminalForeground) ?? .white
        customTerminalBackground = try values.decodeIfPresent(TerminalColorPreference.self, forKey: .customTerminalBackground) ?? .black
        customTerminalPalette = try values.decodeIfPresent([TerminalColorPreference].self, forKey: .customTerminalPalette) ?? TerminalColorPreference.cliveANSIPalette
        normalizeDefaultSelection()
        normalizeTerminalPalette()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(allowsCellularConnections, forKey: .allowsCellularConnections)
        try values.encode(shortcuts, forKey: .shortcuts)
        try values.encodeIfPresent(newTerminalDefaultShortcutID, forKey: .newTerminalDefaultShortcutID)
        try values.encode(terminalTheme, forKey: .terminalTheme)
        try values.encode(customTerminalForeground, forKey: .customTerminalForeground)
        try values.encode(customTerminalBackground, forKey: .customTerminalBackground)
        try values.encode(customTerminalPalette, forKey: .customTerminalPalette)
    }

    mutating func normalizeDefaultSelection() {
        guard let selected = newTerminalDefaultShortcutID else { return }
        if !shortcuts.contains(where: { $0.id == selected && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            newTerminalDefaultShortcutID = nil
        }
    }

    mutating func normalizeTerminalPalette() {
        if customTerminalPalette.count != 16 {
            customTerminalPalette = TerminalColorPreference.cliveANSIPalette
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
    func loadIfPresent() throws -> AppPreferences? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try load()
    }

    func save(_ preferences: AppPreferences) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var sanitized = preferences
        sanitized.normalizeDefaultSelection()
        sanitized.normalizeTerminalPalette()
        try JSONEncoder().encode(sanitized).write(to: url, options: [.atomic, .completeFileProtection])
    }
    func remove() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}

@MainActor @Observable final class AppPreferencesModel {
    var value: AppPreferences {
        didSet {
            persist(value)
        }
    }

    private let store: AppPreferencesStore
    private let persist: (AppPreferences) -> Void

    init(store: AppPreferencesStore = AppPreferencesStore()) {
        self.store = store
        value = (try? store.load()) ?? AppPreferences()
        persist = { value in
            try? store.save(value)
            WidgetShortcutStore.save(value.shortcuts)
        }
        persist(value)
    }

    #if DEBUG
    init(previewValue: AppPreferences) {
        store = AppPreferencesStore(rootURL: FileManager.default.temporaryDirectory)
        value = previewValue
        persist = { _ in }
    }
    #endif

    func validation(for draft: ShortcutDraft) -> ShortcutValidation {
        ShortcutValidation(draft: draft, existing: value.shortcuts)
    }

    @discardableResult
    func commit(_ draft: ShortcutDraft) -> ShortcutValidation {
        let validation = validation(for: draft)
        guard validation.isValid else { return validation }
        let shortcut = CLIShortcut(id: draft.id ?? UUID(), name: validation.name, command: validation.command)
        if let id = draft.id, let index = value.shortcuts.firstIndex(where: { $0.id == id }) {
            value.shortcuts[index] = shortcut
        } else {
            value.shortcuts.append(shortcut)
        }
        value.normalizeDefaultSelection()
        return validation
    }

    @discardableResult
    func saveShortcut(name: String, command: String) -> Bool {
        commit(ShortcutDraft(name: name, command: command)).isValid
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

    func moveShortcuts(from offsets: IndexSet, to destination: Int) {
        value.shortcuts.move(fromOffsets: offsets, toOffset: destination)
    }

}

struct ShortcutDraft: Equatable {
    var id: UUID?
    var name: String
    var command: String

    init(id: UUID? = nil, name: String = "", command: String = "") {
        self.id = id
        self.name = name
        self.command = command
    }

    init(shortcut: CLIShortcut) {
        self.init(id: shortcut.id, name: shortcut.name, command: shortcut.command)
    }
}

struct ShortcutValidation: Equatable {
    let name: String
    let command: String
    let titleError: String?
    let commandError: String?

    init(draft: ShortcutDraft, existing: [CLIShortcut]) {
        let normalizedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = existing.filter { $0.id != draft.id }
        let titleError: String?
        if normalizedName.isEmpty { titleError = "Enter a title." }
        else if others.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(normalizedName) == .orderedSame }) {
            titleError = "A shortcut already uses this title."
        } else { titleError = nil }

        let commandError: String?
        if normalizedCommand.isEmpty { commandError = "Enter a command." }
        else if others.contains(where: { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCommand }) {
            commandError = "A shortcut already uses this command."
        } else { commandError = nil }
        name = normalizedName
        command = normalizedCommand
        self.titleError = titleError
        self.commandError = commandError
    }

    var isValid: Bool { titleError == nil && commandError == nil }
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
