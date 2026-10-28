import SwiftUI

/// "About FLACtastic" window contents — shown from the application menu.
struct AboutView: View {
    @State private var showsFontCredits = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "beta"
    }

    var body: some View {
        VStack(spacing: 0) {
            Wordmark(height: 52)
                .padding(.bottom, Theme.Spacing.lg)

            Text("Version \(version)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text("Lossless music, beautifully organized.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, Theme.Spacing.sm)

            Button("Font Credits") { showsFontCredits.toggle() }
                .buttonStyle(QuietTextButtonStyle())
                .padding(.top, Theme.Spacing.lg)
                .popover(isPresented: $showsFontCredits, arrowEdge: .bottom) { FontCreditsView() }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 44)
        .frame(width: 420)
        .background(Theme.background)
    }
}

/// The typefaces the Albums rack sets spine titles in, and who made them.
/// Licences and sources are in Resources/SpineFonts/Licenses.
private struct FontCreditsView: View {
    private static let credits: [(String, String)] = [
        ("1942 Report", "Johan Holmdahl"),
        ("60sekuntia, Phorssa", "Juha Korhonen"),
        ("Anton", "The Anton Project Authors"),
        ("AquilineTwo, Stampede", "Manfred Klein"),
        ("Audiowide", "Astigmatic"),
        ("Blackout", "Dharma Type"),
        ("Bungee", "The Bungee Project Authors"),
        ("Chomsky", "Fredrick R. Brennan"),
        ("Cinzel", "The Cinzel Project Authors"),
        ("Cormorant Garamond", "The Cormorant Project Authors"),
        ("DM Serif Display", "Colophon Foundry, after Adobe's Source Serif"),
        ("Dolce Vita", "Michael Muranaka"),
        ("Dufay", "Luca Ricossa"),
        ("Fraunces", "The Fraunces Project Authors"),
        ("Freshman", "William Boyd"),
        ("Higher", "Marisa Passos"),
        ("IM Fell English", "Igino Marini"),
        ("Infiltrace", "Smoking Drum"),
        ("Infinity", "Joep van der Poel"),
        ("Jefferson", "SnatchSoft"),
        ("JSL Blackletter", "Jeffrey S. Lee"),
        ("Khodijah", "Arterfak Project"),
        ("Magicial Game", "Svika5 (CC BY-SA 3.0)"),
        ("Major Mono Display", "The Major Mono Project Authors"),
        ("Mayonice", "Khurasan"),
        ("Metal Mania", "Open Window"),
        ("Moderniz", "Eko Bimantara"),
        ("Orbitron", "The Orbitron Project Authors"),
        ("Permanent Marker", "Font Diner"),
        ("Pirata One", "Rodrigo Fuenzalida, Nicolas Massi"),
        ("Rubik Dirt, Rubik Mono One", "The Rubik Project Authors"),
        ("Special Elite", "Astigmatic"),
        ("Tagmarker", "Pop Ovidiu Sebastian"),
        ("UnifrakturMaguntia", "j. 'mach' wust"),
        ("Yeseva One", "The Yeseva One Project Authors"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Spine title fonts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(Self.credits, id: \.0) { credit in
                        GridRow {
                            Text(credit.0).foregroundStyle(Theme.textPrimary)
                            Text(credit.1).foregroundStyle(Theme.textSecondary)
                        }
                        .font(.system(size: 11.5))
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 380, height: 360)
    }
}
