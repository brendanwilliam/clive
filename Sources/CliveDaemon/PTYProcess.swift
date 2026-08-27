import Darwin
import Dispatch
import Foundation
import CliveCore

enum PTYProcessError: LocalizedError {
    case spawnFailed(Int32)
    case writeFailed(Int32)
    case invalidWorkingDirectory

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code): "Could not create terminal PTY: \(String(cString: strerror(code)))."
        case .writeFailed(let code): "Could not write terminal input: \(String(cString: strerror(code)))."
        case .invalidWorkingDirectory: "The configured default directory is unavailable."
        }
    }
}

/// Owns one login shell and its pseudo-terminal. It deliberately has no persistence:
/// closing the network session closes this object and sends SIGHUP to the shell process group.
protocol TerminalProcess: AnyObject, Sendable {
    func write(_ bytes: Data) throws
    func resize(to size: TerminalSize)
    func suspendOutput()
    func resumeOutput()
    func terminate()
}

typealias TerminalProcessFactory = @Sendable (
    _ size: TerminalSize,
    _ workingDirectory: String?,
    _ output: @escaping @Sendable (Data) -> Void,
    _ onExit: @escaping @Sendable () -> Void
) throws -> any TerminalProcess

enum TerminalColorEnvironment {
    static let variables = [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "CLICOLOR": "1",
        "CLICOLOR_FORCE": "1",
        "FORCE_COLOR": "1",
    ]

    static func configure() {
        variables.forEach { name, value in
            setenv(name, value, 1)
        }
        unsetenv("NO_COLOR")
    }
}

final class PTYProcess: TerminalProcess, @unchecked Sendable {
    let pid: pid_t
    private let masterFD: Int32
    private let readSource: DispatchSourceRead
    private let output: @Sendable (Data) -> Void
    private let onExit: @Sendable () -> Void
    private let stateLock = NSLock()
    private var outputSuspended = false
    private var terminated = false

    init(size: TerminalSize, workingDirectory: String? = nil, command: ManagedSessionCommand = .shell, output: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void = {}) throws {
        self.output = output
        self.onExit = onExit
        let directory = try Self.resolveWorkingDirectory(workingDirectory)
        var masterFD: Int32 = -1
        var windowSize = winsize(ws_row: size.rows, ws_col: size.columns, ws_xpixel: 0, ws_ypixel: 0)
        let childPID = forkpty(&masterFD, nil, nil, &windowSize)
        guard childPID >= 0 else { throw PTYProcessError.spawnFailed(errno) }
        if childPID == 0 {
            if chdir(directory) != 0 { _exit(126) }
            TerminalColorEnvironment.configure()
            // Development tools invoked from a Clive shell sometimes need to
            // restart the daemon that owns this PTY. Give those tools a
            // reliable way to hand work off before that restart closes the
            // shell's process group.
            setenv("CLIVE_MANAGED_TERMINAL", "1", 1)
            let arguments: [String] = switch command {
            case .shell: ["zsh", "-l"]
            case .codex(let values, _): ["zsh", "-l", "-c", Self.codexScript(arguments: values)]
            }
            var childArguments = arguments.map { strdup($0) } + [nil]
            childArguments.withUnsafeMutableBufferPointer { buffer in
                _ = execv("/bin/zsh", buffer.baseAddress)
            }
            _exit(127)
        }

        self.pid = childPID
        self.masterFD = masterFD
        readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInitiated))
        readSource.setEventHandler { [weak self] in self?.readAvailableOutput() }
        readSource.setCancelHandler { close(masterFD) }
        readSource.resume()
    }

    static func codexScript(arguments: [String]) -> String {
        let command = (["codex"] + arguments).map(shellQuote).joined(separator: " ")
        return "if ! command -v codex >/dev/null 2>&1; then print -u2 'clive: codex executable was not found on PATH.'; exec zsh -l; fi; " + command + "; exec zsh -l"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func resolveWorkingDirectory(_ value: String?) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path: String
        if trimmed.isEmpty || trimmed == "~" { path = home }
        else if trimmed.hasPrefix("~/") { path = home + String(trimmed.dropFirst()) }
        else { path = trimmed }
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue, access(path, X_OK) == 0 else {
            throw PTYProcessError.invalidWorkingDirectory
        }
        return path
    }

    func write(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in Darwin.write(masterFD, buffer.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if result > 0 { offset += result; continue }
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw PTYProcessError.writeFailed(errno) }
        }
    }

    func resize(to size: TerminalSize) {
        var windowSize = winsize(ws_row: size.rows, ws_col: size.columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &windowSize)
    }

    func suspendOutput() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !outputSuspended else { return }
        outputSuspended = true; readSource.suspend()
    }
    func resumeOutput() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard outputSuspended else { return }
        outputSuspended = false; readSource.resume()
    }

    func terminate() {
        let shouldTerminate = stateLock.withLock { () -> Bool in guard !terminated else { return false }; terminated = true; return true }
        guard shouldTerminate else { return }
        _ = kill(-pid, SIGHUP)
        resumeOutput()
        readSource.cancel()
        let child = pid
        DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {} }
    }

    deinit { terminate() }

    private func readAvailableOutput() {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(masterFD, &bytes, bytes.count)
        if count > 0 {
            output(Data(bytes.prefix(Int(count))))
        } else if count == 0 || errno != EAGAIN {
            readSource.cancel()
            onExit()
        }
    }
}
