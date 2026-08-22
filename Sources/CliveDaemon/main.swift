import Darwin
import Dispatch
import Foundation
import CliveCloud
import CliveCore

struct CliveDaemon {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            Foundation.exit(0)
        } catch {
            FileHandle.standardError.write(Data("clive: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else { throw CommandError.usage }
        switch command {
        case "start":
            if arguments.count == 1, FileManager.default.fileExists(atPath: "/Applications/Clive.app") {
                try launchCompanionApp(); return
            }
            let allowsNonPrivateNetwork = arguments.contains("--allow-non-private-network")
            let remote = try parseRemoteEndpoint(arguments)
            if arguments.contains("--clear-remote") {
                guard arguments.count == 2 else { throw CommandError.usage }
                try DaemonState.updateRemoteEndpoint(url: RuntimePaths.live.stateURL, endpoint: nil)
                return
            }
            if let remote { try DaemonState.updateRemoteEndpoint(url: RuntimePaths.live.stateURL, endpoint: remote) }
            guard allowsNonPrivateNetwork || !PrivateNetwork.eligibleAddresses().isEmpty else { throw CommandError.nonPrivateNetwork }
            try await runDaemon()
        case "pair":
            try requireInteractiveTerminal()
            try runPairingClient()
        case "status": try runOneShot(.init(command: .status))
        case "revoke":
            guard arguments.count == 2 else { throw CommandError.usage }
            try runOneShot(.init(command: .revoke, deviceID: arguments[1]))
        case "stop": try runOneShot(.init(command: .stop))
        case "cellular":
            guard arguments.count >= 2 else { throw CommandError.usage }
            switch arguments[1] {
            case "on" where arguments.count == 2: try runCellularCommand(enabled: true)
            case "off" where arguments.count == 2: try runCellularCommand(enabled: false)
            case "setup": try runCellularSetup(arguments: Array(arguments.dropFirst(2)))
            case "test" where arguments.count == 2: try runCellularTest()
            default: throw CommandError.usage
            }
        case "sessions": try runSessions(arguments: Array(arguments.dropFirst()))
        case "attach":
            guard arguments.count >= 2, let id = UUID(uuidString: arguments[1]) else { throw CommandError.usage }
            try requireInteractiveTerminal(); try runManagedTerminal(command: .sessionAttach, sessionID: id, deviceID: option("--device", in: arguments))
        case "shell": try requireInteractiveTerminal(); try runManagedTerminal(command: .sessionCreate, sessionID: nil, deviceID: option("--device", in: arguments))
        case "help", "--help", "-h": print(usage)
        default: throw CommandError.usage
        }
    }

    private static func runDaemon() async throws {
        let waiter = ShutdownWaiter()
        let runtime = try DaemonRuntime(paths: .live) { waiter.signal() }
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interrupt.setEventHandler { runtime.stop() }; terminate.setEventHandler { runtime.stop() }
        interrupt.resume(); terminate.resume()
        await runtime.start()
        await waiter.wait()
        withExtendedLifetime((runtime, interrupt, terminate)) {}
    }

    private static func launchCompanionApp() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-a", "/Applications/Clive.app"]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CommandError.remote("The Clive companion could not be launched.") }
        print("Started the Clive menu bar companion.")
    }

    private static func runCellularCommand(enabled: Bool) throws {
        let request = ControlRequest(command: .setCellularAccess, cellularEnabled: enabled)
        let response: ControlResponse
        if enabled {
            response = try CompanionStartupPolicy.run(
                companionIsInstalled: FileManager.default.fileExists(atPath: "/Applications/Clive.app"),
                launch: launchCompanionApp,
                request: { try sendOneShot(request) },
                isUnavailable: { $0 is ControlSocketError }
            )
        } else {
            response = try sendOneShot(request)
        }
        if !response.success,
           response.message == CloudRendezvousError.entitlementUnavailable.localizedDescription {
            throw CommandError.remote("\(response.message!) Stop the foreground daemon with `clive stop`, then retry so the signed companion can start.")
        }
        try printResponse(response)
        if enabled, response.cellularStatus?.state == .configurationRequired { print("Run `clive cellular setup` to finish configuration.") }
    }

    private static func runCellularSetup(arguments: [String]) throws {
        let configuration: CellularConfiguration
        if arguments.contains("--automatic") {
            guard arguments.count == 1 else { throw CommandError.usage }
            configuration = CellularConfiguration(endpointMode: .automatic, allowsRouterMapping: true)
        } else if arguments.contains("--manual") {
            guard let host = option("--host", in: arguments), let portText = option("--external-port", in: arguments), let port = UInt16(portText), port > 0 else { throw CommandError.usage }
            let listenerPort = option("--listener-port", in: arguments).flatMap(UInt16.init) ?? 64236
            configuration = CellularConfiguration(listenerPort: listenerPort, endpointMode: .manual, manualEndpoint: .init(host: host, port: port))
        } else {
            guard arguments.isEmpty else { throw CommandError.usage }
            try requireInteractiveTerminal()
            print("Clive can try a temporary TCP mapping using PCP or NAT-PMP. It will not use UPnP.")
            print("Allow Clive to request this router mapping? [Y/n]: ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if answer.isEmpty || answer == "y" || answer == "yes" {
                configuration = CellularConfiguration(endpointMode: .automatic, allowsRouterMapping: true)
            } else {
                print("Public hostname or address: ", terminator: ""); guard let host = readLine(), !host.isEmpty else { throw CommandError.usage }
                print("External TCP port [64236]: ", terminator: ""); let port = UInt16(readLine() ?? "") ?? 64236
                configuration = CellularConfiguration(endpointMode: .manual, manualEndpoint: .init(host: host, port: port))
            }
        }
        _ = try sendThroughCompanion(.init(command: .configureCellular, cellularConfiguration: configuration))
        let enabled = try sendThroughCompanion(.init(command: .setCellularAccess, cellularEnabled: true))
        try printResponse(enabled)
        guard enabled.cellularStatus?.advertisedEndpoint != nil || enabled.cellularStatus?.state != .configurationRequired else {
            print(enabled.cellularStatus?.diagnostic ?? "Router configuration is required."); return
        }
        try runCellularTest()
    }

    private static func runCellularTest() throws {
        let response = try sendThroughCompanion(.init(command: .beginCellularVerification))
        try printResponse(response)
        print("On the paired iPhone, turn off Wi-Fi and open Clive. Waiting up to 90 seconds…")
        let deadline = Date.now.addingTimeInterval(90)
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 2)
            let status = try sendOneShot(.init(command: .status))
            if status.cellularStatus?.state == .available { try printResponse(status); return }
            if status.cellularStatus?.state == .configurationRequired, let diagnostic = status.cellularStatus?.diagnostic, !diagnostic.contains("Verify") {
                throw CommandError.remote(diagnostic)
            }
        }
        throw CommandError.remote("Verification timed out. Confirm Wi-Fi is off on the iPhone, open Clive, and retry `clive cellular test`.")
    }

    private static func sendThroughCompanion(_ request: ControlRequest) throws -> ControlResponse {
        try CompanionStartupPolicy.run(
            companionIsInstalled: FileManager.default.fileExists(atPath: "/Applications/Clive.app"),
            launch: launchCompanionApp,
            request: { try sendOneShot(request) },
            isUnavailable: { $0 is ControlSocketError }
        )
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func runOneShot(_ request: ControlRequest) throws {
        try printResponse(sendOneShot(request))
    }

    private static func sendOneShot(_ request: ControlRequest) throws -> ControlResponse {
        let channel = try ControlSocketClient.connect(url: RuntimePaths.live.controlSocketURL)
        try channel.send(request)
        return try channel.readResponse()
    }

    private static func printResponse(_ response: ControlResponse) throws {
        guard response.success else { throw CommandError.remote(response.message ?? "Command failed.") }
        if let devices = response.devices {
            if devices.isEmpty { print("No paired devices.") }
            for device in devices { print("\(device.id)  \(device.displayName)  \(device.certificateFingerprint)  sessions=\(device.activeSessionCount)") }
        }
        if let cellular = response.cellularStatus {
            print("cellular=\(cellular.enabled ? "on" : "off") state=\(cellular.state.rawValue)\(cellular.diagnostic.map { " diagnostic=\($0)" } ?? "")")
            if let endpoint = cellular.advertisedEndpoint { print("endpoint=\(endpoint.host):\(endpoint.port)\(cellular.mappingMethod.map { " mapping=\($0)" } ?? "")") }
        } else if let message = response.message { print(message) }
    }

    private static func runPairingClient() throws {
        let channel = try ControlSocketClient.connect(url: RuntimePaths.live.controlSocketURL)
        try channel.send(ControlRequest(command: .pair))
        while true {
            let response = try channel.readResponse()
            guard response.success else { throw CommandError.remote(response.message ?? "Pairing failed.") }
            switch response.kind {
            case .pairingTicket:
                guard let ticket = response.pairingTicket else { throw ControlSocketError.malformedMessage }
                print("Scan this pairing code within five minutes:")
                print("Pairing endpoint: \(ticket.endpoint):\(ticket.port)")
                print(try TerminalQRCode.render(payload: PairingPayload.encode(ticket)))
                print("Waiting for the iPhone. After scanning, approve the device below.")
            case .pairingPrompt:
                guard let prompt = response.pairingPrompt else { throw ControlSocketError.malformedMessage }
                print("Pair \(prompt.displayName) (\(prompt.deviceID))?")
                print("Certificate: \(prompt.certificateFingerprint)")
                print("Approve [y/N]: ", terminator: "")
                let approved = readLine()?.lowercased() == "y"
                try channel.send(ControlRequest(command: .approvePairing, approved: approved))
            case .result:
                if let message = response.message { print(message) }
                return
            }
        }
    }

    private static func requireInteractiveTerminal() throws {
        guard isatty(STDIN_FILENO) != 0 else { throw CommandError.requiresInteractiveTerminal }
    }

    static let usage = """
    Usage: clive <start|pair|status|revoke|stop|cellular> [options]
      start [--allow-non-private-network] [--remote-host <private-vpn-host-or-ip> --session-port <port>]
      start --clear-remote
      pair
      status
      revoke <device-id>
      stop
      cellular <on|off>
      cellular setup [--automatic]
      cellular setup --manual --host <hostname-or-ip> --external-port <port> [--listener-port <port>]
      cellular test
      shell
      sessions [--device <device-id>]
      attach <session-id> [--device <device-id>]
    """

    private static func parseRemoteEndpoint(_ arguments: [String]) throws -> RemoteEndpoint? {
        let hostIndex = arguments.firstIndex(of: "--remote-host")
        let portIndex = arguments.firstIndex(of: "--session-port")
        guard hostIndex != nil || portIndex != nil else { return nil }
        guard let hostIndex, let portIndex,
              hostIndex + 1 < arguments.count, portIndex + 1 < arguments.count,
              !arguments[hostIndex + 1].isEmpty,
              let port = UInt16(arguments[portIndex + 1]), port > 0 else { throw CommandError.usage }
        return RemoteEndpoint(host: arguments[hostIndex + 1], port: port)
    }

    private static func runSessions(arguments: [String]) throws {
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--device") else { throw CommandError.usage }
        let response = try sendOneShot(.init(command: .sessions, deviceID: option("--device", in: arguments)))
        guard response.success else { throw CommandError.remote(response.message ?? "Unable to list sessions.") }
        if response.sessions?.isEmpty != false { print("No active sessions."); return }
        for session in response.sessions ?? [] { print("\(session.id.uuidString)  attachments=\(session.attachmentCount)  clive attach \(session.id.uuidString)") }
    }

    private static func runManagedTerminal(command: ControlCommand, sessionID: UUID?, deviceID: String?) throws {
        let channel = try ControlSocketClient.connect(url: RuntimePaths.live.controlSocketURL)
        let size = terminalSize()
        try channel.send(ControlRequest(command: command, deviceID: deviceID, sessionID: sessionID, initialSize: size))
        let response = try channel.readResponse(); guard response.success else { throw CommandError.remote(response.message ?? "Unable to open session.") }
        var original = termios(); guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw CommandError.requiresInteractiveTerminal }
        var raw = original; cfmakeraw(&raw); guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw CommandError.requiresInteractiveTerminal }
        defer { var restored = original; tcsetattr(STDIN_FILENO, TCSANOW, &restored) }
        try channel.send(ProtocolFrame(kind: .resizeClaim)); try channel.send(ProtocolFrame(kind: .terminalResize, payload: ProtocolPayload.encode(size)))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.signal() }
            while let frame = try? channel.readFrame() {
                if frame.kind == .sessionClose { return }
                guard frame.kind == .terminalOutput, let chunk = try? ProtocolPayload.decode(TerminalOutputChunk.self, from: frame.payload) else { continue }
                FileHandle.standardOutput.write(chunk.bytes)
            }
        }
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global(qos: .userInitiated))
        input.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count > 0 { try? channel.send(ProtocolFrame(kind: .terminalInput, payload: Data(bytes.prefix(Int(count))))) }
            else { try? channel.send(ProtocolFrame(kind: .sessionClose)); input.cancel(); finished.signal() }
        }
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInitiated))
        signal(SIGWINCH, SIG_IGN); resize.setEventHandler { try? channel.send(ProtocolFrame(kind: .terminalResize, payload: ProtocolPayload.encode(terminalSize()))) }
        input.resume(); resize.resume(); finished.wait(); input.cancel(); resize.cancel()
    }

    private static func terminalSize() -> TerminalSize {
        var value = winsize(); _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &value)
        return TerminalSize(columns: max(value.ws_col, 1), rows: max(value.ws_row, 1))
    }
}

private final class ShutdownWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false
    func wait() async { await withCheckedContinuation { value in lock.withLock { if signaled { value.resume() } else { continuation = value } } } }
    func signal() { let value = lock.withLock { () -> CheckedContinuation<Void, Never>? in signaled = true; defer { continuation = nil }; return continuation }; value?.resume() }
}

Task { await CliveDaemon.main() }
dispatchMain()

private enum CommandError: LocalizedError {
    case usage, requiresInteractiveTerminal, nonPrivateNetwork, remote(String)
    var errorDescription: String? {
        switch self {
        case .usage: CliveDaemon.usage
        case .requiresInteractiveTerminal: "This command requires an interactive local terminal."
        case .nonPrivateNetwork: "Refusing to advertise without an eligible private interface. Use --allow-non-private-network to override."
        case .remote(let message): message
        }
    }
}
