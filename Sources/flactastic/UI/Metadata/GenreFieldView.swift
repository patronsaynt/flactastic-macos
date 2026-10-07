import SwiftUI

let predefinedGenres: [String] = [
    "Alternative", "Ambient", "Blues", "Classical", "Country",
    "Electronic", "Folk", "Hip-Hop", "Indie", "Jazz",
    "Latin", "Metal", "Pop", "Punk", "R&B",
    "Reggae", "Rock", "Soul", "Soundtrack", "World"
]

/// Drop-in replacement for the genre metaField that adds a tag picker button.
struct GenreFieldView: View {
    @Binding var text: String
    @Environment(Settings.self) private var settings
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SheetLabel(text: "Genre")
            HStack(spacing: Theme.Spacing.xs) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.textPrimary.opacity(0.05))
                    )

                Button {
                    showPicker.toggle()
                } label: {
                    Image(systemName: "tag")
                        .font(.system(size: 11))
                        .foregroundStyle(showPicker ? Theme.accent : Theme.textTertiary)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.textPrimary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                    GenrePickerPopover(genre: $text)
                        .environment(settings)
                }
            }
        }
    }
}

// MARK: - Picker popover

private struct GenrePickerPopover: View {
    @Binding var genre: String
    @Environment(Settings.self) private var settings
    @State private var newGenreText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                chipGrid(predefinedGenres + settings.customGenres)

                Divider().foregroundStyle(Theme.divider)

                sectionLabel("Custom")
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("Genre name…", text: $newGenreText)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.textPrimary.opacity(0.05))
                        )
                        .onSubmit { addCustomGenre() }

                    Button("Add") { addCustomGenre() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(isAddDisabled)
                }
            }
            .padding(Theme.Spacing.md)
        }
        .frame(width: 280)
        .frame(maxHeight: 380)
        .background(Theme.surface)
    }

    private var isAddDisabled: Bool {
        let t = newGenreText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty
            || predefinedGenres.contains(t)
            || settings.customGenres.contains(t)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .tracking(1)
    }

    private func chipGrid(_ genres: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 74), spacing: Theme.Spacing.xs)],
            alignment: .leading,
            spacing: Theme.Spacing.xs
        ) {
            ForEach(genres, id: \.self) { g in
                let isCustom = settings.customGenres.contains(g)
                GenreChip(
                    label: g,
                    isSelected: genre.lowercased() == g.lowercased(),
                    isCustom: isCustom,
                    onSelect: { genre = g },
                    onRemove: isCustom ? { settings.customGenres.removeAll { $0 == g } } : nil
                )
            }
        }
    }

    private func addCustomGenre() {
        let trimmed = newGenreText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !predefinedGenres.contains(trimmed),
              !settings.customGenres.contains(trimmed) else { return }
        settings.customGenres.append(trimmed)
        newGenreText = ""
    }
}

// MARK: - Chip

struct GenreChip: View {
    let label: String
    let isSelected: Bool
    let isCustom: Bool
    let onSelect: () -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Button {
                onSelect()
            } label: {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if isCustom, let remove = onRemove {
                Button {
                    remove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(isSelected ? Theme.accent.opacity(0.15) : Theme.surfaceElevated)
        )
        .overlay(
            Capsule()
                .strokeBorder(isSelected ? Theme.accent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}
