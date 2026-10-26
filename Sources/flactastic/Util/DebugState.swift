import Foundation
import Observation

/// Developer-tool state behind Settings → Debug. Saved like other settings
/// so a debugging session survives relaunches.
///
/// `debuggingEnabled` is the master switch (Settings → General → Enable
/// Debugging): it shows the Debug tab, and while it's off every switch in
/// that tab is paused. Callers read the effective `…Active` values, never
/// the raw switches, so turning debugging off takes them all out of play
/// without forgetting how they were set.
@Observable
@MainActor
final class DebugState {
    var debuggingEnabled: Bool { didSet { save(debuggingEnabled, "debuggingEnabled") } }

    var showsOnboardingEveryLaunch: Bool { didSet { save(showsOnboardingEveryLaunch, "showsOnboardingEveryLaunch") } }
    var showsTutorialsEveryVisit: Bool { didSet { save(showsTutorialsEveryVisit, "showsTutorialsEveryVisit") } }
    var previewsEmptyLibrary: Bool { didSet { save(previewsEmptyLibrary, "previewsEmptyLibrary") } }
    var showsPerformanceOverlay: Bool { didSet { save(showsPerformanceOverlay, "showsPerformanceOverlay") } }
    var lucidaInspector: Bool { didSet { save(lucidaInspector, "lucidaInspector") } }

    var onboardingEveryLaunchActive: Bool { debuggingEnabled && showsOnboardingEveryLaunch }
    var tutorialsEveryVisitActive: Bool { debuggingEnabled && showsTutorialsEveryVisit }
    var emptyLibraryPreviewActive: Bool { debuggingEnabled && previewsEmptyLibrary }
    var performanceOverlayActive: Bool { debuggingEnabled && showsPerformanceOverlay }
    var lucidaInspectorActive: Bool { debuggingEnabled && lucidaInspector }

    init() {
        let d = UserDefaults.standard
        debuggingEnabled = d.bool(forKey: Self.key("debuggingEnabled"))
        showsOnboardingEveryLaunch = d.bool(forKey: Self.key("showsOnboardingEveryLaunch"))
        showsTutorialsEveryVisit = d.bool(forKey: Self.key("showsTutorialsEveryVisit"))
        previewsEmptyLibrary = d.bool(forKey: Self.key("previewsEmptyLibrary"))
        showsPerformanceOverlay = d.bool(forKey: Self.key("showsPerformanceOverlay"))
        lucidaInspector = d.bool(forKey: Self.key("lucidaInspector"))
    }

    /// The saved "Show onboarding at every launch" decision, readable before
    /// the app's state exists, so launch can pick onboarding or the app.
    nonisolated static var onboardingEveryLaunchAtStartup: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: key("debuggingEnabled")) && d.bool(forKey: key("showsOnboardingEveryLaunch"))
    }

    nonisolated private static func key(_ name: String) -> String { "flactastic.debug.\(name)" }

    private func save(_ value: Bool, _ name: String) {
        UserDefaults.standard.set(value, forKey: Self.key(name))
    }
}
