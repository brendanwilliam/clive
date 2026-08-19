import Darwin
import Dispatch
import Foundation
import CliveCore

enum PTYProcessError: LocalizedError {
    case spawnFailed(Int32)
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code): "Could not create terminal PTY: \(String(cString: strerror(code)))."
        case .writeFailed(let code): "Could not write terminal input: \(String(cString: strerror(code)))."
        }
    }
}

/// Owns one login shell and its pseudo-terminal. It deliberately has no persistence:
/// closing the network session closes this object and sends SIGHUP to the shell process group.
final class PTYProcess: @unchecked Sendable {
    let pid: pid_t
    private let masterFD: Int32
    private let readSource: DispatchSourceRead
    private let output: @Sendable (Data) -> Void
    private let stateLock = NSLock()
    private var outputSuspended = false
    private var terminated = false

    init(size: TerminalSize, output: @escaping @Sendable (Data) -> Void) throws {
        self.output = output
        var masterFD: Int32 = -1
        var windowSize = winsize(ws_row: size.rows, ws_col: size.columns, ws_xpixel: 0, ws_ypixel: 0)
        let childPID = forkpty(&masterFD, nil, nil, &windowSize)
        guard childPID >= 0 else { throw PTYProcessError.spawnFailed(errno) }
        if childPID == 0 {
            setenv("TERM", "xterm-256color", 1)
            var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("zsh"), strdup("-l"), nil]
            arguments.withUnsafeMutableBufferPointer { buffer in
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
        }
    }
}
