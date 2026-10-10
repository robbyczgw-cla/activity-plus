import ActivityCore
import SwiftUI

/// Top of Storage → Explore: which folder or drive the map shows (home folder, another volume, the whole startup disk).
struct ExploreRootPicker: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let model = services.diskIndex
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Map of").foregroundStyle(.secondary)
                Picker("Map of", selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                    choiceLabel(.home, model: model).tag(DiskIndexModel.ScanRoot.home)
                    if !model.volumes.isEmpty {
                        Divider()
                        ForEach(model.volumes) { volume in
                            choiceLabel(.volume(volume.path), model: model).tag(DiskIndexModel.ScanRoot.volume(volume.path))
                        }
                    }
                    Divider()
                    choiceLabel(.startupDisk, model: model).tag(DiskIndexModel.ScanRoot.startupDisk)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer(minLength: 0)
            }
            if model.selection == .startupDisk {
                Text("macOS shows Activity+ only what it may read: some system folders and other users' folders appear as “Not read”. Only files in your home folder can be moved to the Trash from here.")
                    .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refreshVolumes() }
    }

    private func choiceLabel(_ choice: DiskIndexModel.ScanRoot, model: DiskIndexModel) -> some View {
        Label {
            Text(verbatim: model.title(for: choice))
        } icon: {
            Image(systemName: model.symbol(for: choice))
        }
    }
}
