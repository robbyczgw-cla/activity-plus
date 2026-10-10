import SwiftUI

/// Settings → Menu Bar → Notch.
struct NotchSettingsSection: View {
    @AppStorage(NotchSettings.enabledKey) private var enabled = true
    @AppStorage(NotchSettings.hoverKey) private var hover = true
    @State private var hasNotch = NotchGeometry.exists

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Notch").font(.headline)
            if hasNotch {
                HStack(spacing: 24) {
                    Toggle("Use the notch", isOn: $enabled)
                    Toggle("Show live values on hover", isOn: $hover).disabled(!enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Hints:").foregroundStyle(.secondary)
                    let kinds = NotchHint.Kind.allCases
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        ForEach(Array(stride(from: 0, to: kinds.count, by: 3)), id: \.self) { start in
                            GridRow {
                                ForEach(kinds[start..<min(start + 3, kinds.count)]) { HintToggle(kind: $0) }
                            }
                        }
                    }
                    .fixedSize()
                }
                .disabled(!enabled)
            } else {
                Text("This Mac has no notch, or its built-in display is off.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: enabled) { _, _ in NotchController.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasNotch = NotchGeometry.exists
        }
    }
}

private struct HintToggle: View {
    let kind: NotchHint.Kind
    @AppStorage private var on: Bool

    init(kind: NotchHint.Kind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: true, NotchSettings.hintKey(kind))
    }

    var body: some View {
        Toggle(kind.title, isOn: $on)
    }
}
