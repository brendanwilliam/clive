import AppKit
import CliveCore
import SwiftUI

extension Notification.Name { static let macCloudRendezvousChanged = Notification.Name("MacCloudRendezvousChanged") }
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApplication.shared.registerForRemoteNotifications() }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) { NotificationCenter.default.post(name: .macCloudRendezvousChanged, object: nil) }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var status = CellularAccessStatus(enabled: false, state: .disabled)
    @Published var devices: [ControlDevice] = []
    @Published var errorMessage: String?
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

    func stop() { runtime?.stop(); runtime = nil }

    private func request(_ value: ControlRequest) throws -> ControlResponse {
        let channel = try ControlSocketClient.connect(url: RuntimePaths.live.controlSocketURL)
        try channel.send(value); return try channel.readResponse()
    }
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
            Group {
                Text("Clive — CLI for iOS").font(.headline)
                Toggle("Allow connection over cellular", isOn: Binding(get: { model.status.enabled }, set: { model.setCellular($0) }))
                Text(stateLabel).foregroundStyle(.secondary)
                if let message = model.status.diagnostic ?? model.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Divider()
                if model.devices.isEmpty { Text("No paired iPhones").foregroundStyle(.secondary) }
                else { ForEach(model.devices, id: \.id) { device in Text("\(device.displayName) — \(device.activeSessionCount) sessions") } }
                Divider()
                Button("Refresh") { Task { await model.refresh() } }
                Button("Pair from Terminal…") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("clive pair", forType: .string)
                    model.errorMessage = "Copied ‘clive pair’. Run it in Terminal to approve the new iPhone."
                }
                Button("Copy Status Command") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("clive status", forType: .string)
                    model.errorMessage = "Copied ‘clive status’. Run it in Terminal for connection and recovery details."
                }
                Button("Quit Clive") { model.stop(); NSApplication.shared.terminate(nil) }
            }
        } label: {
            Label("Clive", systemImage: model.status.enabled ? "network.badge.shield.half.filled" : "terminal")
        }
        .commandsRemoved()
        Settings { EmptyView() }
    }

    private var stateLabel: String {
        switch model.status.state {
        case .disabled: "Cellular access is off"
        case .preparing: "Preparing cellular access…"
        case .available: "Cellular access is enabled"
        case .configurationRequired: "Cellular configuration required"
        case .blocked: "Cellular access is blocked"
        }
    }
}
