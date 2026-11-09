---
version: 1
slug: "ui-for-nerds"
primary_target: "Sources/flactastic/UI/Settings/UIForNerdsView.swift"
related_targets: ["Sources/flactastic/UI/Settings/SettingsView.swift", "Sources/flactastic/UI/Navigation/TopBarItems.swift"]
---

# UI for nerds

Scope: a new window, opened from the FLACtastic menu just below "Settings…", that holds every appearance control beyond light/dark (which stays in Settings › General). Mode Operate.

Audience: people who like to tune their player. From the interview (2026-11-03): its own window with a built-in live preview; per-page controls of every kind (show/hide and reorder, size and density, colour and type, motion and effects); playful but tidy copy.

Constraints: inherit the app's world (monochrome ladder, SF Pro heavy titles, pill toggles, glass icon buttons, quality-tier colours, the artist palette); light and dark both first-class. Everything in Settings › Appearance moves here (Home sections, album rack and spines, artwork, animations); Theme stays in General.

## Direction contract

THESIS: The preview is the menu: hover any part of a miniature page and it outlines; click it and the inspector beside it shows that element's controls.

OWN-WORLD: The app's own surfaces drawn small and live (real covers, the thrown case, shelves, the rack, the player bar); the settings sheet's type and pill controls in a slim right-hand inspector.

STORY: Pick a page; see it live in miniature; point at the thing that bugs you; click; tune it; watch it change; Escape back up to the page's own controls.

FIRST VIEWPORT: Title row "UI for nerds" with a page picker (Everywhere, Home, Collection, Playlists, Player bar, Visualizer); a large live preview of the chosen page filling most of the window; a 300pt inspector on the right headed by the selection's breadcrumb (Home › Recommended for today), its controls below, and "Reset this" at the foot.

FORM: Surface roll seed 5cd83111 (dealt 7/2/1); the user locked the "click to inspect" card. Code-led. Signature move: hover outline + click to inspect, Escape walks back up. Every value shows its number (170 pt, 6 columns, 1.2×) with a dot to reset it.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
