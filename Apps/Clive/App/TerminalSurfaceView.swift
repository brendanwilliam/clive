import CliveCore
import SwiftTerm
import SwiftUI

struct TerminalSurfaceView: UIViewRepresentable {
    let session: SessionClient?
    let accessibilityIdentifier: String
    let isSelected: Bool
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero); view.terminalDelegate = context.coordinator
        view.linkReporting = .implicit
        view.linkHighlightMode = .hoverWithModifier
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityLabel = "Terminal"
        view.accessibilityValue = isSelected ? "Selected" : "Not selected"
        context.coordinator.view = view; context.coordinator.installAccessory(on: view); context.coordinator.installControls(on: view)
        view.keyboardDismissMode = TerminalSurfaceConfiguration.keyboardDismissMode
        view.scrollsToTop = TerminalSurfaceConfiguration.scrollsToTop
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let fixtureOutput = (1...80).map {
                $0 == 80 ? "https://example.com" : "fixture line \($0)"
            }.joined(separator: "\r\n")
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
        fileprivate var keyboardDismissObserver: TerminalKeyboardDismissObserver?
        fileprivate var linkLongPressObserver: TerminalLinkLongPressObserver?
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
        @MainActor func installControls(on view: TerminalView) {
            keyboardDismissObserver = TerminalKeyboardDismissObserver.install(on: view)
            linkLongPressObserver = TerminalLinkLongPressObserver.install(on: view) { [weak self] url, source, point in
                self?.presentLinkActions(for: url, from: source, at: point)
            }
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
        @MainActor private func presentLinkActions(for url: URL, from view: UIView, at point: CGPoint) {
            let alert = UIAlertController(title: url.absoluteString, message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "Open Link", style: .default) { _ in
                UIApplication.shared.open(url)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.popoverPresentationController?.sourceView = view
            alert.popoverPresentationController?.sourceRect = CGRect(origin: point, size: .zero)
            view.topMostViewController?.present(alert, animated: true)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0, newCols <= Int(UInt16.max), newRows <= Int(UInt16.max) else { return }
            session?.resize(TerminalSize(columns: UInt16(newCols), rows: UInt16(newRows)))
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = TerminalLinkPolicy.destination(for: link) else { return }
            MainActor.assumeIsolated {
                UIApplication.shared.open(url)
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

enum TerminalSurfaceConfiguration {
    static let keyboardDismissMode: UIScrollView.KeyboardDismissMode = .none
    static let scrollsToTop = false
    static let contentPadding: CGFloat = 2
}

private extension UIView {
    var topMostViewController: UIViewController? {
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

@MainActor private final class TerminalLinkLongPressObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let activate: (URL, UIView, CGPoint) -> Void
    private var destination: URL?
    private lazy var longPressGestureRecognizer = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handleLongPress(_:))
    )

    static func install(
        on view: TerminalView,
        activate: @escaping (URL, UIView, CGPoint) -> Void
    ) -> TerminalLinkLongPressObserver {
        let observer = TerminalLinkLongPressObserver(view: view, activate: activate)
        observer.longPressGestureRecognizer.delegate = observer
        view.addGestureRecognizer(observer.longPressGestureRecognizer)
        (view.gestureRecognizers ?? [])
            .compactMap { $0 as? UILongPressGestureRecognizer }
            .filter { $0 !== observer.longPressGestureRecognizer }
            .forEach { $0.require(toFail: observer.longPressGestureRecognizer) }
        return observer
    }

    private init(view: TerminalView, activate: @escaping (URL, UIView, CGPoint) -> Void) {
        self.view = view
        self.activate = activate
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let destination,
              let view else {
            return
        }
        activate(destination, view, gesture.location(in: view))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view,
              let destination = destination(at: gestureRecognizer.location(in: view), in: view) else {
            destination = nil
            return false
        }
        self.destination = destination
        return true
    }

    private func destination(at point: CGPoint, in view: TerminalView) -> URL? {
        let terminal = view.getTerminal()
        guard terminal.cols > 0,
              view.contentSize.width > 0,
              terminal.rows > 0 else {
            return nil
        }
        let columnWidth = view.contentSize.width / CGFloat(terminal.cols)
        let rowHeight = view.getOptimalFrameSize().height / CGFloat(terminal.rows)
        guard columnWidth > 0, rowHeight > 0 else { return nil }
        let position = Position(
            col: min(max(0, Int(point.x / columnWidth)), terminal.cols - 1),
            row: max(0, Int(point.y / rowHeight))
        )
        guard let link = terminal.link(at: .buffer(position), mode: .explicitAndImplicit) else {
            return nil
        }
        return TerminalLinkPolicy.destination(for: link)
    }
}

@MainActor private final class TerminalKeyboardDismissObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private lazy var dismissPanGestureRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handlePan(_:))
    )

    static func install(on view: TerminalView) -> TerminalKeyboardDismissObserver {
        let observer = TerminalKeyboardDismissObserver(view: view)
        observer.dismissPanGestureRecognizer.delegate = observer
        observer.dismissPanGestureRecognizer.cancelsTouchesInView = true
        view.addGestureRecognizer(observer.dismissPanGestureRecognizer)
        // Let an intentional downward keyboard-dismiss gesture win before SwiftTerm's
        // scroll view begins moving terminal history.
        view.panGestureRecognizer.require(toFail: observer.dismissPanGestureRecognizer)
        return observer
    }

    private init(view: TerminalView) { self.view = view }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began else { return }
        _ = view?.resignFirstResponder()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view, view.isFirstResponder,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.25
    }
}
