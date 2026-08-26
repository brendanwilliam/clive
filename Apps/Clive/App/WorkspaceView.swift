import CliveCore
import SwiftUI
import UIKit

private extension View {
    @ViewBuilder
    func cliveGlassBackground<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.thinMaterial, in: shape)
        }
    }
}

struct WorkspaceView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingScanner = false
    @State private var showingSetupGuide = false
    @State private var renameTarget: WorkspaceSession?
    @State private var renameText = ""
    @State private var deleteTarget: WorkspaceSession?
    @State private var showingClearAllConfirmation = false
    @State private var showingDeleteDisconnectedConfirmation = false
    @State private var showingDisconnectAndDeleteConnectedConfirmation = false
    @State private var showingDisconnectConfirmation = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var sidebarOverlayVisible = false

    var body: some View {
        presentedWorkspace
    }

    private var mainNavigation: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactNavigation
            } else {
                NavigationSplitView(
                    columnVisibility: $sidebarVisibility,
                    preferredCompactColumn: $preferredCompactColumn
                ) {
                    terminalSidebar
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 380)
                } detail: {
                    navigation
                }
                .navigationSplitViewStyle(.prominentDetail)
            }
        }
    }

    private var observedNavigation: some View {
        mainNavigation
        .task {
            await startWorkspace()
        }
        .onOpenURL(perform: handleOpenURL)
        .onReceive(NotificationCenter.default.publisher(for: .externalTerminalLaunchRequested)) { _ in coordinator.handleExternalLaunch() }
        .onChange(of: coordinator.preferences.value.allowsCellularConnections) { _, _ in coordinator.cellularPreferenceChanged() }
        .onChange(of: coordinator.presentedScreen) { _, screen in
            guard screen == .terminalList else { return }
            if horizontalSizeClass == .compact {
                sidebarOverlayVisible = true
            } else {
                sidebarVisibility = .all
                preferredCompactColumn = .sidebar
            }
            coordinator.dismissPresentedScreen()
        }
        .onChange(of: coordinator.state) { _, state in
            if state == .active { presentConnectionSetupGuideIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { coordinator.sceneWillLeaveForeground() }
            else if coordinator.state != .active { Task { ExternalLaunchRequestStore().consumePending(); await coordinator.sceneDidBecomeActive() } }
            else if ExternalLaunchRequestStore().consumePending() { coordinator.handleExternalLaunch() }
        }
    }

    private var presentedWorkspace: some View {
        observedNavigation
        .sheet(isPresented: settingsBinding) {
            SettingsView(coordinator: coordinator, opensShortcutSettings: coordinator.presentedScreen == .shortcutSettings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingSetupGuide) {
            NavigationStack {
                SetupGuideView(
                    pairedMacs: coordinator.macs,
                    pairMac: { showingScanner = true },
                    dismiss: { showingSetupGuide = false }
                )
            }
        }
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
            Text("Closing \(session.descriptor.label) only detaches this iPhone. The shared Terminal remains available on the Mac.")
        }
        .alert("Delete all terminals?", isPresented: $showingClearAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { Task { await coordinator.deleteAllVisibleSessions() } }
        } message: {
            Text("This permanently ends every Clive terminal currently open from this iPhone.")
        }
        .alert("Delete all disconnected terminals?", isPresented: $showingDeleteDisconnectedConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { Task { await coordinator.deleteDisconnectedVisibleSessions() } }
        } message: {
            Text("This permanently ends the disconnected terminals shown in the drawer.")
        }
        .alert("Disconnect and delete all connected terminals?", isPresented: $showingDisconnectAndDeleteConnectedConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect and Delete All", role: .destructive) { Task { await coordinator.disconnectAndDeleteConnectedSessions() } }
        } message: {
            Text("This disconnects this iPhone and permanently ends the connected terminals shown in the drawer.")
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
        .alert("Couldn’t delete all terminals", isPresented: deleteAllErrorBinding) {
            Button("OK") { coordinator.deleteAllError = nil }
        } message: { Text(coordinator.deleteAllError ?? "Try again.") }
    }

    private var compactNavigation: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                navigation
                if sidebarOverlayVisible {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { sidebarOverlayVisible = false } }
                        .zIndex(1)
                    terminalSidebar
                        .frame(width: min(320, proxy.size.width * 0.84))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(.rect(bottomTrailingRadius: 18, topTrailingRadius: 18))
                        // The drawer background reaches the screen edges; its content
                        // keeps the safe-area padding applied in `terminalSidebar`.
                        .ignoresSafeArea(.container, edges: .vertical)
                        .shadow(color: .black.opacity(0.28), radius: 18, x: 6)
                        .transition(.move(edge: .leading))
                        .zIndex(2)
                }
            }
        }
    }

    private func handleOpenURL(_ url: URL) {
        guard let action = ExternalLaunchURL.action(for: url) else { return }
        coordinator.handleExternalLaunch(action)
    }

    private func startWorkspace() async {
        coordinator.start()
        ExternalLaunchRequestStore().consumePending()
        await coordinator.sceneDidBecomeActive()
        presentConnectionSetupGuideIfNeeded()
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
                case .unsupportedLocalState:
                    ContentUnavailableView {
                        Label("Clive needs to reset local data", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("This version cannot safely read local data from an older Clive version. Resetting removes saved connections and terminal restoration data from this iPhone. Pair again afterward.")
                    } actions: {
                        Button("Reset local data", role: .destructive) { coordinator.resetUnsupportedLocalState() }
                    }
                case .failed(let message):
                    ContentUnavailableView("Connection failed", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissKeyboard()
                        if horizontalSizeClass == .compact {
                            withAnimation(.easeOut(duration: 0.2)) { sidebarOverlayVisible = true }
                        } else {
                            sidebarVisibility = .all
                            preferredCompactColumn = .sidebar
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .accessibilityLabel("Terminals")
                    .accessibilityIdentifier("terminal-sidebar-button")
                }
                ToolbarItem(placement: .principal) { terminalTitleButton }
                ToolbarItem(placement: .topBarTrailing) { terminalActions }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var terminalTitleButton: some View {
        TerminalTitleControl(
            title: coordinator.selectedSession?.descriptor.label ?? "No terminal",
            isEnabled: coordinator.selectedSession != nil,
            rename: { if let session = coordinator.selectedSession { beginRename(session) } }
        )
    }

    private var connectionPresentation: ConnectionStatusPresentation {
        ConnectionStatusPresentation.make(state: coordinator.selectedSession?.state, deviceName: coordinator.selectedMac?.displayName, route: coordinator.selectedSession?.activeRouteKind)
    }

    private var connectionHealthColor: Color {
        switch ConnectionPresentation.status(for: coordinator.selectedSession?.state) {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected: .secondary
        case .attention: .red
        }
    }

    private var terminalActions: some View {
        Button { navigate { coordinator.addShell() } } label: { Image(systemName: "plus") }
            .accessibilityLabel("New Terminal").accessibilityIdentifier("new-terminal-button")
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if let recovery = coordinator.recovery { recoveryView(recovery) }
            else {
                if coordinator.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No terminal", systemImage: "terminal")
                    } description: {
                        Text("Start a new Terminal on your Connection.")
                    } actions: {
                        Button("New Terminal") { coordinator.addShell() }.buttonStyle(.borderedProminent)
                    }
                } else if let session = coordinator.selectedSession {
                    ZStack {
                        TerminalSurfaceView(
                            session: session.client,
                            accessibilityIdentifier: "terminal-surface-\(session.id.uuidString)",
                            isSelected: true,
                            shortcuts: coordinator.preferences.value.shortcuts,
                            openDrawer: { dismissKeyboard(); coordinator.showTerminalList() },
                            selectAdjacentTerminal: selectAdjacentTerminal,
                            runShortcut: coordinator.runShortcut,
                            manageShortcuts: { coordinator.showShortcutSettings() }
                        )
                        .id(session.id)
                        sessionOverlay(session)
                    }
                    .padding(TerminalSurfaceConfiguration.contentPadding)
                    .accessibilityIdentifier("terminal-page-\(session.id.uuidString)")
                    .accessibilityValue("Selected")
                }
            }
        }
    }

    private var terminalSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section {
                    if connectedSessions.isEmpty {
                        emptyDrawerSection("No connected terminals")
                    } else {
                        ForEach(connectedSessions) { session in
                            terminalRow(session)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                        }
                    }
                } header: {
                    drawerSectionHeader("Connected") {
                        Button("Disconnect and Delete All", systemImage: "network.slash", role: .destructive) {
                            showingDisconnectAndDeleteConnectedConfirmation = true
                        }
                        .disabled(connectedSessions.isEmpty)
                    }
                }
                Section {
                    if disconnectedSessions.isEmpty && coordinator.unrepresentedCatalogSessions.isEmpty {
                        emptyDrawerSection("No disconnected terminals")
                    } else {
                        ForEach(disconnectedSessions) { session in
                            terminalRow(session)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                        }
                        ForEach(coordinator.unrepresentedCatalogSessions) { session in
                            catalogSessionRow(session)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                        }
                    }
                } header: {
                    drawerSectionHeader("Disconnected") {
                        Button("Delete All", systemImage: "trash", role: .destructive) {
                            showingDeleteDisconnectedConfirmation = true
                        }
                        .disabled(disconnectedSessions.isEmpty && coordinator.unrepresentedCatalogSessions.isEmpty)
                    }
                }
            }
            .listStyle(.plain)
            .listRowSpacing(DrawerRowRevealPolicy.rowSpacing)
            .scrollContentBackground(.hidden)
            .navigationTitle("Terminals")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Disconnect All", systemImage: "network.slash") { coordinator.disconnectAll() }
                        Button("Delete All", systemImage: "trash", role: .destructive) { showingClearAllConfirmation = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 32) }
                    .accessibilityLabel("Terminal actions")
                    .disabled(coordinator.openSessionCount == 0)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            if let current = coordinator.selectedMac {
                Divider()
                HStack(spacing: 12) {
                    Button { navigate { coordinator.showSettings() } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer").frame(width: 38, height: 38)
                    Text(current.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                            Spacer(minLength: 8)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("drawer-settings-button")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                Divider()
                Button { coordinator.dismissPresentedScreen(); showingScanner = true } label: {
                    Label("Add connection", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
        }
        .safeAreaPadding(.top, 16)
        .safeAreaPadding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var connectedSessions: [WorkspaceSession] {
        coordinator.sessions.filter { ConnectionPresentation.status(for: $0.state) == .connected }
    }

    private var disconnectedSessions: [WorkspaceSession] {
        coordinator.sessions.filter { ConnectionPresentation.status(for: $0.state) != .connected }
    }

    private func drawerSectionHeader<Content: View>(
        _ title: String,
        @ViewBuilder actions: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu(content: actions) {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 32)
            }
            .accessibilityLabel("\(title) actions")
        }
        .textCase(nil)
    }

    private func emptyDrawerSection(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(.init(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    private func terminalRow(_ session: WorkspaceSession) -> some View {
        Button {
            coordinator.selectSession(session.id)
            if horizontalSizeClass == .compact {
                withAnimation(.easeOut(duration: 0.2)) { sidebarOverlayVisible = false }
            } else {
                sidebarVisibility = .detailOnly
                preferredCompactColumn = .detail
            }
            coordinator.dismissPresentedScreen()
        } label: {
            HStack(spacing: 12) {
                terminalStatusIcon(for: session.state)
                    .accessibilityIdentifier("terminal-status-\(session.id.uuidString)")
                Text(session.descriptor.label)
                Spacer(minLength: 4)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .accessibilityIdentifier("terminal-row-\(session.id.uuidString)")
        .accessibilityValue(session.id == coordinator.selectedSessionID ? "Selected" : "Not selected")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = session }
            if ConnectionPresentation.status(for: session.state) == .connected {
                Button("Disconnect", systemImage: "network.slash") { coordinator.disconnect(session) }
                    .tint(.orange)
            } else {
                Button("Reconnect", systemImage: "arrow.clockwise") { coordinator.reconnect(session) }
                    .tint(.green)
            }
            Button("Rename", systemImage: "pencil") { beginRename(session) }
                .tint(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: DrawerRowRevealPolicy.minimumRowHeight)
        .background(session.id == coordinator.selectedSessionID ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func catalogSessionRow(_ session: CliveCore.SessionDescriptor) -> some View {
        Button { coordinator.reconnect(session) } label: {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .foregroundStyle(session.attachmentCount > 0 ? Color.green : Color.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Disconnected")
                    .accessibilityIdentifier("catalog-terminal-status-\(session.id.uuidString)")
                Text(session.label ?? "Detached terminal")
                Spacer(minLength: 4)
                if session.attachmentCount == 0 {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(session.attachmentCount != 0)
        .accessibilityIdentifier("reconnect-terminal-\(session.id.uuidString)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Reconnect", systemImage: "arrow.clockwise") { coordinator.reconnect(session) }
                .tint(.green)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: DrawerRowRevealPolicy.minimumRowHeight)
    }

    private func terminalStatusIcon(for state: SessionClient.State) -> some View {
        let presentation = ConnectionStatusPresentation.make(state: state, deviceName: nil, route: nil)
        return Image(systemName: "terminal")
            .foregroundStyle(terminalStatusColor(for: presentation.health))
            .frame(width: 20, height: 20)
            .accessibilityLabel(presentation.text)
    }

    private func terminalStatusText(for state: SessionClient.State, attachment: AttachmentState?) -> String {
        let status = ConnectionStatusPresentation.make(state: state, deviceName: nil, route: nil).text
        guard let attachment else { return status }
        return "\(status) · \(attachment.attachmentCount) attached"
    }

    private func terminalStatusColor(for health: ConnectionHealth) -> Color {
        switch health {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected: .secondary
        case .attention: .red
        }
    }

    private func beginRename(_ session: WorkspaceSession) {
        renameText = session.descriptor.label; renameTarget = session
    }

    private func selectAdjacentTerminal(forward: Bool) {
        guard let selected = coordinator.selectedSessionID,
              let index = coordinator.sessions.firstIndex(where: { $0.id == selected }),
              let adjacent = TerminalTwoFingerNavigationPolicy.adjacentIndex(
                  current: index,
                  count: coordinator.sessions.count,
                  forward: forward
              ) else { return }
        // Only the selected TerminalView is mounted, so SwiftTerm cannot provide
        // a live neighboring-terminal peek without duplicating a session view.
        // Keep the transition short and animated as the closest practical preview.
        withAnimation(.easeInOut(duration: 0.2)) {
            coordinator.selectSession(coordinator.sessions[adjacent].id)
        }
    }

    private var scanner: some View {
        PairingScannerView(
            onTicket: { ticket in
                showingScanner = false
                Task {
                    await coordinator.macs.pair(ticket)
                    if coordinator.macs.state == .idle, !coordinator.macs.devices.isEmpty {
                        coordinator.pairingDidSucceed()
                        showingSetupGuide = false
                    }
                }
            },
            onError: { error in showingScanner = false; coordinator.macs.state = .failed(error.localizedDescription) }
        )
        .ignoresSafeArea()
    }

    private var renameBinding: Binding<Bool> { Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }) }
    private var deleteBinding: Binding<Bool> { Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }) }
    private var disconnectErrorBinding: Binding<Bool> { Binding(get: { coordinator.disconnectError != nil }, set: { if !$0 { coordinator.disconnectError = nil } }) }
    private var deleteAllErrorBinding: Binding<Bool> { Binding(get: { coordinator.deleteAllError != nil }, set: { if !$0 { coordinator.deleteAllError = nil } }) }
    private var settingsBinding: Binding<Bool> {
        Binding(
            get: { coordinator.presentedScreen == .settings || coordinator.presentedScreen == .shortcutSettings },
            set: { if !$0 { coordinator.dismissPresentedScreen() } }
        )
    }

    private func presentConnectionSetupGuideIfNeeded() {
        guard coordinator.state == .active else { return }
        if coordinator.shouldPresentConnectionSetupGuide() { showingSetupGuide = true }
    }

    private func navigate(_ action: () -> Void) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        action()
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
        case .active(_, _, let replayTruncated):
            VStack(spacing: 6) {
                if session.showsReconnectNotice { Text("Reconnected to the existing Terminal.").font(.caption).padding(8).background(.regularMaterial, in: .capsule) }
                if replayTruncated { Text("Some output produced while disconnected was discarded.").font(.caption).padding(8).background(.regularMaterial, in: .capsule) }
            }
        case .connecting: ProgressView("Connecting…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .reconnecting(let waitingForWiFi):
            ProgressView(waitingForWiFi ? "Waiting for Wi-Fi…" : "Reconnecting…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .disconnected: ContentUnavailableView("Disconnected", systemImage: "network.slash")
        case .resumeUnavailable:
            ContentUnavailableView { Label("Terminal no longer available", systemImage: "terminal.fill") } description: { Text("The detached Terminal could not be resumed.") } actions: { Button("Start New Terminal") { coordinator.addShell() } }
        case .revoked:
            ContentUnavailableView { Label("Access revoked", systemImage: "lock.slash") } description: { Text("Pair this iPhone with the Mac again.") } actions: { Button("Pair Again") { showingScanner = true } }
        case .workingDirectoryUnavailable:
            ContentUnavailableView("Working directory unavailable", systemImage: "folder.badge.questionmark", description: Text("Choose another directory for this shortcut in Settings."))
        case .certificateChanged:
            ContentUnavailableView { Label("Certificate changed", systemImage: "exclamationmark.shield") } description: { Text("Verify the Mac locally before pairing it again.") } actions: { Button("Pair Again") { showingScanner = true } }
        case .protocolError: ContentUnavailableView("Protocol error", systemImage: "exclamationmark.triangle")
        case .networkError(let message):
            ContentUnavailableView { Label("Connection unavailable", systemImage: "wifi.exclamationmark") } description: { Text(message) } actions: { Button("Retry") { coordinator.retryConnection() }; Button("Choose Mac") { coordinator.showConnections() } }
        }
    }
}

private struct TerminalTitleControl: UIViewRepresentable {
    let title: String
    let isEnabled: Bool
    let rename: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(rename: rename) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityLabel = "Terminal title"
        button.accessibilityIdentifier = "terminal-title-button"
        button.addTarget(context.coordinator, action: #selector(Coordinator.renameTerminal), for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.rename = rename
        button.setTitle(title, for: .normal)
        // The title identifies the current terminal; it is not a primary action.
        button.setTitleColor(.label, for: .normal)
        button.isEnabled = isEnabled
    }

    @MainActor final class Coordinator: NSObject {
        var rename: () -> Void

        init(rename: @escaping () -> Void) {
            self.rename = rename
        }

        @objc func renameTerminal() { rename() }
    }
}

private struct SettingsView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    let opensShortcutSettings: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showingScanner = false
    @State private var showingShortcutSettings: Bool

    init(coordinator: WorkspaceCoordinator, opensShortcutSettings: Bool) {
        self.coordinator = coordinator
        self.opensShortcutSettings = opensShortcutSettings
        _showingShortcutSettings = State(initialValue: opensShortcutSettings)
    }

    private var preferences: AppPreferencesModel { coordinator.preferences }

    var body: some View {
        NavigationStack {
            if showingShortcutSettings {
                ShortcutManagementView(preferences: preferences) {
                    showingShortcutSettings = false
                }
            } else {
                settingsList
            }
        }
        .fullScreenCover(isPresented: $showingScanner) {
            PairingScannerView(
                onTicket: { ticket in
                    showingScanner = false
                    Task {
                        await coordinator.macs.pair(ticket)
                        if coordinator.macs.state == .idle, !coordinator.macs.devices.isEmpty {
                            coordinator.pairingDidSucceed()
                        }
                    }
                },
                onError: { error in
                    showingScanner = false
                    coordinator.macs.state = .failed(error.localizedDescription)
                }
            )
            .ignoresSafeArea()
        }
    }

    private var settingsList: some View {
        List {
                if let connection = coordinator.selectedMac {
                    Section("Current Connection") {
                        NavigationLink {
                            ConnectionDetailsView(coordinator: coordinator, connection: connection)
                        } label: {
                            LabeledContent(connection.displayName, value: ConnectionPresentation.status(for: coordinator.selectedSession?.state).label)
                        }
                    }
                }
                Section("Terminals") {
                    LabeledContent("Open Terminals", value: "\(coordinator.openSessionCount)")
                    LabeledContent("Active Terminals", value: "\(coordinator.activeSessionCount)")
                }
                Section {
                    Toggle("Cellular connections", isOn: Binding(
                        get: { preferences.value.allowsCellularConnections },
                        set: { preferences.value.allowsCellularConnections = $0 }
                    ))
                } footer: {
                    Text("This controls whether this iPhone may use cellular routes already enabled by the Mac.")
                }
                Section {
                    Picker("New terminal default", selection: Binding(
                        get: { preferences.value.newTerminalDefaultShortcutID },
                        set: { preferences.value.newTerminalDefaultShortcutID = $0 }
                    )) {
                        Text("None").tag(nil as UUID?)
                        ForEach(preferences.value.shortcuts.filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { shortcut in
                            Text(shortcut.name.isEmpty ? "Unnamed shortcut" : shortcut.name).tag(Optional(shortcut.id))
                        }
                    }
                } footer: {
                    Text("Ordinary new terminals use the selected shortcut. With no selection, Clive starts a login shell in your Home directory.")
                }
                Section {
                        NavigationLink {
                            ShortcutManagementView(preferences: preferences)
                    } label: {
                        LabeledContent("Shortcuts", value: "\(preferences.value.shortcuts.count)")
                    }
                    NavigationLink("Setup Guide") {
                        SetupGuideView(
                            pairedMacs: coordinator.macs,
                            pairMac: { showingScanner = true },
                            dismiss: { }
                        )
                    }
                }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.left") { dismiss() }
                    .accessibilityIdentifier("settings-back-button")
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct ShortcutManagementView: View {
    @Bindable var preferences: AppPreferencesModel
    var onBackToSettings: (() -> Void)? = nil
    @State private var isEditing = false
    var body: some View {
        List {
            ForEach(preferences.value.shortcuts) { shortcut in
                NavigationLink {
                    ShortcutEditorView(preferences: preferences, shortcutID: shortcut.id)
                } label: {
                    Text(shortcut.name.isEmpty ? "Unnamed shortcut" : shortcut.name)
                        .foregroundStyle(.primary)
                }
            }
            .onDelete(perform: preferences.deleteShortcuts)
            .onMove(perform: preferences.moveShortcuts)
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .listStyle(.plain)
        .listRowBackground(Color.clear)
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onBackToSettings {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "chevron.left", action: onBackToSettings)
                        .accessibilityIdentifier("shortcut-settings-back-button")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ControlGroup {
                    Button(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil") {
                        isEditing.toggle()
                    }
                    Button("Add", systemImage: "plus") { preferences.addShortcut() }
                }
                .accessibilityIdentifier("shortcut-management-actions")
                .foregroundStyle(.tint)
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct ShortcutEditorView: View {
    @Bindable var preferences: AppPreferencesModel
    let shortcutID: UUID
    var body: some View {
        Form {
            TextField("Title", text: shortcutBinding(\.name))
            TextField("Command", text: shortcutBinding(\.command), axis: .vertical)
                .font(.body.monospaced())
        }
        .navigationTitle("Edit Shortcut")
        .navigationBarTitleDisplayMode(.inline)
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
    private func shortcutBinding(_ keyPath: WritableKeyPath<CLIShortcut, String>) -> Binding<String> {
        shortcutBinding(shortcutID, keyPath)
    }
}

private struct SetupGuideView: View {
    @Bindable var pairedMacs: PairedMacsModel
    let pairMac: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 52)).foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                Text("Connect Clive to your Mac").font(.title2.bold())
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Install Clive on your Mac").font(.headline)
                    Text("In Terminal on your Mac, run:")
                    Text(ConnectionSetupGuideConfiguration.macInstallCommand)
                        .font(.body.monospaced()).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 10))
                    Text("Then open Clive from Applications.").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("2. Pair your Mac").font(.headline)
                    Text("Choose Pair iPhone in Clive on the Mac. It shows a secure, short-lived pairing code. Scan that code here, then approve this iPhone on the Mac.")
                        .foregroundStyle(.secondary)
                    Button("Pair a Mac", systemImage: "qrcode.viewfinder", action: pairMac)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("setup-guide-pair-mac-button")
                }
                if case .failed(let message) = pairedMacs.state {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Pairing couldn’t finish", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(message)
                        Text("Check that you scanned the current secure pairing code and that the Mac is open, then try again.")
                            .foregroundStyle(.secondary)
                        Button("Try Pairing Again", action: pairMac)
                    }
                    .padding(12).background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("setup-guide-pairing-error")
                }
            }
            .padding(24)
        }
        .navigationTitle("Setup Guide")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done", action: dismiss) } }
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityIdentifier("setup-guide-screen")
    }
}

private struct ConnectionDetailsView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    let connection: PairedMac

    private var presentation: ConnectionStatusPresentation {
        ConnectionStatusPresentation.make(
            state: coordinator.selectedSession?.state,
            deviceName: connection.displayName,
            route: coordinator.selectedSession?.activeRouteKind
        )
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Connection", value: connection.displayName)
                LabeledContent("Connection health", value: presentation.health.label)
                LabeledContent("Route", value: ConnectionPresentation.routeLabel(for: coordinator.selectedSession?.activeRouteKind))
                LabeledContent("Terminal", value: presentation.activity)
                LabeledContent(
                    "Attachments",
                    value: coordinator.selectedSession?.attachmentState.map { "\($0.attachmentCount) connected" } ?? "Unavailable"
                )
                LabeledContent(
                    "Resize owner",
                    value: coordinator.selectedSession?.attachmentState?.resizeOwner?.rawValue ?? "None"
                )
                if let warning = presentation.replayWarning {
                    Text(warning).foregroundStyle(.orange)
                }
            }
            Section("Security") {
                LabeledContent("Transport") {
                    Text("TLS 1.3")
                        .accessibilityIdentifier("connection-transport-value")
                }
                LabeledContent("Authentication") {
                    Text("Mutual authentication")
                        .accessibilityIdentifier("connection-authentication-value")
                }
                LabeledContent("Certificate pin", value: presentation.certificatePin)
                Text("The stored fingerprint below is verification information, not a secret. Clive never displays private keys, pairing secrets, identities, rendezvous tokens, or raw certificates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("SHA-256 fingerprint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(FingerprintFormatter.formatted(connection.certificateFingerprint))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button("Copy fingerprint", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = FingerprintFormatter.formatted(connection.certificateFingerprint)
                    }
                }
            }
        }
        .accessibilityIdentifier("connection-details-list")
        .navigationTitle("Connection Details")
    }
}
