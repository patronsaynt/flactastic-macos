import Foundation

/// Starts a fresh copy of FLACtastic and quits this one without saving, so
/// everything (settings, stores, the library) is read anew. Used after a
/// backup is restored during onboarding. Returns only if the new copy
/// couldn't be started, leaving this one running.
enum AppRelauncher {
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        let isApp = bundle.pathExtension == "app"
        let target = isApp ? bundle.path : (Bundle.main.executablePath ?? bundle.path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this copy to be gone, then start the new one.
        task.arguments = ["-c", isApp ? "sleep 0.6; /usr/bin/open -n \"$0\"" : "sleep 0.6; \"$0\" >/dev/null 2>&1 &", target]
        guard (try? task.run()) != nil else { return }
        UserDataEraser.quitWithoutSaving()
    }
}
