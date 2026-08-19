import Foundation
import XCTest
@testable import Clive

final class AppPreferencesTests: XCTestCase {
    func testDefaultsDisableCellularAndUseHomeDirectory() {
        let preferences = AppPreferences()

        XCTAssertFalse(preferences.allowsCellularConnections)
        XCTAssertEqual(preferences.defaultDirectoryPath, "")
        XCTAssertTrue(preferences.shortcuts.isEmpty)
    }

    func testStoreRoundTripsOrderedShortcuts() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppPreferencesStore(rootURL: root)
        let preferences = AppPreferences(
            allowsCellularConnections: true,
            defaultDirectoryPath: "~/Projects",
            shortcuts: [
                CLIShortcut(name: "Status", command: "git status --short"),
                CLIShortcut(name: "Tests", command: "swift test")
            ]
        )

        try store.save(preferences)

        XCTAssertEqual(try store.load(), preferences)
    }
}
