import SwiftUI

/// Multi-select genre field for up to `GenreResolver.maxSecondaryCount`
/// secondary genres, pooling from the same predefined + custom genre list as
/// the primary `GenreFieldView`. The current primary genre is excluded from the
/// pickable list (and pruned from selection if the primary changes to match an
/// already-selected secondary) so the same genre can't be both primary and
/// secondary.
struct SecondaryGenresFieldView: View {
    @Binding var genres: [String]
    /// The album/track's current primary genre. Excluded from the picker and
    /// pruned from `genres` automatically when it changes to match a selection.
    var primaryGenre: String

    @Environment(Settings.self) private var settings
    @State private var showPicker = false

    private var cap: Int { GenreResolver.maxSecondaryCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                SheetLabel(text: "Secondary Genres")
                Spacer()
                Text("\(genres.count)/\(cap)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(genres, id: \.self) { g in
                        chip(label: g) {
                            genres.removeAll { $0.lowercased() == g.lowercased() }
                        }
                    }

                    if genres.isEmpty {
                        Text("None")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(minHeight: 22, alignment: .leading)
                    }
                }

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
                .disabled(genres.count >= cap)
                .help(genres.count >= cap ? "Up to \(cap) secondary genres" : "Add a secondary genre")
                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                    SecondaryGenrePickerPopover(
                        selected: $genres,
                        primaryGenre: primaryGenre,
                        cap: cap
                    )
                    .environment(settings)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.05))
            )
        }
        .onChange(of: primaryGenre) { _, newPrimary in
            // Keep primary and secondary disjoint — mirrors the dedup
            // GenreResolver.join performs anyway, but doing it here makes the
            // chip disappear immediately rather than only at save time.
            let key = newPrimary.lowercased()
            genres.removeAll { $0.lowercased() == key }
        }
    }

    private func chip(label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.textPrimary.opacity(0.09)))
    }
}

// MARK: - Picker popover

private struct SecondaryGenrePickerPopover: View {
    @Binding var selected: [String]
    let primaryGenre: String
    let cap: Int

    @Environment(Settings.self) private var settings
    @State private var newGenreText = ""

    private var pickableGenres: [String] {
        (predefinedGenres + settings.customGenres).filter {
            $0.lowercased() != primaryGenre.lowercased()
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if selected.count >= cap {
                    Text("Up to \(cap) secondary genres")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }

                chipGrid(pickableGenres)

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
                let isSelected = selected.contains { $0.lowercased() == g.lowercased() }
                let atCap = selected.count >= cap
                GenreChip(
                    label: g,
                    isSelected: isSelected,
                    isCustom: isCustom,
                    onSelect: { toggle(g) },
                    onRemove: isCustom ? { settings.customGenres.removeAll { $0 == g } } : nil
                )
                .disabled(!isSelected && atCap)
                .opacity((!isSelected && atCap) ? 0.4 : 1.0)
            }
        }
    }

    private func toggle(_ g: String) {
        if let idx = selected.firstIndex(where: { $0.lowercased() == g.lowercased() }) {
            selected.remove(at: idx)
        } else {
            guard selected.count < cap else { return }
            selected.append(g)
        }
    }

    private func addCustomGenre() {
        let trimmed = newGenreText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !predefinedGenres.contains(trimmed),
              !settings.customGenres.contains(trimmed) else { return }
        settings.customGenres.append(trimmed)
        newGenreText = ""
        toggle(trimmed)
    }
}
