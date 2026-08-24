import CliveCore
import SwiftTerm
import SwiftUI

struct TerminalSurfaceView: UIViewRepresentable {
    let session: SessionClient?
    let accessibilityIdentifier: String
    let isSelected: Bool
    let onOpenDrawer: @MainActor () -> Void
    let onOpenShortcuts: @MainActor () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero); view.terminalDelegate = context.coordinator
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityLabel = "Terminal"
        view.accessibilityValue = isSelected ? "Selected" : "Not selected"
        context.coordinator.view = view; context.coordinator.installAccessory(on: view); context.coordinator.installControls(on: view, onOpenDrawer: onOpenDrawer, onOpenShortcuts: onOpenShortcuts)
        view.keyboardDismissMode = TerminalSurfaceConfiguration.keyboardDismissMode
        view.scrollsToTop = TerminalSurfaceConfiguration.scrollsToTop
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let fixtureOutput = (1...80).map { "fixture line \($0)" }.joined(separator: "\r\n")
            view.feed(byteArray: ArraySlice(("\u{1b}[2 q" + fixtureOutput).utf8))
        }
        session?.onOutput = { [weak view] data in DispatchQueue.main.async { view?.feed(byteArray: ArraySlice(data)) } }
        return view
    }
    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.session = session
        uiView.accessibilityIdentifier = accessibilityIdentifier
        uiView.accessibilityValue = isSelected ? "Selected" : "Not selected"
    }

    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        var session: SessionClient?; weak var view: TerminalView?
        fileprivate var accessory: TerminalKeyboardAccessory?
        fileprivate var gestureObserver: TerminalSurfaceGestureObserver?
        init(session: SessionClient?) { self.session = session }
        @MainActor func installAccessory(on view: TerminalView) {
            let accessory = TerminalKeyboardAccessory(send: { [weak self] data in self?.sendInput(data) }, command: { [weak self] key in self?.performCommand(key) }, onLayoutChanged: { [weak view] in view?.reloadInputViews() })
            self.accessory = accessory
            view.inputAccessoryView = accessory
            // SwiftTerm installs a default accessory during its initialization. Reload the
            // responder so UIKit replaces that view even if the terminal is already focused.
            view.reloadInputViews()
            _ = view.becomeFirstResponder()
        }
        @MainActor func installControls(on view: TerminalView, onOpenDrawer: @escaping @MainActor () -> Void, onOpenShortcuts: @escaping @MainActor () -> Void) {
            gestureObserver = TerminalSurfaceGestureObserver.install(on: view, sendInput: { [weak self] input in self?.sendInput(input) }, onOpenDrawer: onOpenDrawer, onOpenShortcuts: onOpenShortcuts)
            view.accessibilityCustomActions = [
                ("Cursor up", "\u{1b}[A"), ("Cursor down", "\u{1b}[B"),
                ("Cursor left", "\u{1b}[D"), ("Cursor right", "\u{1b}[C")
            ].map { name, sequence in UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.session?.sendInput(Data(sequence.utf8)); return true } }
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

enum TerminalSurfaceConfiguration {
    static let keyboardDismissMode: UIScrollView.KeyboardDismissMode = .none
    static let scrollsToTop = false
    static let contentPadding: CGFloat = 2
}

@MainActor private final class TerminalSurfaceGestureObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let sendInput: (Data) -> Void
    private let onOpenDrawer: () -> Void
    private let onOpenShortcuts: () -> Void
    private lazy var doubleTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    private lazy var leftEdgeGestureRecognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
    private lazy var rightEdgeGestureRecognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))

    static func install(on view: TerminalView, sendInput: @escaping (Data) -> Void, onOpenDrawer: @escaping () -> Void, onOpenShortcuts: @escaping () -> Void) -> TerminalSurfaceGestureObserver {
        let observer = TerminalSurfaceGestureObserver(view: view, sendInput: sendInput, onOpenDrawer: onOpenDrawer, onOpenShortcuts: onOpenShortcuts)
        observer.doubleTapGestureRecognizer.numberOfTapsRequired = 2
        observer.leftEdgeGestureRecognizer.edges = .left
        observer.rightEdgeGestureRecognizer.edges = .right
        [observer.doubleTapGestureRecognizer, observer.leftEdgeGestureRecognizer, observer.rightEdgeGestureRecognizer].forEach { gesture in
            gesture.delegate = observer
            gesture.cancelsTouchesInView = false
            view.addGestureRecognizer(gesture)
        }
        return observer
    }

    private init(view: TerminalView, sendInput: @escaping (Data) -> Void, onOpenDrawer: @escaping () -> Void, onOpenShortcuts: @escaping () -> Void) {
        self.view = view
        self.sendInput = sendInput
        self.onOpenDrawer = onOpenDrawer
        self.onOpenShortcuts = onOpenShortcuts
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let view,
              let region = TerminalContentGesturePolicy.region(
                forDoubleTapAt: gesture.location(in: view).y,
                height: view.bounds.height
              ) else { return }
        sendInput(TerminalContentGesturePolicy.input(for: region))
    }

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        switch gesture.edges {
        case .left: onOpenDrawer()
        case .right: onOpenShortcuts()
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer, let view else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y) * TerminalTitleNavigationPolicy.dominanceRatio
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
