import SwiftUI
import IPhoneTerminalCore

struct WorkspaceView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingConnections = false
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.state {
                case .active: workspace
                case .locked, .authenticating: ProgressView("Authenticating…")
                case .authenticationCancelled: ContentUnavailableView("Authentication cancelled", systemImage: "faceid")
                case .failed(let message): ContentUnavailableView("Connection failed", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("New shell", systemImage: "plus") { coordinator.addShell() }.disabled(coordinator.state != .active || coordinator.selectedMac == nil) }
                ToolbarItem(placement: .principal) { connectionTitle }
                ToolbarItem(placement: .topBarTrailing) { Button("Connections", systemImage: "gearshape") { showingConnections = true } }
            }
        }
        .task { coordinator.start(); await coordinator.authorize(); if coordinator.selectedMac == nil { showingConnections = true } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { coordinator.sceneDidBackground() } else if coordinator.state == .locked { Task { await coordinator.authorize() } } }
        .sheet(isPresented: $showingConnections) { connectionSwitcher }
        .sheet(isPresented: $showingScanner) { PairingScannerView(onTicket: { ticket in showingScanner = false; Task { await coordinator.macs.pair(ticket) } }, onError: { error in showingScanner = false; coordinator.macs.state = .failed(error.localizedDescription) }).ignoresSafeArea() }
    }

    private var connectionTitle: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.green)
            Text(coordinator.selectedMac?.displayName ?? "iPhone Terminal")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(.green)
        }
        .accessibilityLabel("Active connection to \(coordinator.selectedMac?.displayName ?? "iPhone Terminal")")
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if coordinator.sessions.isEmpty { ContentUnavailableView("No shell", systemImage: "terminal", description: Text("Create a shell to connect.")) }
            else {
                TabView(selection: $coordinator.selectedSessionID) {
                    ForEach(coordinator.sessions) { session in
                        ZStack { TerminalSurfaceView(session: session.client); sessionOverlay(session) }.tag(Optional(session.id))
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
                HStack(spacing: 7) { ForEach(coordinator.sessions) { session in Circle().fill(session.id == coordinator.selectedSessionID ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 6, height: 6) } }.padding(8)
            }
        }
    }

    private var connectionSwitcher: some View {
        NavigationStack {
            List {
                Section("Paired Macs") { ForEach(coordinator.macs.devices) { mac in Button { coordinator.selectMac(mac); showingConnections = false } label: { HStack { Text(mac.displayName); Spacer(); Text(routeStatus(mac)).foregroundStyle(.secondary); if mac.id == coordinator.selectedMacID { Image(systemName: "checkmark") } } } } }
                if !coordinator.sessions.isEmpty { Section("Sessions") { ForEach(coordinator.sessions) { session in HStack { VStack(alignment: .leading) { Text(session.descriptor.label); if let preview = session.preview { Text(preview).lineLimit(1).foregroundStyle(.secondary) } }; Spacer(); Button("Close") { coordinator.close(session) }.labelStyle(.iconOnly) } } } }
                Section { Button("Add Connection", systemImage: "qrcode.viewfinder") { showingScanner = true } } footer: { Text("Remote access uses the private VPN endpoint supplied during pairing.") }
            }
            .navigationTitle("Connections")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingConnections = false } } }
        }
    }

    private func routeStatus(_ mac: PairedMac) -> String { coordinator.macs.route(for: mac) != nil ? "Nearby" : mac.remoteEndpoint != nil ? "VPN" : "Unavailable" }
    @ViewBuilder private func sessionOverlay(_ session: WorkspaceSession) -> some View {
        switch session.state {
        case .active: EmptyView()
        case .connecting: ProgressView("Connecting…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .disconnected: ContentUnavailableView("Disconnected", systemImage: "network.slash")
        case .revoked: ContentUnavailableView("Access revoked", systemImage: "lock.slash")
        case .certificateChanged: ContentUnavailableView("Certificate changed", systemImage: "exclamationmark.shield")
        case .protocolError: ContentUnavailableView("Protocol error", systemImage: "exclamationmark.triangle")
        case .networkError(let message): ContentUnavailableView("VPN unavailable", systemImage: "wifi.exclamationmark", description: Text(message))
        }
    }
}
