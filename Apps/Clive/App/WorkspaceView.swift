import CliveCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingScanner = false
    @State private var renameTarget: WorkspaceSession?
    @State private var renameText = ""
    @State private var deleteTarget: WorkspaceSession?
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = min(proxy.size.width * 0.86, 380)
            ZStack(alignment: .leading) {
                navigation
                    .offset(x: coordinator.presentedScreen == .terminalList ? drawerWidth : 0)
                    .disabled(coordinator.presentedScreen == .terminalList || coordinator.presentedScreen == .connectionMenu)

                if coordinator.presentedScreen == .terminalList {
                    Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { coordinator.dismissPresentedScreen() }
                    terminalDrawer.frame(width: drawerWidth).transition(.move(edge: .leading))
                }
                if coordinator.presentedScreen == .connectionMenu {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { coordinator.dismissPresentedScreen() }
                    connectionPopover.transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.28), value: coordinator.presentedScreen)
        }
        .task { coordinator.start(); ExternalLaunchRequestStore().consumePending(); await coordinator.authorize() }
        .onOpenURL { url in if ExternalLaunchURL.matches(url) { coordinator.handleExternalLaunch() } }
        .onReceive(NotificationCenter.default.publisher(for: .externalTerminalLaunchRequested)) { _ in coordinator.handleExternalLaunch() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { coordinator.sceneDidBackground() }
            else if coordinator.state == .locked { Task { ExternalLaunchRequestStore().consumePending(); await coordinator.authorize() } }
            else if ExternalLaunchRequestStore().consumePending() { coordinator.handleExternalLaunch() }
        }
        .fullScreenCover(isPresented: settingsBinding) { SettingsView(preferences: coordinator.preferences) }
        .fullScreenCover(isPresented: $showingScanner) { scanner }
        .alert("Rename terminal", isPresented: renameBinding) {
            TextField("Terminal name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let renameTarget { coordinator.rename(renameTarget, to: renameText) }
                renameTarget = nil
            }
        }
        .alert("Close terminal?", isPresented: deleteBinding, presenting: deleteTarget) { session in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Close Terminal", role: .destructive) { coordinator.close(session); deleteTarget = nil }
        } message: { session in
            Text("Closing \(session.descriptor.label) ends its shell and any running processes.")
        }
        .alert("Disconnect and unpair?", isPresented: $showingDisconnectConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { Task { await coordinator.disconnectCurrentMac() } }
        } message: {
            Text("The Mac must be online. Clive will revoke this iPhone on the Mac before removing the connection from this phone.")
        }
        .alert("Couldn’t disconnect", isPresented: disconnectErrorBinding) {
            Button("OK") { coordinator.disconnectError = nil }
        } message: { Text(coordinator.disconnectError ?? "The Mac did not confirm the request.") }
    }

    private var navigation: some View {
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
                case .failed(let message):
                    ContentUnavailableView("Connection failed", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { terminalButton }
                ToolbarItem(placement: .topBarTrailing) { connectionButton }
            }
        }
    }

    private var terminalButton: some View {
        Button { coordinator.showTerminalList() } label: {
            Image(systemName: "terminal")
                .frame(width: 32, height: 32)
                .overlay(alignment: .topTrailing) {
                    Text("\(coordinator.sessions.count)")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.blue, in: .capsule)
                        .offset(x: 8, y: -7)
                }
        }
        .accessibilityLabel("Terminals")
        .accessibilityValue("\(coordinator.sessions.count) open")
    }

    private var connectionButton: some View {
        Button { coordinator.showConnections() } label: {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(coordinator.selectedMac == nil ? Color.secondary : Color.green)
                Text(coordinator.selectedMac?.displayName ?? "Connections")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .accessibilityLabel("Connections")
        .accessibilityValue(coordinator.selectedMac?.displayName ?? "No connection")
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if let recovery = coordinator.recovery { recoveryView(recovery) }
            else if coordinator.sessions.isEmpty {
                ContentUnavailableView("No terminal", systemImage: "terminal", description: Text("Create a terminal from the terminal menu."))
            } else {
                TabView(selection: Binding(get: { coordinator.selectedSessionID }, set: { coordinator.selectSession($0) })) {
                    ForEach(coordinator.sessions) { session in
                        ZStack {
                            TerminalSurfaceView(session: session.client, shortcuts: coordinator.preferences.value.shortcuts)
                            sessionOverlay(session)
                        }
                        .tag(Optional(session.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }

    private var terminalDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                coordinator.addShell()
                coordinator.dismissPresentedScreen()
            } label: {
                Label("New terminal", systemImage: "terminal.fill").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 18)
            }
            .disabled(coordinator.selectedMac == nil || coordinator.state != .active)
            Divider()
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(coordinator.sessions) { session in terminalRow(session) }
                }
                .padding(12)
            }
        }
        .background(.background)
        .ignoresSafeArea()
    }

    private func terminalRow(_ session: WorkspaceSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.descriptor.label).fontWeight(session.id == coordinator.selectedSessionID ? .semibold : .regular)
                if let preview = session.preview { Text(preview).font(.caption.monospaced()).lineLimit(1).foregroundStyle(.secondary) }
            }
            .contentShape(.rect)
            .onTapGesture { coordinator.selectSession(session.id); coordinator.dismissPresentedScreen() }
            Spacer(minLength: 4)
            Button("Rename \(session.descriptor.label)", systemImage: "pencil") {
                renameText = session.descriptor.label; renameTarget = session
            }
            .labelStyle(.iconOnly)
            Button("Close \(session.descriptor.label)", systemImage: "trash", role: .destructive) { deleteTarget = session }
                .labelStyle(.iconOnly).tint(.red)
        }
        .padding(12)
        .background(session.id == coordinator.selectedSessionID ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private var connectionPopover: some View {
        VStack {
            VStack(alignment: .leading, spacing: 0) {
                if let current = coordinator.selectedMac {
                    Text("CURRENT CONNECTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
                    HStack {
                        Image(systemName: "laptopcomputer").foregroundStyle(.green)
                        VStack(alignment: .leading) { Text(current.displayName).fontWeight(.semibold); Text(routeStatus(current)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Settings", systemImage: "gearshape") { coordinator.showSettings() }.labelStyle(.iconOnly)
                    }
                    .padding(.bottom, 14)
                }

                let available = coordinator.macs.devices.filter { $0.id != coordinator.selectedMacID }
                if !available.isEmpty {
                    Divider()
                    Text("AVAILABLE CONNECTIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 10)
                    ForEach(available) { mac in
                        Button { coordinator.selectMac(mac) } label: {
                            HStack { Image(systemName: "laptopcomputer"); Text(mac.displayName); Spacer(); Text(routeStatus(mac)).font(.caption).foregroundStyle(.secondary) }
                                .padding(.vertical, 8)
                        }
                    }
                }

                Divider().padding(.vertical, 6)
                Button { coordinator.dismissPresentedScreen(); showingScanner = true } label: { Label("Add connection", systemImage: "qrcode.viewfinder") }.padding(.vertical, 8)
                if coordinator.selectedMac != nil {
                    Button(role: .destructive) { showingDisconnectConfirmation = true } label: {
                        HStack {
                            Label("Disconnect and unpair", systemImage: "network.slash")
                            if coordinator.isDisconnecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(coordinator.isDisconnecting)
                    .padding(.vertical, 8)
                }
            }
            .padding(18)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .shadow(radius: 18, y: 8)
            .padding(.horizontal, 12)
            .padding(.top, 58)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var scanner: some View {
        PairingScannerView(
            onTicket: { ticket in showingScanner = false; Task { await coordinator.macs.pair(ticket) } },
            onError: { error in showingScanner = false; coordinator.macs.state = .failed(error.localizedDescription) }
        )
        .ignoresSafeArea()
    }

    private func routeStatus(_ mac: PairedMac) -> String {
        if coordinator.macs.route(for: mac) != nil { return "Nearby" }
        if mac.remoteEndpoint != nil { return "VPN" }
        if !coordinator.macs.cellularRoutes(for: mac).isEmpty { return coordinator.preferences.value.allowsCellularConnections ? "Cellular" : "Cellular disabled" }
        return coordinator.macs.rendezvousDiagnostics[mac.id] == nil ? "Unavailable" : "Configuration required"
    }

    private var renameBinding: Binding<Bool> { Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }) }
    private var deleteBinding: Binding<Bool> { Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }) }
    private var disconnectErrorBinding: Binding<Bool> { Binding(get: { coordinator.disconnectError != nil }, set: { if !$0 { coordinator.disconnectError = nil } }) }
    private var settingsBinding: Binding<Bool> { Binding(get: { coordinator.presentedScreen == .settings }, set: { if !$0 { coordinator.dismissPresentedScreen() } }) }

    @ViewBuilder private func recoveryView(_ recovery: WorkspaceCoordinator.Recovery) -> some View {
        switch recovery {
        case .unavailableMac(let name):
            ContentUnavailableView {
                Label("Mac unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text("\(name) is offline or has no reachable connection route.")
            } actions: {
                Button("Retry") { coordinator.retryConnection() }
                Button("Choose Mac") { coordinator.showConnections() }
            }
        case .noPairedMac:
            ContentUnavailableView {
                Label("No paired Mac", systemImage: "laptopcomputer.and.iphone")
            } description: {
                Text("Pair a Mac before starting a terminal.")
            } actions: {
                Button("Add Connection") { showingScanner = true }
            }
        case .disconnected:
            ContentUnavailableView {
                Label("Disconnected", systemImage: "network.slash")
            } description: {
                Text("Choose a paired Mac to start another terminal.")
            } actions: {
                Button("Choose Mac") { coordinator.showConnections() }
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
            ContentUnavailableView { Label("Connection unavailable", systemImage: "wifi.exclamationmark") } description: { Text(message) } actions: { Button("Retry") { coordinator.retryConnection() }; Button("Choose Mac") { coordinator.showConnections() } }
        }
    }
}

private struct SettingsView: View {
    @Bindable var preferences: AppPreferencesModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Enable connections over cellular", isOn: Binding(
                        get: { preferences.value.allowsCellularConnections },
                        set: { preferences.value.allowsCellularConnections = $0 }
                    ))
                } footer: {
                    Text("This controls whether this iPhone may use cellular routes already enabled by the Mac.")
                }
                Section("Default directory") {
                    TextField("~/Projects", text: Binding(
                        get: { preferences.value.defaultDirectoryPath },
                        set: { preferences.value.defaultDirectoryPath = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                Section {
                    ForEach(preferences.value.shortcuts) { shortcut in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: shortcutBinding(shortcut.id, \.name))
                                .font(.headline)
                            TextField("Command", text: shortcutBinding(shortcut.id, \.command))
                                .font(.body.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: preferences.deleteShortcuts)
                    .onMove(perform: preferences.moveShortcuts)
                    Button("Add shortcut", systemImage: "plus") { preferences.addShortcut() }
                } header: {
                    Text("CLI shortcuts")
                } footer: {
                    Text("Selecting a shortcut above the keyboard runs its command immediately. Avoid storing secrets in commands.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
    }

    private func shortcutBinding(_ id: UUID, _ keyPath: WritableKeyPath<CLIShortcut, String>) -> Binding<String> {
        Binding(
            get: { preferences.value.shortcuts.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { value in
                guard let index = preferences.value.shortcuts.firstIndex(where: { $0.id == id }) else { return }
                preferences.value.shortcuts[index][keyPath: keyPath] = value
            }
        )
    }
}
