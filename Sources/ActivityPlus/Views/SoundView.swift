import ActivityCore
import SwiftUI

/// Per-app volume. Changing a slider creates a private Core Audio tap for that app only;
/// back at 100 % the tap is removed and the app plays untouched.
struct SoundView: View {
    @Environment(AppServices.self) private var services
    @State private var tick = 0

    var body: some View {
        let controller = services.volumeController
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Turn the meeting up and the music down. Audio is adjusted as it plays; nothing is recorded.")
                    .foregroundStyle(.secondary)
                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Card {
                    if controller.apps.isEmpty {
                        ContentUnavailableView("Nothing is playing", systemImage: "speaker.slash",
                                               description: Text("Apps appear here while they play sound."))
                    }
                    ForEach(controller.apps) { app in
                        VolumeRow(app: app, controller: controller)
                        if app.id != controller.apps.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Sound")
        .task {
            while !Task.isCancelled {
                controller.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct VolumeRow: View {
    let app: AppVolumeController.AudioApp
    let controller: AppVolumeController
    @State private var volume: Double = 1

    var body: some View {
        HStack(spacing: 12) {
            icon.resizable().frame(width: 24, height: 24)
            Text(app.name).frame(width: 150, alignment: .leading).lineLimit(1)
            Button {
                controller.setMuted(!controller.isMuted(app.id), for: app.id)
            } label: {
                Image(systemName: controller.isMuted(app.id) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            Slider(value: $volume, in: 0...2) { editing in
                if !editing, abs(volume - 1) < 0.04 { volume = 1 }   // snap to 100 %
                controller.setVolume(Float(volume), for: app.id)
            }
            Text(Format.percent(volume * 100)).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
        .onAppear { volume = Double(controller.volume(for: app.id)) }
    }

    private var icon: Image {
        if let pid = app.pids.first, let running = NSRunningApplication(processIdentifier: pid), let image = running.icon {
            return Image(nsImage: image)
        }
        return Image(systemName: "app")
    }
}

