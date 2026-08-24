import CliveCore
import SwiftUI
import UIKit

struct WorkspaceView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingScanner = false
    @State private var renameTarget: WorkspaceSession?
    @State private var renameText = ""
    @State private var deleteTarget: WorkspaceSession?
    @State private var showingClearAllConfirmation = false
    @State private var showingDisconnectConfirmation = false
    @State private var showingShortcuts = false
    @State private var shortcutEditTarget: CLIShortcut?
    @State private var shortcutEditName = ""
    @State private var shortcutEditCommand = ""
    @State private var isReorderingShortcuts = false
    @State private var pagerSelection = TerminalPagerPage.empty
    @State private var pagerPolicy = TerminalPagerPolicy()

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = min(proxy.size.width * 0.86, 380)
            ZStack(alignment: .leading) {
                navigation
                    .offset(x: coordinator.presentedScreen == .terminalList ? drawerWidth : 0)
                    .disabled(coordinator.presentedScreen == .terminalList)

                if coordinator.presentedScreen == .terminalList {
                    Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { coordinator.dismissPresentedScreen() }
                    terminalDrawer.frame(width: drawerWidth).transition(.move(edge: .leading))
                }
            }
            .animation(.snappy(duration: 0.18, extraBounce: 0), value: coordinator.presentedScreen)
        }
        .task { coordinator.start(); ExternalLaunchRequestStore().consumePending(); await coordinator.sceneDidBecomeActive() }
        .onOpenURL { url in if let action = ExternalLaunchURL.action(for: url) { coordinator.handleExternalLaunch(action) } }
        .onReceive(NotificationCenter.default.publisher(for: .externalTerminalLaunchRequested)) { _ in coordinator.handleExternalLaunch() }
        .onChange(of: coordinator.preferences.value.allowsCellularConnections) { _, _ in coordinator.cellularPreferenceChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { coordinator.sceneWillLeaveForeground() }
            else if coordinator.state != .active { Task { ExternalLaunchRequestStore().consumePending(); await coordinator.sceneDidBecomeActive() } }
            else if ExternalLaunchRequestStore().consumePending() { coordinator.handleExternalLaunch() }
        }
        .fullScreenCover(isPresented: settingsBinding) {
            SettingsView(coordinator: coordinator)
        }
        .fullScreenCover(isPresented: $showingScanner) { scanner }
        .sheet(isPresented: $showingShortcuts) { shortcutsSheet }
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
                ToolbarItem(placement: .topBarLeading) { terminalButton }
                ToolbarItem(placement: .principal) { connectionStatusButton }
                ToolbarItem(placement: .topBarTrailing) { terminalActions }
            }
            .toolbarBackground(Color.black.opacity(0.18), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var terminalButton: some View {
        Button { navigate { coordinator.showTerminalList() } } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                Text("\(coordinator.sessions.count)").monospacedDigit()
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityLabel("Terminals")
        .accessibilityValue("\(coordinator.sessions.count) open")
    }

    private var connectionStatusButton: some View {
        let presentation = connectionPresentation
        return Button { navigate { coordinator.showSettings() } } label: {
            HStack(spacing: 6) {
                Image(systemName: presentation.icon)
                    .foregroundStyle(connectionHealthColor)
                Text(coordinator.selectedMac?.displayName ?? "No Mac")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.subheadline.weight(.semibold))
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .disabled(coordinator.selectedMac == nil)
        .accessibilityLabel("Settings")
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityIdentifier("connection-details-button")
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
        HStack(spacing: 0) {
            Button { navigate { showingShortcuts = true } } label: { Image(systemName: "bolt.fill").frame(width: 38, height: 34) }
                .accessibilityLabel("Shortcuts").accessibilityIdentifier("shortcuts-button")
            Button { navigate { coordinator.addShell() } } label: { Image(systemName: "plus.rectangle.on.rectangle").frame(width: 38, height: 34) }
                .accessibilityLabel("New Terminal").accessibilityIdentifier("new-terminal-button")
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: Capsule())
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if let recovery = coordinator.recovery { recoveryView(recovery) }
            else {
                TabView(selection: $pagerSelection) {
                    Color.clear
                        .tag(TerminalPagerPage.leading)
                        .accessibilityHidden(true)
                    if coordinator.sessions.isEmpty {
                        ContentUnavailableView {
                            Label("No terminal", systemImage: "terminal")
                        } description: {
                            Text("Start a new Terminal on your Connection.")
                        } actions: {
                            Button("New Terminal") { coordinator.addShell() }
                                .buttonStyle(.borderedProminent)
                        }
                        .tag(TerminalPagerPage.empty)
                    } else {
                        ForEach(coordinator.sessions) { session in
                            ZStack {
                                TerminalSurfaceView(
                                    session: session.client,
                                    accessibilityIdentifier: "terminal-surface-\(session.id.uuidString)",
                                    isSelected: session.id == coordinator.selectedSessionID
                                )
                                sessionOverlay(session)
                            }
                            .padding(TerminalSurfaceConfiguration.contentPadding)
                            .tag(TerminalPagerPage.terminal(session.id))
                            .accessibilityIdentifier("terminal-page-\(session.id.uuidString)")
                            .accessibilityValue(session.id == coordinator.selectedSessionID ? "Selected" : "Not selected")
                        }
                    }
                    Color.clear
                        .tag(TerminalPagerPage.trailing)
                        .accessibilityHidden(true)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onAppear { pagerSelection = coordinator.selectedSessionID.map(TerminalPagerPage.terminal) ?? .empty }
                .onChange(of: pagerSelection) { _, page in handlePagerSelection(page) }
                .onChange(of: coordinator.selectedSessionID) { _, id in
                    pagerSelection = id.map(TerminalPagerPage.terminal) ?? .empty
                }
            }
        }
    }

    private var terminalDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section {
                    ForEach(coordinator.sessions) { session in
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
                } header: {
                    HStack {
                        Text("Terminals")
                        Spacer()
                        Menu {
                            Button("Disconnect All", systemImage: "network.slash") { coordinator.disconnectAll() }
                            Button("Delete All", systemImage: "trash", role: .destructive) { showingClearAllConfirmation = true }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 32) }
                        .accessibilityLabel("Terminal actions")
                        .disabled(coordinator.openSessionCount == 0)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                }
            }
            .listStyle(.plain)
            .listRowSpacing(DrawerRowRevealPolicy.rowSpacing)
            .scrollContentBackground(.hidden)
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
                    Button { navigate { coordinator.addShell(); coordinator.dismissPresentedScreen() } } label: {
                        Image(systemName: "plus.rectangle.on.rectangle").font(.title3).frame(width: 44, height: 44)
                    }.accessibilityLabel("New Terminal")
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
        .safeAreaPadding(.top, 6)
        .safeAreaPadding(.bottom, 4)
        .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
    }

    private func terminalRow(_ session: WorkspaceSession) -> some View {
        Button {
            coordinator.selectSession(session.id)
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
                .tint(.blue)
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

    private func handlePagerSelection(_ page: TerminalPagerPage) {
        let before = coordinator.sessions.map(\.id)
        switch pagerPolicy.transition(to: page, terminalIDs: before) {
        case .select(let id):
            pagerSelection = .terminal(id); coordinator.selectSession(id)
        case .openDrawer(let restoring):
            pagerSelection = restoring.map(TerminalPagerPage.terminal) ?? .empty
            coordinator.selectSession(restoring)
            coordinator.showTerminalList()
        case .createTerminal:
            coordinator.addShell()
            if let id = coordinator.selectedSessionID { pagerSelection = .terminal(id) }
        case .restore(let id):
            pagerSelection = id.map(TerminalPagerPage.terminal) ?? .empty
            coordinator.selectSession(id)
        case nil: break
        }
    }

    private var connectionDetailsSheet: some View {
        NavigationStack {
            List {
                if let mac = coordinator.selectedMac {
                    Section("Connection") {
                        LabeledContent("Connection", value: mac.displayName)
                        LabeledContent("Connection health", value: ConnectionPresentation.status(for: coordinator.selectedSession?.state).label)
                        LabeledContent("Route", value: ConnectionPresentation.routeLabel(for: coordinator.selectedSession?.activeRouteKind))
                        LabeledContent("Terminal", value: connectionPresentation.activity)
                        LabeledContent("Attachments", value: coordinator.selectedSession?.attachmentState.map { "\($0.attachmentCount) connected" } ?? "Unavailable")
                        LabeledContent("Resize owner", value: coordinator.selectedSession?.attachmentState?.resizeOwner?.rawValue ?? "None")
                        if let warning = connectionPresentation.replayWarning { Text(warning).foregroundStyle(.orange) }
                    }
                    Section("Security") {
                        LabeledContent("Transport", value: "TLS 1.3")
                        LabeledContent("Authentication", value: "Mutual authentication")
                        LabeledContent("Certificate pin", value: connectionPresentation.certificatePin)
                        Text("The stored fingerprint below is verification information, not a secret. Clive never displays private keys, pairing secrets, identities, rendezvous tokens, or raw certificates.")
                            .font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SHA-256 fingerprint").font(.caption).foregroundStyle(.secondary)
                            Text(FingerprintFormatter.formatted(mac.certificateFingerprint)).font(.footnote.monospaced()).textSelection(.enabled)
                            Button("Copy fingerprint", systemImage: "doc.on.doc") { UIPasteboard.general.string = FingerprintFormatter.formatted(mac.certificateFingerprint) }
                        }
                    }
                }
            }
            .accessibilityIdentifier("connection-details-list")
            .navigationTitle("Connection Details")
            .accessibilityIdentifier("connection-details-sheet")
            .presentationDetents([.medium, .large])
        }
    }

    private var shortcutsSheet: some View {
        NavigationStack {
            List {
                if coordinator.preferences.value.shortcuts.isEmpty {
                    ContentUnavailableView("No shortcuts", systemImage: "bolt", description: Text("Add commands in Settings to run them here."))
                } else {
                    ForEach(coordinator.preferences.value.shortcuts) { shortcut in
                        Button {
                            if coordinator.runShortcut(shortcut) { showingShortcuts = false }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "terminal")
                                    .foregroundStyle(.tint)
                                    .frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shortcut.name.isEmpty ? "Unnamed shortcut" : shortcut.name)
                                    Text(shortcut.command.isEmpty ? "No command" : shortcut.command)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isReorderingShortcuts || shortcut.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("shortcut-row-\(shortcut.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                coordinator.preferences.deleteShortcut(id: shortcut.id)
                            }
                            Button("Edit", systemImage: "pencil") { beginEditing(shortcut) }
                                .tint(.blue)
                        }
                    }
                    .onMove(perform: coordinator.preferences.moveShortcuts)
                }
            }
            .environment(\.editMode, .constant(isReorderingShortcuts ? .active : .inactive))
            .navigationTitle("Shortcuts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showingShortcuts = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(isReorderingShortcuts ? "Done Reordering" : "Reorder Shortcuts", systemImage: "arrow.up.arrow.down") {
                            isReorderingShortcuts.toggle()
                        }
                        Button("Manage in Settings", systemImage: "gearshape") {
                            showingShortcuts = false
                            DispatchQueue.main.async { coordinator.showSettings() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Shortcut options")
                    .accessibilityIdentifier("shortcut-options")
                }
            }
            .accessibilityIdentifier("shortcuts-sheet")
            .presentationDetents([.medium, .large])
            .alert("Edit shortcut", isPresented: shortcutEditBinding) {
                TextField("Name", text: $shortcutEditName)
                TextField("Command", text: $shortcutEditCommand)
                Button("Cancel", role: .cancel) { shortcutEditTarget = nil }
                Button("Save") {
                    if let shortcutEditTarget {
                        coordinator.preferences.updateShortcut(
                            id: shortcutEditTarget.id,
                            name: shortcutEditName,
                            command: shortcutEditCommand
                        )
                    }
                    shortcutEditTarget = nil
                }
            }
        }
    }

    private var scanner: some View {
        PairingScannerView(
            onTicket: { ticket in showingScanner = false; Task { await coordinator.macs.pair(ticket) } },
            onError: { error in showingScanner = false; coordinator.macs.state = .failed(error.localizedDescription) }
        )
        .ignoresSafeArea()
    }

    private var renameBinding: Binding<Bool> { Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }) }
    private var shortcutEditBinding: Binding<Bool> { Binding(get: { shortcutEditTarget != nil }, set: { if !$0 { shortcutEditTarget = nil } }) }
    private var deleteBinding: Binding<Bool> { Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }) }
    private var disconnectErrorBinding: Binding<Bool> { Binding(get: { coordinator.disconnectError != nil }, set: { if !$0 { coordinator.disconnectError = nil } }) }
    private var deleteAllErrorBinding: Binding<Bool> { Binding(get: { coordinator.deleteAllError != nil }, set: { if !$0 { coordinator.deleteAllError = nil } }) }
    private var settingsBinding: Binding<Bool> { Binding(get: { coordinator.presentedScreen == .settings }, set: { if !$0 { coordinator.dismissPresentedScreen() } }) }

    private func navigate(_ action: () -> Void) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        action()
    }

    private func beginEditing(_ shortcut: CLIShortcut) {
        shortcutEditName = shortcut.name
        shortcutEditCommand = shortcut.command
        shortcutEditTarget = shortcut
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

private struct SettingsView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    @Environment(\.dismiss) private var dismiss

    private var preferences: AppPreferencesModel { coordinator.preferences }

    var body: some View {
        NavigationStack {
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
                    NavigationLink("Setup Guide") { SetupGuideView() }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct ShortcutManagementView: View {
    @Bindable var preferences: AppPreferencesModel
    @State private var isEditing = false
    var body: some View {
        List {
            ForEach(preferences.value.shortcuts) { shortcut in
                NavigationLink(shortcut.name.isEmpty ? "Unnamed shortcut" : shortcut.name) {
                    ShortcutEditorView(preferences: preferences, shortcutID: shortcut.id)
                }
            }
            .onDelete(perform: preferences.deleteShortcuts)
            .onMove(perform: preferences.moveShortcuts)
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle("Shortcuts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ControlGroup {
                    Button(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil") {
                        isEditing.toggle()
                    }
                    Button("Add", systemImage: "plus") { preferences.addShortcut() }
                }
                .accessibilityIdentifier("shortcut-management-actions")
            }
        }
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
    var body: some View {
        ContentUnavailableView("Setup Guide", systemImage: "book", description: Text("Guided setup is coming soon."))
            .navigationTitle("Setup Guide")
    }
}

private struct ConnectionDetailsView: View {
    @Bindable var coordinator: WorkspaceCoordinator
    let connection: PairedMac
    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Connection", value: connection.displayName)
                LabeledContent("Status", value: ConnectionPresentation.status(for: coordinator.selectedSession?.state).label)
                LabeledContent("Route", value: ConnectionPresentation.routeLabel(for: coordinator.selectedSession?.activeRouteKind))
            }
            Section("Security") {
                LabeledContent("Transport", value: "TLS 1.3")
                LabeledContent("Authentication", value: "Mutual authentication")
                Text(FingerprintFormatter.formatted(connection.certificateFingerprint)).font(.footnote.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Connection Details")
    }
}
