---
version: 1
slug: "sources-flactastic-ui-home-homeview-swift"
primary_target: "Sources/flactastic/UI/Home/HomeView.swift"
related_targets: ["Sources/flactastic/UI/Home/HomeTop.swift"]
---

# Home

Scope: FLACtastic's Home tab (native macOS SwiftUI), mode Operate. Its job is choosing something to play from your own library; the top of it is a small daily moment.

Audience: former streaming listeners who own their music. Task: open Home, get a moment from a song you love, then pick from the shelves. Content: the daily lyric (HomeHighlight), its song and artist, the song's story with you (album, year, plays, first play, quality), the artist's photo and the palette sampled from it. Constraints: monochrome app; colour only from the artist's palette and quality tiers; no blurred banner; light and dark both first-class.

## Direction contract

THESIS: The top of Home is the song's album as a real jewel case, thrown at you and caught just short of the glass, beside the day's lyric; not a banner photo behind a title.

OWN-WORLD: Home's black/white ladder and SF Pro heavy type; the Collection rack's own jewel case (RackBox, clear-case look, designed spine) and disc (RackDisc); a soft glow in the artist's palette colour; a floor shadow far below.

STORY: The case flies in from the right and stops dead with the disc caught halfway out; the lyric arrives as it's caught; you read the line, the song and artist, and where it's from, then move into Recommended for today.

FIRST VIEWPORT: The 60pt wordmark at left with today's date beside it; below, the lyric large on the left 54%, the song line (title, linked artist, pin) and "From <album> (<year>)"; the case on the right, about 430pt and leaning in, centred against the left block, turned to show its spine, the disc half out to its right, reaching up beside the wordmark.

FORM: User-pinned direction (A2 of the jewel-case round, 2026-11-03). Signature move: the throw, once per app launch (`ThrownCase.hasThrown`); afterwards, and with Reduce Motion or fades off, the case is at rest and completely still. Uncoloured quote marks. No album in the library for the song: no case.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
