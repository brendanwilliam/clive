import AppKit
import CliveCore
import CoreImage
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
    @Published var pairingTicket: PairingTicket?
    @Published var pairingPrompt: PairingPrompt?
    @Published var pairingMessage: String?
    @Published var isPairing = false
    @Published var shouldDismissPairingWindow = false
    private var pairingChannel: ControlChannel?
    private var submittedPairingDecision = false
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

    func beginPairing() {
        guard !isPairing else { return }
        isPairing = true; pairingTicket = nil; pairingPrompt = nil; pairingMessage = nil
        shouldDismissPairingWindow = false; submittedPairingDecision = false
        Task.detached { [weak self] in
            do {
                let channel = try ControlSocketClient.connect(url: RuntimePaths.live.controlSocketURL)
                try channel.send(.init(command: .pair))
                await MainActor.run { self?.pairingChannel = channel }
                while true {
                    let response = try channel.readResponse()
                    await MainActor.run {
                        guard let self else { return }
                        switch response.kind {
                        case .pairingTicket: self.pairingTicket = response.pairingTicket
                        case .pairingPrompt: self.pairingPrompt = response.pairingPrompt
                        case .result:
                            self.pairingMessage = response.message
                            self.isPairing = false; self.pairingChannel = nil
                            self.pairingPrompt = nil
                            self.shouldDismissPairingWindow = self.submittedPairingDecision || response.success || response.message == "Pairing ticket expired."
                            Task { await self.refresh() }
                        }
                    }
                    if response.kind == .result { return }
                }
            } catch {
                await MainActor.run { self?.pairingMessage = error.localizedDescription; self?.isPairing = false; self?.pairingChannel = nil }
            }
        }
    }

    func approvePairing(_ approved: Bool) {
        do {
            guard let pairingChannel else { throw ControlSocketError.unavailable }
            submittedPairingDecision = true
            try pairingChannel.send(.init(command: .approvePairing, approved: approved)); pairingPrompt = nil
        }
        catch { pairingMessage = error.localizedDescription; isPairing = false }
    }

    func cancelPairing() {
        guard isPairing else { return }
        Task.detached { [weak self] in
            do { let channel = try ControlSocketClient.connect(url: RuntimePaths.live.controlSocketURL); try channel.send(.init(command: .cancelPairing)); _ = try channel.readResponse() }
            catch { await MainActor.run { self?.pairingMessage = error.localizedDescription } }
        }
        pairingTicket = nil; pairingPrompt = nil
    }

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
                PairMenuButton(model: model)
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
        WindowGroup("Pair iPhone", id: "pair-iphone") {
            PairingWindow(model: model)
                .frame(minWidth: 390, minHeight: 500)
        }
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

private struct PairMenuButton: View {
    @ObservedObject var model: CompanionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Pair iPhone") {
            model.beginPairing()
            openWindow(id: "pair-iphone")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct PairingWindow: View {
    @ObservedObject var model: CompanionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair iPhone").font(.title2.bold())
            if let ticket = model.pairingTicket, let image = qrImage(for: ticket) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 280, height: 280)
                Text("Scan this code in Clive for iPhone. It expires \(ticket.expiresAt, style: .relative).")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else if model.isPairing { ProgressView("Creating secure pairing code…") }
            if let prompt = model.pairingPrompt {
                Divider(); Text("Pair \(prompt.displayName)?").font(.headline)
                Text("Certificate fingerprint\n\(prompt.certificateFingerprint)").font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.center)
                HStack { Button("Reject") { model.approvePairing(false) }; Button("Approve") { model.approvePairing(true) }.keyboardShortcut(.defaultAction) }
            }
            if let message = model.pairingMessage { Text(message).foregroundStyle(.secondary) }
            Spacer()
            Button("Cancel") { model.cancelPairing(); dismiss() }
        }
        .padding(24)
        .onChange(of: model.shouldDismissPairingWindow) { shouldDismiss in
            if shouldDismiss { dismiss() }
        }
        .onDisappear { model.cancelPairing() }
    }

    private func qrImage(for ticket: PairingTicket) -> NSImage? {
        guard let payload = try? PairingPayload.encode(ticket), let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: .init(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
