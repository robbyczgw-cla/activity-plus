import SwiftUI

/// Small orange "Paused" label next to a process name.
struct PausedTag: View {
    var body: some View {
        Text("Paused")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .help("Stopped with SIGSTOP. Resume it from the right-click menu.")
    }
}
