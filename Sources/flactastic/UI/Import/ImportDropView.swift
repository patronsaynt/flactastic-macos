import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Reusable dark drop zone used as the first stage of every import flow.
/// Accepts both drag-and-drop file URLs and a click that opens an
/// `NSOpenPanel`. Forwards any URLs whose extension classifies as a
/// supported `AudioFileFormat`.
struct ImportDropView: View {
    let title: String
    let allowsMultiple: Bool
    let onFiles: ([URL]) -> Void

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(isTargeted ? Theme.accent : Theme.textTertiary)

            Text("Drag and drop here, or select files")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text("FLAC · MP3 · WAV · AIFF · M4A · AAC")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)

            Button("Select Files…") { pickFiles() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .padding(.top, Theme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.surfaceElevated.opacity(isTargeted ? 0.85 : 0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(
                    isTargeted ? Theme.accent : Theme.divider,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .onTapGesture { pickFiles() }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    // MARK: - Actions

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultiple
        panel.allowedContentTypes = [.audio]
        panel.title = title
        panel.message = allowsMultiple
            ? "Choose one or more audio files"
            : "Choose an audio file"

        guard panel.runModal() == .OK else { return }
        let urls = allowsMultiple ? panel.urls : [panel.url].compactMap { $0 }
        let filtered = urls.filter { AudioFileFormat.classify($0) != nil }
        guard !filtered.isEmpty else { return }
        onFiles(allowsMultiple ? filtered : Array(filtered.prefix(1)))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            let filtered = urls.filter { AudioFileFormat.classify($0) != nil }
            guard !filtered.isEmpty else { return }
            onFiles(allowsMultiple ? filtered : Array(filtered.prefix(1)))
        }
        return true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
