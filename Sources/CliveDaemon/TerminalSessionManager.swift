import Foundation
import CliveCore

final class TerminalSessionManager: @unchecked Sendable {
    struct Attachment { let serverSessionID: UUID; let disposition: SessionOpened.Disposition; let replay: Data; let replayOffset: UInt64; let replayTruncated: Bool }
    typealias Output = @Sendable (TerminalOutputChunk, @escaping @Sendable () -> Void) -> Void
    private struct Key: Hashable { let deviceID: String; let clientSessionID: UUID }
    private final class Sink: @unchecked Sendable {
        let id: UUID; let kind: AttachmentKind; let output: Output; let onDetached: @Sendable () -> Void; let onShellExit: @Sendable () -> Void
        var backpressure = OutputBackpressure()
        init(id: UUID, kind: AttachmentKind, output: @escaping Output, onDetached: @escaping @Sendable () -> Void, onShellExit: @escaping @Sendable () -> Void) { self.id = id; self.kind = kind; self.output = output; self.onDetached = onDetached; self.onShellExit = onShellExit }
    }
    private final class Entry: @unchecked Sendable {
        let session: TerminalSession; let shell: any TerminalProcess
        var sinks: [UUID: Sink] = [:]; var resizeOwner: UUID?; var detachTimer: DispatchWorkItem?
        var replay = Data(); var replayStartOffset: UInt64 = 0; var outputOffset: UInt64 = 0
        init(session: TerminalSession, shell: any TerminalProcess) { self.session = session; self.shell = shell }
    }
    private let queue = DispatchQueue(label: "com.clive.daemon.sessions")
    private let registry: SessionRegistry; private let graceInterval: TimeInterval; private let replayLimit: Int
    private let sleepActivity: SleepActivityCoordinator; private let processFactory: TerminalProcessFactory
    private var entries: [Key: Entry] = [:]

    init(registry: SessionRegistry, graceInterval: TimeInterval = 30 * 60, replayLimit: Int = 1_048_576, sleepActivity: SleepActivityCoordinator = SleepActivityCoordinator(), processFactory: @escaping TerminalProcessFactory = { size, directory, output, onExit in try PTYProcess(size: size, workingDirectory: directory, output: output, onExit: onExit) }) {
        self.registry = registry; self.graceInterval = graceInterval; self.replayLimit = replayLimit; self.sleepActivity = sleepActivity; self.processFactory = processFactory
    }

    func attach(deviceID: String, clientSessionID: UUID, size: TerminalSize, workingDirectory: String?, attachmentID: UUID, attachmentKind: AttachmentKind = .iPhone, lastReceivedOffset: UInt64 = 0, output: @escaping Output, onSuperseded: @escaping @Sendable () -> Void, onShellExit: @escaping @Sendable () -> Void) throws -> Attachment {
        try queue.sync {
            let key = Key(deviceID: deviceID, clientSessionID: clientSessionID)
            let entry: Entry; let disposition: SessionOpened.Disposition
            if let current = entries[key] { entry = current; disposition = .resumed }
            else {
                let session = TerminalSession(deviceID: deviceID, clientSessionID: clientSessionID, size: size)
                let shell = try processFactory(size, workingDirectory, { [weak self] bytes in
                    guard let self else { return }
                    self.queue.async { self.receive(bytes, for: key) }
                }, { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.shellExited(key) }
                })
                entry = Entry(session: session, shell: shell); entries[key] = entry; disposition = .created; Task { await registry.record(session) }
            }
            entry.detachTimer?.cancel(); entry.detachTimer = nil
            entry.sinks[attachmentID] = Sink(id: attachmentID, kind: attachmentKind, output: output, onDetached: onSuperseded, onShellExit: onShellExit)
            if entry.resizeOwner == nil { entry.resizeOwner = attachmentID; entry.shell.resize(to: size) }
            let requested = min(lastReceivedOffset, entry.outputOffset); let start = max(requested, entry.replayStartOffset); let index = Int(start - entry.replayStartOffset)
            let replay = index < entry.replay.count ? Data(entry.replay.dropFirst(index)) : Data()
            return Attachment(serverSessionID: entry.session.id, disposition: disposition, replay: replay, replayOffset: start, replayTruncated: requested < entry.replayStartOffset)
        }
    }
    func input(deviceID: String, clientSessionID: UUID, attachmentID: UUID, bytes: Data) throws { try queue.sync { guard let entry = current(deviceID, clientSessionID, attachmentID) else { return }; entry.resizeOwner = attachmentID; try entry.shell.write(bytes); sleepActivity.noteActivity(sessionID: entry.session.id) } }
    func claimResize(deviceID: String, clientSessionID: UUID, attachmentID: UUID) { queue.async { self.current(deviceID, clientSessionID, attachmentID)?.resizeOwner = attachmentID } }
    func resize(deviceID: String, clientSessionID: UUID, attachmentID: UUID, size: TerminalSize) { queue.async { guard let entry = self.current(deviceID, clientSessionID, attachmentID), entry.resizeOwner == attachmentID else { return }; entry.shell.resize(to: size) } }
    func detach(deviceID: String, clientSessionID: UUID, attachmentID: UUID) { queue.async { self.removeSink(Key(deviceID: deviceID, clientSessionID: clientSessionID), attachmentID: attachmentID) } }
    func close(deviceID: String, clientSessionID: UUID, attachmentID: UUID) { queue.async { let key = Key(deviceID: deviceID, clientSessionID: clientSessionID); guard self.entries[key]?.sinks[attachmentID] != nil else { return }; self.terminate(key) } }
    func closeAll(deviceID: String) { queue.async { self.entries.keys.filter { $0.deviceID == deviceID }.forEach(self.terminate) } }
    func shutdown() { queue.sync { Array(entries.keys).forEach(terminate) }; sleepActivity.shutdown() }
    func synchronize() { queue.sync {} }
    func descriptors(deviceID: String) -> [SessionDescriptor] { queue.sync { entries.values.filter { $0.session.deviceID == deviceID }.map { entry in SessionDescriptor(id: entry.session.id, attachmentCount: entry.sinks.count, resizeOwner: entry.resizeOwner.flatMap { entry.sinks[$0]?.kind }, outputOffset: entry.outputOffset) }.sorted { $0.id.uuidString < $1.id.uuidString } } }
    func clientSessionID(deviceID: String, serverSessionID: UUID) -> UUID? { queue.sync { entries.first { $0.key.deviceID == deviceID && $0.value.session.id == serverSessionID }?.key.clientSessionID } }
    func end(deviceID: String, serverSessionID: UUID) -> Bool { queue.sync { guard let key = entries.first(where: { $0.key.deviceID == deviceID && $0.value.session.id == serverSessionID })?.key else { return false }; terminate(key); return true } }

    private func current(_ deviceID: String, _ clientSessionID: UUID, _ attachmentID: UUID) -> Entry? { let entry = entries[Key(deviceID: deviceID, clientSessionID: clientSessionID)]; return entry?.sinks[attachmentID] == nil ? nil : entry }
    private func receive(_ bytes: Data, for key: Key) {
        guard let entry = entries[key] else { return }; sleepActivity.noteActivity(sessionID: entry.session.id)
        let chunk = TerminalOutputChunk(offset: entry.outputOffset, bytes: bytes)
        entry.replay.append(bytes); entry.outputOffset = chunk.endOffset
        if entry.replay.count > replayLimit { let removed = entry.replay.count - replayLimit; entry.replay = Data(entry.replay.suffix(replayLimit)); entry.replayStartOffset += UInt64(removed) }
        for sink in Array(entry.sinks.values) {
            if sink.backpressure.enqueue(bytes.count) { removeSink(key, attachmentID: sink.id); sink.onDetached(); continue }
            sink.output(chunk) { [weak self, weak sink] in
                guard let self, let sink else { return }
                self.queue.async { guard self.entries[key]?.sinks[sink.id] === sink else { return }; _ = sink.backpressure.complete(bytes.count) }
            }
        }
    }
    private func removeSink(_ key: Key, attachmentID: UUID) {
        guard let entry = entries[key], entry.sinks.removeValue(forKey: attachmentID) != nil else { return }
        if entry.resizeOwner == attachmentID { entry.resizeOwner = entry.sinks.keys.sorted { $0.uuidString < $1.uuidString }.first }
        guard entry.sinks.isEmpty else { return }
        entry.detachTimer?.cancel(); let timer = DispatchWorkItem { [weak self] in self?.terminate(key) }; entry.detachTimer = timer; queue.asyncAfter(deadline: .now() + graceInterval, execute: timer)
    }
    private func shellExited(_ key: Key) { guard let entry = entries[key] else { return }; entry.sinks.values.forEach { $0.onShellExit() }; terminate(key) }
    private func terminate(_ key: Key) { guard let entry = entries.removeValue(forKey: key) else { return }; entry.detachTimer?.cancel(); entry.shell.terminate(); sleepActivity.end(sessionID: entry.session.id); Task { await registry.close(id: entry.session.id) } }
}
