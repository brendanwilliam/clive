import Foundation
import CliveCore
import XCTest
@testable import Clive

final class AppPreferencesTests: XCTestCase {
    func testDefaultsDisableCellularAndUseHomeDirectory() {
        let preferences = AppPreferences()

        XCTAssertFalse(preferences.allowsCellularConnections)
        XCTAssertEqual(preferences.defaultDirectoryPath, "")
        XCTAssertTrue(preferences.shortcuts.isEmpty)
        XCTAssertTrue(preferences.connectionIndicators.isEmpty)
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

    func testLegacyPreferencesDecodeWithoutConnectionIndicators() throws {
        let data = Data(#"{"allowsCellularConnections":true,"defaultDirectoryPath":"~/Code","shortcuts":[]}"#.utf8)

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertTrue(preferences.allowsCellularConnections)
        XCTAssertEqual(preferences.defaultDirectoryPath, "~/Code")
        XCTAssertTrue(preferences.connectionIndicators.isEmpty)
    }

    @MainActor
    func testConnectionIndicatorDefaultsToInitialsAndCanUseEmoji() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppPreferencesModel(store: AppPreferencesStore(rootURL: root))
        let mac = PairedMac(
            id: "mac-1",
            displayName: "Brendan's MacBook Pro",
            serviceID: "service",
            certificateFingerprint: "fingerprint",
            createdAt: Date()
        )

        XCTAssertEqual(model.indicator(for: mac), "BM")

        model.setIndicator("🧑‍💻", for: mac)

        XCTAssertEqual(model.indicator(for: mac), "🧑‍💻")
    }
}
