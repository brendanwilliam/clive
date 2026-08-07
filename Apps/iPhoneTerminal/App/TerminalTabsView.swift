import IPhoneTerminalCore
import SwiftUI

struct TerminalTabsView: View {
    let device: PairedDevice
    @State private var sessions: [UUID] = [UUID()]
    @State private var selectedSession: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Session", selection: $selectedSession) {
                ForEach(sessions, id: \.self) { session in
                    Text("Shell \(sessions.firstIndex(of: session)! + 1)").tag(Optional(session))
                }
            }
            .pickerStyle(.segmented)
            .padding()
            TerminalSurfaceView()
        }
        .navigationTitle(device.displayName)
        .toolbar {
            Button("New shell", systemImage: "plus") {
                let session = UUID(); sessions.append(session); selectedSession = session
            }
        }
        .onAppear { selectedSession = sessions.first }
    }
}
