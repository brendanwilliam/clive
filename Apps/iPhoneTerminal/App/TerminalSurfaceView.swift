import IPhoneTerminalCore
import SwiftTerm
import SwiftUI

struct TerminalSurfaceView: UIViewRepresentable {
    let session: SessionClient?
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero); view.terminalDelegate = context.coordinator
        context.coordinator.view = view; context.coordinator.installAccessory(on: view)
        session?.onOutput = { [weak view] data in DispatchQueue.main.async { view?.feed(byteArray: ArraySlice(data)) } }
        return view
    }
    func updateUIView(_ uiView: TerminalView, context: Context) { context.coordinator.session = session }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: SessionClient?; weak var view: TerminalView?
        private var accessory: TerminalKeyboardAccessory?
        init(session: SessionClient?) { self.session = session }
        @MainActor func installAccessory(on view: TerminalView) {
            let accessory = TerminalKeyboardAccessory(send: { [weak self] data in self?.session?.sendInput(data) }, command: { [weak self] key in self?.performCommand(key) })
            self.accessory = accessory
            view.inputAccessoryView = accessory
            // SwiftTerm installs a default accessory during its initialization. Reload the
            // responder so UIKit replaces that view even if the terminal is already focused.
            view.reloadInputViews()
            _ = view.becomeFirstResponder()
        }
        @MainActor private func performCommand(_ key: String) {
            switch key.lowercased() {
            case "k": view?.feed(byteArray: ArraySlice("\u{1b}[2J\u{1b}[H".utf8))
            case "w": session?.close()
            default: break // C/V/A/T/[ / ] are handled by the workspace command router.
            }
            accessory?.resetModifiers()
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { session?.sendInput(Data(data)) }
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
