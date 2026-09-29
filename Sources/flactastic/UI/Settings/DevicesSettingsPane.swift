import SwiftUI

/// Settings ▸ Devices: the Sync UI as a tab. Shares its model with the Sync
/// window, so a pairing or run started in one shows up in the other.
struct DevicesSettingsPane: View {
    @Environment(SyncModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SyncContent()

            HStack {
                Text("Devices are only discoverable while this tab or the Sync window is open.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Open Sync Window") { openWindow(id: "sync") }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .onAppear { model.begin() }
        .onDisappear { model.end() }
    }
}
