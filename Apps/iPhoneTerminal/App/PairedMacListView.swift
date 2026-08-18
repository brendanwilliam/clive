import SwiftUI

struct PairedMacListView: View {
    @Bindable var model: PairedMacsModel
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            List(model.devices) { device in
                if let route = model.route(for: device) { NavigationLink(device.displayName) { TerminalTabsView(device: device, route: route) } }
            }
            .navigationTitle("My Macs")
            .toolbar { Button("Pair Mac", systemImage: "qrcode.viewfinder") { showingScanner = true } }
            .overlay {
                if model.devices.isEmpty { ContentUnavailableView("No paired Macs available", systemImage: "laptopcomputer.and.iphone", description: Text("Start the daemon or scan a pairing QR code.")) }
                if model.state == .pairing { ProgressView("Waiting for approval on Mac…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) }
            }
            .alert("iPhone Terminal", isPresented: Binding(get: { if case .failed = model.state { true } else { false } }, set: { if !$0 { model.state = .idle } })) {
                Button("OK") { model.state = .idle }
            } message: { if case .failed(let message) = model.state { Text(message) } }
        }
        .sheet(isPresented: $showingScanner) {
            PairingScannerView(onTicket: { ticket in showingScanner = false; Task { await model.pair(ticket) } }, onError: { error in showingScanner = false; model.state = .failed(error.localizedDescription) }).ignoresSafeArea()
        }
        .task { model.start() }
    }
}
