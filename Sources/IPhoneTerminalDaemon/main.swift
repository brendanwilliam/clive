import Darwin
import Dispatch
import Foundation
import IPhoneTerminalCore

struct IPhoneTerminalDaemon {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            Foundation.exit(0)
        } catch {
            FileHandle.standardError.write(Data("iphone-terminald: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        let store = try TrustStore(url: pairingStoreURL())
        guard let command = arguments.first else { throw CommandError.usage }
        switch command {
        case "status":
            let devices = await store.all()
            if devices.isEmpty { print("No paired devices.") }
            for device in devices { print("\(device.id)  \(device.displayName)  \(device.certificateFingerprint)") }
        case "revoke":
            guard arguments.count == 2 else { throw CommandError.usage }
            guard try await store.revoke(id: arguments[1]) else { throw CommandError.unknownDevice(arguments[1]) }
            print("Revoked \(arguments[1]). Active sessions for this device must be terminated by the running service.")
        case "pair":
            try requireInteractiveTerminal()
            let ticket = PairingTicket(
                endpoint: "<local-ip-address>",
                port: 0,
                expiresAt: .now.addingTimeInterval(5 * 60),
                oneTimeSecret: UUID().uuidString.lowercased(),
                pairingCertificateFingerprint: "<ephemeral-tls-fingerprint>"
            )
            let encoded = try JSONEncoder().encode(ticket).base64EncodedString()
            print("Pairing ticket (expires in five minutes):\n\(encoded)")
            print("Run `iphone-terminald start` first to advertise a pairing endpoint, then render this payload as a QR code.")
        case "start":
            let allowsNonPrivateNetwork = arguments.contains("--allow-non-private-network")
            guard allowsNonPrivateNetwork || isPrivateNetworkEnvironment() else {
                throw CommandError.nonPrivateNetwork
            }
            let identityStore = TLSIdentityStore()
            let identity = try identityStore.loadOrCreate()
            let listener = try SecureListener(identity: identity)
            listener.start()
            print("Listening with TLS 1.3 on port \(listener.port.map(String.init) ?? "pending") (certificate \(try identityStore.fingerprint(of: identity))).")
            dispatchMain()
        case "shell":
            try requireInteractiveTerminal()
            try runLocalShell()
        case "stop":
            print("No foreground iphone-terminald service is running in this process.")
        case "help", "--help", "-h":
            print(usage)
        default:
            throw CommandError.usage
        }
    }

    private static func pairingStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "iphone-terminal/Pairings/devices.json")
    }

    private static func requireInteractiveTerminal() throws {
        guard isatty(STDIN_FILENO) != 0 else { throw CommandError.requiresInteractiveTerminal }
    }

    private static func isPrivateNetworkEnvironment() -> Bool {
        // A full implementation inspects active interface addresses. The explicit override
        // remains mandatory until that classifier is available.
        ProcessInfo.processInfo.environment["IPHONE_TERMINAL_PRIVATE_NETWORK"] == "1"
    }

    static let usage = """
    Usage: iphone-terminald <start|pair|status|revoke|stop> [options]
      start [--allow-non-private-network]
      shell                 Start a local PTY-backed login shell for transport diagnostics.
      pair
      status
      revoke <device-id>
      stop
    """

    private static func runLocalShell() throws {
        let shell = try PTYProcess(size: TerminalSize(columns: 80, rows: 24)) { data in
            FileHandle.standardOutput.write(data)
        }
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global(qos: .userInitiated))
        input.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count > 0 { try? shell.write(Data(bytes.prefix(Int(count)))) }
            else { shell.terminate(); input.cancel(); Foundation.exit(0) }
        }
        input.resume()
        dispatchMain()
    }
}

Task {
    await IPhoneTerminalDaemon.main()
}
dispatchMain()

private enum CommandError: LocalizedError {
    case usage
    case unknownDevice(String)
    case requiresInteractiveTerminal
    case nonPrivateNetwork

    var errorDescription: String? {
        switch self {
        case .usage: IPhoneTerminalDaemon.usage
        case .unknownDevice(let id): "No paired device with ID \(id)."
        case .requiresInteractiveTerminal: "Pairing requires an interactive local terminal."
        case .nonPrivateNetwork: "Refusing to advertise on a non-private network. Use --allow-non-private-network to opt in for this launch."
        }
    }
}
