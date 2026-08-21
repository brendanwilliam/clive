import Foundation
import CliveCore

/// Daemon-owned PTYs survive a transport disappearing. Nothing here is persisted.
final class TerminalSessionManager: @unchecked Sendable {
    struct Attachment {
        let serverSessionID: UUID
        let disposition: SessionOpened.Disposition
        let replay: Data
        let replayTruncated: Bool
    }

    typealias Output = @Sendable (Data, @escaping @Sendable () -> Void) -> Void

    private struct Key: Hashable { let deviceID: String; let clientSessionID: UUID }
    private final class Entry: @unchecked Sendable {
        let session: TerminalSession
        let shell: any TerminalProcess
        var attachmentID: UUID?
        var output: Output?
        var onSuperseded: (@Sendable () -> Void)?
        var onShellExit: (@Sendable () -> Void)?
        var detachTimer: DispatchWorkItem?
        var replay = Data()
        var replayTruncated = false
        var backpressure = OutputBackpressure()
        init(session: TerminalSession, shell: any TerminalProcess) { self.session = session; self.shell = shell }
    }

    private let queue = DispatchQueue(label: "com.clive.daemon.sessions")
    private let registry: SessionRegistry
    private let graceInterval: TimeInterval
    private let replayLimit: Int
    private let sleepActivity: SleepActivityCoordinator
    private let processFactory: TerminalProcessFactory
    private var entries: [Key: Entry] = [:]

    init(registry: SessionRegistry, graceInterval: TimeInterval = 30 * 60, replayLimit: Int = 1_048_576, sleepActivity: SleepActivityCoordinator = SleepActivityCoordinator(), processFactory: @escaping TerminalProcessFactory = { size, directory, output, onExit in try PTYProcess(size: size, workingDirectory: directory, output: output, onExit: onExit) }) {
        self.registry = registry; self.graceInterval = graceInterval; self.replayLimit = replayLimit; self.sleepActivity = sleepActivity; self.processFactory = processFactory
    }

    func attach(deviceID: String, clientSessionID: UUID, size: TerminalSize, workingDirectory: String?, attachmentID: UUID, output: @escaping Output, onSuperseded: @escaping @Sendable () -> Void, onShellExit: @escaping @Sendable () -> Void) throws -> Attachment {
        try queue.sync {
            let key = Key(deviceID: deviceID, clientSessionID: clientSessionID)
            if let entry = entries[key] {
                let replaced = entry.attachmentID != nil && entry.attachmentID != attachmentID ? entry.onSuperseded : nil
                entry.detachTimer?.cancel(); entry.detachTimer = nil
                entry.shell.resumeOutput(); entry.backpressure = OutputBackpressure()
                entry.attachmentID = attachmentID; entry.output = output
                entry.onSuperseded = onSuperseded; entry.onShellExit = onShellExit
                entry.shell.resize(to: size)
                let replay = entry.replay; let truncated = entry.replayTruncated
                entry.replay.removeAll(keepingCapacity: true); entry.replayTruncated = false
                replaced?()
                return Attachment(serverSessionID: entry.session.id, disposition: .resumed, replay: replay, replayTruncated: truncated)
            }
            let session = TerminalSession(deviceID: deviceID, clientSessionID: clientSessionID, size: size)
            let shell = try processFactory(size, workingDirectory, { [weak self] bytes in
                guard let self else { return }
                self.queue.async { self.receive(bytes, for: key) }
            }, { [weak self] in
                guard let self else { return }
                self.queue.async { self.shellExited(key) }
            })
            let entry = Entry(session: session, shell: shell)
            entry.attachmentID = attachmentID; entry.output = output
            entry.onSuperseded = onSuperseded; entry.onShellExit = onShellExit; entries[key] = entry
            Task { await registry.record(session) }
            return Attachment(serverSessionID: session.id, disposition: .created, replay: Data(), replayTruncated: false)
        }
    }

    func input(deviceID: String, clientSessionID: UUID, attachmentID: UUID, bytes: Data) throws {
        try queue.sync { guard let entry = current(deviceID, clientSessionID, attachmentID) else { return }; try entry.shell.write(bytes); sleepActivity.noteActivity(sessionID: entry.session.id) }
    }
    func resize(deviceID: String, clientSessionID: UUID, attachmentID: UUID, size: TerminalSize) {
        queue.async { self.current(deviceID, clientSessionID, attachmentID)?.shell.resize(to: size) }
    }
    func detach(deviceID: String, clientSessionID: UUID, attachmentID: UUID) {
        queue.async {
            let key = Key(deviceID: deviceID, clientSessionID: clientSessionID)
            guard let entry = self.entries[key], entry.attachmentID == attachmentID else { return }
            entry.attachmentID = nil; entry.output = nil; entry.onSuperseded = nil; entry.onShellExit = nil
            entry.shell.resumeOutput(); entry.backpressure = OutputBackpressure(); entry.detachTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in self?.terminate(key) }
            entry.detachTimer = timer; self.queue.asyncAfter(deadline: .now() + self.graceInterval, execute: timer)
        }
    }
    func close(deviceID: String, clientSessionID: UUID, attachmentID: UUID) {
        queue.async {
            let key = Key(deviceID: deviceID, clientSessionID: clientSessionID)
            guard self.entries[key]?.attachmentID == attachmentID else { return }
            self.terminate(key)
        }
    }
    func closeAll(deviceID: String) { queue.async { self.entries.keys.filter { $0.deviceID == deviceID }.forEach(self.terminate) } }
    func shutdown() { queue.sync { Array(entries.keys).forEach(terminate) }; sleepActivity.shutdown() }
    func synchronize() { queue.sync {} }

    private func current(_ deviceID: String, _ clientSessionID: UUID, _ attachmentID: UUID) -> Entry? {
        let entry = entries[Key(deviceID: deviceID, clientSessionID: clientSessionID)]
        return entry?.attachmentID == attachmentID ? entry : nil
    }
    private func receive(_ bytes: Data, for key: Key) {
        guard let entry = entries[key] else { return }
        sleepActivity.noteActivity(sessionID: entry.session.id)
        if let output = entry.output {
            if entry.backpressure.enqueue(bytes.count) { entry.shell.suspendOutput() }
            output(bytes) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard let current = self.entries[key], current === entry else { return }
                    if !current.backpressure.complete(bytes.count) { current.shell.resumeOutput() }
                }
            }
            return
        }
        entry.replay.append(bytes)
        if entry.replay.count > replayLimit {
            entry.replay.removeFirst(entry.replay.count - replayLimit); entry.replayTruncated = true
        }
    }
    private func shellExited(_ key: Key) {
        guard let entry = entries[key] else { return }
        entry.onShellExit?()
        terminate(key)
    }
    private func terminate(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.detachTimer?.cancel(); entry.shell.terminate()
        sleepActivity.end(sessionID: entry.session.id)
        Task { await registry.close(id: entry.session.id) }
    }
}
