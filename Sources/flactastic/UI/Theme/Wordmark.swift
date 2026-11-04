import SwiftUI
import AppKit

/// The FLACtastic logo wordmark.
///
/// The artwork is a flat monochrome PNG resource (the asset catalog is copied
/// raw rather than compiled to a `.car` by SwiftPM, so `Image(name:bundle:)`
/// can't resolve catalog imagesets here). It's rendered as a template image
/// tinted with `Theme.textPrimary`, so the single asset adapts to light/dark
/// like the rest of the chrome.
struct Wordmark: View {
    var height: CGFloat = 15
    var color: Color = Theme.textPrimary

    /// Locates the SwiftPM resource bundle without going through
    /// `Bundle.module`.
    ///
    /// SPM's generated accessor only probes `Bundle.main.bundleURL` and the
    /// absolute `.build` path from the machine that compiled the binary — and
    /// it `fatalError`s when both miss. In a packaged `.app` the bundle lives
    /// in `Contents/Resources` (it can't sit at the bundle root without
    /// invalidating the code signature), so the first probe never hits and the
    /// app survives only on the build machine, where the `.build` path still
    /// exists. Probe the real locations ourselves, and degrade to no artwork
    /// rather than trapping.
    static let resourceBundle: Bundle? = {
        let name = "flactastic_flactastic.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            Bundle.main.resourceURL,
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url),
               bundle.url(forResource: "Wordmark", withExtension: "png") != nil {
                return bundle
            }
        }
        return nil
    }()

    private static let image: NSImage? = {
        guard let url = resourceBundle?.url(forResource: "Wordmark", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(height: height)
                .foregroundStyle(color)
                .accessibilityLabel("FLACtastic")
        }
    }
}

/// The FLACtastic mark on its own (the menu bar icon's glyph), drawn in one
/// ink. Nothing if the resource is missing.
struct BrandMark: View {
    var height: CGFloat = 40
    var color: Color = Theme.textPrimary

    static let image: NSImage? = {
        guard let url = Wordmark.resourceBundle?.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(height: height)
                .foregroundStyle(color)
                .accessibilityLabel("FLACtastic")
        }
    }
}
