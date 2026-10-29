import AppKit
import SwiftUI
import Testing
@testable import flactastic

/// Edit Spine's preview reports where each part of the spine is drawn, so it
/// can be clicked. The spine is laid out sideways and turned upright, then
/// scaled up, and the reported places must follow both.
@MainActor
@Test func spinePartsLandOnTheUprightScaledSpine() throws {
    let album = Album(id: "x", name: "A Fairly Long Album Title", artist: "Some Artist", albumArtist: nil, year: 2020, genre: nil,
                      label: "Sub Pop", secondaryGenres: [], artwork: nil,
                      tracks: [Track(url: URL(fileURLWithPath: "/tmp/x.flac"), title: "x", fileFormat: .flac)])
    var o = SpineOverrides()
    o.isLong = false
    o.artistOnArt = false
    o.position = .center
    o.markEnd = .bottom
    let design = SpineDesign.roll(for: album, credit: "Some Artist", shuffles: 0,
                                  options: SpineDesign.Options(currentYear: 2026), overrides: o)
    let scale: CGFloat = 1.3
    final class Box { var frames: [SpineElement: [UUID: CGRect]] = [:] }
    let box = Box()
    let view = RackSpine(album: album, credit: "Some Artist", width: 30, height: 384, isHovered: false, design: design, reportsParts: true)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: 30 * scale, height: 384 * scale, alignment: .topLeading)
        .coordinateSpace(name: SpinePartReporting.space)
        .environment(\.spinePartReporter, SpinePartReporter { element, id, rect in box.frames[element, default: [:]][id] = rect })
        .frame(width: 100, height: 600, alignment: .topLeading)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    host.display()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    let rectsByPart = box.frames.mapValues { $0.values.reduce(CGRect.null) { $0.union($1) } }
    let spine = CGRect(x: 0, y: 0, width: 30 * scale, height: 384 * scale)
    let title = try #require(rectsByPart[.title])
    let strip = try #require(rectsByPart[.insert])
    let artist = try #require(rectsByPart[.artist])
    let mark = try #require(rectsByPart[.labelMark])
    // Upright: each part runs down the spine, taller than wide.
    #expect(title.height > title.width)
    #expect(strip.height > strip.width)
    // Within the scaled spine, and the strip holds the title.
    #expect(spine.insetBy(dx: -2, dy: -2).contains(strip))
    #expect(strip.insetBy(dx: -1, dy: -1).contains(title))
    #expect(strip.insetBy(dx: -1, dy: -1).contains(artist))
    // Read down the spine: the title comes before the artist.
    #expect(title.maxY <= artist.minY + 1)
    // The mark at the foot sits below the strip.
    #expect(mark.minY > strip.maxY - 1)
    #expect(mark.maxY <= spine.maxY + 1)
}
