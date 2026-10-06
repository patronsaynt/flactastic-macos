# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (Swift / SwiftUI / AppKit, macOS 14+, Intel and Apple Silicon). Not one of Impeccable's recognized platform values; treat as a native desktop app, not a web surface. A Windows port is future work and not started (`Scripts/windows/WINDOWS_BUILD_NOTES.md`).

## Users

Primary: listeners moving off streaming services (Spotify, Apple Music) who now want to own their music as lossless files, without giving up the polish and convenience of a modern streaming player. They are building or growing a local FLAC / hi-res library, often bringing playlists over from Spotify, and want the app to make that library feel as alive as a streaming home screen.

## Product Purpose

FLACtastic organizes and plays a local lossless music collection on macOS. It exists so that owning your music feels better than renting it: the library is browsable by albums, artists and tracks, playback is high-fidelity, and listening history, stats and lyrics give it the personal, living quality of a streaming app. Success is a former streaming user choosing FLACtastic as their everyday player.

## Positioning

- **Fidelity made visible.** Audio quality (format, bit depth, sample rate, quality tier) is surfaced throughout the app, and summarized across the library by the Fidelidex panel and its fidelity score.
- **Library care tools.** An organizer for folder structure, metadata, artwork and lyrics editing, and playlists that persist even when the music folder is reorganized.
- **Beautiful, modern feel.** A streaming-grade experience for local files: home dashboard, visualizers (spectrum, big-picture, real-time lyrics), artist profiles.

## Operating Context

- Library lives in a local folder the user links during onboarding; the app scans and watches it.
- Home screen: lyric highlight hero, Recently Played, listening stats, top albums this week, Fidelidex.
- Optional connected features: Spotify playlist import/rebuild, Lucida-powered downloads (FLACtastic is a frontend for Lucida.to and does not host or distribute music), lyrics and artist-image fetching, Discord presence, LAN library sync between Macs.
- Floating player bar, queue panel, menu bar player, output device / sample rate / bit depth selection.

## Capabilities and Constraints

- Quality tiers: Hi-Res, CD, Mid, Low (`AudioQuality.classify`). Fidelity score is the per-file tier score averaged to 0–100.
- Light and dark themes are both first-class: every screen must work in both.
- Releases are on a beta track (`version.txt` holds `beta-N`).
- Terminology: "Fidelidex" (library fidelity panel), "Collection" (albums/artists/tracks), "Organizer".

## Brand Commitments

- Name: FLACtastic, with the wordmark asset (`Sources/flactastic/Resources/Wordmark.png`, `design_handoffs/logos/`).
- Monochrome UI (black / white / gray ladder). The accent is white in dark mode and black in light mode.
- Home takes its color from the hero banner: up to four hues sampled from the artist image (`HomePalette`) color the highlighted figures, the number-one ranks, the hourly genre chart and the Fidelidex. With no banner image, or a gray one, Home stays monochrome.
- Elsewhere, audio-quality tiers keep their own colors (turquoise Hi-Res, green CD, amber Mid, red Low); they never act as a general UI accent.
- Voice from onboarding copy: short, warm, confident ("Your library is linked and ready. Time to hear it properly.").

## Evidence on Hand

- README screenshots of Home, Collection, Playlists, Visualizer.
- Prior design handoffs in `design_handoffs/` (home page, navigation, collection, download, organizer, onboarding, settings, visualizer) with tokens ported 1:1 from `Theme.swift`.
- No testimonials, user counts, reviews or press exist; do not fabricate them.

## Product Principles

1. Owning beats renting: every surface should make a local library feel at least as alive as a streaming home.
2. Fidelity is shown, not claimed: quality data comes from the actual files and is never decorative.
3. The library is the user's: respect their folder, metadata and playlists; destructive actions are explicit.
4. Restraint carries the brand: monochrome first; color comes from the music itself (the Home banner's palette) or means audio quality.
