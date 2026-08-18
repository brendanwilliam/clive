import Darwin
import Foundation
import IPhoneTerminalCore

enum ControlSocketError: LocalizedError {
    case unavailable, malformedMessage, messageTooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable: "The foreground daemon is not running."
        case .malformedMessage: "The daemon returned a malformed control message."
        case .messageTooLarge: "The control message exceeded the size limit."
        }
    }
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
}

final class ControlSocketServer: @unchecked Sendable {
    private let path: String
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let handler: @Sendable (ControlRequest, ControlChannel) async -> Void

    init(url: URL, handler: @escaping @Sendable (ControlRequest, ControlChannel) async -> Void) throws {
        let socketPath = url.path
        path = socketPath
        self.handler = handler
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let serverDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        descriptor = serverDescriptor
        guard serverDescriptor >= 0 else { throw ControlSocketError.unavailable }
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
        source = DispatchSource.makeReadSource(fileDescriptor: serverDescriptor, queue: DispatchQueue(label: "com.iphoneterminal.control"))
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
    }

    func start() { source.resume() }
    func stop() { source.cancel(); try? FileManager.default.removeItem(atPath: path) }

    private func acceptConnections() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { if errno == EAGAIN || errno == EWOULDBLOCK { return }; return }
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
