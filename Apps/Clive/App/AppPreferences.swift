import Foundation
import Observation
import SwiftUI

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
}
