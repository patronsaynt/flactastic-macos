// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Info.plist linked into debug executables so `swift run` builds can be
/// granted Local Network access (see Support/DebugInfo.plist).
let debugInfoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Support/DebugInfo.plist").path

let package = Package(
    name: "flactastic",
    platforms: [.macOS(.v14)],
    targets: [
        // TagLib C API — discovered via `pkg-config taglib_c` (requires `brew install taglib`).
        .systemLibrary(
            name: "CTagLib",
            pkgConfig: "taglib_c",
            providers: [.brew(["taglib"])]
        ),
        // Thin C bridge exposing the TAGLIB_COMPLEX_PROPERTY_PICTURE macro as a
        // plain C function callable from Swift (Swift cannot expand C macros directly).
        .target(
            name: "CTagLibHelper",
            dependencies: ["CTagLib"],
            path: "Sources/CTagLibHelper",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "flactastic",
            dependencies: ["CTagLibHelper"],
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources/Wordmark.png"),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                     "-Xlinker", "__info_plist", "-Xlinker", debugInfoPlist],
                    .when(configuration: .debug)
                ),
            ]
        ),
        .testTarget(
            name: "flactasticTests",
            dependencies: ["flactastic"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
