import IPhoneTerminalCore
import SwiftTerm
import SwiftUI

struct TerminalSurfaceView: UIViewRepresentable {
    let session: SessionClient?
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero); view.terminalDelegate = context.coordinator
        context.coordinator.view = view; session?.onOutput = { [weak view] data in DispatchQueue.main.async { view?.feed(byteArray: ArraySlice(data)) } }
        return view
    }
    func updateUIView(_ uiView: TerminalView, context: Context) { context.coordinator.session = session }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: SessionClient?; weak var view: TerminalView?
        init(session: SessionClient?) { self.session = session }
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
