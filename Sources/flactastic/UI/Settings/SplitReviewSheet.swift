import SwiftUI

/// Asks about artist credits FLACtastic can't split on its own: "Simon &
/// Garfunkel" is one act, "Artist A, Artist B" may be two. Each row shows the
/// credit as tagged, how many tracks carry it, and what Split would make of
/// it. Nothing touches the files; answers are saved with the library.
///
/// Anything left unanswered when the sheet closes, by Done, Keep All
/// Remaining or the close button, is kept whole.
struct SplitReviewSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// The queue as it was when the sheet opened, so rows don't move while
    /// they're being answered.
    @State private var items: [SplitReviewItem] = []
    @State private var answers: [String: MultiValueParser.Decision] = [:]
    @State private var didLoad = false

    var body: some View {
        FLSheet(title: "Review Artist Credits", width: 560, height: height, contentScrolls: true) {
            VStack(alignment: .leading, spacing: 18) {
                Text("These credits could be one artist or several. Split turns a credit into separate artists; Keep leaves it as one. Your files aren't changed.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SheetLabel(text: "Credits · \(items.count)")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            SplitReviewRow(item: item, answer: binding(for: item.raw))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 20)
        } footer: {
            HStack {
                Button("Keep All Remaining") { dismiss() }
                    .buttonStyle(QuietTextButtonStyle())
                    .disabled(answers.count == items.count)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            items = library.pendingSplitReview
        }
        .onDisappear(perform: commit)
    }

    /// Tall enough for up to seven rows before the list scrolls.
    private var height: CGFloat {
        300 + CGFloat(min(max(items.count, 1), 7)) * 58
    }

    private func binding(for raw: String) -> Binding<MultiValueParser.Decision?> {
        Binding(get: { answers[raw] }, set: { answers[raw] = $0 })
    }

    /// Saves every answer, with Keep for anything left unanswered.
    private func commit() {
        var all = answers
        for item in items where all[item.raw] == nil { all[item.raw] = .keep }
        library.recordSplitDecisions(all)
    }
}

/// One credit: the raw text over its track count and split preview, with
/// Split and Keep on the right.
private struct SplitReviewRow: View {
    let item: SplitReviewItem
    @Binding var answer: MultiValueParser.Decision?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.raw)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.trackCount == 1 ? "1 track" : "\(item.trackCount) tracks") · Split: \(item.preview.joined(separator: " | "))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            SheetTogglePill(title: "Split", isOn: Binding(
                get: { if case .split = answer { return true } else { return false } },
                set: { answer = $0 ? .split(item.preview) : nil }
            ))
            SheetTogglePill(title: "Keep", isOn: Binding(
                get: { answer == .keep },
                set: { answer = $0 ? .keep : nil }
            ))
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.raw), \(item.trackCount) tracks")
    }
}
