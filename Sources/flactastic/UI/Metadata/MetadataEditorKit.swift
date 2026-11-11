import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The parts the album and track editors share: the sheet's chrome, the
// review of what will be written to which file, the cover well with its
// menu, and Find Online.

// MARK: - Changes and writing

/// One tag on one file, as it is and as it will be written.
struct TagDiff: Identifiable, Equatable {
    var id: String { tag }
    let tag: String
    let old: String
    let new: String
}

/// Everything that will change in one file.
struct FileChange: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let rows: [TagDiff]
}

enum FileWriteStatus: Equatable {
    case writing
    case written
    case failed(String)
}

/// Where the editor is: editing, reviewing what it will write, writing it,
/// or written with some files failed.
@MainActor
@Observable
final class MetadataWriteSession {
    enum Phase: Equatable { case editing, reviewing, writing, finished }

    var phase: Phase = .editing
    var statuses: [UUID: FileWriteStatus] = [:]

    var failedIDs: [UUID] {
        statuses.compactMap { if case .failed = $0.value { return $0.key } else { return nil } }
    }

    /// Writes each file in turn with `write`, marking it as it goes. Files
    /// already written in an earlier attempt are skipped, so Retry only
    /// redoes what failed. Returns whether every file was written.
    func write(_ files: [FileChange], with write: (FileChange) async throws -> Void) async -> Bool {
        phase = .writing
        for file in files where statuses[file.id] != .written {
            statuses[file.id] = .writing
            do {
                // Reviewed by the user, so it may reach a server library.
                try await MetadataWriter.$isUserEdit.withValue(true) { try await write(file) }
                statuses[file.id] = .written
            } catch {
                statuses[file.id] = .failed(Self.message(for: error))
            }
        }
        phase = failedIDs.isEmpty ? .finished : .reviewing
        return failedIDs.isEmpty
    }

    /// What went wrong, and what to do about it, in plain words.
    static func message(for error: Error) -> String {
        if let e = error as? MetadataWriter.WriteError {
            switch e {
            case .fileNotFound: return "The file has moved or been deleted since the library was scanned. Rescan the library, then try again."
            case .fileOpenFailed: return "The file couldn't be opened for writing. It may be read-only or in use by another app."
            case .saveFailed: return "The file couldn't be saved. Check that it isn't read-only and that the disk has room, then retry."
            case .serverLibrary: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// The list of every file that will change and how, shown before anything
/// is written; while writing, each file's progress; after, any that failed
/// and why.
struct ReviewChangesPanel: View {
    let changes: [FileChange]
    let session: MetadataWriteSession
    let reveal: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Review Changes")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Exactly what will be written to each file. Fields you didn't change are left as they are.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(changes) { file in
                        fileCard(file)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        }
    }

    private func fileCard(_ file: FileChange) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(file.fileName)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                status(file)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ForEach(file.rows) { row in
                Rectangle().fill(Theme.divider).frame(height: 0.5)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.tag)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 150, alignment: .leading)
                    Text(row.old.isEmpty ? "empty" : row.old)
                        .font(.system(size: 12.5))
                        .italic(row.old.isEmpty)
                        .strikethrough(!row.old.isEmpty)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("→")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(row.new.isEmpty ? "removed" : row.new)
                        .font(.system(size: 12.5, weight: row.new.isEmpty ? .regular : .semibold))
                        .italic(row.new.isEmpty)
                        .foregroundStyle(row.new.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            if case .failed(let message) = session.statuses[file.id] {
                Rectangle().fill(Theme.divider).frame(height: 0.5)
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.qualityLow)
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.qualityLow)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Show in Finder") { reveal(file.id) }
                        .buttonStyle(QuietTextButtonStyle())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textPrimary.opacity(0.05)))
    }

    @ViewBuilder
    private func status(_ file: FileChange) -> some View {
        switch session.statuses[file.id] {
        case .writing:
            ProgressView().controlSize(.small)
        case .written:
            Label("Written", systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.qualityCD)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.qualityLow)
        case nil:
            Text("\(file.rows.count) tag\(file.rows.count == 1 ? "" : "s")")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// The editors' footer: what will change, then Cancel and Review Changes…;
/// while reviewing, Back, and Write to N Files (or Retry after a failure).
struct MetadataEditorFooter: View {
    let session: MetadataWriteSession
    let changes: [FileChange]
    /// Why Review can't go ahead yet (an empty required field), if anything.
    var blocker: String?
    let cancel: () -> Void
    let write: () -> Void

    var body: some View {
        let tags = changes.reduce(0) { $0 + $1.rows.count }
        let files = changes.count
        HStack(spacing: 10) {
            switch session.phase {
            case .editing:
                Group {
                    if let blocker {
                        Text(blocker)
                    } else if files == 0 {
                        Text("No changes yet")
                    } else {
                        Text("**\(tags) change\(tags == 1 ? "" : "s")** to \(files) file\(files == 1 ? "" : "s"). Nothing is written until you review.")
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(SheetPillStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Review Changes…") { session.phase = .reviewing }
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Review what will be written (⌘↩)")
                    .disabled(files == 0 || blocker != nil)
            case .reviewing, .writing, .finished:
                let failed = session.failedIDs.count
                let writing = session.phase == .writing
                Button {
                    session.phase = .editing
                } label: {
                    Label("Back to Editing", systemImage: "chevron.left")
                }
                .buttonStyle(SheetPillStyle())
                .disabled(writing || !session.statuses.isEmpty)
                Group {
                    if failed > 0 {
                        Text("**\(failed) file\(failed == 1 ? "" : "s") couldn't be written.** The rest were saved.")
                            .foregroundStyle(Theme.qualityLow)
                    } else if writing {
                        Text("Writing \(session.statuses.values.filter { $0 == .written }.count + 1) of \(files)…")
                    } else {
                        Text("**\(tags) tag change\(tags == 1 ? "" : "s")** across \(files) file\(files == 1 ? "" : "s"). Files are rewritten in place.")
                    }
                }
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                Spacer()
                Button(failed > 0 ? "Close" : "Cancel", action: cancel)
                    .buttonStyle(SheetPillStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(writing)
                Button(failed > 0 ? "Retry" : writing ? "Writing…" : "Write to \(files) File\(files == 1 ? "" : "s")", action: write)
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(writing)
            }
        }
        .frame(height: 40)
    }
}

/// The editors' header: the sheet's name (or a way back to the album), and
/// on the right any tabs, then the close button.
struct MetadataEditorHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    var back: (label: String, action: () -> Void)?
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let back {
                Button(action: back.action) {
                    Label(back.label, systemImage: "chevron.left")
                        .lineLimit(1)
                }
                .buttonStyle(QuietTextButtonStyle())
                .padding(.leading, -10)
                Text("/").foregroundStyle(Theme.textTertiary)
            }
            SheetLabel(text: title)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            trailing()
            SheetCloseButton(label: "Close without saving", handlesEscape: false, action: close)
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

/// A row of tabs in one capsule track, the chosen one solid.
struct EditorTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var marked: (Tab) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let on = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 6) {
                        Text(title(tab))
                        if marked(tab) { Circle().frame(width: 5, height: 5).opacity(0.75) }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(on ? Theme.background : Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(Capsule().fill(on ? Theme.textPrimary : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.textPrimary.opacity(0.07)))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// A labelled field in the quiet style the edit sheets use: the value reads
/// as plain text until it's hovered or focused.
struct QuietLabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var font: Font = .system(size: 15, weight: .semibold)
    var numeric = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SheetLabel(text: label)
            TextField(placeholder, text: $text)
                .textFieldStyle(QuietFieldStyle(font: font))
                .accessibilityLabel(label)
                .onChange(of: text) { _, v in
                    if numeric {
                        let digits = v.filter(\.isNumber)
                        if digits != v { text = digits }
                    }
                }
        }
    }
}

// MARK: - Cover

/// The cover, its size and quality, and a menu on it: Choose File…, Paste
/// Image, Find Online…, Crop… and Remove Cover. An image dropped on it, or
/// pasted while the sheet has no text field focused, becomes the cover too.
struct CoverWell: View {
    let data: Data?
    var size: CGFloat = 184
    /// What Find Online searches for.
    let album: String
    let artist: String
    /// A new cover, or nil to remove it.
    let set: (Data?) -> Void

    @State private var isTargeted = false
    @State private var cropping: CroppingPayload?
    @State private var finding = false
    @State private var info: CoverInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: showMenu) {
                ArtworkView(data: data, size: size, showsShadow: false)
                    .overlay { CoverEditOverlay(isEmpty: data == nil) }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .strokeBorder(Theme.textPrimary, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .opacity(isTargeted ? 1 : 0)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
            }
            .buttonStyle(.plain)
            .help(data == nil ? "Add a cover: choose, paste, drop or find one online" : "Change the cover")
            .accessibilityLabel(data == nil ? "Add cover" : "Change cover")
            // An image file dragged from Finder, or from another app that
            // offers it as a file.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.isFileURL, let image = try? Data(contentsOf: url), NSImage(data: image) != nil else { return false }
                cropping = CroppingPayload(data: image)
                return true
            } isTargeted: { isTargeted = $0 }

            HStack(spacing: 6) {
                if let info {
                    Text("\(info.width) × \(info.height) · \(info.sizeText)")
                    if min(info.width, info.height) < 600 {
                        Label("Low res", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.qualityMid)
                            .help("Under 600 px looks soft on the album page and in the visualizer. Find Online can usually find a larger copy.")
                    }
                } else {
                    Text(data == nil ? "No cover · drop an image here" : " ")
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
        .task(id: data?.count) { info = data.flatMap(CoverInfo.init) }
        .onPasteCommand(of: [.image, .png, .jpeg, .tiff]) { providers in
            loadPasted(providers)
        }
        .sheet(item: $cropping) { payload in
            SquareImageCropperView(sourceData: payload.data) { set($0) }
        }
        .sheet(isPresented: $finding) {
            ArtworkFinderSheet(album: album, artist: artist) { found in
                set(found)
            }
        }
    }

    private func showMenu() {
        var items: [FLContextMenuItem] = [
            .button("Choose File…", systemImage: "folder") { choose() },
            .button("Paste Image", systemImage: "doc.on.clipboard") { pasteFromClipboard() },
            .button("Find Online…", systemImage: "globe") { finding = true },
        ]
        if let data {
            items.append(.button("Crop…", systemImage: "crop") { cropping = CroppingPayload(data: data) })
            items.append(.divider)
            items.append(.button("Remove Cover", systemImage: "trash", destructive: true) { set(nil) })
        }
        FLContextMenuWindow.present(items: items, at: NSEvent.mouseLocation)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a cover image"
        guard panel.runModal() == .OK, let url = panel.url, let picked = try? Data(contentsOf: url) else { return }
        cropping = CroppingPayload(data: picked)
    }

    private func pasteFromClipboard() {
        let board = NSPasteboard.general
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
            cropping = CroppingPayload(data: jpeg)
        } else {
            NSSound.beep()
        }
    }

    private func loadPasted(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadDataRepresentation(for: .image) { data, _ in
            guard let data, NSImage(data: data) != nil else { return }
            Task { @MainActor in cropping = CroppingPayload(data: data) }
        }
    }
}

/// A cover's pixel size and file size, read from its header.
struct CoverInfo: Equatable {
    let width: Int
    let height: Int
    let bytes: Int

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        width = w
        height = h
        bytes = data.count
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

// MARK: - Find Online

/// Covers found online for this album, largest sources first. Choosing one
/// downloads it at full size and uses it as the cover.
struct ArtworkFinderSheet: View {
    let album: String
    let artist: String
    let use: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ArtworkCandidate] = []
    @State private var isSearching = false
    @State private var downloading: String?
    @State private var failed: String?

    var body: some View {
        FLSheet(title: "Find Cover Online", width: 760, height: 620, contentScrolls: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField("Artist and album", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .onSubmit { Task { await search() } }
                    if isSearching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.textPrimary.opacity(0.06)))

                if let failed {
                    Text(failed)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.qualityLow)
                }

                ScrollView {
                    if results.isEmpty && !isSearching {
                        Text("No covers found. Try fewer words, or just the album's name.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)], spacing: 16) {
                        ForEach(results) { candidate in
                            candidateCell(candidate)
                        }
                    }
                    .padding(.bottom, 12)
                }
                Text("Apple Music covers come at up to 3000 × 3000; Deezer's at 1000 × 1000; the Cover Art Archive's are community scans at any size.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SheetPillStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .task {
            query = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
            await search()
        }
    }

    private func candidateCell(_ c: ArtworkCandidate) -> some View {
        Button { Task { await pick(c) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: c.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(1, contentMode: .fill)
                    } else {
                        Theme.textPrimary.opacity(0.06)
                            .overlay { if phase.error == nil { ProgressView().controlSize(.small) } }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if downloading == c.id {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.45))
                            .overlay { ProgressView().controlSize(.small).tint(.white) }
                    }
                }
                Text(c.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text([c.artist, c.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text(c.pixelSize.map { "\(c.source.rawValue) · \($0) px" } ?? c.source.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading != nil)
        .help("Use this cover")
    }

    private func search() async {
        isSearching = true
        failed = nil
        let words = query.trimmingCharacters(in: .whitespaces)
        // The fields are searched as typed; a hand-typed query goes in as the term.
        let edited = words != [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        results = await ArtworkFinder.shared.search(album: edited ? words : album, artist: edited ? "" : artist)
        isSearching = false
    }

    private func pick(_ c: ArtworkCandidate) async {
        downloading = c.id
        failed = nil
        do {
            let data = try await ArtworkFinder.shared.download(c)
            guard NSImage(data: data) != nil else { throw URLError(.cannotDecodeContentData) }
            use(data)
            dismiss()
        } catch {
            failed = "That cover couldn't be downloaded. Try another, or try again in a moment."
        }
        downloading = nil
    }
}

// MARK: - Helpers

enum TagText {
    /// Chips trimmed, empties dropped, joined as the app writes artists.
    static func joined(_ chips: [String]) -> String? {
        let cleaned = chips.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleaned.isEmpty { return nil }
        return cleaned.count == 1 ? cleaned[0] : ArtistResolver.joinExplicit(cleaned)
    }

    /// An artist tag split into chips.
    static func chips(_ tag: String?) -> [String] {
        ArtistResolver.explicitlySeparated(tag ?? "") ?? (tag.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
    }

    static func number(_ n: Int?) -> String { n.map(String.init) ?? "" }

    /// A cover's size for the review. Kept per image, since the changes are
    /// worked out again on every edit and each track carries its own copy.
    @MainActor
    static func cover(_ data: Data?) -> String {
        guard let data else { return "" }
        let key = CoverKey(data)
        if let hit = coverCache[key] { return hit }
        let text = CoverInfo(data).map { "\($0.width) × \($0.height)" } ?? "image"
        if coverCache.count > 200 { coverCache.removeAll() }
        coverCache[key] = text
        return text
    }

    @MainActor private static var coverCache: [CoverKey: String] = [:]

    /// An image told apart cheaply: its length and a sample of its bytes.
    private struct CoverKey: Hashable {
        let count: Int
        let head: Int
        let tail: Int
        init(_ data: Data) {
            count = data.count
            head = data.prefix(256).hashValue
            tail = data.suffix(256).hashValue
        }
    }
}
