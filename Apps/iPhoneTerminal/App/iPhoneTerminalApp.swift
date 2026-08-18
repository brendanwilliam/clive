import SwiftUI

@main
struct iPhoneTerminalApp: App {
    @State private var model = PairedMacsModel()

    var body: some Scene {
        WindowGroup {
            PairedMacListView(model: model)
        }
    }
}
