import Darwin
import Foundation
import CliveCore

enum ControlSocketError: LocalizedError {
    case unavailable, alreadyRunning, malformedMessage, messageTooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable: "The foreground daemon is not running."
        case .alreadyRunning: "Another Clive daemon is already running."
        case .malformedMessage: "The daemon returned a malformed control message."
        case .messageTooLarge: "The control message exceeded the size limit."
        }
    }
}

private final class DaemonInstanceLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(url: URL) throws {
        let value = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard value >= 0 else { throw ControlSocketError.unavailable }
        guard Darwin.fchmod(value, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(value)
            throw ControlSocketError.unavailable
        }
        guard Darwin.lockf(value, F_TLOCK, 0) == 0 else {
            Darwin.close(value)
            throw ControlSocketError.alreadyRunning
        }
        descriptor = value
    }

    deinit { release() }

    func release() {
        let value = lock.withLock { () -> Int32 in
            let value = descriptor
            descriptor = -1
            return value
        }
        guard value >= 0 else { return }
        _ = Darwin.lockf(value, F_ULOCK, 0)
        Darwin.close(value)
    }
}

private struct SocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var status = stat()
        guard Darwin.lstat(path, &status) == 0 else { return nil }
        device = status.st_dev
        inode = status.st_ino
    }
}

private func configureDescriptor(_ descriptor: Int32, nonblocking: Bool = false) -> Bool {
    let descriptorFlags = fcntl(descriptor, F_GETFD)
    guard descriptorFlags >= 0, fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { return false }
    let statusFlags = fcntl(descriptor, F_GETFL)
    guard statusFlags >= 0 else { return false }
    let desiredStatusFlags = nonblocking ? statusFlags | O_NONBLOCK : statusFlags & ~O_NONBLOCK
    guard fcntl(descriptor, F_SETFL, desiredStatusFlags) == 0 else { return false }
    var noSigPipe: Int32 = 1
    return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe))) == 0
}

final class ControlChannel: @unchecked Sendable {
    private let descriptor: Int32
    private let writeLock = NSLock()

    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    func readRequest() throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: readLine())
    }

    func readResponse() throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: readLine())
    }

    func send(_ request: ControlRequest) throws { try write(ControlCodec.encode(request)) }
    func send(_ response: ControlResponse) throws { try write(ControlCodec.encode(response)) }
    func send(_ frame: ProtocolFrame) throws { try write(frame.encoded()) }
    func readFrame() throws -> ProtocolFrame {
        let header = try readExactly(4)
        let length = Int(header.uint32(at: 0))
        guard length >= 3, length - 3 <= ProtocolFrame.defaultMaximumPayloadSize else { throw ControlSocketError.messageTooLarge }
        var decoder = FrameDecoder(); let frames = try decoder.append(header + readExactly(length))
        guard let frame = frames.first else { throw ControlSocketError.malformedMessage }
        return frame
    }

    private func readLine() throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < ControlCodec.maximumMessageSize {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else { throw ControlSocketError.unavailable }
            if byte == 0x0a { return data }
            data.append(byte)
        }
        throw ControlSocketError.messageTooLarge
    }

    private func write(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else { throw ControlSocketError.unavailable }
            offset += written
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count); var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            guard readCount > 0 else { throw ControlSocketError.unavailable }; offset += readCount
        }
        return data
    }
}

final class ControlSocketServer: @unchecked Sendable {
    private let path: String
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let instanceLock: DaemonInstanceLock
    private let socketIdentity: SocketIdentity
    private let lifecycleLock = NSLock()
    private var started = false
    private var stopped = false
    private let handler: @Sendable (ControlRequest, ControlChannel) async -> Void

    init(url: URL, handler: @escaping @Sendable (ControlRequest, ControlChannel) async -> Void) throws {
        let socketPath = url.path
        path = socketPath
        self.handler = handler
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        instanceLock = try DaemonInstanceLock(url: url.deletingLastPathComponent().appending(path: "daemon.lock"))
        try? FileManager.default.removeItem(at: url)
        let serverDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        descriptor = serverDescriptor
        guard serverDescriptor >= 0 else { throw ControlSocketError.unavailable }
        guard configureDescriptor(serverDescriptor, nonblocking: true) else { Darwin.close(serverDescriptor); throw ControlSocketError.unavailable }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(serverDescriptor); throw ControlSocketError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in socketPath.utf8.enumerated() { bytes[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(serverDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, Darwin.listen(serverDescriptor, 8) == 0 else { Darwin.close(serverDescriptor); throw ControlSocketError.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)
        guard let identity = SocketIdentity(path: socketPath) else { Darwin.close(serverDescriptor); throw ControlSocketError.unavailable }
        socketIdentity = identity
        source = DispatchSource.makeReadSource(fileDescriptor: serverDescriptor, queue: DispatchQueue(label: "com.clive.control"))
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
    }

    deinit { stop() }

    func start() {
        let shouldStart = lifecycleLock.withLock { () -> Bool in
            guard !started, !stopped else { return false }
            started = true
            return true
        }
        if shouldStart { source.activate() }
    }

    func stop() {
        let state = lifecycleLock.withLock { () -> (shouldStop: Bool, shouldActivate: Bool) in
            guard !stopped else { return (false, false) }
            stopped = true
            return (true, !started)
        }
        guard state.shouldStop else { return }
        if state.shouldActivate { source.activate() }
        source.cancel()
        if SocketIdentity(path: path) == socketIdentity { try? FileManager.default.removeItem(atPath: path) }
        instanceLock.release()
    }

    private func acceptConnections() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { if errno == EAGAIN || errno == EWOULDBLOCK { return }; return }
            guard configureDescriptor(client) else { Darwin.close(client); continue }
            let channel = ControlChannel(descriptor: client)
            Task { [handler] in
                do { try await handler(channel.readRequest(), channel) }
                catch { try? channel.send(ControlResponse(success: false, message: error.localizedDescription)) }
            }
            return
        }
    }
}

enum ControlSocketClient {
    static func connect(url: URL) throws -> ControlChannel {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlSocketError.unavailable }
        guard configureDescriptor(descriptor) else { Darwin.close(descriptor); throw ControlSocketError.unavailable }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(descriptor); throw ControlSocketError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in path.utf8.enumerated() { bytes[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw ControlSocketError.unavailable }
        return ControlChannel(descriptor: descriptor)
    }
}
