import SwiftUI

/// Hosts the real onboarding sequence in its own window for developer
/// testing — reuses the app's live `Settings`/`LibraryStore`/etc. via the
/// environment (injected by the `"onboarding-debug"` window scene in
/// `FlactasticApp`), so it exercises the exact flow a fresh user sees.
/// Opened from Settings → Debug → "Preview onboarding".
struct OnboardingDebugPreviewView: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingView(onFinish: { dismissWindow(id: "onboarding-debug") }, appliesRestore: false)
            .preferredColorScheme(settings.theme.colorScheme)
            .frame(width: 1180, height: 740)
    }
}
