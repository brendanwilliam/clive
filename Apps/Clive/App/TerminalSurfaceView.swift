import CliveCore
import SwiftTerm
import SwiftUI

struct TerminalSurfaceView: UIViewRepresentable {
    let session: SessionClient?
    let shortcuts: [CLIShortcut]
    let saveShortcut: (String, String) -> Bool
    var isFirstTerminal = false
    var isLastTerminal = false
    var onSwipePastFirst: () -> Void = {}
    var onSwipePastLast: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(session: session, shortcuts: shortcuts, saveShortcut: saveShortcut, isFirstTerminal: isFirstTerminal, isLastTerminal: isLastTerminal, onSwipePastFirst: onSwipePastFirst, onSwipePastLast: onSwipePastLast) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero); view.terminalDelegate = context.coordinator
        context.coordinator.view = view; context.coordinator.installAccessory(on: view); context.coordinator.installEdgeControls(on: view)
        view.keyboardDismissMode = TerminalSurfaceConfiguration.keyboardDismissMode
        session?.onOutput = { [weak view] data in DispatchQueue.main.async { view?.feed(byteArray: ArraySlice(data)) } }
        return view
    }
    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.updateBoundaryContext(isFirstTerminal: isFirstTerminal, isLastTerminal: isLastTerminal, onSwipePastFirst: onSwipePastFirst, onSwipePastLast: onSwipePastLast)
        context.coordinator.accessory?.updateShortcuts(shortcuts)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        var session: SessionClient?; weak var view: TerminalView?
        fileprivate var accessory: TerminalKeyboardAccessory?
        private var shortcuts: [CLIShortcut]
        private var commandTracker = TerminalCommandTracker()
        private let saveShortcut: (String, String) -> Bool
        private var isFirstTerminal: Bool
        private var isLastTerminal: Bool
        private var onSwipePastFirst: () -> Void
        private var onSwipePastLast: () -> Void
        private var boundaryGate = TerminalBoundaryGestureGate()
        init(session: SessionClient?, shortcuts: [CLIShortcut], saveShortcut: @escaping (String, String) -> Bool, isFirstTerminal: Bool, isLastTerminal: Bool, onSwipePastFirst: @escaping () -> Void, onSwipePastLast: @escaping () -> Void) {
            self.session = session; self.shortcuts = shortcuts; self.saveShortcut = saveShortcut
            self.isFirstTerminal = isFirstTerminal; self.isLastTerminal = isLastTerminal
            self.onSwipePastFirst = onSwipePastFirst; self.onSwipePastLast = onSwipePastLast
        }
        func updateBoundaryContext(isFirstTerminal: Bool, isLastTerminal: Bool, onSwipePastFirst: @escaping () -> Void, onSwipePastLast: @escaping () -> Void) {
            if self.isFirstTerminal != isFirstTerminal || self.isLastTerminal != isLastTerminal { boundaryGate.reset() }
            self.isFirstTerminal = isFirstTerminal; self.isLastTerminal = isLastTerminal
            self.onSwipePastFirst = onSwipePastFirst; self.onSwipePastLast = onSwipePastLast
        }
        @MainActor func installAccessory(on view: TerminalView) {
            let accessory = TerminalKeyboardAccessory(shortcuts: shortcuts, saveLastCommand: { [weak self] name, command in self?.saveShortcut(name, command) ?? false }, send: { [weak self] data in self?.sendInput(data) }, command: { [weak self] key in self?.performCommand(key) }, onLayoutChanged: { [weak view] in view?.reloadInputViews() })
            self.accessory = accessory
            view.inputAccessoryView = accessory
            // SwiftTerm installs a default accessory during its initialization. Reload the
            // responder so UIKit replaces that view even if the terminal is already focused.
            view.reloadInputViews()
            _ = view.becomeFirstResponder()
        }
        @MainActor func installEdgeControls(on view: TerminalView) {
            let gesture = TerminalEdgeTapGestureRecognizer { [weak self] sequence in self?.session?.sendInput(Data(sequence.utf8)) }
            gesture.cancelsTouchesInView = false; view.addGestureRecognizer(gesture)
            view.accessibilityCustomActions = [
                ("Cursor up", "\u{1b}[A"), ("Cursor down", "\u{1b}[B"),
                ("Cursor left", "\u{1b}[D"), ("Cursor right", "\u{1b}[C")
            ].map { name, sequence in UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.session?.sendInput(Data(sequence.utf8)); return true } }
            let right = NonPreventingSwipeGestureRecognizer(target: self, action: #selector(boundarySwipe(_:))); right.direction = .right
            let left = NonPreventingSwipeGestureRecognizer(target: self, action: #selector(boundarySwipe(_:))); left.direction = .left
            right.cancelsTouchesInView = false; left.cancelsTouchesInView = false
            view.addGestureRecognizer(right); view.addGestureRecognizer(left)
        }
        @objc @MainActor private func boundarySwipe(_ gesture: UISwipeGestureRecognizer) {
            switch boundaryGate.takeAction(direction: gesture.direction, isFirstTerminal: isFirstTerminal, isLastTerminal: isLastTerminal) {
            case .openDrawer: onSwipePastFirst()
            case .createTerminal: onSwipePastLast()
            case .none: break
            }
        }
        @MainActor private func performCommand(_ key: String) {
            switch key.lowercased() {
            case "k": view?.feed(byteArray: ArraySlice("\u{1b}[2J\u{1b}[H".utf8))
            case "w": session?.close()
            default: break // C/V/A/T/[ / ] are handled by the workspace command router.
            }
            accessory?.resetModifiers()
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let input = Data(data)
            MainActor.assumeIsolated {
                if let accessory {
                    guard let transformed = accessory.transformSoftwareInput(input) else { return }
                    sendInput(transformed)
                } else {
                    session?.sendInput(input)
                }
            }
        }
        @MainActor private func sendInput(_ data: Data) {
            commandTracker.consume(data)
            accessory?.updateLastCommand(commandTracker.lastCommand)
            session?.sendInput(data)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0, newCols <= Int(UInt16.max), newRows <= Int(UInt16.max) else { return }
            session?.resize(TerminalSize(columns: UInt16(newCols), rows: UInt16(newRows)))
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

@MainActor private final class NonPreventingSwipeGestureRecognizer: UISwipeGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

enum TerminalBoundaryAction: Hashable { case openDrawer, createTerminal }

enum TerminalSurfaceConfiguration { static let keyboardDismissMode: UIScrollView.KeyboardDismissMode = .interactive }

enum TerminalBoundaryGesturePolicy {
    static func action(direction: UISwipeGestureRecognizer.Direction, isFirstTerminal: Bool, isLastTerminal: Bool) -> TerminalBoundaryAction? {
        if direction == .right, isFirstTerminal { return .openDrawer }
        if direction == .left, isLastTerminal { return .createTerminal }
        return nil
    }
}

struct TerminalBoundaryGestureGate {
    private var consumed: Set<TerminalBoundaryAction> = []

    mutating func takeAction(direction: UISwipeGestureRecognizer.Direction, isFirstTerminal: Bool, isLastTerminal: Bool) -> TerminalBoundaryAction? {
        guard let action = TerminalBoundaryGesturePolicy.action(direction: direction, isFirstTerminal: isFirstTerminal, isLastTerminal: isLastTerminal),
              consumed.insert(action).inserted else { return nil }
        return action
    }

    mutating func reset() { consumed.removeAll() }
}

struct TerminalCommandTracker {
    private(set) var currentCommand = ""
    private(set) var lastCommand: String?

    mutating func consume(_ data: Data) {
        if data.first == 0x1b { return }
        for byte in data {
            switch byte {
            case 0x0d, 0x0a:
                let command = currentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty { lastCommand = command }
                currentCommand = ""
            case 0x08, 0x7f:
                if !currentCommand.isEmpty { currentCommand.removeLast() }
            case 0x03:
                currentCommand = ""
            case 0x20...0x7e:
                currentCommand.append(Character(UnicodeScalar(byte)))
            default:
                break
            }
        }
    }
}

struct TerminalEdgeGesturePolicy {
    static let edgeWidth: CGFloat = 44
    static let maximumMovement: CGFloat = 10
    static let maximumDuration: TimeInterval = 0.35

    static func sequence(at point: CGPoint, in bounds: CGRect) -> String? {
        let distances: [(CGFloat, Bool, String)] = [
            (point.y - bounds.minY, true, "\u{1b}[A"), (bounds.maxY - point.y, true, "\u{1b}[B"),
            (point.x - bounds.minX, false, "\u{1b}[D"), (bounds.maxX - point.x, false, "\u{1b}[C")
        ].filter { $0.0 >= 0 && $0.0 <= edgeWidth }
        return distances.min { lhs, rhs in lhs.0 == rhs.0 ? (lhs.1 && !rhs.1) : lhs.0 < rhs.0 }?.2
    }

    static func accepts(movement: CGFloat, duration: TimeInterval) -> Bool {
        movement <= maximumMovement && duration < maximumDuration
    }
}

@MainActor private final class TerminalEdgeTapGestureRecognizer: UIGestureRecognizer {
    private let send: (String) -> Void
    private var start = CGPoint.zero
    private var beganAt = Date()
    private var sequence: String?
    init(send: @escaping (String) -> Void) { self.send = send; super.init(target: nil, action: nil) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, let view else { state = .failed; return }
        start = touch.location(in: view); beganAt = Date(); sequence = TerminalEdgeGesturePolicy.sequence(at: start, in: view.bounds)
        if sequence == nil { state = .failed }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { state = .failed; return }
        let point = touch.location(in: view)
        if hypot(point.x - start.x, point.y - start.y) > TerminalEdgeGesturePolicy.maximumMovement { state = .failed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, TerminalEdgeGesturePolicy.accepts(movement: 0, duration: Date().timeIntervalSince(beganAt)), let sequence else { state = .failed; return }
        state = .recognized; send(sequence)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { sequence = nil }
}
