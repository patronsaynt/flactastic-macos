import SwiftUI

/// Home Sections, from Settings › Appearance › Home: which sections Home
/// shows and in what order, for when Arrange Automatically is off. Drag a
/// row to move it; switch one off to hide it. Changes apply on Done.
struct HomeSectionsSheet: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var order: [HomeSection] = []
    @State private var hidden: Set<HomeSection> = []
    @State private var hasSeeded = false

    var body: some View {
        FLSheet(title: "Home Sections", width: 560, height: 640, contentScrolls: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drag to reorder. Sections with nothing to show still hide on their own.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 24)
                List {
                    ForEach(order) { section in
                        row(section)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 3, leading: 18, bottom: 3, trailing: 18))
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .padding(.top, 14)
            .frame(maxHeight: .infinity, alignment: .top)
        } footer: {
            HStack(spacing: 10) {
                Button("Reset to Defaults") {
                    order = HomeSection.allCases
                    hidden = []
                }
                .buttonStyle(QuietTextButtonStyle())
                .disabled(order == HomeSection.allCases && hidden.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SheetPillStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    settings.homeSectionOrder = order
                    settings.homeHiddenSections = hidden
                    dismiss()
                }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard !hasSeeded else { return }
            hasSeeded = true
            // The saved order, with any section it lacks at its designed place.
            var seeded = settings.homeSectionOrder
            for (index, section) in HomeSection.allCases.enumerated() where !seeded.contains(section) {
                seeded.insert(section, at: min(index, seeded.count))
            }
            order = seeded
            hidden = settings.homeHiddenSections
        }
    }

    private func row(_ section: HomeSection) -> some View {
        let shown = !hidden.contains(section)
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .help("Drag to reorder")
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(shown ? Theme.textPrimary : Theme.textTertiary)
                Text(section.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { shown },
                set: { on in if on { hidden.remove(section) } else { hidden.insert(section) } }
            ))
            .toggleStyle(FLSwitchStyle())
            .labelsHidden()
            .accessibilityLabel("Show \(section.title)")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.textPrimary.opacity(0.05)))
    }
}
