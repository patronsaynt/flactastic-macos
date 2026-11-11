import SwiftUI
import AppKit

enum TrackEditorTab: String, Identifiable, CaseIterable {
    case details, lyrics, markers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .details: return "Details"
        case .lyrics: return "Lyrics"
        case .markers: return "Markers"
        }
    }
}

/// Edit Track: the track's details, its lyrics (written, then synced in
/// place while it plays) and, for a mix, its chapter markers, in one sheet.
/// A mix has markers and no lyrics; any other track has lyrics.
///
/// Like Edit Album, nothing is written until Review Changes shows every tag
/// that will change in each file. A new cover can go on this track alone or
/// on every track of its album.
struct TrackMetadataEditorView: View {
    let track: Track
    var initialTab: TrackEditorTab = .details
    /// Shown as a way back when opened from Edit Album.
    var backLabel: String? = nil

    @Environment(\.dismiss)               private var dismiss
    @Environment(\.metadataWriter)        private var writer
    @Environment(LibraryStore.self)       private var library
    @Environment(LyricsRemoteCache.self)  private var lyricsCache
    @Environment(PlayerState.self)        private var player

    @State private var tab: TrackEditorTab = .details

    // Details
    @State private var title:       String
    @State private var artists:     [String]
    @State private var album:       String
    @State private var year:        String
    @State private var genre:           String
    @State private var secondaryGenres: [String]
    @State private var trackNumber:     String
    @State private var isMixCompilation: Bool

    // Cover
    @State private var artworkData:    Data?
    @State private var artworkChanged: Bool = false
    @State private var artworkRemoved: Bool = false
    @State private var coverForAlbum:  Bool = false

    // Lyrics
    @State private var lyrics = ""
    @State private var lyricsOriginal = ""
    @State private var lyricsLoaded = false
    @State private var lyricsBeforeFetch: String?
    @State private var isFetchingLyrics = false
    @State private var lyricsNote: String?
    @State private var syncing = false

    // Markers
    @State private var markers: [TrackMarker] = []
    @State private var markersOriginal: [TrackMarker] = []
    @State private var markersLoaded = false

    @State private var session = MetadataWriteSession()
    @State private var size = Self.fittedSize()
    @State private var written: [UUID: Track] = [:]

    init(track: Track, initialTab: TrackEditorTab = .details, backLabel: String? = nil) {
        self.track = track
        self.initialTab = initialTab
        self.backLabel = backLabel
        _tab         = State(initialValue: initialTab)
        _title       = State(initialValue: track.title)
        _artists     = State(initialValue: TagText.chips(track.artist))
        _album       = State(initialValue: track.album ?? "")
        _year        = State(initialValue: track.year.map { "\($0)" } ?? "")
        _genre           = State(initialValue: track.genre ?? "")
        _secondaryGenres = State(initialValue: track.secondaryGenres)
        _trackNumber     = State(initialValue: track.trackNumber.map { "\($0)" } ?? "")
        _isMixCompilation = State(initialValue: track.isMixCompilation)
        _artworkData = State(initialValue: track.artwork)
    }

    private var tabs: [TrackEditorTab] { [.details, isMixCompilation ? .markers : .lyrics] }
    private var shownTab: TrackEditorTab { tabs.contains(tab) ? tab : .details }
    private var albumTracks: [Track] { library.album(for: track)?.tracks ?? [track] }

    var body: some View {
        let changes = fileChanges()
        return VStack(spacing: 0) {
            MetadataEditorHeader(
                title: "Edit Track", detail: track.title,
                back: backLabel.map { label in (label: label, action: requestClose) },
                close: requestClose
            ) {
                if session.phase == .editing {
                    EditorTabs(tabs: tabs, selection: $tab, title: \.title, marked: edited)
                }
            }
            Group {
                if session.phase == .editing {
                    switch shownTab {
                    case .details: details
                    case .lyrics: lyricsStudio
                    case .markers: markersEditor
                    }
                } else {
                    ReviewChangesPanel(changes: changes, session: session) { _ in
                        NSWorkspace.shared.activateFileViewerSelecting([track.url])
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Theme.divider).frame(height: 1)
            MetadataEditorFooter(
                session: session, changes: changes,
                blocker: title.trimmingCharacters(in: .whitespaces).isEmpty ? "The track needs a title." : nil,
                cancel: requestClose,
                write: { Task { await write(changes) } }
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.surface)
        .task { await loadLyrics() }
        .task { await loadMarkers() }
        .onDisappear { if syncing { player.isLyricsSyncActive = false } }
    }

    private static func fittedSize() -> CGSize {
        let window = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentLayoutRect.size ?? CGSize(width: 1400, height: 900)
        return CGSize(width: min(1000, max(860, window.width - 60)), height: min(740, max(580, window.height - 60)))
    }

    private func edited(_ t: TrackEditorTab) -> Bool {
        switch t {
        case .details: return !detailRows().isEmpty || artworkChanged || artworkRemoved
        case .lyrics: return lyrics != lyricsOriginal
        case .markers: return markers != markersOriginal
        }
    }

    // MARK: - Details

    private var details: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                CoverWell(data: artworkData, album: album, artist: artists.first ?? "") { data in
                    artworkData = data
                    artworkChanged = data != nil
                    artworkRemoved = data == nil && track.artwork != nil
                }
                if (artworkChanged || artworkRemoved), albumTracks.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        SheetLabel(text: "Use For")
                        HStack(spacing: 6) {
                            SheetTogglePill(title: "This Track", isOn: Binding(get: { !coverForAlbum }, set: { if $0 { coverForAlbum = false } }))
                            SheetTogglePill(title: "Whole Album", isOn: Binding(get: { coverForAlbum }, set: { if $0 { coverForAlbum = true } }))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $title)
                    .textFieldStyle(QuietFieldStyle(font: .system(size: 26, weight: .heavy)))
                    .accessibilityLabel("Title")
                ArtistsFieldView(artists: $artists, label: "Artists")
                HStack(alignment: .top, spacing: 18) {
                    QuietLabeledField(label: "Album", text: $album, placeholder: "None")
                        .frame(maxWidth: .infinity)
                    QuietLabeledField(label: "Year", text: $year, placeholder: "YYYY", numeric: true)
                        .frame(width: 80)
                    QuietLabeledField(label: "Track", text: $trackNumber, numeric: true)
                        .frame(width: 70)
                }
                HStack(alignment: .top, spacing: 18) {
                    GenreFieldView(text: $genre)
                        .frame(maxWidth: .infinity)
                    SecondaryGenresFieldView(genres: $secondaryGenres, primaryGenre: genre)
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 10) {
                    SheetTogglePill(title: "Mix Compilation", isOn: $isMixCompilation)
                        .disabled(!mixCompilationEligible && !isMixCompilation)
                    Text(mixCompilationEligible
                         ? "A mix, live set or radio show: chapter markers instead of lyrics."
                         : "Only for tracks longer than 10 minutes.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    SheetLabel(text: "File")
                    Text(fileLine)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
    }

    private var mixCompilationEligible: Bool { (track.duration ?? 0) > 600 }

    private var fileLine: String {
        var bits = [track.url.lastPathComponent, track.fileFormat.displayName]
        if let depth = track.bitDepth, let rate = track.sampleRate {
            bits.append("\(depth)-bit / \(rate.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(rate / 1000)) : String(format: "%.1f", rate / 1000)) kHz")
        }
        return bits.joined(separator: " · ")
    }

    // MARK: - Lyrics

    private var lyricsStudio: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                EditorTabs(tabs: [LyricsMode.write, .sync], selection: Binding(
                    get: { syncing ? .sync : .write },
                    set: { setSyncing($0 == .sync) }
                ), title: \.title)
                Text(lyricsCounts)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if !syncing {
                    if let before = lyricsBeforeFetch {
                        Button("Restore Yours") { lyrics = before; lyricsBeforeFetch = nil; lyricsNote = nil }
                            .buttonStyle(QuietTextButtonStyle())
                    }
                    Button {
                        Task { await fetchLyrics() }
                    } label: {
                        Label(isFetchingLyrics ? "Searching…" : "Find on lrclib", systemImage: "globe")
                    }
                    .buttonStyle(QuietTextButtonStyle())
                    .disabled(isFetchingLyrics)
                    Button("Remove Timings") { lyrics = Self.stripTimings(lyrics) }
                        .buttonStyle(QuietTextButtonStyle())
                        .disabled(!Self.hasTimings(lyrics))
                    Button("Clear") { lyrics = "" }
                        .buttonStyle(QuietTextButtonStyle())
                        .disabled(lyrics.isEmpty)
                }
            }
            if let lyricsNote {
                Text(lyricsNote)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            if !lyricsLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if syncing {
                LyricsSyncPane(track: track, lyrics: $lyrics)
            } else {
                TextEditor(text: $lyrics)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textPrimary.opacity(0.05)))
                    .accessibilityLabel("Lyrics")
                Text("Plain lines are fine. Lines with timings like [01:23.45] are synced lyrics in the visualizer; switch to Sync to set them while the track plays.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }

    enum LyricsMode: String, Identifiable, Hashable {
        case write, sync
        var id: String { rawValue }
        var title: String { self == .write ? "Write" : "Sync" }
    }

    private func setSyncing(_ on: Bool) {
        guard on != syncing else { return }
        syncing = on
        player.isLyricsSyncActive = on
        // Syncing listens to this track: start it if something else is on.
        if on, player.currentTrack?.id != track.id { player.startFreshQueue([track]) }
    }

    private var lyricsCounts: String {
        let lines = lyrics.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let timed = lines.filter { $0.range(of: #"^\[\d{1,2}:\d{2}"#, options: .regularExpression) != nil }.count
        return "\(lines.count) lines · \(timed) timed"
    }

    static func hasTimings(_ text: String) -> Bool {
        text.range(of: #"\[\d{1,2}:\d{2}"#, options: .regularExpression) != nil
    }

    static func stripTimings(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^(\[\d{1,2}:\d{2}(?:[.:,]\d{1,3})?\])+\s*"#, with: "", options: .regularExpression)
    }

    private func loadLyrics() async {
        // Prefer the file's embedded LYRICS tag — that's the source of truth
        // the user is editing. Fall back to whatever's in the in-memory cache
        // (e.g. just-fetched lrclib content not yet flushed to file).
        var initial = ""
        if let stored = try? await writer.readLyrics(from: track),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initial = stored
        } else if let entry = lyricsCache.entry(forKey: cacheKey), !entry.notFound {
            initial = entry.syncedLyrics ?? entry.plainLyrics ?? ""
        }
        lyrics = initial
        lyricsOriginal = initial
        lyricsLoaded = true
    }

    private var cacheKey: String {
        LyricsCacheKey.make(artist: track.artist ?? track.albumArtist, title: track.title, duration: track.duration)
    }

    private func fetchLyrics() async {
        isFetchingLyrics = true
        lyricsNote = nil
        defer { isFetchingLyrics = false }
        do {
            let found = try await LrcLibClient.shared.fetchLyrics(
                artist: artists.first ?? track.artist ?? "", title: title, album: album.isEmpty ? nil : album, duration: track.duration
            )
            guard let text = found?.syncedLyrics ?? found?.plainLyrics, !text.isEmpty else {
                lyricsNote = found?.instrumental == true ? "lrclib lists this track as instrumental." : "lrclib has no lyrics for this track."
                return
            }
            lyricsBeforeFetch = lyrics
            lyrics = text
            lyricsNote = found?.syncedLyrics != nil ? "Found synced lyrics on lrclib." : "Found plain lyrics on lrclib; Sync can time them."
        } catch {
            lyricsNote = "lrclib couldn't be reached. Check your connection and try again."
        }
    }

    /// The visualizer picks up the edit without waiting for the next track
    /// change. Empty input clears the cached entry entirely (so the next
    /// play re-reads from file or re-fetches).
    private func refreshLyricsCache(with payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lyricsCache.setEntry(LyricsCacheEntry(key: cacheKey, notFound: false))
            return
        }
        let synced = Self.hasTimings(trimmed)
        lyricsCache.setEntry(LyricsCacheEntry(key: cacheKey, plainLyrics: synced ? nil : trimmed, syncedLyrics: synced ? trimmed : nil))
    }

    // MARK: - Markers

    private var markersEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if markersLoaded {
                MarkersTimeline(track: track, markers: $markers)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }

    private func loadMarkers() async {
        let loaded = ((try? await writer.readMarkers(from: track)) ?? []).sortedByTime()
        markers = loaded
        markersOriginal = loaded
        markersLoaded = true
    }

    // MARK: - Changes

    private var artChange: MetadataWriter.ArtworkChange {
        if artworkRemoved { return .removed }
        if artworkChanged, let d = artworkData { return .updated(d) }
        return .unchanged
    }

    private var cleanedSecondary: [String] { secondaryGenres.filter { $0.lowercased() != genre.lowercased() } }

    private func detailRows() -> [TagDiff] {
        var rows: [TagDiff] = []
        func diff(_ tag: String, _ old: String, _ new: String) { if old != new { rows.append(TagDiff(tag: tag, old: old, new: new)) } }
        diff("TITLE", track.title, title.trimmingCharacters(in: .whitespaces))
        diff("ARTIST", track.artist ?? "", TagText.joined(artists) ?? "")
        diff("ALBUM", track.album ?? "", album)
        diff("DATE", TagText.number(track.year), TagText.number(Int(year)))
        diff("GENRE", GenreResolver.join(primary: track.genre, secondary: track.secondaryGenres) ?? "",
             GenreResolver.join(primary: genre.isEmpty ? nil : genre, secondary: cleanedSecondary) ?? "")
        diff("TRACKNUMBER", TagText.number(track.trackNumber), TagText.number(Int(trackNumber)))
        diff("MIX COMPILATION", track.isMixCompilation ? "Yes" : "No", isMixCompilation ? "Yes" : "No")
        return rows
    }

    private func pictureRow(for t: Track) -> TagDiff? {
        switch artChange {
        case .removed: return t.artwork == nil ? nil : TagDiff(tag: "PICTURE", old: TagText.cover(t.artwork), new: "")
        case .updated(let d): return t.artwork == d ? nil : TagDiff(tag: "PICTURE", old: TagText.cover(t.artwork), new: TagText.cover(d))
        case .unchanged: return nil
        }
    }

    private func fileChanges() -> [FileChange] {
        var rows = detailRows()
        if let p = pictureRow(for: track) { rows.append(p) }
        if lyricsLoaded, lyrics != lyricsOriginal {
            rows.append(TagDiff(tag: "LYRICS", old: Self.describe(lyricsOriginal), new: Self.describe(lyrics)))
        }
        if markersLoaded, markers != markersOriginal {
            rows.append(TagDiff(tag: "CUESHEET", old: Self.describe(markersOriginal), new: Self.describe(markers)))
        }
        var out: [FileChange] = []
        if !rows.isEmpty { out.append(FileChange(id: track.id, fileName: AlbumMetadataEditorView.displayPath(track.url), rows: rows)) }
        if coverForAlbum {
            for other in albumTracks where other.id != track.id {
                if let p = pictureRow(for: other) {
                    out.append(FileChange(id: other.id, fileName: AlbumMetadataEditorView.displayPath(other.url), rows: [p]))
                }
            }
        }
        return out
    }

    private static func describe(_ lyrics: String) -> String {
        let lines = lyrics.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "" }
        let timed = lines.filter { hasTimings(String($0)) }.count
        return timed > 0 ? "\(lines.count) lines, \(timed) timed" : "\(lines.count) lines"
    }

    private static func describe(_ markers: [TrackMarker]) -> String {
        markers.isEmpty ? "" : "\(markers.count) marker\(markers.count == 1 ? "" : "s")"
    }

    // MARK: - Writing

    private func write(_ changes: [FileChange]) async {
        let writer = writer
        let art = artChange
        let title = title.trimmingCharacters(in: .whitespaces)
        let artist = TagText.joined(artists)
        let album = album.isEmpty ? nil : album
        let year = Int(year)
        let genre = genre.isEmpty ? nil : genre
        let secondary = cleanedSecondary
        let number = Int(trackNumber)
        let mixChange: MetadataWriter.MixCompilationChange = isMixCompilation == track.isMixCompilation ? .unchanged : .set(isMixCompilation)
        let lyricsPayload = lyrics, markersPayload = markers.sortedByTime()
        let others = Dictionary(uniqueKeysWithValues: albumTracks.map { ($0.id, $0) })

        let allWritten = await session.write(changes) { file in
            if file.id == track.id {
                let tags = file.rows.filter { $0.tag != "LYRICS" && $0.tag != "CUESHEET" }
                var updated = track
                if !tags.isEmpty {
                    updated = try await writer.write(
                        to: track, title: title, artist: artist, album: album, year: year, genre: genre,
                        secondaryGenres: secondary, trackNumber: number, artworkChange: art, mixCompilationChange: mixChange
                    )
                }
                if file.rows.contains(where: { $0.tag == "LYRICS" }) {
                    try await writer.writeLyrics(to: track, lyrics: lyricsPayload.isEmpty ? nil : lyricsPayload)
                    refreshLyricsCache(with: lyricsPayload)
                }
                if file.rows.contains(where: { $0.tag == "CUESHEET" }) {
                    try await writer.writeMarkers(to: track, markers: markersPayload)
                }
                written[track.id] = updated
            } else if let other = others[file.id] {
                // Another track on the album: only its cover changes.
                written[other.id] = try await writer.write(
                    to: other, title: other.title, artist: other.artist, album: other.album, year: other.year,
                    genre: other.genre, secondaryGenres: other.secondaryGenres, trackNumber: other.trackNumber, artworkChange: art
                )
            }
        }
        commitWritten()
        if allWritten { dismiss() }
    }

    private func commitWritten() {
        guard !written.isEmpty else { return }
        for (id, t) in written {
            library.updateTrack(id: id, with: t)
            ArtworkImageCache.shared.invalidate(id: "track:\(id.uuidString)")
        }
        if written.count > 1 || coverForAlbum, let a = library.album(for: track) {
            library.invalidateAlbumArtwork(albumID: a.id)
        }
        written.removeAll()
    }

    private func requestClose() {
        guard session.phase != .writing else { return }
        commitWritten()
        dismiss()
    }
}

// MARK: - Sync

/// Syncing lyrics while the track plays: each line with its time, a
/// transport with a scrubber marked where lines are timed, and Set Line
/// (Space) stamping the line at the cursor with the playhead. The lines are
/// written back as LRC as they're stamped.
private struct LyricsSyncPane: View {
    let track: Track
    @Binding var lyrics: String

    @Environment(PlayerState.self) private var player
    @State private var lines: [(TimeInterval?, String)] = []
    @State private var cursor = 0
    /// The scrubber's width, measured after layout: a GeometryReader in a
    /// sheet can make the sheet's sizing depend on itself.
    @State private var scrubWidth: CGFloat = 300

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(lines.indices, id: \.self) { i in
                                lineRow(i).id(i)
                            }
                        }
                        .padding(6)
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textPrimary.opacity(0.05)))
                    .onChange(of: cursor) { _, c in
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(min(c, max(0, lines.count - 1)), anchor: .center) }
                    }
                }
                transport
            }
            preview
                .frame(width: 280)
        }
        // Space stamps the line at the cursor.
        .background {
            Button("", action: stamp)
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .onAppear(perform: seed)
    }

    private func lineRow(_ i: Int) -> some View {
        let active = i == cursor
        return HStack(spacing: 12) {
            Text(lines[i].0.map(Self.format) ?? "--:--.--")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(active ? Theme.background.opacity(0.7) : lines[i].0 == nil ? Theme.textTertiary : Theme.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(lines[i].1.isEmpty ? " " : lines[i].1)
                .font(.system(size: 14, weight: i == cursor + 1 ? .semibold : .regular))
                .foregroundStyle(active ? Theme.background : Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if lines[i].0 != nil {
                Button {
                    lines[i].0 = nil
                    commit()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(active ? Theme.background.opacity(0.7) : Theme.textTertiary)
                .help("Clear this line's time")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(active ? Theme.textPrimary : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            cursor = i
            if let t = lines[i].0, player.currentTrack?.id == track.id { player.engine.seek(to: t) }
        }
    }

    private var transport: some View {
        // Paused schedule: the readout only moves with playback time.
        TimelineView(.animation(minimumInterval: 0.05, paused: !player.isPlaying)) { _ in
            let duration = max(player.duration ?? track.duration ?? 1, 1)
            HStack(spacing: 10) {
                iconButton("gobackward.5", help: "Back 3 seconds") { player.engine.seek(to: max(0, player.currentTime - 3)) }
                Button { player.engine.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.textPrimary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Text(Self.format(player.currentTime))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 70)
                ZStack(alignment: .leading) {
                    ForEach(lines.indices, id: \.self) { i in
                        if let t = lines[i].0 {
                            Capsule().fill(Theme.textPrimary.opacity(0.45))
                                .frame(width: 2, height: 10)
                                .offset(x: scrubWidth * CGFloat(t / duration), y: -13)
                        }
                    }
                    Slider(value: Binding(get: { min(player.currentTime, duration) }, set: { player.engine.seek(to: $0) }), in: 0...duration)
                        .controlSize(.small)
                        .tint(Theme.textPrimary)
                        .accessibilityLabel("Playback position")
                }
                .frame(height: 30)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { scrubWidth = $0 }
                Button("Back") { stepBack() }
                    .buttonStyle(QuietTextButtonStyle())
                    .help("Undo the last time set")
                Button("Skip") { cursor = min(lines.count, cursor + 1) }
                    .buttonStyle(QuietTextButtonStyle())
                Button(action: stamp) {
                    HStack(spacing: 8) {
                        Text("Set Line")
                        Text("Space")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.background.opacity(0.2)))
                    }
                }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(cursor >= lines.count)
            }
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The line playing now, with the one before and after, as the
    /// visualizer will show them.
    private var preview: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !player.isAdvancing)) { _ in
            let now = currentIndex(at: player.heardTime)
            VStack(spacing: 10) {
                SheetLabel(text: "Preview")
                Text(text(now - 1)).font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
                Text(text(now)).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text(text(now + 1)).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                Text("Play, then press Space as each line starts. Click a line to jump to it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 12)
            }
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.textPrimary.opacity(0.05)))
        }
    }

    private func text(_ i: Int) -> String { lines.indices.contains(i) ? lines[i].1 : " " }

    private func currentIndex(at time: TimeInterval) -> Int {
        var idx = cursor
        var best: TimeInterval = -1
        for (i, l) in lines.enumerated() { if let t = l.0, t <= time, t > best { best = t; idx = i } }
        return best < 0 ? cursor : idx
    }

    private func seed() {
        if TrackMetadataEditorView.hasTimings(lyrics) {
            lines = Lyrics.parseLRC(lyrics).lines.map { ($0.timestamp, $0.text) }
        } else {
            lines = lyrics.split(separator: "\n", omittingEmptySubsequences: false).map { (nil, String($0)) }
        }
        cursor = lines.firstIndex { $0.0 == nil } ?? lines.count
    }

    private func stamp() {
        guard cursor < lines.count else { return }
        // The line the listener just heard: stamped against heard time, as
        // the lyrics visualizer shows it.
        lines[cursor].0 = player.heardTime
        cursor += 1
        commit()
    }

    private func stepBack() {
        guard cursor > 0 else { return }
        cursor -= 1
        lines[cursor].0 = nil
        commit()
    }

    private func commit() {
        lyrics = Lyrics.serializeLRC(lines: lines)
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--.--" }
        return String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Markers

/// The track as a bar with a flag at each chapter: drag a flag to move its
/// chapter, or nudge it with the arrow keys. A list below edits each one's
/// time and title.
private struct MarkersTimeline: View {
    let track: Track
    @Binding var markers: [TrackMarker]

    @Environment(PlayerState.self) private var player
    @State private var dragging: UUID?
    /// The timeline's width, measured after layout (see LyricsSyncPane).
    @State private var timelineWidth: CGFloat = 600
    @State private var newTime = ""
    @State private var newTitle = ""
    @FocusState private var focusedFlag: UUID?

    private var duration: TimeInterval { max(track.duration ?? player.duration ?? 1, 1) }
    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Chapter Markers")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    add(at: player.heardTime, title: "New Chapter")
                } label: {
                    Label("Add at Playhead", systemImage: "plus")
                }
                .buttonStyle(QuietTextButtonStyle())
                .disabled(!isCurrent)
                .help(isCurrent ? "Add a chapter where the track is playing" : "Play this track to add a chapter at the playhead")
            }
            timeline
            scale
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(markers.indices, id: \.self) { i in
                        row(i)
                    }
                    addRow
                }
            }
            Text("Drag a flag along the track to move its chapter, or select one and use ←/→ (hold Shift for 10 seconds). Chapters show in the player bar's scrubber.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var timeline: some View {
        let height: CGFloat = 84
        return Color.clear
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timelineWidth = $0 }
        .overlay(alignment: .topLeading) {
            let inset: CGFloat = 8
            let width = max(1, timelineWidth - inset * 2)
            let x = { (t: TimeInterval) in inset + width * CGFloat(min(max(t / duration, 0), 1)) }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.05))
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        if isCurrent { player.engine.seek(to: Double((p.x - inset) / width) * duration) }
                    }
                // Each chapter as a band, so the track's sections read at a glance.
                ForEach(markers.indices, id: \.self) { i in
                    let start = x(markers[i].timestamp)
                    let end = i + 1 < markers.count ? x(markers[i + 1].timestamp) : inset + width
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.textPrimary.opacity(i.isMultiple(of: 2) ? 0.14 : 0.08))
                        .frame(width: max(0, end - start - 2), height: 26)
                        .offset(x: start + 1, y: 44)
                        .allowsHitTesting(false)
                }
                if isCurrent {
                    TimelineView(.animation(minimumInterval: 0.1, paused: !player.isPlaying)) { _ in
                        Rectangle().fill(Theme.textSecondary.opacity(0.6))
                            .frame(width: 2, height: height)
                            .offset(x: x(player.currentTime) - 1)
                    }
                    .allowsHitTesting(false)
                }
                ForEach(markers) { marker in
                    flag(marker, x: x(marker.timestamp), width: width, inset: inset, height: height)
                }
            }
            .frame(width: timelineWidth, height: height, alignment: .topLeading)
            .coordinateSpace(name: "markers")
        }
    }

    private func flag(_ marker: TrackMarker, x: CGFloat, width: CGFloat, inset: CGFloat, height: CGFloat) -> some View {
        let active = dragging == marker.id || focusedFlag == marker.id
        return ZStack(alignment: .topLeading) {
            Capsule().fill(Theme.textPrimary)
                .frame(width: active ? 3 : 2, height: height - 8)
                .offset(x: 7, y: 4)
            Text(marker.title.isEmpty ? "Untitled" : marker.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.background)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.textPrimary))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.surface, lineWidth: active ? 1.5 : 0))
                .fixedSize()
                .offset(x: 10, y: 4)
            if active {
                Text(LyricsSyncPane.format(marker.timestamp))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surfaceElevated))
                    .fixedSize()
                    .offset(x: 10, y: height - 26)
            }
        }
        .frame(width: 16, height: height, alignment: .topLeading)
        .contentShape(Rectangle().size(width: 16, height: height))
        .offset(x: x - 8)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("markers"))
                .onChanged { v in
                    dragging = marker.id
                    move(marker.id, to: Double((v.location.x - inset) / width) * duration)
                }
                .onEnded { _ in dragging = nil }
        )
        .focusable()
        .focused($focusedFlag, equals: marker.id)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: .down) { press in nudge(marker.id, by: press.modifiers.contains(.shift) ? -10 : -1) }
        .onKeyPress(.rightArrow, phases: .down) { press in nudge(marker.id, by: press.modifiers.contains(.shift) ? 10 : 1) }
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .accessibilityElement()
        .accessibilityLabel(marker.title.isEmpty ? "Chapter" : marker.title)
        .accessibilityValue(LyricsSyncPane.format(marker.timestamp))
        .accessibilityAdjustableAction { d in _ = nudge(marker.id, by: d == .increment ? 1 : -1) }
    }

    private var scale: some View {
        HStack {
            ForEach(0..<5) { i in
                Text(FormatUtils.formatDuration(duration * Double(i) / 4))
                if i < 4 { Spacer() }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 8)
    }

    private func row(_ i: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(i + 1)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, alignment: .trailing)
                TimeField(seconds: Binding(get: { markers[i].timestamp }, set: { move(markers[i].id, to: $0) }))
                    .frame(width: 96)
                TextField("Chapter title", text: $markers[i].title)
                    .textFieldStyle(QuietFieldStyle(font: .system(size: 14, weight: .semibold)))
                Button {
                    markers.remove(at: i)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 28, height: 28)
                .help("Remove this chapter")
                .accessibilityLabel("Remove \(markers[i].title)")
            }
            .padding(.vertical, 5)
            Rectangle().fill(Theme.divider).frame(height: 0.5)
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22)
            TextField("mm:ss", text: $newTime)
                .textFieldStyle(QuietFieldStyle(font: .system(size: 13, design: .monospaced)))
                .frame(width: 96)
            TextField("New chapter title", text: $newTitle)
                .textFieldStyle(QuietFieldStyle(font: .system(size: 14, weight: .semibold)))
                .onSubmit(addTyped)
            Button("Add", action: addTyped)
                .buttonStyle(QuietTextButtonStyle())
                .disabled(TrackMarker.parseUserTimestamp(newTime) == nil)
        }
        .padding(.vertical, 6)
    }

    private func addTyped() {
        guard let t = TrackMarker.parseUserTimestamp(newTime) else { return }
        add(at: t, title: newTitle)
        newTime = ""
        newTitle = ""
    }

    private func add(at time: TimeInterval, title: String) {
        let t = min(max(time, 0), duration)
        guard !markers.contains(where: { abs($0.timestamp - t) < 1 }) else { return }
        markers.append(TrackMarker(timestamp: (t * 10).rounded() / 10, title: title))
        markers = markers.sortedByTime()
    }

    /// Moves a chapter, never past its neighbours, snapped to a tenth.
    private func move(_ id: UUID, to time: TimeInterval) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        let lo = i > 0 ? markers[i - 1].timestamp + 1 : 0
        let hi = i + 1 < markers.count ? markers[i + 1].timestamp - 1 : duration
        guard lo <= hi else { return }
        markers[i].timestamp = (min(max(time, lo), hi) * 10).rounded() / 10
    }

    private func nudge(_ id: UUID, by seconds: TimeInterval) -> KeyPress.Result {
        guard let m = markers.first(where: { $0.id == id }) else { return .ignored }
        move(id, to: m.timestamp + seconds)
        return .handled
    }
}

/// A time typed as m:ss, committed when the field loses focus or on Return.
private struct TimeField: View {
    @Binding var seconds: TimeInterval
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("m:ss", text: $text)
            .textFieldStyle(QuietFieldStyle(font: .system(size: 13, design: .monospaced)))
            .focused($focused)
            .onAppear { text = LyricsSyncPane.format(seconds) }
            .onChange(of: seconds) { _, s in if !focused { text = LyricsSyncPane.format(s) } }
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onSubmit(commit)
            .accessibilityLabel("Chapter time")
    }

    private func commit() {
        if let t = TrackMarker.parseUserTimestamp(text) { seconds = t }
        text = LyricsSyncPane.format(seconds)
    }
}
