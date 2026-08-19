import Darwin
import Dispatch
import Foundation
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
            guard arguments.count == 2, let enabled = ["on": true, "off": false][arguments[1]] else { throw CommandError.usage }
            try runOneShot(.init(command: .setCellularAccess, cellularEnabled: enabled))
        case "shell": try requireInteractiveTerminal(); try runLocalShell()
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

    private static func runOneShot(_ request: ControlRequest) throws {
        let channel = try ControlSocketClient.connect(url: RuntimePaths.live.controlSocketURL)
        try channel.send(request)
        let response = try channel.readResponse()
        guard response.success else { throw CommandError.remote(response.message ?? "Command failed.") }
        if let devices = response.devices {
            if devices.isEmpty { print("No paired devices.") }
            for device in devices { print("\(device.id)  \(device.displayName)  \(device.certificateFingerprint)  sessions=\(device.activeSessionCount)") }
        }
        if let cellular = response.cellularStatus {
            print("cellular=\(cellular.enabled ? "on" : "off") state=\(cellular.state.rawValue)\(cellular.diagnostic.map { " diagnostic=\($0)" } ?? "")")
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
      shell
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

    private static func runLocalShell() throws {
        let shell = try PTYProcess(size: TerminalSize(columns: 80, rows: 24)) { FileHandle.standardOutput.write($0) }
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global(qos: .userInitiated))
        input.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count > 0 { try? shell.write(Data(bytes.prefix(Int(count)))) }
            else { shell.terminate(); input.cancel(); Foundation.exit(0) }
        }
        input.resume(); dispatchMain()
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
        case .requiresInteractiveTerminal: "Pairing requires an interactive local terminal."
        case .nonPrivateNetwork: "Refusing to advertise without an eligible private interface. Use --allow-non-private-network to override."
        case .remote(let message): message
        }
    }
}
