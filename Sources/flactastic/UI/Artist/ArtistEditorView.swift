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
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().foregroundStyle(Theme.divider)
            ScrollView { formBody }
            Divider().foregroundStyle(Theme.divider)
            footer
        }
        .frame(width: 580, height: 720)
        .background(Theme.surface)
        .onAppear(perform: loadOverride)
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

    private var header: some View {
        HStack {
            Text("Edit Artist")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.xl)
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            displayNameField
            bannerSection
            profileSection
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Display name

    private var displayNameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display Name")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField(fallbackName, text: $displayName)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.surfaceElevated)
                )
            Text("Override only — original tags are not modified.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Banner

    private var bannerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Banner Image")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Button { pickImage(for: .banner) } label: {
                bannerPreview
            }
            .buttonStyle(.plain)
            .help("Click to choose a banner image")

            HStack(spacing: Theme.Spacing.md) {
                if currentBannerData != nil {
                    Button("Remove Banner") {
                        bannerData = nil
                        bannerRemoved = true
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("Cropped to 16:9 to fill the artist page.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var bannerPreview: some View {
        let displayData = currentBannerData ?? fallbackArtwork
        // Size a clear 16:9 box first and lay the image over it. A fill-mode
        // image as the base would report its own size and stretch the sheet.
        return Color.clear
            .aspectRatio(Self.bannerAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let data = displayData, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else {
                    Theme.surfaceElevated
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
            if displayData != nil { pageLayoutGuide }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay {
            if currentBannerData == nil {
                Text("Click to choose a banner")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
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
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Profile Image")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Button { pickImage(for: .profile) } label: {
                    profilePreview
                }
                .buttonStyle(.plain)
                .help("Click to choose a profile image")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Shown as a circular avatar on the artist page. Cropped to 1:1.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    if currentProfileData != nil {
                        Button("Remove Profile Image") {
                            profileData = nil
                            profileRemoved = true
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var profilePreview: some View {
        ZStack {
            if let data = currentProfileData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.surfaceElevated
                    .overlay {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 28, weight: .ultraLight))
                            .foregroundStyle(Theme.textTertiary.opacity(0.6))
                    }
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Reset to Default") { resetOverride() }
                .buttonStyle(PillButtonStyle())
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(PillButtonStyle())
            Button("Save") { save() }
                .buttonStyle(PillButtonStyle(isPrimary: true))
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
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
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        pendingCrop = PendingCrop(data: data, target: target)
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
