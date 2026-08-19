import SwiftUI
import CliveCore
import UIKit

struct WorkspaceView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.state {
                case .active: workspace
                case .locked, .authenticating: ProgressView("Authenticating…")
                case .authenticationCancelled:
                    ContentUnavailableView {
                        Label("Authentication cancelled", systemImage: "faceid")
                    } actions: {
                        Button("Try Again") { Task { await coordinator.authorize() } }
                    }
                case .failed(let message): ContentUnavailableView("Connection failed", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { coordinator.showTerminalList() } label: { Label("Terminals: \(coordinator.sessions.count)", systemImage: "terminal") } }
                ToolbarItem(placement: .principal) { connectionTitle }
                ToolbarItem(placement: .topBarTrailing) { Button("New shell", systemImage: "plus") { coordinator.addShell() }.disabled(coordinator.state != .active || coordinator.selectedMac == nil) }
            }
        }
        .task { coordinator.start(); ExternalLaunchRequestStore().consumePending(); await coordinator.authorize() }
        .onOpenURL { url in if ExternalLaunchURL.matches(url) { coordinator.handleExternalLaunch() } }
        .onReceive(NotificationCenter.default.publisher(for: .externalTerminalLaunchRequested)) { _ in coordinator.handleExternalLaunch() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { coordinator.sceneDidBackground() }
            else if coordinator.state == .locked { Task { ExternalLaunchRequestStore().consumePending(); await coordinator.authorize() } }
            else if ExternalLaunchRequestStore().consumePending() { coordinator.handleExternalLaunch() }
        }
        .sheet(isPresented: terminalListBinding) { home }
        .sheet(isPresented: settingsBinding) { settings }
    }

    private var connectionTitle: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.green)
            Text(coordinator.selectedMac?.displayName ?? "Clive")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(.green)
        }
        .accessibilityLabel("Active connection to \(coordinator.selectedMac?.displayName ?? "Clive")")
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if let recovery = coordinator.recovery { recoveryView(recovery) }
            else if coordinator.sessions.isEmpty { ContentUnavailableView("No shell", systemImage: "terminal", description: Text("Create a shell to connect.")) }
            else {
                TabView(selection: Binding(get: { coordinator.selectedSessionID }, set: { coordinator.selectSession($0) })) {
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
                ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { coordinator.showSettings() } }
                ToolbarItem(placement: .bottomBar) { Button("Done") { coordinator.dismissPresentedScreen() } }
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
                Section("Paired Macs") { ForEach(coordinator.macs.devices) { mac in Button { coordinator.selectMac(mac) } label: { HStack { Text(mac.displayName); Spacer(); Text(routeStatus(mac)).foregroundStyle(.secondary); if mac.id == coordinator.selectedMacID { Image(systemName: "checkmark") } } } } }
                Section { Button("Add Connection", systemImage: "qrcode.viewfinder") { showingScanner = true }; Button("Refresh cellular routes", systemImage: "arrow.clockwise") { Task { await coordinator.macs.refreshRendezvous() } } } footer: { Text("Nearby connections are preferred. Cellular uses encrypted, short-lived direct-WAN metadata from the same Apple Account; terminal traffic never passes through iCloud.") }
                if coordinator.selectedMac != nil { Section { Button("Disconnect", systemImage: "network.slash", role: .destructive) { coordinator.disconnectCurrentMac(); coordinator.dismissPresentedScreen() } } }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { coordinator.dismissPresentedScreen() } } }
        }
        .fullScreenCover(isPresented: $showingScanner) {
            PairingScannerView(
                onTicket: { ticket in
                    showingScanner = false
                    Task { await coordinator.macs.pair(ticket) }
                },
                onError: { error in
                    showingScanner = false
                    coordinator.macs.state = .failed(error.localizedDescription)
                }
            )
            .ignoresSafeArea()
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

    private func routeStatus(_ mac: PairedMac) -> String {
        if coordinator.macs.route(for: mac) != nil { return "Nearby" }
        if mac.remoteEndpoint != nil { return "VPN" }
        if !coordinator.macs.cellularRoutes(for: mac).isEmpty { return "Cellular" }
        return coordinator.macs.rendezvousDiagnostics[mac.id] == nil ? "Unavailable" : "Configuration required"
    }

    private var terminalListBinding: Binding<Bool> {
        Binding(get: { coordinator.presentedScreen == .terminalList }, set: { if !$0 { coordinator.dismissPresentedScreen() } })
    }

    private var settingsBinding: Binding<Bool> {
        Binding(get: { coordinator.presentedScreen == .settings }, set: { if !$0 { coordinator.dismissPresentedScreen() } })
    }

    @ViewBuilder private func recoveryView(_ recovery: WorkspaceCoordinator.Recovery) -> some View {
        switch recovery {
        case .unavailableMac(let name):
            ContentUnavailableView {
                Label("Mac unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text("\(name) is offline or has no reachable connection route.")
            } actions: {
                Button("Retry") { coordinator.retryConnection() }
                Button("Choose Mac") { coordinator.showSettings() }
            }
        case .noPairedMac:
            ContentUnavailableView {
                Label("No paired Mac", systemImage: "laptopcomputer.and.iphone")
            } description: {
                Text("Pair a Mac before starting a terminal.")
            } actions: {
                Button("Add Connection") { showingScanner = true }
            }
        }
    }

    @ViewBuilder private func sessionOverlay(_ session: WorkspaceSession) -> some View {
        switch session.state {
        case .active: EmptyView()
        case .connecting: ProgressView("Connecting…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .disconnected: ContentUnavailableView("Disconnected", systemImage: "network.slash")
        case .revoked:
            ContentUnavailableView { Label("Access revoked", systemImage: "lock.slash") } description: { Text("Pair this iPhone with the Mac again.") } actions: { Button("Pair Again") { showingScanner = true } }
        case .certificateChanged:
            ContentUnavailableView { Label("Certificate changed", systemImage: "exclamationmark.shield") } description: { Text("Verify the Mac locally before pairing it again.") } actions: { Button("Pair Again") { showingScanner = true } }
        case .protocolError: ContentUnavailableView("Protocol error", systemImage: "exclamationmark.triangle")
        case .networkError(let message):
            ContentUnavailableView { Label("Connection unavailable", systemImage: "wifi.exclamationmark") } description: { Text(message) } actions: { Button("Retry") { coordinator.retryConnection() }; Button("Choose Mac") { coordinator.showSettings() } }
        }
    }
}
