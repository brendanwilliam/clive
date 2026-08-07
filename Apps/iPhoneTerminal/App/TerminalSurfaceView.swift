import SwiftUI

/// Replace this placeholder with a UIViewRepresentable adapter for SwiftTerm's TerminalView.
/// The adapter owns a session stream, forwards terminal bytes to SwiftTerm, and sends resize/input events.
struct TerminalSurfaceView: View {
    var body: some View {
        Rectangle()
            .fill(.black)
            .overlay(alignment: .topLeading) {
                Text("Connecting terminal…")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding()
            }
            .ignoresSafeArea(edges: .bottom)
    }
}
