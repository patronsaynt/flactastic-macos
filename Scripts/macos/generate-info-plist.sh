#!/usr/bin/env bash
# Generates Info.plist for the FLACtastic.app bundle.
# Usage: generate-info-plist.sh <output_path> <version> <build_number>

set -euo pipefail

OUTPUT_PATH="${1:?Output path required}"
VERSION="${2:?Version required}"
BUILD_NUMBER="${3:-1}"

# Strip the pre-release suffix only when doing so still leaves a version behind:
# "1.2.0-beta" → "1.2.0", but "beta-5" must stay "beta-5" rather than collapsing
# to a bare "beta" that tells a user nothing about which build they are running.
SHORT_VERSION="${VERSION%%-*}"
if [[ ! "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    SHORT_VERSION="$VERSION"
fi

cat > "$OUTPUT_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>FLACtastic</string>
    <key>CFBundleExecutable</key>
    <string>flactastic</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.flactastic.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FLACtastic</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <!-- Library sync over the LAN. Both keys are required from macOS 15: without
         NSBonjourServices the browser returns nothing and the listener fails,
         and the failure is completely silent, so a missing key here looks
         exactly like "no other devices are running FLACtastic". -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>FLACtastic uses the local network to find your other devices and sync your music library between them, and to find and play music on network speakers. Nothing is sent over the internet.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_flactastic._tcp</string>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 FLACtastic. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Audio File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>org.xiph.flac</string>
                <string>public.mp3</string>
                <string>com.apple.m4a-audio</string>
                <string>com.microsoft.waveform-audio</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Generated Info.plist at: $OUTPUT_PATH (version: $SHORT_VERSION, build: $BUILD_NUMBER)"
