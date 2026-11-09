---
version: 1
slug: "sources-flactastic-ui-menubar-menubarplayerview-swift"
primary_target: "Sources/flactastic/UI/MenuBar/MenuBarPlayerView.swift"
related_targets: ["Sources/flactastic/UI/Transport/FloatingPlayerBar.swift", "Sources/flactastic/UI/Transport/QueuePanelView.swift"]
---

# Menu bar player

Scope: the popover under FLACtastic's menu bar icon (native macOS SwiftUI `MenuBarExtra`, window style), mode Operate.

Audience: someone working in another app. Tasks, from the interview (2026-11-03): quick control (skip, pause, shuffle, repeat) without leaving what they're doing; check what's on (song, artist, album, quality, time left); manage the queue (see what's next, jump, reorder, remove). Not a place to browse the library.

Constraints: inherit the app's established world (no DESIGN.md yet): the floating player bar's frosted glass with a faint cover wash and lit edge, `GlassIconButtonStyle` buttons (accent toggles with a dot), `PlayerQualityBadge`, the queue panel's rows. Monochrome; colour only from quality tiers and the accent. Light and dark both first-class. The menu bar icon stays while the app is open by default; a setting can limit it to while music plays. Volume and the speaker picker included. The queue is an expandable drawer that remembers whether it was left open, with full editing (drag to reorder, remove, double-click to play).

## Direction contract

THESIS: The seek bar doesn't stop at the end of the song: it runs on into the next few tracks, so what's on and what's next read as one line.

OWN-WORLD: The floating bar's frosted glass and cover wash, its glass icon buttons and quality badge, SF Pro at the bar's sizes, the queue panel's rows.

STORY: Glance at the cover, title, artist and quality; see where you are in the song and what the next three are; act with the transport row; open the drawer to manage the rest.

FIRST VIEWPORT: 340pt wide. Cover (56pt), title with badge, artist, album; the road: this song's scrubbable segment, then the next three as short segments; elapsed and remaining times, or the hovered track's name; shuffle, previous, play/pause, next, repeat centred; a quiet row of volume, speaker, open-app and the queue chevron. The drawer opens below with Next Up.

FORM: Structure dealt by the surface roll (seed key 039bb463, lead of 7/2/3), chosen by the user. Signature move: hover a segment ahead to name it, click to jump there. Code-led (no image generation).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
