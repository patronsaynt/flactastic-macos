import SwiftUI
import AppKit

/// Lightweight identifiable wrapper so callers can drive `.sheet(item:)`
/// with raw `Data` from a file picker.
struct CroppingPayload: Identifiable {
    let id = UUID()
    let data: Data
}

/// Sheet that lets the user pan + zoom an image inside a fixed crop window
/// of arbitrary aspect ratio, then returns the cropped image as PNG `Data`
/// via `onComplete`.
///
/// Used by album artwork (1:1), playlist covers (1:1), artist profile
/// images (1:1), and artist banners (16:9) so all stored images are
/// guaranteed to match the surface they'll render on.
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

    /// Width of the crop window, in points. Height is derived from aspectRatio.
    private var cropWidth: CGFloat { cropWindowWidth ?? (aspectRatio >= 1 ? 380 : 320) }
    private var cropHeight: CGFloat { cropWidth / aspectRatio }
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0

    private var cgImage: CGImage? {
        guard let nsImage = NSImage(data: sourceData) else { return nil }
        return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().foregroundStyle(Theme.divider)
            cropArea
                .padding(Theme.Spacing.xl)
            zoomSlider
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.md)
            Divider().foregroundStyle(Theme.divider)
            footer
        }
        .frame(width: max(440, cropWidth + 80), height: cropHeight + 220)
        .background(Theme.surface)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(title)
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Crop area

    private var cropArea: some View {
        ZStack {
            Color.black
            if let nsImage = NSImage(data: sourceData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cropWidth, height: cropHeight)
                    .scaleEffect(scale)
                    .offset(offset)
            }
        }
        .frame(width: cropWidth, height: cropHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
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
            .tint(Theme.accent)
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button("Use") { commit() }
                .buttonStyle(PillButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(cgImage == nil)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
    }

    // MARK: - Geometry helpers

    /// Image dimensions, in *preview-window* coordinates, after the initial
    /// aspect-fill into the crop window (before user zoom is applied).
    private func filledSize() -> CGSize? {
        guard let cg = cgImage else { return nil }
        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        guard imgW > 0, imgH > 0 else { return nil }
        let fillScale = max(cropWidth / imgW, cropHeight / imgH)
        return CGSize(width: imgW * fillScale, height: imgH * fillScale)
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

    private func commit() {
        guard let cg = cgImage, let filled = filledSize() else { return }

        let totalScale = scale
        let pixelsPerPreviewPoint = CGFloat(cg.width) / filled.width / totalScale

        let srcW = cropWidth * pixelsPerPreviewPoint
        let srcH = cropHeight * pixelsPerPreviewPoint

        let renderedW = filled.width * totalScale
        let renderedH = filled.height * totalScale

        let srcX = (renderedW / 2 - cropWidth / 2 - offset.width) * pixelsPerPreviewPoint
        let srcY = (renderedH / 2 - cropHeight / 2 - offset.height) * pixelsPerPreviewPoint

        let cropRect = CGRect(x: srcX, y: srcY, width: srcW, height: srcH).integral
        guard let cropped = cg.cropping(to: cropRect) else { return }

        let outputWidth = min(maxOutputPixelWidth, max(cropRect.width, 1200))
        let outW = Int(outputWidth)
        let outH = Int(outputWidth / aspectRatio)
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let outCG = ctx.makeImage() else { return }

        let rep = NSBitmapImageRep(cgImage: outCG)
        let encoded = jpegQuality.map { rep.representation(using: .jpeg, properties: [.compressionFactor: $0]) }
            ?? rep.representation(using: .png, properties: [:])
        guard let data = encoded else { return }

        onComplete(data)
        dismiss()
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
