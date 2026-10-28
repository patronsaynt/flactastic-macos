import SwiftUI

/// Genre Groups, from Settings › Library View: which genres go in which of the
/// six groups that pick a spine's title face, and which faces each group may
/// use. The groups down the side; the chosen one's genres and faces beside.
/// Changes apply on Done.
struct GenreGroupsSheet: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var groups = GenreGroups()
    @State private var disabled: Set<SpineFont> = []
    @State private var selected: GenreTier = .heavy
    @State private var newGenre = ""
    @State private var hasSeeded = false

    private static let sample = "Come Over When You're Sober"

    var body: some View {
        FLSheet(title: "Genre Groups", width: 820, height: 640, contentScrolls: true) {
            HStack(alignment: .top, spacing: 0) {
                sidebar
                Rectangle().fill(Theme.divider).frame(width: 0.5)
                ScrollView {
                    detail
                        .padding(.horizontal, 28)
                        .padding(.vertical, 20)
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxHeight: .infinity)
        } footer: {
            HStack(spacing: 10) {
                Button("Reset to Defaults") {
                    groups = GenreGroups()
                    disabled = []
                }
                .buttonStyle(QuietTextButtonStyle())
                .disabled(groups == GenreGroups() && disabled.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SheetPillStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    settings.genreGroups = groups
                    settings.disabledSpineFaces = disabled
                    dismiss()
                }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard !hasSeeded else { return }
            hasSeeded = true
            groups = settings.genreGroups
            disabled = settings.disabledSpineFaces
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(GenreTier.allCases) { tier in
                GroupRow(
                    name: tier.name,
                    detail: "\(tier.fonts.filter { !disabled.contains($0) }.count) of \(tier.fonts.count) faces · \(groups.keywords(in: tier).count) genres",
                    isSelected: tier == selected
                ) { selected = tier }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 210)
    }

    // MARK: - Detail

    private var detail: some View {
        let faces = selected.fonts
        let firstOn = faces.first { !disabled.contains($0) }
        return VStack(alignment: .leading, spacing: 0) {
            Text(selected.name)
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Theme.textPrimary)
            Text(Self.sample)
                .font(firstOn.map { .custom($0.postScriptName, size: 20 * $0.scale) } ?? .system(size: 18, weight: .heavy))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.top, 4)

            SheetLabel(text: "Genres")
                .padding(.top, 26)
            Text("An album goes in the first group with a genre its own genre contains, so \u{201C}pop punk\u{201D} can sit here while \u{201C}pop\u{201D} sits elsewhere.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(groups.keywords(in: selected), id: \.self) { keyword in
                    GenreKeywordChip(
                        keyword: keyword,
                        isCustom: groups.isCustom(keyword),
                        current: selected,
                        move: { groups.move(keyword, to: $0) },
                        remove: { groups.remove(keyword) }
                    )
                }
            }
            .padding(.top, 12)
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Add a genre to \(selected.name)…", text: $newGenre)
                    .textFieldStyle(QuietFieldStyle(font: .system(size: 13, weight: .medium)))
                    .onSubmit(addGenre)
                    .frame(maxWidth: 280)
                    .accessibilityLabel("Add a genre to \(selected.name)")
            }
            .padding(.top, 12)

            SheetLabel(text: "Faces")
                .padding(.top, 28)
            Text(firstOn == nil
                 ? "Every face is off: this group's titles stay in SF Pro."
                 : "Each album rolls one of the faces left on. A face in two groups is switched off in both.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(faces, id: \.self) { face in
                    FaceRow(
                        face: face,
                        sample: Self.sample,
                        alsoIn: GenreTier.allCases.filter { $0 != selected && $0.fonts.contains(face) }.map(\.name),
                        isOn: Binding(
                            get: { !disabled.contains(face) },
                            set: { on in if on { disabled.remove(face) } else { disabled.insert(face) } }
                        )
                    )
                    if face != faces.last {
                        Rectangle().fill(Theme.divider).frame(height: 0.5)
                    }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addGenre() {
        let keyword = newGenre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return }
        groups.move(keyword, to: selected)
        newGenre = ""
    }
}

// MARK: - Parts

private struct GroupRow: View {
    let name: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.textPrimary.opacity(isSelected ? 0.08 : (isHovering ? 0.04 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A genre keyword. Click for Move To and, for the person's own, Remove.
/// A keyword the person added carries an outline.
private struct GenreKeywordChip: View {
    let keyword: String
    let isCustom: Bool
    let current: GenreTier
    let move: (GenreTier) -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            var items: [FLContextMenuItem] = [.label("Move \u{201C}\(keyword)\u{201D} to")]
            items += GenreTier.allCases.filter { $0 != current }.map { tier in .button(tier.name) { move(tier) } }
            if isCustom {
                items.append(.divider)
                items.append(.button("Remove", systemImage: "trash", destructive: true, action: remove))
            }
            FLContextMenuWindow.present(items: items, at: NSEvent.mouseLocation)
        } label: {
            Text(keyword)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Theme.textPrimary.opacity(isHovering ? 0.12 : 0.06)))
                .overlay(Capsule().inset(by: 0.5).stroke(Theme.textPrimary.opacity(isCustom ? 0.35 : 0), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isCustom ? "Your genre: move or remove it" : "Move to another group")
        .accessibilityLabel(keyword)
        .accessibilityHint(isCustom ? "Move or remove" : "Move to another group")
    }
}

/// A face: a title set in it, its name, and whether the group may use it.
private struct FaceRow: View {
    let face: SpineFont
    let sample: String
    let alsoIn: [String]
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sample)
                    .font(.custom(face.postScriptName, size: 19 * face.scale))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(alsoIn.isEmpty ? face.displayName : "\(face.displayName) · also in \(alsoIn.joined(separator: ", "))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .opacity(isOn ? 1 : 0.4)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(FLSwitchStyle())
                .accessibilityLabel(face.displayName)
        }
        .padding(.vertical, 10)
    }
}
