import SwiftUI
import IPhoneTerminalCore
import UIKit

struct WorkspaceView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingHome = false
    @State private var showingSettings = false
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
                ToolbarItem(placement: .topBarLeading) { Button { showingHome = true } label: { Label("Terminals: \(coordinator.sessions.count)", systemImage: "terminal") } }
                ToolbarItem(placement: .principal) { connectionTitle }
                ToolbarItem(placement: .topBarTrailing) { Button("New shell", systemImage: "plus") { coordinator.addShell() }.disabled(coordinator.state != .active || coordinator.selectedMac == nil) }
            }
        }
        .task { coordinator.start(); await coordinator.authorize(); if coordinator.selectedMac == nil { showingSettings = true } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { coordinator.sceneDidBackground() } else if coordinator.state == .locked { Task { await coordinator.authorize() } } }
        .sheet(isPresented: $showingHome) { home }
        .sheet(isPresented: $showingSettings) { settings }
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
            }
        }
    }

    private var home: some View {
        NavigationStack {
            List {
                Section { ForEach(coordinator.sessions) { session in terminalRow(session) } } header: { Text("Active terminals") }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text(coordinator.selectedMac?.displayName ?? "No connection").font(.subheadline.weight(.medium)) }
                ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { showingSettings = true } }
                ToolbarItem(placement: .bottomBar) { Button("Done") { showingHome = false } }
            }
        }
    }

    private func terminalRow(_ session: WorkspaceSession) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(session.descriptor.label)
                if let preview = session.preview { Text(preview).lineLimit(1).foregroundStyle(.secondary) }
            }
            Spacer()
            Menu {
                Button("Rename", systemImage: "pencil") { rename(session) }
                Button("Close", systemImage: "xmark", role: .destructive) { coordinator.close(session) }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private var settings: some View {
        NavigationStack {
            List {
                Section("Paired Macs") { ForEach(coordinator.macs.devices) { mac in Button { coordinator.selectMac(mac); showingSettings = false } label: { HStack { Text(mac.displayName); Spacer(); Text(routeStatus(mac)).foregroundStyle(.secondary); if mac.id == coordinator.selectedMacID { Image(systemName: "checkmark") } } } } }
                Section { Button("Add Connection", systemImage: "qrcode.viewfinder") { showingScanner = true } } footer: { Text("Remote access uses the private VPN endpoint supplied during pairing.") }
                if coordinator.selectedMac != nil { Section { Button("Disconnect", systemImage: "network.slash", role: .destructive) { coordinator.disconnectCurrentMac(); showingSettings = false } } }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingSettings = false } } }
        }
    }

    private func rename(_ session: WorkspaceSession) {
        // A focused rename sheet keeps the Home list compact while retaining its context.
        let controller = UIAlertController(title: "Rename terminal", message: nil, preferredStyle: .alert)
        controller.addTextField { $0.text = session.descriptor.label }
        controller.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        controller.addAction(UIAlertAction(title: "Save", style: .default) { _ in coordinator.rename(session, to: controller.textFields?.first?.text ?? "") })
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first?.present(controller, animated: true)
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
