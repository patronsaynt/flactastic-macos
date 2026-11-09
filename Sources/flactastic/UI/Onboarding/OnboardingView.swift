import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// First-run setup, staged as an album. The steps are numbered tracks down
/// the left; the playing one plays out on the stage to the right, with the
/// rack's jewel case riding along beside it. Continue skips to the next
/// track: the stage stutters and tears off, a read laser sweeps across, the
/// case spins a full turn to its next mark and the new title springs in.
///
/// An intro throws the case in over the wordmark; "New here" or "Coming
/// back" then rewrites the tracklist (Look, Library, Spotify, or Restore,
/// Spotify). The finale throws the case back out and hands over to Home,
/// whose own case is thrown in. A backup is applied at the very end, and
/// FLACtastic restarts so every part of the app reads it fresh.
struct OnboardingView: View {
    /// Called when the user finishes. Defaults to marking onboarding complete
    /// in `Settings`. The app passes its own to also end a debug replay; the
    /// preview window closes itself instead.
    var onFinish: (() -> Void)?
    /// False in the debug preview: a backup can be read and shown, but is
    /// never written over this Mac's data.
    var appliesRestore = true

    @Environment(Settings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(ListeningStore.self) private var listening
    @Environment(SpotifyAuthController.self) private var spotifyAuth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var flow = OnboardingFlow()
    @State private var flood = ThemeFlood()
    @State private var isDropTargeted = false
    @State private var floatUp = false
    @State private var isBusy = false
    @State private var isSkipping = false
    @State private var revealTask: Task<Void, Never>?
    @State private var windowSize: CGSize = CGSize(width: 1200, height: 760)

    /// The tracklist's width: 372, narrowing to 300 in small windows to
    /// leave the case room.
    private static func trackWidth(in size: CGSize) -> CGFloat {
        min(372, max(300, size.width * 0.3)).rounded()
    }
    private static let ease = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.8)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                scene(in: geo.size)
                if flood.isPouring {
                    scene(in: geo.size)
                        .environment(\.colorScheme, flood.oldScheme)
                        .mask { FloodMask(flood: flood) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onAppear { windowSize = geo.size }
            .onChange(of: geo.size) { _, new in windowSize = new }
        }
        .clipped()
        .ignoresSafeArea()
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: drop)
        .task { await intro() }
        .onChange(of: copy.title) { _, _ in
            guard flow.phase == .steps, !isSkipping else { return }
            startReveal(from: CGSize(width: 0, height: 24), stagger: 0.05)
        }
        .onChange(of: library.tracksRevision) { _, _ in pickCaseAlbum() }
        .onChange(of: library.isLoadingFolder) { _, loading in
            if !loading { libraryFinished() }
        }
        .onChange(of: isConnectedToSpotify) { _, connected in
            guard connected, flow.current == .spotify else { return }
            flow.answers[.spotify] = "Connected"
            jolt()
        }
    }

    // MARK: - Layout

    /// Everything on screen, on its background: drawn a second time in the
    /// old look while a theme change pours in.
    private func scene(in size: CGSize) -> some View {
        let caseSize = Self.caseSize(in: size)
        let anchor = caseAnchor(in: size)
        return ZStack(alignment: .topLeading) {
            introMark
                .position(x: size.width / 2, y: size.height / 2)

            OnboardingCase(pose: flow.pose, album: flow.caseAlbum, size: caseSize, spin: discSpin,
                           backList: flow.tracks.enumerated().map { String(format: "%02d  %@", $0.offset + 1, $0.element.title) })
                .opacity(flow.caseShown ? 1 : 0)
                .frame(width: caseSize * 2.4, height: caseSize * 2.4)
                .offset(y: floatUp ? -5 : 5)
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: floatUp)
                .keyframeAnimator(initialValue: CGSize.zero, trigger: flow.jolts) { content, jolt in
                    content.offset(jolt)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(CGSize(width: 4, height: -3), duration: 0.04)
                        LinearKeyframe(CGSize(width: -3, height: 2), duration: 0.05)
                        LinearKeyframe(CGSize(width: 1, height: -1), duration: 0.05)
                        LinearKeyframe(CGSize.zero, duration: 0.06)
                    }
                }
                .position(anchor)

            HStack(spacing: 0) {
                OnboardingTracklist(flow: flow) { i in Task { await go(to: i) } }
                    .frame(width: Self.trackWidth(in: size))
                stage(in: size)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Theme.background)
    }

    /// The step's column: wide enough for the scan's counts, at most 450.
    private static func bodyWidth(in size: CGSize) -> CGFloat {
        min(450, max(330, (size.width - trackWidth(in: size)) * 0.5))
    }

    /// The room right of the step's column, where the case lives.
    private static func caseRoom(in size: CGSize) -> (left: CGFloat, width: CGFloat) {
        let left = trackWidth(in: size) + 68 + bodyWidth(in: size) + 24
        return (left, max(0, size.width - 28 - left))
    }

    /// As big as the room beside the column allows. The case with its disc
    /// slid out spans about 1.5 times its size, so it never reaches the
    /// step's content or the window's edge.
    private static func caseSize(in size: CGSize) -> CGFloat {
        min(240, size.height * 0.32, max(90, caseRoom(in: size).width / 1.55)).rounded()
    }

    /// Where the case's mark sits: centred in that room, allowing for the
    /// disc sliding out to the right.
    private func caseAnchor(in size: CGSize) -> CGPoint {
        let room = Self.caseRoom(in: size)
        let caseSize = Self.caseSize(in: size)
        let span = caseSize * 1.46
        return CGPoint(x: room.left + max(0, room.width - span) / 2 + caseSize * 0.5, y: size.height * 0.52)
    }

    private var copy: OnboardingCopy {
        OnboardingCopy.for(flow, settings: settings, library: library, spotify: spotifyAuth.state)
    }

    private var isConnectedToSpotify: Bool {
        if case .connected = spotifyAuth.state { return true }
        return false
    }

    /// The disc spins up while the library is read, and while Spotify signs in.
    private var discSpin: Double {
        if flow.current == .library && library.isLoadingFolder && settings.lastRootPath != nil { return 520 }
        if flow.current == .spotify, case .connecting = spotifyAuth.state { return 300 }
        return 0
    }

    private var introMark: some View {
        Wordmark(height: 62)
            .mask(alignment: .leading) {
                Rectangle().frame(width: flow.markIn ? 900 : 0)
            }
            .scaleEffect(flow.markLifted ? 0.5 : 1)
            .offset(y: flow.markLifted ? -190 : 0)
            .opacity(flow.markLifted ? 0 : 1)
            .blur(radius: flow.markLifted ? 8 : 0)
            .accessibilityHidden(true)
    }

    private func stage(in size: CGSize) -> some View {
        let stageWidth = size.width - Self.trackWidth(in: size)
        let titleSize = min(76, max(56, size.height * 0.1)).rounded()
        let bodyWidth = Self.bodyWidth(in: size)
        let copy = copy
        let cut = flow.cut
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if copy.isOptional {
                    Text("OPTIONAL")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.18), lineWidth: 1))
                        .padding(.bottom, 14)
                        .opacity(flow.detailsIn ? 1 : 0)
                }
                OnboardingTitle(text: copy.title, revealed: flow.revealedWords, from: flow.wordsFrom, fontSize: titleSize)
                    .frame(maxWidth: min(stageWidth - 132, titleSize * 8.6), alignment: .leading)
                Text(copy.subtitle)
                    .font(.system(size: 17))
                    .foregroundStyle(flow.restoreError != nil && flow.current == .play ? Theme.qualityLow : Theme.textSecondary)
                    .lineSpacing(4)
                    .frame(maxWidth: min(stageWidth - 132, 520), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
                    .modifier(Arrive(isIn: flow.detailsIn, delay: 0))
                stepBody
                    .frame(width: bodyWidth, alignment: .leading)
                    .padding(.top, 30)
                    .modifier(Arrive(isIn: flow.detailsIn, delay: 0.12))
            }
            .modifier(SkewEffect(skew: cut.skew))
            .scaleEffect(x: cut.stretch, y: 1, anchor: .leading)
            .blur(radius: cut.blur)
            .opacity(cut.opacity)
            .offset(x: cut.x)

            Spacer(minLength: 16)
            transport(copy)
                .opacity(flow.dealt && !flow.leaving ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(flow.leaving ? 0 : 0.8), value: flow.dealt)
                .animation(.easeOut(duration: 0.4), value: flow.leaving)
        }
        .padding(.leading, 68)
        .padding(.trailing, 64)
        // Less air above the title in short windows, so the scan fits.
        .padding(.top, max(64, size.height * 0.147 - max(0, 760 - size.height) * 0.25).rounded())
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay { laser }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch flow.current {
        case .hello:
            OnboardingHelloStep(flow: flow, choose: choose)
        case .look:
            OnboardingLookStep(pick: pickLook)
        case .library:
            OnboardingLibraryStep(flow: flow, useDefault: useDefaultFolder, choose: chooseFolder, isTargeted: isDropTargeted)
                .animation(Self.ease, value: settings.lastRootPath)
                .animation(Self.ease, value: flow.libraryScanned)
        case .restore:
            OnboardingRestoreStep(flow: flow, chooseBackup: chooseBackup, unlock: unlock, chooseFolder: chooseFolderForBackup, isTargeted: isDropTargeted)
                .animation(Self.ease, value: flow.backup?.createdAt)
                .animation(Self.ease, value: flow.lockedBackup)
        case .spotify:
            OnboardingSpotifyStep()
        case .play:
            EmptyView()
        }
    }

    private func transport(_ copy: OnboardingCopy) -> some View {
        HStack(spacing: 14) {
            Button { Task { await go(to: flow.at - 1) } } label: {
                Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
            }
            .buttonStyle(QuietTextButtonStyle())
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .opacity(flow.at == 0 ? 0 : 1)
            .disabled(flow.at == 0)

            Spacer()

            if copy.canContinue {
                Text("Return to continue")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .transition(.opacity)
            }
            if let secondary = copy.secondary {
                if copy.primary == nil {
                    Button(secondary) { Task { await go(to: flow.at + 1) } }
                        .buttonStyle(SheetPillStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(secondary) { Task { await go(to: flow.at + 1) } }
                        .buttonStyle(SheetPillStyle())
                }
            }
            if let primary = copy.primary {
                Button { Task { await go(to: flow.at + 1) } } label: {
                    HStack(spacing: 9) {
                        Text(primary)
                        Image(systemName: copy.primaryIcon).font(.system(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!copy.canContinue)
            }
        }
        .animation(.easeOut(duration: 0.2), value: copy)
    }

    /// The skip's read laser and the flash of light behind it.
    private var laser: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Theme.textPrimary.opacity(flow.pop)
                Rectangle()
                    .fill(Theme.textPrimary)
                    .frame(width: 2)
                    .shadow(color: Theme.textPrimary.opacity(0.5), radius: 9)
                    .shadow(color: Theme.textPrimary.opacity(0.14), radius: 30)
                    .offset(x: geo.size.width * flow.laser - 1)
                    .opacity(flow.laserOpacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Intro

    private func intro() async {
        flow.answers[.hello] = "New here"
        flow.answers[.look] = lookName(settings.theme)
        let size = windowSize
        let anchor = caseAnchor(in: size)
        if reduceMotion {
            flow.caseShown = true
            flow.pose = flow.pose(for: .hello)
            flow.markIn = true
            flow.markLifted = true
            flow.dealt = true
            flow.phase = .steps
            flow.revealedWords = 99
            flow.detailsIn = true
            return
        }
        try? await Task.sleep(for: .seconds(0.25))
        // The wordmark wipes on, big and centred.
        withAnimation(.timingCurve(0.7, 0, 0.2, 1, duration: 1.1)) { flow.markIn = true }
        try? await Task.sleep(for: .seconds(1.0))
        // The case is thrown in from the right and caught in front of it.
        let landX = size.width / 2 - anchor.x, landY = size.height / 2 - anchor.y + 20
        flow.caseShown = true
        withAnimation(.linear(duration: 0.64)) {
            flow.pose = CasePose(x: landX + 70, y: landY - 10, zoom: 1.08, tilt: 30, roll: -8, turn: 70, disc: 0.08)
        }
        try? await Task.sleep(for: .seconds(0.64))
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9)) {
            flow.pose = CasePose(x: landX, y: landY, zoom: 1.15, tilt: 10, roll: 4, turn: 26, disc: 0.42)
        }
        jolt()
        try? await Task.sleep(for: .seconds(1.1))
        // The wordmark lifts away, the case glides to its mark, and the
        // tracklist deals in a row at a time.
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.0)) { flow.markLifted = true }
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 1.3)) { flow.pose = flow.pose(for: .hello) }
        try? await Task.sleep(for: .seconds(0.3))
        flow.dealt = true
        try? await Task.sleep(for: .seconds(0.4))
        flow.phase = .steps
        floatUp = true
        startReveal(from: CGSize(width: 0, height: 34), stagger: 0.06)
    }

    /// Brings the title in word by word, then the line under it and the step.
    private func startReveal(from offset: CGSize, stagger: Double, spring: Bool = false) {
        revealTask?.cancel()
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            flow.wordsFrom = offset
            flow.revealedWords = 0
            flow.detailsIn = false
        }
        let words = copy.title.split(separator: " ").count
        revealTask = Task {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.2)) { flow.revealedWords = words; flow.detailsIn = true }
                return
            }
            for i in 1...max(1, words) {
                withAnimation(spring ? .spring(response: 0.5, dampingFraction: 0.68) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.75)) {
                    flow.revealedWords = i
                }
                try? await Task.sleep(for: .seconds(stagger))
                if Task.isCancelled { return }
            }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)) { flow.detailsIn = true }
        }
    }

    // MARK: - The skip

    private func go(to index: Int) async {
        guard !isBusy, flow.phase == .steps else { return }
        if index >= flow.tracks.count, flow.current == .play { await finale(); return }
        guard index >= 0, index < flow.tracks.count, index != flow.at else { return }
        let dir: Double = index > flow.at ? 1 : -1
        isBusy = true
        isSkipping = true
        defer { isBusy = false }

        if dir > 0 {
            let current = flow.current
            if flow.answers[current] == nil || current == .spotify {
                flow.answers[current] = defaultAnswer(for: current)
            }
            flow.skipping = current
        }
        let target = flow.tracks[index]
        if !reduceMotion { flow.spins += Int(dir) }
        move(.timingCurve(0.16, 1, 0.3, 1, duration: 1.15), to: flow.pose(for: target))

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) { flow.cut.opacity = 0 }
            try? await Task.sleep(for: .seconds(0.15))
        } else {
            // The laser sweeps the stage and the light pops once.
            flow.laser = dir > 0 ? 0 : 1
            withAnimation(.timingCurve(0.5, 0, 0.3, 1, duration: 0.42)) { flow.laser = dir > 0 ? 1 : 0 }
            withAnimation(.easeOut(duration: 0.06)) { flow.laserOpacity = 1 }
            withAnimation(.easeIn(duration: 0.08).delay(0.34)) { flow.laserOpacity = 0 }
            withAnimation(.easeOut(duration: 0.09).delay(0.1)) { flow.pop = 0.07 }
            withAnimation(.easeOut(duration: 0.35).delay(0.19)) { flow.pop = 0 }
            // The old track stutters like a disc catching…
            for (x, t) in [(-12.0, 0.04), (5.0, 0.025), (-20.0, 0.03), (-8.0, 0.025)] {
                withAnimation(.linear(duration: t)) { flow.cut.x = x * dir }
                try? await Task.sleep(for: .seconds(t))
            }
            // …then tears off sideways.
            withAnimation(.timingCurve(0.6, 0, 0.9, 0.4, duration: 0.24)) {
                flow.cut = StageCut(x: -140 * dir, skew: -12 * dir, blur: 20, opacity: 0, stretch: 1.1)
            }
            try? await Task.sleep(for: .seconds(0.24))
        }

        var swap = Transaction()
        swap.disablesAnimations = true
        withTransaction(swap) {
            flow.skipping = nil
            flow.at = index
            flow.cut = StageCut()
            flow.progress = target == .play || (target == .library && flow.libraryScanned) ? 1 : 0.08
        }
        if target == .library {
            pickCaseAlbum()
            // A folder linked before (a replay) that's already read through.
            if settings.lastRootPath != nil, !library.isLoadingFolder, library.hasCompletedInitialLoad { libraryFinished() }
        }
        isSkipping = false
        startReveal(from: CGSize(width: 40 * dir, height: 0), stagger: 0.045, spring: true)
        Task {
            try? await Task.sleep(for: .seconds(0.38))
            jolt()
        }
    }

    /// A pose move, or a short fade under Reduce Motion.
    private func move(_ animation: Animation, to pose: CasePose) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : animation) { flow.pose = pose }
    }

    private func jolt() {
        if !reduceMotion { flow.jolts += 1 }
    }

    private func defaultAnswer(for track: OnboardingFlow.Track) -> String? {
        switch track {
        case .hello: flow.branch == .new ? "New here" : "Coming back"
        case .look: lookName(settings.theme)
        case .spotify: isConnectedToSpotify ? "Connected" : "Skipped, connect any time"
        default: flow.answers[track]
        }
    }

    private func lookName(_ theme: AppTheme) -> String {
        theme == .system ? "Follow System" : theme.label
    }

    // MARK: - Finale

    private func finale() async {
        guard !isBusy else { return }
        isBusy = true
        let restoring = flow.branch == .back && appliesRestore
        if restoring, var archive = flow.backup {
            if let folder = flow.backupFolder { archive.libraryRootPath = folder }
            let folder = flow.backupFolder
            flow.restoreError = nil
            flow.isRestoring = true
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try UserDataBackup.restore(archive)
                    if let folder { UserDefaults.standard.set(folder, forKey: "flactastic.lastRootPath") }
                    UserDefaults.standard.set(true, forKey: "flactastic.hasCompletedOnboarding")
                }
            }.value
            flow.isRestoring = false
            if case .failure(let error) = result {
                flow.restoreError = "The restore didn't finish: \(error.localizedDescription)"
                isBusy = false
                return
            }
        }
        flow.phase = .finale
        floatUp = false
        withAnimation(.timingCurve(0.6, 0, 0.9, 0.4, duration: 0.5)) {
            flow.leaving = true
            flow.detailsIn = false
            flow.cut = StageCut(x: 0, skew: 0, blur: 12, opacity: 0, stretch: 1)
        }
        if !reduceMotion {
            try? await Task.sleep(for: .seconds(0.25))
            // Thrown back out; Home throws its own case in.
            withAnimation(.timingCurve(0.5, 0, 0.75, 0, duration: 0.7)) {
                flow.pose = CasePose(x: -1300, y: -260, zoom: 0.2, tilt: -200, roll: 120, turn: flow.pose.turn - 300, disc: 0.4)
            }
            try? await Task.sleep(for: .seconds(0.8))
        }
        if restoring {
            AppRelauncher.relaunch()
            // Still here: the new copy couldn't be started.
            flow.restoreError = "Your backup is in place. Quit and reopen FLACtastic to finish."
            return
        }
        if let onFinish {
            onFinish()
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { settings.hasCompletedOnboarding = true }
        }
    }

    // MARK: - Hello

    private func choose(_ branch: OnboardingFlow.Branch) {
        guard branch != flow.branch else { return }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.6)) { flow.branch = branch }
        flow.answers[.hello] = branch == .new ? "New here" : "Coming back"
        move(.spring(response: 0.9, dampingFraction: 0.72), to: flow.pose(for: .hello))
        // A backup read earlier is put aside, along with the look it brought.
        if branch == .new, flow.backup != nil || flow.lockedBackup != nil {
            flow.backup = nil
            flow.lockedBackup = nil
            flow.backupFolder = nil
            flow.answers[.restore] = nil
            if let before = flow.themeBeforeBackup, before != settings.theme {
                if reduceMotion { settings.theme = before } else { flood.pour(from: colorScheme) { settings.theme = before } }
            }
            flow.themeBeforeBackup = nil
        }
    }

    // MARK: - Look

    private func pickLook(_ theme: AppTheme, at point: CGPoint?) {
        guard theme != settings.theme else { return }
        flow.answers[.look] = lookName(theme)
        if reduceMotion {
            settings.theme = theme
        } else {
            flood.pour(from: colorScheme, at: point) { settings.theme = theme }
        }
        // The case turns to catch the new light.
        var pose = flow.pose(for: .look)
        pose.turn += theme == .light ? -14 : theme == .dark ? 14 : 0
        move(.spring(response: 1.0, dampingFraction: 0.65), to: pose)
    }

    // MARK: - Library

    private func useDefaultFolder() {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        let folder = music.appendingPathComponent("FLACtastic", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            adopt(folder)
        } catch {
            showError("Couldn't create ~/Music/FLACtastic", error)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose your music folder"
        if panel.runModal() == .OK, let url = panel.url { adopt(url) }
    }

    private func adopt(_ url: URL) {
        flow.libraryScanned = false
        flow.caseAlbum = nil
        flow.progress = 0.08
        flow.answers[.library] = "Scanning…"
        settings.lastRootPath = url.path
        library.openFolder(url)
        playlistStore.load(from: url)
        listening.load(from: url)
        var pose = flow.pose(for: .library)
        pose.disc = 0.5
        move(.spring(response: 0.9, dampingFraction: 0.7), to: pose)
        // An empty folder can be read before the change is ever seen.
        Task {
            for _ in 0..<40 where !flow.libraryScanned {
                try? await Task.sleep(for: .seconds(0.25))
                if !library.isLoadingFolder, library.rootURL?.path == url.path { libraryFinished() }
            }
        }
    }

    /// The case takes the first cover the scan finds.
    private func pickCaseAlbum() {
        guard flow.branch == .new, flow.at >= (flow.tracks.firstIndex(of: .library) ?? 99),
              flow.caseAlbum == nil, settings.lastRootPath != nil else { return }
        flow.caseAlbum = library.albums.first { $0.artwork != nil }
    }

    private func libraryFinished() {
        guard flow.branch == .new, settings.lastRootPath != nil, !flow.libraryScanned,
              flow.at >= (flow.tracks.firstIndex(of: .library) ?? 99) else { return }
        flow.libraryScanned = true
        pickCaseAlbum()
        let count = library.tracks.count
        flow.answers[.library] = count == 0
            ? "\(((settings.lastRootPath ?? "") as NSString).lastPathComponent), empty"
            : "\(count.formatted()) track\(count == 1 ? "" : "s")"
        if flow.current == .library {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.6)) { flow.progress = 1 }
            move(.spring(response: 0.8, dampingFraction: 0.6), to: flow.pose(for: .library))
            jolt()
        }
    }

    // MARK: - Restore

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.title = "Choose a FLACtastic Backup"
        panel.allowedContentTypes = [UTType(filenameExtension: UserDataBackup.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { readBackup(url) }
    }

    private func readBackup(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if try UserDataBackup.isEncrypted(data) {
                flow.passwordError = nil
                flow.lockedBackup = data
            } else {
                decode(data, password: nil)
            }
        } catch {
            showError("Couldn't open that backup", error)
        }
    }

    private func unlock(_ password: String) {
        guard let data = flow.lockedBackup else { return }
        guard !password.isEmpty else {
            flow.passwordError = "Enter the backup's password."
            return
        }
        decode(data, password: password)
    }

    private func decode(_ data: Data, password: String?) {
        flow.passwordError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try UserDataBackup.decode(data, password: password) }
            }.value
            switch result {
            case .success(let archive):
                flow.lockedBackup = nil
                flow.receiptIn = false
                flow.backup = archive
                Task { @MainActor in flow.receiptIn = true }
                flow.answers[.restore] = "From \(archive.createdAt.formatted(.dateTime.day().month(.wide)))"
                // The backup slides in with a full turn, and its look pours in.
                var pose = flow.pose(for: .restore)
                if !reduceMotion { pose.turn += 360 }
                pose.disc = 0.5
                move(.timingCurve(0.16, 1, 0.3, 1, duration: 1.2), to: pose)
                Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    jolt()
                    if let theme = flow.backupTheme, theme != settings.theme {
                        if flow.themeBeforeBackup == nil { flow.themeBeforeBackup = settings.theme }
                        if reduceMotion { settings.theme = theme } else { flood.pour(from: colorScheme) { settings.theme = theme } }
                    }
                }
            case .failure(let error):
                if flow.lockedBackup != nil {
                    flow.passwordError = error.localizedDescription
                } else {
                    showError("Couldn't read that backup", error)
                }
            }
        }
    }

    private func chooseFolderForBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose your music folder"
        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(Self.ease) { flow.backupFolder = url.path }
        }
    }

    // MARK: - Drop

    /// A folder dropped on the Library track, or a backup on the Restore track.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let track = flow.current
        guard track == .library || track == .restore else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
                if track == .library, isDirectory.boolValue, flow.current == .library {
                    adopt(url)
                } else if track == .restore, !isDirectory.boolValue, flow.current == .restore, flow.backup == nil {
                    readBackup(url)
                }
            }
        }
        return true
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// The subtitle and step body arriving after the title: up, unblurred, in.
private struct Arrive: ViewModifier {
    let isIn: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isIn ? 1 : 0)
            .blur(radius: isIn ? 0 : 6)
            .offset(y: isIn ? 0 : 14)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.8).delay(isIn ? delay : 0), value: isIn)
    }
}
