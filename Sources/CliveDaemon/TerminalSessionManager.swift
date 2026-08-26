import Foundation
import CliveCore

final class TerminalSessionManager: @unchecked Sendable {
    static let detachedSessionGraceInterval: TimeInterval = 90 * 60
    static let replayRingLimit = 1_048_576

    struct Attachment {
        let serverSessionID: UUID
        let disposition: SessionOpened.Disposition
        let replay: Data
        let replayOffset: UInt64
        let replayTruncated: Bool
        let generation: UInt64
    }
    enum DetachmentReason { case slowConsumer, replaced }
    enum AttachmentError: Error, Equatable, LocalizedError {
        case attachedByDifferentEndpoint

        var errorDescription: String? {
            switch self {
            case .attachedByDifferentEndpoint:
                "The requested session is still attached to an active terminal on a different endpoint. Disconnect it before trying again."
            }
        }
    }
    typealias Output = @Sendable (TerminalOutputChunk, @escaping @Sendable () -> Void) -> Void
    typealias CatalogUpdate = @Sendable ([SessionDescriptor]) -> Void
    typealias StateUpdate = @Sendable (AttachmentState) -> Void
    private struct Key: Hashable { let deviceID: String; let clientSessionID: UUID }
    private final class Sink: @unchecked Sendable {
        let id: UUID; let kind: AttachmentKind; let generation: UInt64; let output: Output; let onDetached: @Sendable (DetachmentReason) -> Void; let onShellExit: @Sendable () -> Void
        var size: TerminalSize
        var activitySequence: UInt64
        var backpressure = OutputBackpressure()
        let onState: StateUpdate
        init(id: UUID, kind: AttachmentKind, generation: UInt64, size: TerminalSize, activitySequence: UInt64, output: @escaping Output, onDetached: @escaping @Sendable (DetachmentReason) -> Void, onShellExit: @escaping @Sendable () -> Void, onState: @escaping StateUpdate) { self.id = id; self.kind = kind; self.generation = generation; self.size = size; self.activitySequence = activitySequence; self.output = output; self.onDetached = onDetached; self.onShellExit = onShellExit; self.onState = onState }
    }
    private final class Entry: @unchecked Sendable {
        let session: TerminalSession; let shell: any TerminalProcess; let label: String?
        var sinks: [UUID: Sink] = [:]; var resizeOwner: UUID?; var detachTimer: DispatchWorkItem?
        var nextGeneration: UInt64 = 0; var authoritativeGeneration: UInt64?
        var replay = Data(); var replayStartOffset: UInt64 = 0; var outputOffset: UInt64 = 0; var activitySequence: UInt64 = 0
        init(session: TerminalSession, shell: any TerminalProcess, label: String?) { self.session = session; self.shell = shell; self.label = label }
    }
    private let queue = DispatchQueue(label: "com.clive.daemon.sessions")
    private let registry: SessionRegistry; private let graceInterval: TimeInterval; private let replayLimit: Int
    private let sleepActivity: SleepActivityCoordinator; private let processFactory: TerminalProcessFactory
    private var entries: [Key: Entry] = [:]
    private var catalogSubscribers: [UUID: (deviceID: String, update: CatalogUpdate)] = [:]

    init(registry: SessionRegistry, graceInterval: TimeInterval = 90 * 60, replayLimit: Int = 1_048_576, sleepActivity: SleepActivityCoordinator = SleepActivityCoordinator(), processFactory: @escaping TerminalProcessFactory = { size, directory, output, onExit in try PTYProcess(size: size, workingDirectory: directory, output: output, onExit: onExit) }) {
        self.registry = registry; self.graceInterval = graceInterval; self.replayLimit = replayLimit; self.sleepActivity = sleepActivity; self.processFactory = processFactory
    }

    func attach(deviceID: String, clientSessionID: UUID, size: TerminalSize, workingDirectory: String?, command: ManagedSessionCommand = .shell, attachmentID: UUID, attachmentKind: AttachmentKind = .iPhone, lastReceivedOffset: UInt64 = 0, output: @escaping Output, onSuperseded: @escaping @Sendable () -> Void, onShellExit: @escaping @Sendable () -> Void, onState: @escaping StateUpdate = { _ in }) throws -> Attachment {
        try attach(deviceID: deviceID, clientSessionID: clientSessionID, size: size, workingDirectory: workingDirectory, command: command, mayCreate: true, attachmentID: attachmentID, attachmentKind: attachmentKind, lastReceivedOffset: lastReceivedOffset, output: output, onDetached: { _ in onSuperseded() }, onShellExit: onShellExit, onState: onState)
    }
    func attachExisting(deviceID: String, serverSessionID: UUID, size: TerminalSize, attachmentID: UUID, attachmentKind: AttachmentKind, lastReceivedOffset: UInt64, output: @escaping Output, onDetached: @escaping @Sendable (DetachmentReason) -> Void, onShellExit: @escaping @Sendable () -> Void, onState: @escaping StateUpdate = { _ in }) throws -> Attachment? {
        try queue.sync {
            guard let key = entries.first(where: { $0.key.deviceID == deviceID && $0.value.session.id == serverSessionID })?.key else { return nil }
            return try attachLocked(key: key, size: size, workingDirectory: nil, command: .shell, mayCreate: false, attachmentID: attachmentID, attachmentKind: attachmentKind, lastReceivedOffset: lastReceivedOffset, output: output, onDetached: onDetached, onShellExit: onShellExit, onState: onState)
        }
    }
    private func attach(deviceID: String, clientSessionID: UUID, size: TerminalSize, workingDirectory: String?, command: ManagedSessionCommand = .shell, mayCreate: Bool, attachmentID: UUID, attachmentKind: AttachmentKind, lastReceivedOffset: UInt64, output: @escaping Output, onDetached: @escaping @Sendable (DetachmentReason) -> Void, onShellExit: @escaping @Sendable () -> Void, onState: @escaping StateUpdate) throws -> Attachment {
        try queue.sync {
            let key = Key(deviceID: deviceID, clientSessionID: clientSessionID)
            return try attachLocked(key: key, size: size, workingDirectory: workingDirectory, command: command, mayCreate: mayCreate, attachmentID: attachmentID, attachmentKind: attachmentKind, lastReceivedOffset: lastReceivedOffset, output: output, onDetached: onDetached, onShellExit: onShellExit, onState: onState)
        }
    }
    private func attachLocked(key: Key, size: TerminalSize, workingDirectory: String?, command: ManagedSessionCommand, mayCreate: Bool, attachmentID: UUID, attachmentKind: AttachmentKind, lastReceivedOffset: UInt64, output: @escaping Output, onDetached: @escaping @Sendable (DetachmentReason) -> Void, onShellExit: @escaping @Sendable () -> Void, onState: @escaping StateUpdate) throws -> Attachment {
            let entry: Entry; let disposition: SessionOpened.Disposition
            if let current = entries[key] { entry = current; disposition = .resumed }
            else {
                precondition(mayCreate)
                let session = TerminalSession(deviceID: key.deviceID, clientSessionID: key.clientSessionID, size: size)
                let outputHandler: @Sendable (Data) -> Void = { [weak self] bytes in
                    guard let self else { return }
                    self.queue.async { self.receive(bytes, for: key) }
                }
                let exitHandler: @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.shellExited(key) }
                }
                let shell: any TerminalProcess
                switch command {
                case .shell: shell = try processFactory(size, workingDirectory, outputHandler, exitHandler)
                case .codex: shell = try PTYProcess(size: size, workingDirectory: workingDirectory, command: command, output: outputHandler, onExit: exitHandler)
                }
                let label = commandLabel(command)
                entry = Entry(session: session, shell: shell, label: label); entries[key] = entry; disposition = .created; Task { await registry.record(session) }
            }
            entry.detachTimer?.cancel(); entry.detachTimer = nil
            let requested = min(lastReceivedOffset, entry.outputOffset); let start = max(requested, entry.replayStartOffset); let index = Int(start - entry.replayStartOffset)
            let replay = index < entry.replay.count ? Data(entry.replay.dropFirst(index)) : Data()
            let replayTruncated = requested < entry.replayStartOffset
            entry.nextGeneration &+= 1
            let generation = entry.nextGeneration
            let previous = entry.sinks.values.first
            if let existing = previous {
                guard existing.kind == attachmentKind else { throw AttachmentError.attachedByDifferentEndpoint }
            }
            // The queue is the handoff fence: install the new generation before
            // notifying the old connection, so a stale close cannot remove it.
            if let existing = previous { entry.sinks.removeValue(forKey: existing.id); if entry.resizeOwner == existing.id { entry.resizeOwner = nil } }
            entry.activitySequence &+= 1
            entry.sinks[attachmentID] = Sink(id: attachmentID, kind: attachmentKind, generation: generation, size: size, activitySequence: entry.activitySequence, output: output, onDetached: onDetached, onShellExit: onShellExit, onState: onState)
            entry.authoritativeGeneration = generation
            if entry.resizeOwner == nil { entry.resizeOwner = attachmentID; entry.shell.resize(to: size) }
            previous?.onDetached(.replaced)
            publish(entry)
            return Attachment(serverSessionID: entry.session.id, disposition: disposition, replay: replay, replayOffset: start, replayTruncated: replayTruncated, generation: generation)
    }
    func input(deviceID: String, clientSessionID: UUID, attachmentID: UUID, bytes: Data) throws { try queue.sync { guard let entry = current(deviceID, clientSessionID, attachmentID), let sink = entry.sinks[attachmentID], sink.generation == entry.authoritativeGeneration else { return }; entry.activitySequence &+= 1; sink.activitySequence = entry.activitySequence; entry.resizeOwner = attachmentID; entry.shell.resize(to: sink.size); try entry.shell.write(bytes); sleepActivity.noteActivity(sessionID: entry.session.id); publish(entry) } }
    func claimResize(deviceID: String, clientSessionID: UUID, attachmentID: UUID) { queue.async { guard let entry = self.current(deviceID, clientSessionID, attachmentID), let sink = entry.sinks[attachmentID] else { return }; entry.activitySequence &+= 1; sink.activitySequence = entry.activitySequence; entry.resizeOwner = attachmentID; entry.shell.resize(to: sink.size); self.publish(entry) } }
    func resize(deviceID: String, clientSessionID: UUID, attachmentID: UUID, size: TerminalSize) { queue.async { guard let entry = self.current(deviceID, clientSessionID, attachmentID), let sink = entry.sinks[attachmentID] else { return }; sink.size = size; if entry.resizeOwner == attachmentID { entry.shell.resize(to: size) }; self.publish(entry) } }
    func detach(deviceID: String, clientSessionID: UUID, attachmentID: UUID) { queue.async { self.removeSink(Key(deviceID: deviceID, clientSessionID: clientSessionID), attachmentID: attachmentID) } }
    func close(deviceID: String, clientSessionID: UUID, attachmentID: UUID) { queue.async { let key = Key(deviceID: deviceID, clientSessionID: clientSessionID); guard self.entries[key]?.sinks[attachmentID] != nil else { return }; self.terminate(key) } }
    func closeAll(deviceID: String) { queue.async { self.entries.keys.filter { $0.deviceID == deviceID }.forEach(self.terminate) } }
    func shutdown() { queue.sync { Array(entries.keys).forEach(terminate) }; sleepActivity.shutdown() }
    func synchronize() { queue.sync {} }
    func descriptors(deviceID: String) -> [SessionDescriptor] { queue.sync { entries.values.filter { $0.session.deviceID == deviceID }.map { descriptor($0) }.sorted { $0.id.uuidString < $1.id.uuidString } } }
    func subscribe(deviceID: String, identifier: UUID, update: @escaping CatalogUpdate) { queue.async { self.catalogSubscribers[identifier] = (deviceID, update); update(self.descriptorsLocked(deviceID: deviceID)) } }
    func unsubscribe(identifier: UUID) { queue.async { self.catalogSubscribers.removeValue(forKey: identifier) } }
    func clientSessionID(deviceID: String, serverSessionID: UUID) -> UUID? { queue.sync { entries.first { $0.key.deviceID == deviceID && $0.value.session.id == serverSessionID }?.key.clientSessionID } }
    func end(deviceID: String, serverSessionID: UUID) -> Bool { queue.sync { guard let key = entries.first(where: { $0.key.deviceID == deviceID && $0.value.session.id == serverSessionID })?.key else { return false }; terminate(key); return true } }
    func endMany(deviceID: String, serverSessionIDs: [UUID]) -> [UUID] { queue.sync {
        let requested = Set(serverSessionIDs)
        let matches = entries.compactMap { key, entry in
            key.deviceID == deviceID && requested.contains(entry.session.id) ? (key, entry.session.id) : nil
        }
        matches.forEach { terminate($0.0) }
        return matches.map(\.1).sorted { $0.uuidString < $1.uuidString }
    } }

    private func current(_ deviceID: String, _ clientSessionID: UUID, _ attachmentID: UUID) -> Entry? { let entry = entries[Key(deviceID: deviceID, clientSessionID: clientSessionID)]; return entry?.sinks[attachmentID] == nil ? nil : entry }
    private func receive(_ bytes: Data, for key: Key) {
        guard let entry = entries[key] else { return }; sleepActivity.noteActivity(sessionID: entry.session.id)
        let chunk = TerminalOutputChunk(offset: entry.outputOffset, bytes: bytes)
        entry.replay.append(bytes); entry.outputOffset = chunk.endOffset
        if entry.replay.count > replayLimit { let removed = entry.replay.count - replayLimit; entry.replay = Data(entry.replay.suffix(replayLimit)); entry.replayStartOffset += UInt64(removed) }
        for sink in Array(entry.sinks.values) {
            if sink.backpressure.enqueue(bytes.count) { removeSink(key, attachmentID: sink.id); sink.onDetached(.slowConsumer); continue }
            sink.output(chunk) { [weak self, weak sink] in
                guard let self, let sink else { return }
                self.queue.async { guard self.entries[key]?.sinks[sink.id] === sink else { return }; _ = sink.backpressure.complete(bytes.count) }
            }
        }
    }
    private func removeSink(_ key: Key, attachmentID: UUID) {
        guard let entry = entries[key], entry.sinks.removeValue(forKey: attachmentID) != nil else { return }
        if entry.resizeOwner == attachmentID { entry.resizeOwner = entry.sinks.values.max { $0.activitySequence < $1.activitySequence }?.id; if let owner = entry.resizeOwner, let sink = entry.sinks[owner] { entry.shell.resize(to: sink.size) } }
        publish(entry)
        guard entry.sinks.isEmpty else { return }
        entry.detachTimer?.cancel(); let timer = DispatchWorkItem { [weak self] in self?.terminate(key) }; entry.detachTimer = timer; queue.asyncAfter(deadline: .now() + graceInterval, execute: timer)
    }
    private func shellExited(_ key: Key) { terminate(key) }
    private func terminate(_ key: Key) { guard let entry = entries.removeValue(forKey: key) else { return }; entry.detachTimer?.cancel(); entry.sinks.values.forEach { $0.onShellExit() }; entry.shell.terminate(); sleepActivity.end(sessionID: entry.session.id); publishCatalog(deviceID: key.deviceID); Task { await registry.close(id: entry.session.id) } }
    private func descriptorsLocked(deviceID: String) -> [SessionDescriptor] { entries.values.filter { $0.session.deviceID == deviceID }.map { entry in descriptor(entry) }.sorted { $0.id.uuidString < $1.id.uuidString } }
    private func descriptor(_ entry: Entry) -> SessionDescriptor { SessionDescriptor(id: entry.session.id, label: entry.label, attachmentCount: entry.sinks.count, resizeOwner: entry.resizeOwner.flatMap { entry.sinks[$0]?.kind }, outputOffset: entry.outputOffset) }
    private func commandLabel(_ command: ManagedSessionCommand) -> String? { if case .codex(_, let label) = command { return label }; return nil }
    private func publish(_ entry: Entry) { let value = descriptor(entry); let state = AttachmentState(sessionID: value.id, attachmentCount: value.attachmentCount, resizeOwner: value.resizeOwner, outputOffset: value.outputOffset); entry.sinks.values.forEach { $0.onState(state) }; publishCatalog(deviceID: entry.session.deviceID) }
    private func publishCatalog(deviceID: String) { let value = descriptorsLocked(deviceID: deviceID); catalogSubscribers.values.filter { $0.deviceID == deviceID }.forEach { $0.update(value) } }
}
