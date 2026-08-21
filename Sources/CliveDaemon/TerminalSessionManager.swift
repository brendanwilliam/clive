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

    private struct Key: Hashable { let deviceID: String; let clientSessionID: UUID }
    private final class Entry {
        let session: TerminalSession
        let shell: PTYProcess
        var attachmentID: UUID?
        var output: ((Data) -> Void)?
        var detachTimer: DispatchWorkItem?
        var replay = Data()
        var replayTruncated = false
        init(session: TerminalSession, shell: PTYProcess) { self.session = session; self.shell = shell }
    }

    private let queue = DispatchQueue(label: "com.clive.daemon.sessions")
    private let registry: SessionRegistry
    private let graceInterval: TimeInterval
    private let replayLimit: Int
    private let sleepActivity: SleepActivityCoordinator
    private var entries: [Key: Entry] = [:]

    init(registry: SessionRegistry, graceInterval: TimeInterval = 30 * 60, replayLimit: Int = 1_048_576, sleepActivity: SleepActivityCoordinator = SleepActivityCoordinator()) {
        self.registry = registry; self.graceInterval = graceInterval; self.replayLimit = replayLimit; self.sleepActivity = sleepActivity
    }

    func attach(deviceID: String, clientSessionID: UUID, size: TerminalSize, workingDirectory: String?, attachmentID: UUID, output: @escaping (Data) -> Void) throws -> Attachment {
        try queue.sync {
            let key = Key(deviceID: deviceID, clientSessionID: clientSessionID)
            if let entry = entries[key] {
                entry.detachTimer?.cancel(); entry.detachTimer = nil
                entry.attachmentID = attachmentID; entry.output = output; entry.shell.resize(to: size)
                let replay = entry.replay; let truncated = entry.replayTruncated
                entry.replay.removeAll(keepingCapacity: true); entry.replayTruncated = false
                return Attachment(serverSessionID: entry.session.id, disposition: .resumed, replay: replay, replayTruncated: truncated)
            }
            let session = TerminalSession(deviceID: deviceID, clientSessionID: clientSessionID, size: size)
            var shell: PTYProcess!
            shell = try PTYProcess(size: size, workingDirectory: workingDirectory, output: { [weak self] bytes in
                self?.queue.async { self?.receive(bytes, for: key) }
            }, onExit: { [weak self] in self?.queue.async { self?.terminate(key) } })
            let entry = Entry(session: session, shell: shell)
            entry.attachmentID = attachmentID; entry.output = output; entries[key] = entry
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
            entry.attachmentID = nil; entry.output = nil; entry.detachTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in self?.terminate(key) }
            entry.detachTimer = timer; self.queue.asyncAfter(deadline: .now() + self.graceInterval, execute: timer)
        }
    }
    func close(deviceID: String, clientSessionID: UUID) { queue.async { self.terminate(Key(deviceID: deviceID, clientSessionID: clientSessionID)) } }
    func closeAll(deviceID: String) { queue.async { self.entries.keys.filter { $0.deviceID == deviceID }.forEach(self.terminate) } }
    func shutdown() { queue.sync { Array(entries.keys).forEach(terminate) }; sleepActivity.shutdown() }

    private func current(_ deviceID: String, _ clientSessionID: UUID, _ attachmentID: UUID) -> Entry? {
        let entry = entries[Key(deviceID: deviceID, clientSessionID: clientSessionID)]
        return entry?.attachmentID == attachmentID ? entry : nil
    }
    private func receive(_ bytes: Data, for key: Key) {
        guard let entry = entries[key] else { return }
        sleepActivity.noteActivity(sessionID: entry.session.id)
        if let output = entry.output { output(bytes); return }
        entry.replay.append(bytes)
        if entry.replay.count > replayLimit {
            entry.replay.removeFirst(entry.replay.count - replayLimit); entry.replayTruncated = true
        }
    }
    private func terminate(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.detachTimer?.cancel(); entry.shell.terminate()
        sleepActivity.end(sessionID: entry.session.id)
        Task { await registry.close(id: entry.session.id) }
    }
}
