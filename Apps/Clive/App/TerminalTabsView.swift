import CliveCore
import Observation
import SwiftUI

@MainActor @Observable final class TerminalTab: Identifiable {
    let id = UUID(); let client = SessionClient(); var state: SessionClient.State = .connecting
    init(device: PairedMac, route: MacRoute, identity: IPhoneIdentity) {
        client.onState = { [weak self] state in DispatchQueue.main.async { self?.state = state } }
        client.connect(host: route.host, port: route.port, pinnedFingerprint: device.certificateFingerprint, identity: identity.identity, clientSessionID: id, size: TerminalSize(columns: 80, rows: 24))
    }
    func close() { client.close() }
}

@MainActor @Observable final class TerminalVisitModel {
    enum VisitState: Equatable { case authenticating, active, authenticationCancelled, failed(String), obscured }
    var state: VisitState = .authenticating; var tabs: [TerminalTab] = []; var selectedID: UUID?
    let device: PairedMac; let route: MacRoute; private var identity: IPhoneIdentity?
    init(device: PairedMac, route: MacRoute) { self.device = device; self.route = route }
    func authorize() async {
        state = .authenticating
        do { try await LocalAuthenticator.authorizeConnection(); identity = try IPhoneIdentityProvider().loadOrCreate(); state = .active; if tabs.isEmpty { addTab() } }
        catch { state = .authenticationCancelled }
    }
    func addTab() { guard state == .active, let identity else { return }; let tab = TerminalTab(device: device, route: route, identity: identity); tabs.append(tab); selectedID = tab.id }
    func closeAll() { tabs.forEach { $0.close() }; tabs.removeAll(); selectedID = nil; identity = nil; state = .obscured }
}

struct TerminalTabsView: View {
    @State private var model: TerminalVisitModel
    @Environment(\.scenePhase) private var scenePhase
    init(device: PairedMac, route: MacRoute) { _model = State(initialValue: TerminalVisitModel(device: device, route: route)) }
    var body: some View {
        Group {
            switch model.state {
            case .active:
                VStack(spacing: 0) {
                    Picker("Session", selection: $model.selectedID) { ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in Text("Shell \(index + 1)").tag(Optional(tab.id)) } }.pickerStyle(.segmented).padding()
                    if let tab = model.tabs.first(where: { $0.id == model.selectedID }) {
                        ZStack {
                            TerminalSurfaceView(session: tab.client, shortcuts: [], saveShortcut: { _, _ in false })
                            tabStateOverlay(tab.state)
                        }
                    }
                    else { ContentUnavailableView("Disconnected", systemImage: "network.slash") }
                }
            case .authenticating: ProgressView("Authenticating…")
            case .authenticationCancelled: ContentUnavailableView("Authentication cancelled", systemImage: "faceid", description: Text("Return to the Mac list and try again."))
            case .failed(let message): ContentUnavailableView("Connection failed", systemImage: "exclamationmark.triangle", description: Text(message))
            case .obscured: Rectangle().fill(.black).overlay { ProgressView("Locked").tint(.white) }
            }
        }
        .navigationTitle(model.device.displayName)
        .toolbar { Button("New shell", systemImage: "plus") { model.addTab() }.disabled(model.state != .active) }
        .task { await model.authorize() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.closeAll() } else if model.state == .obscured { Task { await model.authorize() } } }
        .onDisappear { model.closeAll() }
    }

    @ViewBuilder private func tabStateOverlay(_ state: SessionClient.State) -> some View {
        switch state {
        case .active: EmptyView()
        case .connecting: ProgressView("Connecting…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .disconnected: ContentUnavailableView("Disconnected", systemImage: "network.slash")
        case .revoked: ContentUnavailableView("Access revoked", systemImage: "lock.slash")
        case .workingDirectoryUnavailable: ContentUnavailableView("Working directory unavailable", systemImage: "folder.badge.questionmark")
        case .certificateChanged: ContentUnavailableView("Certificate changed", systemImage: "exclamationmark.shield", description: Text("Pair this Mac again only after verifying it locally."))
        case .protocolError: ContentUnavailableView("Protocol error", systemImage: "exclamationmark.triangle")
        case .networkError(let message): ContentUnavailableView("Network error", systemImage: "wifi.exclamationmark", description: Text(message))
        }
    }
}
