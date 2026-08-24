import Foundation
import CliveCore
import XCTest
@testable import Clive

final class AppPreferencesTests: XCTestCase {
    func testDefaultsDisableCellularAndUseHomeDirectory() {
        let preferences = AppPreferences()

        XCTAssertFalse(preferences.allowsCellularConnections)
        XCTAssertTrue(preferences.shortcuts.isEmpty)
    }

    func testStoreRoundTripsOrderedShortcuts() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppPreferencesStore(rootURL: root)
        let preferences = AppPreferences(
            allowsCellularConnections: true,
            shortcuts: [
                CLIShortcut(name: "Status", command: "git status --short"),
                CLIShortcut(name: "Tests", command: "swift test")
            ]
        )

        try store.save(preferences)

        XCTAssertEqual(try store.load(), preferences)
    }

    func testWidgetProjectionSharesOnlyOrderedNamesAndOpaqueIDs() {
        let first = CLIShortcut(name: " Status ", command: " git status ")
        let second = CLIShortcut(name: "Tests", command: "swift test")

        let choices = WidgetShortcutStore.choices(for: [first, second])

        XCTAssertEqual(choices.map { $0["id"] }, [first.id.uuidString, second.id.uuidString])
        XCTAssertEqual(choices.map { $0["name"] }, ["Status", "Tests"])
        XCTAssertFalse(choices.description.contains("git status"))
        XCTAssertFalse(choices.description.contains("swift test"))
    }

    func testWidgetProjectionRejectsIncompleteShortcuts() {
        let valid = CLIShortcut(name: "Status", command: "git status")
        let emptyName = CLIShortcut(name: "  ", command: "pwd")
        let emptyCommand = CLIShortcut(name: "Home", command: "  ")

        XCTAssertEqual(WidgetShortcutStore.choices(for: [emptyName, valid, emptyCommand]).map { $0["id"] }, [valid.id.uuidString])
    }

    func testRetiredPreferenceFieldsAreRejected() throws {
        let shortcutID = UUID()
        let data = Data(#"{"allowsCellularConnections":true,"defaultDirectoryPath":"~/Code","shortcuts":[{"id":"\#(shortcutID.uuidString)","name":"Status","command":"git status","workingDirectory":"~/Status"}]}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(AppPreferences.self, from: data))
    }

    func testMissingRequiredPreferenceFieldsAreRejected() throws {
        let missing = UUID()
        let data = Data(#"{"shortcuts":[],"newTerminalDefaultShortcutID":"\#(missing.uuidString)"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(AppPreferences.self, from: data))
    }

    func testDefaultShortcutWithEmptyCommandIsCleared() throws {
        let shortcut = CLIShortcut(name: "Empty", command: " ")
        let preferences = AppPreferences(shortcuts: [shortcut], newTerminalDefaultShortcutID: shortcut.id)

        XCTAssertNil(preferences.newTerminalDefaultShortcutID)
    }

    func testRetiredPreferenceShapeIsRejected() throws {
        let data = Data(##"{"connectionIndicators":{"mac":"M"},"connectionIndicatorColors":{"mac":"#FFFFFFFF"}}"##.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppPreferences.self, from: data))
    }

    @MainActor
    func testSavingLastCommandAddsShortcut() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppPreferencesModel(store: AppPreferencesStore(rootURL: root))

        XCTAssertTrue(model.saveShortcut(name: "Status", command: "  git status --short  "))

        XCTAssertEqual(model.value.shortcuts.map(\.name), ["Status"])
        XCTAssertEqual(model.value.shortcuts.map(\.command), ["git status --short"])
    }

    @MainActor
    func testSavingShortcutRejectsDuplicateNameOrCommand() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppPreferencesModel(store: AppPreferencesStore(rootURL: root))

        XCTAssertTrue(model.saveShortcut(name: "Status", command: "git status"))
        XCTAssertFalse(model.saveShortcut(name: "status", command: "pwd"))
        XCTAssertFalse(model.saveShortcut(name: "Working directory", command: " git status "))
        XCTAssertEqual(model.value.shortcuts.count, 1)
    }
}
