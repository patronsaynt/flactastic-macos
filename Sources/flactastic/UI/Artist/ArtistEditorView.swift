import SwiftUI
import AppKit

struct ArtistEditorView: View {
    let canonicalKey: String
    let fallbackName: String
    let fallbackArtwork: Data?

    @Environment(\.dismiss)        private var dismiss
    @Environment(ArtistStore.self) private var artistStore

    @State private var displayName: String = ""
    @State private var bannerData: Data? = nil
    @State private var bannerRemoved: Bool = false
    @State private var profileData: Data? = nil
    @State private var profileRemoved: Bool = false

    /// Drives a cropping sheet — `target` decides which field receives the
    /// cropped result.
    @State private var pendingCrop: PendingCrop? = nil
    /// Previews, decoded off the main thread at the size they're shown.
    /// Decoding a full-size banner in `body` ran on every redraw, even while
    /// typing the name.
    @State private var bannerPreviewImage: NSImage?
    @State private var profilePreviewImage: NSImage?

    /// The artist page's banner fills the window below the top bar, so
    /// banners are cropped to a widescreen frame rather than a strip.
    static let bannerAspectRatio: CGFloat = 16.0 / 9.0

    private struct PendingCrop: Identifiable {
        let id = UUID()
        enum Target { case banner, profile }
        let data: Data
        let target: Target
    }

    var body: some View {
        FLSheet(title: "Edit Artist", width: 600, height: 740) {
            ScrollView { formBody }
                .scrollIndicators(.automatic)
        } footer: {
            footer
        }
        .onAppear(perform: loadOverride)
        .task(id: previewKey(currentBannerData ?? fallbackArtwork)) {
            bannerPreviewImage = await Self.preview(currentBannerData ?? fallbackArtwork, maxPixel: 1100)
        }
        .task(id: previewKey(currentProfileData)) {
            profilePreviewImage = await Self.preview(currentProfileData, maxPixel: 240)
        }
        .sheet(item: $pendingCrop) { crop in
            let isBanner = crop.target == .banner
            ImageCropperView(
                sourceData: crop.data,
                aspectRatio: isBanner ? Self.bannerAspectRatio : 1.0,
                title: isBanner ? "Crop Banner" : "Crop Profile Image",
                maxOutputPixelWidth: isBanner ? 2400 : 1200,
                jpegQuality: isBanner ? 0.86 : nil,
                cropWindowWidth: isBanner ? 560 : nil
            ) { cropped in
                switch crop.target {
                case .banner:
                    bannerData = cropped
                    bannerRemoved = false
                case .profile:
                    profileData = cropped
                    profileRemoved = false
                }
            }
        }
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 30) {
            displayNameField
            bannerSection
            profileSection
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    // MARK: - Display name

    private var displayNameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(fallbackName, text: $displayName)
                .textFieldStyle(QuietFieldStyle(font: .system(size: 34, weight: .heavy)))
                .accessibilityLabel("Display name")
            Text("Shown in FLACtastic only; your files' tags aren't changed.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Banner

    private var bannerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SheetLabel(text: "Banner")
                Spacer()
                Text("Cropped to 16:9 to fill the artist page.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            Button { pickImage(for: .banner) } label: {
                bannerPreview
            }
            .buttonStyle(.plain)
            .help(currentBannerData == nil ? "Choose a banner image" : "Change the banner image")
            .accessibilityLabel(currentBannerData == nil ? "Add banner" : "Change banner")

            if currentBannerData != nil {
                Button("Remove banner") {
                    bannerData = nil
                    bannerRemoved = true
                }
                .buttonStyle(QuietTextButtonStyle())
                .padding(.leading, -10)
            }
        }
    }

    private var bannerPreview: some View {
        // Size a clear 16:9 box first and lay the image over it. A fill-mode
        // image as the base would report its own size and stretch the sheet.
        Color.clear
            .aspectRatio(Self.bannerAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = bannerPreviewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else {
                    Theme.textPrimary.opacity(0.05)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                if bannerPreviewImage != nil { pageLayoutGuide }
            }
            .overlay {
                // "Add banner" until one is set (the preview may be the
                // artist's album art standing in); "Change banner" on hover.
                CoverEditOverlay(isEmpty: currentBannerData == nil, emptyLabel: "Add banner", changeLabel: "Change banner")
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Faint stand-ins for the profile picture, name and buttons, so the
    /// user can see which part of the banner sits under them on the page.
    private var pageLayoutGuide: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 10) {
                Circle()
                    .strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(.white.opacity(0.55)).frame(width: 150, height: 16)
                    Capsule().fill(.white.opacity(0.35)).frame(width: 80, height: 5)
                    HStack(spacing: 5) {
                        Capsule().fill(.white.opacity(0.5)).frame(width: 30, height: 11)
                        Capsule().fill(.white.opacity(0.3)).frame(width: 34, height: 11)
                    }
                    .padding(.top, 3)
                }
            }
            .padding(.leading, 12)
            .padding(.bottom, 30)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Profile image

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetLabel(text: "Profile Picture")

            HStack(alignment: .center, spacing: 20) {
                Button { pickImage(for: .profile) } label: {
                    profilePreview
                }
                .buttonStyle(.plain)
                .help(currentProfileData == nil ? "Choose a profile picture" : "Change the profile picture")
                .accessibilityLabel(currentProfileData == nil ? "Add profile picture" : "Change profile picture")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Shown as a circle on the artist page. Cropped to 1:1.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    if currentProfileData != nil {
                        Button("Remove picture") {
                            profileData = nil
                            profileRemoved = true
                        }
                        .buttonStyle(QuietTextButtonStyle())
                        .padding(.leading, -10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var profilePreview: some View {
        ZStack {
            if let image = profilePreviewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.textPrimary.opacity(0.05)
                    .overlay {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 30, weight: .ultraLight))
                            .foregroundStyle(Theme.textTertiary.opacity(0.6))
                    }
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(Circle())
        .overlay {
            CoverEditOverlay(isEmpty: false, changeLabel: currentProfileData == nil ? "Add" : "Change", shape: .circle)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Reset to Default") { resetOverride() }
                .buttonStyle(QuietTextButtonStyle())
                .help("Remove this artist's custom name, banner and picture")
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetPillStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
        }
    }

    // MARK: - Previews

    /// Identifies an image cheaply (no hashing of the bytes), so a preview
    /// is only re-decoded when the image actually changes.
    private func previewKey(_ data: Data?) -> String {
        data.map(ArtworkImageCache.contentID(for:)) ?? "none"
    }

    private static func preview(_ data: Data?, maxPixel: Int) async -> NSImage? {
        guard let data else { return nil }
        let box = await Task.detached(priority: .userInitiated) {
            ArtworkImageCache.ImageBox(image: PrerenderedImage.nsImage(PrerenderedImage.downsampled(data, maxPixel: maxPixel)))
        }.value
        return box.image
    }

    // MARK: - Computed accessors

    private var currentBannerData: Data? {
        bannerRemoved ? nil : bannerData
    }

    private var currentProfileData: Data? {
        profileRemoved ? nil : profileData
    }

    // MARK: - Actions

    private func loadOverride() {
        if let existing = artistStore.override(forKey: canonicalKey) {
            displayName = existing.displayName ?? ""
            bannerData = existing.bannerImage
            profileData = existing.profileImage
            bannerRemoved = false
            profileRemoved = false
        }
    }

    private func pickImage(for target: PendingCrop.Target) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = target == .banner
            ? "Choose a banner image"
            : "Choose a profile image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Large originals read off the main thread.
        Task {
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard let data else { return }
            pendingCrop = PendingCrop(data: data, target: target)
        }
    }

    private func save() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameToStore: String? = trimmed.isEmpty ? nil : trimmed
        let bannerToStore: Data? = bannerRemoved ? nil : bannerData
        let profileToStore: Data? = profileRemoved ? nil : profileData
        let override = ArtistOverride(
            canonicalKey: canonicalKey,
            displayName: nameToStore,
            bannerImage: bannerToStore,
            profileImage: profileToStore
        )
        artistStore.upsert(override)
        dismiss()
    }

    private func resetOverride() {
        artistStore.remove(key: canonicalKey)
        dismiss()
    }
}
