import AppKit
import CliveCore
import CoreImage
import SwiftUI

/// UI-only public distribution destination. It is not pairing material.
enum ConnectionSetupGuideConfiguration {
    static let testFlightURL = URL(string: "https://testflight.apple.com/join/SUcN1FkH")!
}

struct ConnectionSetupAutoPresentationPolicy: Equatable {
    private var didPresent = false

    mutating func shouldPresent(hasPairedIPhone: Bool) -> Bool {
        guard !hasPairedIPhone, !didPresent else { return false }
        didPresent = true
        return true
    }
}

extension Notification.Name { static let macCloudRendezvousChanged = Notification.Name("MacCloudRendezvousChanged") }
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApplication.shared.registerForRemoteNotifications() }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) { NotificationCenter.default.post(name: .macCloudRendezvousChanged, object: nil) }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var status = CellularAccessStatus(enabled: false, state: .disabled)
    @Published var devices: [ControlDevice] = []
    @Published var sessionsByDevice: [String: [CliveCore.SessionDescriptor]] = [:]
    @Published var errorMessage: String?
    @Published var isConfiguringCellular = false
    private var runtime: DaemonRuntime?
    private var observer: NSObjectProtocol?

    func start() {
        guard runtime == nil else { return }
        do {
            let value = try DaemonRuntime(paths: .live) { }
            runtime = value
            observer = NotificationCenter.default.addObserver(forName: .macCloudRendezvousChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.runtime?.cloudDidChange(); await self?.refresh() }
            }
            Task { await value.start(); try? await Task.sleep(for: .milliseconds(250)); await refresh() }
        } catch {
            errorMessage = "The companion could not start. Stop any foreground clive process and try again. \(error.localizedDescription)"
        }
    }

    func refresh() async {
        do {
            let response = try request(.init(command: .status))
            devices = response.devices ?? []; if let cellular = response.cellularStatus { status = cellular }
            sessionsByDevice = Dictionary(uniqueKeysWithValues: devices.map { device in
                let sessions = (try? request(.init(command: .sessions, deviceID: device.id)).sessions) ?? []
                return (device.id, sessions)
            })
            errorMessage = response.message
        } catch { errorMessage = error.localizedDescription }
    }

    func setCellular(_ enabled: Bool) {
        Task {
            do {
                let response = try request(.init(command: .setCellularAccess, cellularEnabled: enabled))
                if let cellular = response.cellularStatus { status = cellular }
                errorMessage = response.success ? nil : response.message
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func configureCellular(_ configuration: CellularConfiguration) {
        guard !isConfiguringCellular else { return }
        isConfiguringCellular = true; errorMessage = nil
        Task {
            defer { isConfiguringCellular = false }
            do {
                let configured = try request(.init(command: .configureCellular, cellularConfiguration: configuration))
                guard configured.success else { throw CompanionError.message(configured.message ?? "Cellular configuration failed.") }
                let enabled = try request(.init(command: .setCellularAccess, cellularEnabled: true))
                guard enabled.success else { throw CompanionError.message(enabled.message ?? "Cellular access could not be enabled.") }
                let verification = try request(.init(command: .beginCellularVerification))
                if let status = verification.cellularStatus { self.status = status }
                errorMessage = verification.success ? nil : verification.message
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func retryCellularVerification() {
        Task {
            do {
                let response = try request(.init(command: .beginCellularVerification))
                if let status = response.cellularStatus { self.status = status }
                errorMessage = response.success ? nil : response.message
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stop() { runtime?.stop(); runtime = nil }

    func end(sessionID: UUID, deviceID: String) {
        Task { do { let response = try request(.init(command: .sessionEnd, deviceID: deviceID, sessionID: sessionID)); errorMessage = response.success ? nil : response.message; await refresh() } catch { errorMessage = error.localizedDescription } }
    }

    private func request(_ value: ControlRequest) throws -> ControlResponse {
        let channel = try ControlSocketClient.connect(url: RuntimePaths.live.controlSocketURL)
        try channel.send(value); return try channel.readResponse()
    }
}

private enum CompanionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

@main
struct CliveMacApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @StateObject private var model: CompanionModel

    init() {
        let model = CompanionModel()
        _model = StateObject(wrappedValue: model)
        Task { @MainActor in model.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model, pendingEnd: $pendingEnd)
        } label: {
            Label("Clive", systemImage: model.status.enabled ? "network.badge.shield.half.filled" : "terminal")
        }
        .commandsRemoved()
        Settings { EmptyView() }
    }

    @State private var pendingEnd: PendingEnd?
}

private struct PendingEnd { let sessionID: UUID; let deviceID: String }

private struct MenuBarContent: View {
    @ObservedObject var model: CompanionModel
    @Binding var pendingEnd: PendingEnd?

    var body: some View {
        Group {
                Text("Clive — CLI for iOS").font(.headline)
                Text(stateLabel).foregroundStyle(.secondary)
                Text("Active terminal I/O keeps idle system sleep off for up to 30 minutes. Display sleep and explicit Sleep are unaffected.").font(.caption).foregroundStyle(.secondary)
                if let message = model.status.diagnostic ?? model.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Divider()
                if model.devices.isEmpty { Text("No paired iPhones").foregroundStyle(.secondary) }
                else { ForEach(model.devices, id: \.id) { device in
                    Menu("\(device.displayName) — \(device.activeSessionCount) Terminals") {
                        if model.sessionsByDevice[device.id, default: []].isEmpty { Text("No active Terminals") }
                        ForEach(model.sessionsByDevice[device.id, default: []]) { session in
                            Menu("\(session.id.uuidString.prefix(8)) — \(session.attachmentCount) Attachments") {
                                Text("Resize owner: \(session.resizeOwner?.rawValue ?? "none")")
                                Button("Copy Attach Command") { copy("clive attach \(session.id.uuidString) --device \(device.id)") }
                                Button("End Terminal…", role: .destructive) { pendingEnd = PendingEnd(sessionID: session.id, deviceID: device.id) }
                            }
                        }
                    }
                } }
                Divider()
                Button("Refresh") { Task { await model.refresh() } }
                Button("Copy Status Command") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("clive status", forType: .string)
                    model.errorMessage = "Copied ‘clive status’. Run it in Terminal for connection and recovery details."
                }
                Button("Quit Clive") { model.stop(); NSApplication.shared.terminate(nil) }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
            .confirmationDialog("End this shared Terminal for every Attachment?", isPresented: Binding(get: { pendingEnd != nil }, set: { if !$0 { pendingEnd = nil } }), titleVisibility: .visible) {
                Button("End Shared Terminal", role: .destructive) { if let pendingEnd { model.end(sessionID: pendingEnd.sessionID, deviceID: pendingEnd.deviceID) }; pendingEnd = nil }
                Button("Cancel", role: .cancel) { pendingEnd = nil }
            }
    }

    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }

    private var stateLabel: String {
        switch model.status.state {
        case .disabled: "Cellular access is off"
        case .preparing: "Preparing cellular access…"
        case .verifying: "Waiting for iPhone verification…"
        case .available: "Cellular access is enabled"
        case .configurationRequired: "Cellular configuration required"
        case .blocked: "Cellular access is blocked"
        }
    }
}

private struct CellularSetupMenuButton: View {
    @ObservedObject var model: CompanionModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.status.state == .available ? "Cellular Setup…" : "Set Up Cellular Access…") {
            openWindow(id: "cellular-setup"); NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct CellularSetupWindow: View {
    @ObservedObject var model: CompanionModel
    @State private var mode = CellularEndpointMode.automatic
    @State private var allowMapping = false
    @State private var host = ""
    @State private var externalPort = "64236"
    @State private var listenerPort = "64236"

    var body: some View {
        Form {
            Section("Cellular route") {
                Picker("Configuration", selection: $mode) {
                    Text("Automatic").tag(CellularEndpointMode.automatic)
                    Text("Manual port forwarding").tag(CellularEndpointMode.manual)
                }.pickerStyle(.segmented)
                if mode == .automatic {
                    Toggle("Allow temporary PCP or NAT-PMP router mapping", isOn: $allowMapping)
                    Text("Clive prefers public IPv6. Router mapping is attempted only with this permission; UPnP is never used.").foregroundStyle(.secondary)
                } else {
                    TextField("Public hostname or address", text: $host)
                    TextField("External TCP port", text: $externalPort)
                    Text("Forward this TCP port to this Mac on port \(listenerPort). Mutual TLS and a rotating gate token remain required.").foregroundStyle(.secondary)
                }
                TextField("Mac listener port", text: $listenerPort)
            }
            Section("Status") {
                Text(statusText)
                if let endpoint = model.status.advertisedEndpoint { Text("Advertised route: \(endpoint.host):\(endpoint.port)\(model.status.mappingMethod.map { " via \($0)" } ?? "")").font(.system(.body, design: .monospaced)) }
                if let message = model.status.diagnostic ?? model.errorMessage { Text(message).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Refresh") { Task { await model.refresh() } }
                if model.status.enabled { Button("Retry iPhone Test") { model.retryCellularVerification() } }
                Spacer()
                Button(model.isConfiguringCellular ? "Configuring…" : "Configure and Test") { configure() }
                    .keyboardShortcut(.defaultAction).disabled(!isValid || model.isConfiguringCellular)
            }
        }
        .formStyle(.grouped).padding()
        .onAppear { loadExistingConfiguration() }
    }

    private var isValid: Bool {
        guard UInt16(listenerPort).map({ $0 > 0 }) == true else { return false }
        return mode == .automatic || (!host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && UInt16(externalPort).map({ $0 > 0 }) == true)
    }
    private var statusText: String {
        switch model.status.state {
        case .disabled: "Cellular access is off."
        case .preparing: "Preparing encrypted rendezvous…"
        case .verifying: "Turn off Wi-Fi on the paired iPhone and open Clive."
        case .available: "Cellular access was verified."
        case .configurationRequired: "Configuration or iPhone verification is required."
        case .blocked: "Cellular access is blocked."
        }
    }
    private func configure() {
        guard let localPort = UInt16(listenerPort) else { return }
        let endpoint = mode == .manual ? UInt16(externalPort).map { RemoteEndpoint(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: $0) } : nil
        model.configureCellular(.init(listenerPort: localPort, endpointMode: mode, manualEndpoint: endpoint, allowsRouterMapping: mode == .automatic && allowMapping))
    }
    private func loadExistingConfiguration() {
        guard let value = model.status.configuration else { return }
        mode = value.endpointMode; allowMapping = value.allowsRouterMapping; listenerPort = String(value.listenerPort)
        if let endpoint = value.manualEndpoint { host = endpoint.host; externalPort = String(endpoint.port) }
    }
}

private struct ConnectionSetupWindow: View {
    @ObservedObject var model: CompanionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Connect your iPhone", systemImage: "iphone.and.arrow.forward")
                    .font(.title2.bold())
                Text("Install Clive for iPhone, then pair it with this Mac. Pairing still requires your local approval and uses a separate secure code.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Get Clive for iPhone").font(.headline)
                    HStack(alignment: .center, spacing: 18) {
                        if let image = qrImage(ConnectionSetupGuideConfiguration.testFlightURL.absoluteString) {
                            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 150, height: 150)
                                .accessibilityLabel("Clive for iPhone TestFlight QR code")
                                .accessibilityIdentifier("connection-setup-testflight-qr")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan this public TestFlight link to install Clive for iPhone.")
                            Link("Get Clive for iPhone", destination: ConnectionSetupGuideConfiguration.testFlightURL)
                                .accessibilityIdentifier("connection-setup-testflight-link")
                            Text("This QR code only opens TestFlight. It cannot pair a device.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                Text("To pair an iPhone, run `clive pair` in Terminal. The command displays a single-use secure code, waits for the iPhone request, and asks for your approval before trust is saved.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .accessibilityIdentifier("connection-setup-window")
    }
}

private func qrImage(_ payload: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(payload.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let representation = NSCIImageRep(ciImage: output.transformed(by: .init(scaleX: 8, y: 8)))
    let image = NSImage(size: representation.size); image.addRepresentation(representation); return image
}
