import SwiftUI
import AppKit
import ImageIO

/// Lightweight identifiable wrapper so callers can drive `.sheet(item:)`
/// with raw `Data` from a file picker.
struct CroppingPayload: Identifiable {
    let id = UUID()
    let data: Data
}

/// Sheet that lets the user pan + zoom an image inside a fixed crop window
/// of arbitrary aspect ratio, then returns the cropped image via
/// `onComplete` (JPEG when `jpegQuality` is set, PNG otherwise).
///
/// Used by album artwork (1:1), playlist covers (1:1), artist profile
/// images (1:1), and artist banners (16:9) so all stored images are
/// guaranteed to match the surface they'll render on.
///
/// Built to stay smooth with very large photos: the source is decoded once,
/// off the main thread, at full resolution (for the crop itself) and again
/// small (for the preview you drag). Panning only does arithmetic on the
/// stored size, and the crop, resize and encode run in the background.
struct ImageCropperView: View {
    let sourceData: Data
    /// Width / height. Defaults to 1.0 (square).
    var aspectRatio: CGFloat = 1.0
    /// Title shown in the sheet header.
    var title: String = "Crop Image"
    /// Longest output width, in pixels. Crops smaller than this are never
    /// upscaled past 1200px.
    var maxOutputPixelWidth: CGFloat = 1200
    /// JPEG quality for the stored result; nil keeps PNG. Large photographic
    /// crops (banners) use JPEG so the override store stays small.
    var jpegQuality: CGFloat? = nil
    /// Crop window width in points; nil picks a default from the ratio.
    var cropWindowWidth: CGFloat? = nil
    let onComplete: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var source: DecodedSource?
    @State private var failedToDecode = false
    @State private var isCommitting = false

    /// Width of the crop window, in points. Height is derived from aspectRatio.
    private var cropWidth: CGFloat { cropWindowWidth ?? (aspectRatio >= 1 ? 380 : 320) }
    private var cropHeight: CGFloat { cropWidth / aspectRatio }
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0

    /// Preview size: the crop window at 2x, with room to zoom in twice
    /// before it softens. Far smaller than a camera original.
    private var previewMaxPixel: Int { Int(max(cropWidth, cropHeight) * 4) }

    var body: some View {
        FLSheet(title: title, width: max(460, cropWidth + 80), height: cropHeight + 236) {
            VStack(spacing: 18) {
                cropArea
                zoomSlider
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
        } footer: {
            footer
        }
        .task {
            let decoded = await DecodedSource.decode(sourceData, previewMaxPixel: previewMaxPixel)
            if let decoded { source = decoded } else { failedToDecode = true }
        }
    }

    // MARK: - Crop area

    private var cropArea: some View {
        ZStack {
            Color.black
            if let preview = source?.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cropWidth, height: cropHeight)
                    .scaleEffect(scale)
                    .offset(offset)
            } else if failedToDecode {
                Text("This image couldn't be opened.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: cropWidth, height: cropHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let proposed = CGSize(
                        width: dragStart.width + value.translation.width,
                        height: dragStart.height + value.translation.height
                    )
                    offset = clamp(offset: proposed, scale: scale)
                }
                .onEnded { _ in dragStart = offset }
        )
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Crop area. Drag to reposition.")
    }

    // MARK: - Zoom slider

    private var zoomSlider: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Slider(value: Binding(
                get: { scale },
                set: { newScale in
                    scale = newScale
                    offset = clamp(offset: offset, scale: newScale)
                    dragStart = offset
                }
            ), in: minScale...maxScale)
            .tint(Theme.textPrimary)
            .accessibilityLabel("Zoom")
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .disabled(source == nil)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Drag to reposition, slide to zoom.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetPillStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(isCommitting)

            Button(isCommitting ? "Cropping…" : "Use") { commit() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || isCommitting)
        }
    }

    // MARK: - Geometry helpers

    /// Image dimensions, in *preview-window* coordinates, after the initial
    /// aspect-fill into the crop window (before user zoom is applied). Uses
    /// the stored size, so it costs nothing to call on every drag event.
    private func filledSize() -> CGSize? {
        guard let size = source?.pixelSize, size.width > 0, size.height > 0 else { return nil }
        let fillScale = max(cropWidth / size.width, cropHeight / size.height)
        return CGSize(width: size.width * fillScale, height: size.height * fillScale)
    }

    /// Clamp the user offset so the image always covers the crop window for
    /// the given zoom level — prevents panning past edges.
    private func clamp(offset: CGSize, scale: CGFloat) -> CGSize {
        guard let filled = filledSize() else { return .zero }
        let renderedW = filled.width * scale
        let renderedH = filled.height * scale
        let maxX = max(0, (renderedW - cropWidth) / 2)
        let maxY = max(0, (renderedH - cropHeight) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    // MARK: - Crop + encode

    /// Works out the crop in full-resolution pixels here, then crops,
    /// resizes and encodes in the background.
    private func commit() {
        guard let source, let filled = filledSize() else { return }

        let pixelsPerPreviewPoint = source.pixelSize.width / filled.width / scale

        let srcW = cropWidth * pixelsPerPreviewPoint
        let srcH = cropHeight * pixelsPerPreviewPoint

        let renderedW = filled.width * scale
        let renderedH = filled.height * scale

        let srcX = (renderedW / 2 - cropWidth / 2 - offset.width) * pixelsPerPreviewPoint
        let srcY = (renderedH / 2 - cropHeight / 2 - offset.height) * pixelsPerPreviewPoint

        let cropRect = CGRect(x: srcX, y: srcY, width: srcW, height: srcH).integral
        let outputWidth = min(maxOutputPixelWidth, max(cropRect.width, 1200))
        let outW = Int(outputWidth)
        let outH = Int(outputWidth / aspectRatio)
        let quality = jpegQuality

        isCommitting = true
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                source.render(crop: cropRect, width: outW, height: outH, jpegQuality: quality)
            }.value
            isCommitting = false
            guard let data else { return }
            onComplete(data)
            dismiss()
        }
    }
}

/// The source image, decoded once: full size for the crop, small for the
/// preview. `CGImage` and `NSImage` aren't formally `Sendable`; both are
/// made once and only read afterward, which is the whole of the claim.
private struct DecodedSource: @unchecked Sendable {
    let full: CGImage
    let preview: NSImage
    let pixelSize: CGSize

    static func decode(_ data: Data, previewMaxPixel: Int) async -> DecodedSource? {
        await Task.detached(priority: .userInitiated) {
            guard let full = fullImage(data) else { return nil }
            let previewCG = PrerenderedImage.downsampled(data, maxPixel: previewMaxPixel) ?? full
            return DecodedSource(
                full: full,
                preview: NSImage(cgImage: previewCG, size: NSSize(width: previewCG.width, height: previewCG.height)),
                pixelSize: CGSize(width: full.width, height: full.height)
            )
        }.value
    }

    /// Full resolution, turned upright per its orientation tag (the same
    /// way the preview is), so what you crop is what you saw.
    private static func fullImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if w > 0, h > 0, let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) {
            return image
        }
        return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func render(crop: CGRect, width: Int, height: Int, jpegQuality: CGFloat?) -> Data? {
        guard let cropped = full.cropping(to: crop),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: output)
        return jpegQuality.map { rep.representation(using: .jpeg, properties: [.compressionFactor: $0]) }
            ?? rep.representation(using: .png, properties: [:])
    }
}

/// Backwards-compatible square-only entry point. Existing call sites continue
/// to work; new callers should use `ImageCropperView` directly to specify a
/// non-square aspect ratio.
struct SquareImageCropperView: View {
    let sourceData: Data
    let onComplete: (Data) -> Void

    var body: some View {
        ImageCropperView(
            sourceData: sourceData,
            aspectRatio: 1.0,
            title: "Crop Cover",
            onComplete: onComplete
        )
    }
}
