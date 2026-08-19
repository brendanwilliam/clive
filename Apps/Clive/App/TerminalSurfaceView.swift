import CliveCore
import SwiftTerm
import SwiftUI

struct TerminalSurfaceView: UIViewRepresentable {
    let session: SessionClient?
    let shortcuts: [CLIShortcut]
    let saveShortcut: (String, String) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(session: session, shortcuts: shortcuts, saveShortcut: saveShortcut) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero); view.terminalDelegate = context.coordinator
        context.coordinator.view = view; context.coordinator.installAccessory(on: view); context.coordinator.installEdgeControls(on: view)
        session?.onOutput = { [weak view] data in DispatchQueue.main.async { view?.feed(byteArray: ArraySlice(data)) } }
        return view
    }
    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.accessory?.updateShortcuts(shortcuts)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        var session: SessionClient?; weak var view: TerminalView?
        fileprivate var accessory: TerminalKeyboardAccessory?
        private var shortcuts: [CLIShortcut]
        private var commandTracker = TerminalCommandTracker()
        private let saveShortcut: (String, String) -> Bool
        init(session: SessionClient?, shortcuts: [CLIShortcut], saveShortcut: @escaping (String, String) -> Bool) {
            self.session = session; self.shortcuts = shortcuts; self.saveShortcut = saveShortcut
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
            let overlay = EdgeKeyOverlay { [weak self] sequence in self?.session?.sendInput(Data(sequence.utf8)) }
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
            NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor), overlay.topAnchor.constraint(equalTo: view.topAnchor), overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
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

/// Transparent edge targets preserve the terminal's centre for selection/tapping while
/// making one-handed cursor navigation available around its perimeter.
@MainActor private final class EdgeKeyOverlay: UIView {
    init(send: @escaping (String) -> Void) {
        super.init(frame: .zero)
        let edges: [(String, String)] = [("top", "\u{1b}[A"), ("bottom", "\u{1b}[B"), ("left", "\u{1b}[D"), ("right", "\u{1b}[C")]
        for (edge, sequence) in edges {
            let button = UIButton(type: .custom); button.backgroundColor = .clear; button.accessibilityLabel = "Cursor \(edge)"
            button.addAction(UIAction { _ in send(sequence) }, for: .touchUpInside); button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
            switch edge {
            case "top": NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor), button.topAnchor.constraint(equalTo: topAnchor), button.heightAnchor.constraint(equalToConstant: 34)])
            case "bottom": NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor), button.heightAnchor.constraint(equalToConstant: 34)])
            case "left": NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: leadingAnchor), button.topAnchor.constraint(equalTo: topAnchor, constant: 34), button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -34), button.widthAnchor.constraint(equalToConstant: 34)])
            default: NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: trailingAnchor), button.topAnchor.constraint(equalTo: topAnchor, constant: 34), button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -34), button.widthAnchor.constraint(equalToConstant: 34)])
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
