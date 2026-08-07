import SwiftUI

struct PairedMacListView: View {
    @Bindable var model: PairedMacsModel

    var body: some View {
        NavigationStack {
            List(model.devices) { device in
                NavigationLink(device.displayName) {
                    TerminalTabsView(device: device)
                }
            }
            .navigationTitle("My Macs")
            .toolbar {
                Button("Pair Mac", systemImage: "qrcode.viewfinder") {
                    // Present the QR scanner after LocalAuthentication approval.
                }
            }
            .overlay {
                if model.devices.isEmpty {
                    ContentUnavailableView("No paired Macs", systemImage: "laptopcomputer.and.iphone", description: Text("Scan a pairing QR code from iphone-terminald."))
                }
            }
        }
        .task { model.refresh() }
    }
}
