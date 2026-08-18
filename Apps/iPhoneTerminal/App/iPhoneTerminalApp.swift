import SwiftUI

@main
struct iPhoneTerminalApp: App {
    @State private var coordinator = WorkspaceCoordinator()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(coordinator: coordinator)
        }
    }
}
