# FLACtastic: Design Style & Philosophy

*Context document for Claude Projects. Snapshot of branch `revisions`, 2026-11-11.*

This guide describes how FLACtastic looks, moves and speaks, why it looks that way, and how design work on it is done. It was put together from:

- the codebase: `Sources/flactastic/UI/**`, `Theme.swift`, `UIStyle.swift`;
- the repo's own `PRODUCT.md` and `DESIGN.md`;
- the Impeccable surface briefs and decision records in `.impeccable/`;
- the design handoffs in `design_handoffs/`;
- the decisions and corrections from earlier design and code sessions.

The companion file `FLACtastic-Visual-Reference.pdf` (or `.html`) draws the tokens, components and motion curves.

> **Source of truth order:** the code (`Theme.swift`, `UIStyle.swift`, the component files) → `DESIGN.md` → this guide. If they disagree, the code wins and the docs are stale. Section 12 lists the known drift.

---

## 1. What FLACtastic is

FLACtastic is a native macOS music player and library manager for a local lossless (FLAC / hi-res) collection.

- **Stack:** Swift 6, SwiftUI and AppKit, macOS 14 or later.
- **Platforms:** Intel and Apple Silicon.
- **Releases:** stay on a beta track (`version.txt` = `beta-N`).

**Who it's for:** listeners leaving Spotify or Apple Music who now want to own their music, without losing the polish of a streaming app.

**The one-line goal:** *owning your music should feel better than renting it.* Success is a former streaming user choosing FLACtastic as their everyday player.

**Main surfaces**

| Area | What it is |
|---|---|
| **Home** | The daily thrown jewel case and lyric, then streaming-style shelves: Recommended for today with a Today's pick card, Recently played, Jump back in, On repeat, generated Mixes, Best sounding, Your listening stats, and the Fidelidex. |
| **Collection** | Albums (a CD rack of designed spines, or a grid), Artists, Tracks. Album, Artist, Playlist and Mix detail pages. |
| **Playlists** | User playlists, Spotify import and rebuild, saved mixes. |
| **Downloads** | A smart "Search or paste a link" field using the Deezer catalogue and Lucida sources. |
| **Organizer** | Folder structure, metadata, artwork and lyrics tools. |
| **Visualizer** | Album-art wheel, Record, Lyrics, radial and horizontal Spectrum, Spectrogram, picked from a mode dial. |
| **Player** | A glass puck in a bottom corner that opens into the full floating player bar, a queue panel, and a menu bar player. |
| **Settings** | A sheet of groups. A separate **UI for nerds** window holds every appearance knob, with a click-to-inspect live preview. |
| **Onboarding** | A "tracklist" setup flow with a thrown jewel case. |

**Vocabulary to use:**
- **Fidelidex:** the library fidelity panel, with a 0 to 100 score.
- **Collection, Organizer, Mixes, the rack, spines.**
- **The puck:** the collapsed player.
- **Quality tiers:** Hi-Res, CD, Mid, Low.

---

## 2. Design philosophy

### Creative North Star: "The CD Back Insert"

The app is printed like the back of a CD: one ink on one ground.

- Heavy SF Pro titles and track numbers.
- Hairline rules and plain lists.
- No chrome that doesn't do something.

The interface itself is colourless. **Colour comes from the music**: album art, the artist palette sampled for Home, and the audio-quality tiers.

The one physical object in this world is **the jewel case**. Albums appear as real clear-plastic CD cases with designed spines and printed discs (`RackBox`, `RackDisc`). That same object shows up in three places:
- it is the Collection rack;
- it is thrown onto Home once per launch;
- it rides through onboarding.

### Product principles (from PRODUCT.md)

1. **Owning beats renting.** Every surface should make a local library feel at least as alive as a streaming home.
2. **Fidelity is shown, not claimed.** Quality data comes from the actual files and is never decorative.
3. **The library is the user's.** Respect their folder, tags and playlists; destructive actions are explicit.
4. **Restraint carries the brand.** Monochrome first. Colour means music or quality.

### The user's standing values (from many sessions)

These come up again and again. Treat them as requirements.

- **Realism and craft over generic UI.** Physical metaphors such as the case, disc, spine, laser, scrubber and skip are preferred to abstract widgets. Spines are generated like real CD spines: genre fonts, torn edges, aging by release year.
- **Flashy, but tasteful, and only at moments.** Big motion is saved for signature moments: the throw, the CD skip, the theme flood. Everything else is calm. After a showpiece the object is *perfectly still*: no idle float, no parallax, no spinning.
- **Streaming-grade warmth from a local library.** Home should feel like Spotify's, personal and comfy, with no blank space and no placeholders. Sections hide when they have nothing real to show.
- **Customisable, but with designed defaults.** Every appearance knob lives in UI for nerds, which shows each value with a reset dot. Defaults are the designed look; settings never replace design decisions.
- **Never damage files or reshape the library.** Tag writes are append-only or fill-if-empty. Writes are deferred while a file is playing. Identical display for existing files ranks just below not damaging them.
- **Consistency across contexts.** The same object behaves the same everywhere. For example, the mix page is styled *exactly* like the playlist page, and context menus must be correct wherever you right-click on a row, not only on its text.
- **Light and dark are both first-class.** Every screen is checked in both.

### Things the user has rejected (anti-references)

- **Blurred-photo banners on Home.** The old blurred artist banner was removed. A "colour field with a cut-out artist" was tried and dropped as tacky, as were drifting colours.
- **Centred wizard cards with dots and a Next button.** Onboarding is a tracklist instead.
- **Invented taglines and slogans.** "LOSSLESS · OWNED · YOURS" was removed from the case.
- **Copy that explains the app or reads "AI-like".**
- **Lock icons and confusing toggle models in editors.** Edit Spine shows current values plus "Surprise me", undo and redo, and Reset to tags.
- **Nested popup menus for long choices.** Use a scrolling list with hover preview.
- **Ad-hoc mockups that skip the design process** (see section 11).
- **Raising tertiary text contrast.** The user confirmed on 2026-11-02 that `Theme` tokens are kept exactly.

---

## 3. Colour

### The monochrome ladder (`Theme.swift`, adaptive dark / light pairs)

| Token | Dark | Light | Use |
|---|---|---|---|
| `background` | `#000000` | `#F5F5F5` | window and page ground |
| `surface` | `#141414` | `#E6E6E6` | sheets, wells |
| `surfaceElevated` | `#1F1F1F` | `#D6D6D6` | context menus, raised wells, glass fallback |
| `surfaceHover` | `#292929` | `#C7C7C7` | press and hover in older controls |
| `textPrimary` | `#F2F2F2` | `#141414` | text; the everyday "ink" |
| `textSecondary` | `#A6A6A6` | `#595959` | subtitles, detail lines |
| `textTertiary` | `#737373` | `#666666` | counts, hints, captions, group labels (light raised to 4.5:1 on 2026-11-20) |
| `divider` | `#2E2E2E` | `#CCCCCC` | 0.5 to 1 pt hairlines |
| `accent` | `#FFFFFF` | `#000000` | the one accent: the ink at full strength |

**The One Ink Rule.** The accent *is* the text colour. Emphasis comes from inverting: an ink fill with ground-coloured text, as on primary pills, the on switch and the play button. No hue is ever used as a UI accent.

**The Opacity Ladder Rule.** Build new fills and strokes from `textPrimary` at fixed opacities, so one component works on both grounds:

| Opacity | Use |
|---|---|
| 4.5% | field hover |
| 5% | resting card or row fill |
| 6 to 7% | quiet-button hover, close-button rest, glass-button hover |
| 8% | hover, secondary pill fill |
| 10% | resting stroke or rule |
| 12% | strong hover, field focus stroke |
| 14% | toggle-pill outline |
| 16% | off switch track |
| 55% | off switch knob |

### Colour sources outside the ladder

1. **Quality tiers** (`AudioQuality.color`).

   | Tier | Dark | Light | When |
   |---|---|---|---|
   | Hi-Res | turquoise `#00E6CC` | `#008073` | lossless above 16-bit or above 44.1 kHz |
   | CD | green `#4DD966` | `#268040` | 16-bit / 44.1 kHz lossless |
   | Mid | amber `#F2BF33` | `#875E05` | lossy at 44.1 kHz or above, or lossless without metadata |
   | Low | red `#F24D4D` | `#B82E2E` | lossy below 44.1 kHz |

   - They appear only where quality is shown: badges, the Fidelidex, spine marks and scan reveals.
   - Low's red doubles as the inline error ink.
   - UI for nerds can turn tier colours off (`tierColours`), and then they fall back to the grey ladder.
2. **The Home palette** (`HomePalette`). Up to four hues sampled from the day's artist image. It colours the highlighted figures, number-one ranks, the genre chart, the Fidelidex and the glow behind the thrown case. A grey or missing image keeps Home monochrome. UI for nerds' **Accent** knob sets the source: Artist (default), Mono, or Custom hex (default `#4AA3FF`).
3. **Album art itself.** Covers, disc prints sampled from the cover, the player's cover wash, mix covers (the artist photo in grayscale with the mix colour laid over it), and the detail-page backdrop washes.

**The Colour Means Something Rule.** Any hue on screen is a quality tier, the Home palette or album art. Quality colours never become a general accent, and the Home palette never leaves Home.

The only other red is the system red on destructive pills (`SheetPillStyle(isDestructive:)`), used only for permanent deletes.

---

## 4. Typography

**One family pushed to its extremes:** SF Pro, the system font. Titles are heavy (800) with tight negative tracking, like a record sleeve. Everything else is small and plain. Numbers use `.monospacedDigit()`; there is no separate mono face.

| Role | Spec | Where |
|---|---|---|
| Display | 80 pt heavy, tracking about -3 | Album, Playlist and Mix detail titles: the title *is* the page |
| Page headline | 40 pt heavy, tracking -1.4 to -1.6 | Collection, Settings, Playlists, Home section pages, sheets such as Connect Server |
| Big page headline | 56 to 72 pt heavy | Organizer (56), Artist discography (56), Playlists header (56), Downloads (72) |
| Stage title | 56 to 76 pt heavy (10% of window height), -4% tracking | Onboarding; revealed word by word |
| Lyric | 50 pt heavy by default (user-adjustable), -1.2 tracking, italic heavy quote marks | Home lyric |
| Numeral | 30 to 54 pt heavy, monospaced digits, `.numericText` transitions | Fidelidex score, counts, scan summary figures |
| Home section title | 22 pt heavy, tracking -0.5 (UI for nerds `sectionTitleSize`) | "Recommended for today" and the other shelves |
| Title | 18 to 19 pt bold or heavy | tracklist names, radio-card titles |
| Row title | 15 pt bold; 13 to 13.5 pt semibold for tiles and lists | option rows, tile titles, missed-album rows |
| Body | 13 pt regular | detail text, Home section subtitle (tertiary) |
| Label | 12 to 12.5 pt | captions, counts, hints; action words in 12.5 semibold |
| Button | 14 pt semibold (sheet pills); 13 pt medium (older pills and hero secondaries) | |
| Group label | 11 pt bold, UPPERCASE, kerning 1.4, tertiary | names a *group of rows or a field* only; also the FLSheet title |
| Badge | 9.5 to 10.5 pt heavy, uppercase | quality badges on covers and in the player |

**The Heavy Title Rule.** Each page has one heavy title with tracking around -0.035 to -0.04 em. Nothing else competes with it in weight.

**The Counting Digits Rule.** Any number that changes or sits in a column uses monospaced digits. Counters animate with `.contentTransition(.numericText())`.

**No eyebrows on page titles.** Spaced capitals name groups and fields, never a page or display title.

---

## 5. Layout & spacing

- **Spacing scale** (`Theme.Spacing`): 4 / 8 / 12 / 16 / 24 / 32. Big surfaces use literal insets on the same rhythm: 20, 28, 36, 64 and 68.
- **Window:** minimum 1000 × 650. The window opens filling the desktop. A transparent full-size title bar puts the traffic lights in the custom top bar.
- **Top bar:** a frosted rail 58 pt tall that floats over the page.
  - It holds the "FLACtastic ⌄" app menu, then the tabs as plain words.
  - The current tab is bright, with an underline that slides between tabs.
  - A hairline separates the library tabs from the tools.
  - Pages scroll underneath it and keep titles clear of it.
- **The Left-Edge Rule.** Content hangs from one left edge, as on an insert: heavy title, quiet line under it, then content. Centring is only for transient moments, such as the intro wordmark.
- **Page tops are tall and generous; lists are tighter.**
- **Home**
  - **Top:** a 60 pt wordmark and today's date. Below it, the lyric fills the left 54% and the thrown case sits on the right, at rest about 430 pt and leaning in.
  - **Today:** the Today's pick card sits beside two rows of covers, and is exactly as tall as the two rows.
  - **Shelves:** horizontal rows of 170 pt covers (`homeCoverSize`) with an 18 pt gap (`homeDensity`). "Show all" expands the row in place; there are no extra pages.
  - **Mix tiles:** larger, about 300 pt, and they grow to fill the row.
- **Detail pages** (Album, Artist, Playlist, Mix):
  - a hero (560 pt on albums) on a pre-blurred wash of the cover;
  - an 80 pt title, a meta line ("Artist · Album · 2024 · Electronic"), and hero pills (Play, Shuffle and others);
  - then the tracklist with a `# / TITLE / FORMAT / QUALITY / LENGTH` header rule, and "More by" in 6 columns with 20 pt gaps.
- **Settings:** groups have no box.
  - A group is a spaced-capitals label, then rows straight on the sheet, split by 0.5 pt hairlines inset 16 pt.
  - The stack is pulled out 16 pt so row text lines up with the label.
- **The player** sits in a bottom corner, right by default (`playerSide`), and opens toward the middle. On Organizer it tucks behind a 20 × 52 handle on the player's own side.

---

## 6. Shape, depth & material

### Shapes
- **Two families.**
  - **Controls are capsules:** pills, switches, quiet buttons, tags, scrubbers, the 34 pt capsule controls.
  - **Containers are continuous-corner rounded rectangles** whose radius grows with size.
- **Radius steps:**
  - 4: small chrome
  - 6: cover badges
  - 7: thumbnails, segments
  - 8: context menus
  - 10: fields, list rows, pill-toggle well
  - 12: artwork default (`artworkRadius`, 0 to square), icon tiles
  - 14: theme tiles
  - 16: option rows, the collapsed puck
  - 18: radio cards, the open player bar
- **The Continuous Corner Rule.** Always `RoundedRectangle(cornerRadius:style: .continuous)`.
- **Physical objects keep their real geometry:** square cases with 1 px edge highlights, and round discs with a hub and rim.

### Depth
- **The Objects Cast Shadows Rule.** Only physical things cast shadows: case, disc, cover art and spine. Controls, rows and cards are flat and show state through fill and stroke opacity. Two exceptions are allowed:
  - floating windows (the context menu, at black 35%, radius 14, y 6);
  - the hover play button on a cover.

**Shadow vocabulary**

| Shadow | Values |
|---|---|
| Artwork | `ArtworkShadow`: radius about 6% of size (2 to 14), y 1 to 6, 30% below 80 pt, 22% at 80 pt and above; drawn after the clip |
| Home tile hover | from 28% / r6 / y4 to 45% / r14 / y10, with a 3 pt rise |
| Case at rest | 50% / r22 / y20 |
| Disc | 50% / r24 / y16 |
| Case lifted from the rack | 45% / r14 / y10 |
| Spine hover | 60% / r14 / y12 |
| Play button | 40% / r9 / y6 |

**Glow** is only for real light sources: the case's palette glow on Home, the skip laser, the loader bloom, and the cover hover highlight.

### Material (glass)
- **Glass appears in a few places:** the player, the top bar rail, the menu bar popover and hero secondary pills.
- **The player glass** (`PlayerGlass`):
  - `ultraThinMaterial`, plus a tint (white 50% in light, black 8% at 46% in dark);
  - a **cover wash**: the album art saturated 1.6× at 38% dark / 22% light, fading from the left;
  - a lit gradient edge.
- **Glass buttons** (`GlassIconButtonStyle`): tertiary icons that brighten on hover, with a 7% circle behind them. When toggled on they show in the accent with a 4 pt dot.
- UI for nerds `glass = false` swaps every glass surface for `surfaceElevated` and turns off the cover wash and the Home glow.

---

## 7. Components (use these; don't reinvent)

| Need | Use | Spec |
|---|---|---|
| Sheet / modal editor | `FLSheet(title:width:height:)` | Spaced-caps title and a 30 pt ✕ (`SheetCloseButton`). Footer under a hairline, with 28 / 16 padding. Cancel owns Esc. Options: `contentScrolls` / `alwaysScrolls`. |
| Sheet actions | `SheetPillStyle` | Capsule 40 pt tall, 22 pt sides, 14 semibold. Primary = ink fill. Secondary = 8% ink. Destructive = system red. Press 0.96 / 80%; disabled 40%. One primary per row, at the right. |
| Minor action | `QuietTextButtonStyle` | 12 pt tertiary text in a 26 pt capsule; on hover the text turns primary over a 6% fill. |
| Page actions (Play / Shuffle) | `FLActionPillStyle` | 36 pt, or 34 pt in a control row. |
| Pills over artwork heroes | `HeroPillStyle`, `HeroBackButton` | Primary ink 44 pt; secondary on `ultraThinMaterial`; a 36 pt frosted back circle. |
| On / off setting | `FLSwitchStyle` | 40 × 24 capsule. On = ink with a ground-coloured knob; off = 16% with a 55% knob; 0.2 s. |
| Segmented choice | `FLPillToggle` | 10 pt well with a hairline; the active 7 pt block slides on a spring (0.3 / 0.78). |
| Dropdown | `FLSortMenu` | Capsule menu instead of `.pickerStyle(.menu)`. |
| Small icon button | `FLCircleIconButton` | A 34 pt circle on `FLCapsuleBackground`. |
| Sheet toggle chips | `SheetTogglePill` | 30 pt. Off = 14% outline; on = solid ink. |
| Text field | `QuietFieldStyle` | Reads as plain 15 semibold text. Hover adds a 4.5% fill; focus adds 7% fill, a 12% stroke and a 10 pt radius. |
| Field / group label | `SheetLabel` / `SettingsGroup(title:)` + `GroupDivider` | 11 bold, caps, kerning 1.4, tertiary. |
| Context menu | `.flContextMenu { … }` | Themed AppKit panel: `surfaceElevated`, 8 pt radius, at least 200 pt wide, with submenus and inline fields. A single router picks the menu for what is actually under the pointer: highest priority, then frontmost, then innermost. Every right-click target registers. |
| Loader | `BrandLoader` | The F mark animated in Core Animation, in three styles, random per launch or chosen in UI for nerds. Sized 40 pt to full screen; optional bloom; still under Reduce Motion. **Never a system spinner.** |
| Brand | `Wordmark`, `BrandMark` | Template PNG tinted with `textPrimary`. Always fixed height and `.aspectRatio(.fit)`: never stretched or squished. |
| Album as an object | `RackBox`, `RackDisc` | Reuse them; never draw a new case. |
| Covers on Home | `HomeAlbumTile`, `HomePlayButton`, `HomeShelf`, `HomeSectionHeader` | See below. |
| Quality | `PlayerQualityBadge`, cover badges, `FidelidexView` | Tier colour on text. Cover badges sit on black at 62%. |
| List rows | `.fl-row` hover | 9 / 10 padding, 10 pt radius, surface fill on hover. Rows that draw their own selection or playing fill opt out. |
| Card hover | `coverHoverHighlight` + the -3 pt rise | Slight magnify, hairline highlight, soft glow. Cards open on click; hovering a card never offers playback, except Home tiles' play button. |
| Entrances | `riseFadeIn(index:)`, `arrival(_:calm:animation:)` | 0.28 s ease-out with a 10 pt rise and a 15 ms stagger capped at 0.25 s. A first big burst skips animation for performance. |

**Home tiles**
- The cover lifts 3 pt on hover on the house ease (0.3 s), and its shadow deepens.
- A 40 pt ink play button rises in at the bottom right.
- Below the cover: a 13.5 semibold title and a 12 pt tertiary caption.
- A quality badge sits top left.

**Section header:** a 22 pt heavy title, a 13 pt tertiary subtitle on the same baseline, and a trailing action ("Show all" or "Play all").

**The player puck** (`CornerPlayerPuck`)
- **Closed:** 320 × 56 at a 16 pt radius. It shows a 40 pt cover, the title, previous / play / next, and a progress line along its lip.
- **Click:** it opens into the bar, at the user's width (default 700) and an 18 pt radius:
  1. it widens first (0.28 s);
  2. then it rises in height (0.26 s), on `timingCurve(0.65, 0, 0.35, 1)`.
  - The bar-only parts fade and unblur in; closing is the exact reverse.
  - A generation token makes a toggle mid-animation reverse cleanly.
  - Under Reduce Motion it becomes a 0.2 s crossfade.
- One view hierarchy, with nothing inserted mid-animation.

**The rack** (`AlbumRackView`)
- One long shelf of designed spines that scrolls sideways.
- Hover lifts a spine and shows the album's details under the shelf.
- **Click takes the case out:**
  - the rack falls back and blurs;
  - the case lifts, turns from its spine to its cover, and the disc slides out to the right;
  - details appear with Play and Open.
- Back or Esc reverses it.

**Spines** (`SpineDesign`)
- A paper insert strip on unblurred art.
- Fonts come from genre tiers: Heavy, Raw, Street, Electric, Smooth, Classic. The artist name is always SF.
- Each spine is seeded from a hash of artist + title, plus a per-album shuffle count.
- Options: Edit Spine workshop, Shuffle / Reset Spine, Spine Variety, Label Mark, real spine scans, and aging by release year.

---

## 8. Motion

**House ease:** `timingCurve(0.16, 1, 0.3, 1)` (`MotionCurve.flactastic`): fast away, then a long soft landing. It is used for arrivals, reveals, hovers on cards, scrubber fills and case glides, at durations from 0.3 to 1.2 s (0.35, 0.45, 0.7 and 0.9 are common).

**Other curves:**

| Curve | Values | Used for |
|---|---|---|
| Exit ease | `(0.6, 0, 0.9, 0.4)`, 0.24 to 0.5 s | things leaving |
| Wipe ease | `(0.7, 0, 0.2, 1)`, 0.9 to 1.1 s | wordmark wipe, theme flood |
| Staggered axes | `(0.65, 0, 0.35, 1)` | the player puck's width, then height |
| Settle springs | response 0.8 to 1.0, damping 0.6 to 0.72 | caught objects |
| UI springs | 0.3 / 0.78 | pill toggle |
| Micro | press 0.08 to 0.12 s ease-out (scale 0.92 to 0.96); hover 0.15 s ease-out; selection 0.2 s | |

**Signature moves**
- **The throw** (Home; onboarding intro and finale):
  - The case flies in from the far right, small and tumbling.
  - It lands on the house ease and is *caught* with a jolt: a keyframed shake of about 4 × 3 pt that decays over 0.16 to 0.2 s.
  - The disc ends caught halfway out.
  - It plays once per launch by default (Each launch / Once a day / Never). After that the case is completely still.
- **CD skip** (onboarding Continue):
  - The case spins an extra turn and a 2 pt read laser sweeps the stage (0.42 s) with a 7% light pop.
  - The old content stutters (-12, 5, -20, -8 pt), then tears off sideways (x -140, skew -12°, blur 20).
  - The scrubber runs off its row with a glow.
  - The new title springs in word by word from the direction of travel, and the case jolts.
- **Theme flood:** the new theme pours out in a circle from the click point.
- **Word reveal:** title words start blurred 10 pt and offset, then settle in a 45 to 60 ms stagger.
- **Page entrance:** detail pages zoom in, then cover, title, details and buttons follow in sequence (`arrival`). A pending question with the user: whether to drop the full-window 28 pt blur on entrance, for performance.
- **The disc spins only while something is being read:** 520°/s during a scan, 300°/s while connecting.

**Rules**
- **Every animation has a Reduce Motion path.** Spins, jolts, lasers, throws and floods turn off; pose changes become 0.15 to 0.25 s fades.
- **Global speed:** UI for nerds `animationSpeed` scales every animation. Its throw and rack-open curves can be swapped for standard curves.
- **Animate only opacity, offset, scale and blur in shared hierarchies.** Use completion-based phases with generation tokens, not timers.
- **Performance is part of the design.**
  - Pre-blur once off the main thread; never blur live while scrolling.
  - Fade the rack's ends with painted gradients, not masks.
  - Use Core Animation for the loader.
  - `.drawingGroup()` is only for large art.

---

## 9. Voice & copy

**Short, warm, plain, confident.** One line, two at most. Never explain what FLACtastic does; the user already downloaded it.

**Examples the user approved:**
- "Are you new to FLACtastic, or a returning audiophile?"
- "Your music, beautifully."
- "Files only move when you say so."
- "Skipped, connect any time."
- "Press Fetch to see its tracks."
- "FLACtastic needs a quick restart to load your backup." (button: "Restart FLACtastic")

**Rules:**
- No taglines or slogans on assets.
- No marketing voice and no exclamation points.
- No "AI-like" hedging.
- Be honest about limits ("best source available, up to Hi-Res"). Never fabricate reviews or user counts.
- Generated mixes use streaming conventions: "Featuring [artist]", with the lead artist added to colliding names.
- Help text and accessibility labels are written plainly ("Open Midnights", "Click to open the player").
- UI for nerds can be "playful but tidy": every value shows its number (170 pt, 6 columns, 1.2×).

---

## 10. Surfaces & their locked directions

| Surface | Direction | Files |
|---|---|---|
| Home top | "The day's CD, thrown": the rack case thrown in and caught beside the lyric; uncoloured quote marks; story line "From <album> (<year>)" only | `UI/Home/HomeTop.swift`, `.impeccable/surfaces/…homeview…md` |
| Home sections | Layout A, shelves: Recommended for today first (Today's pick + 2 rows, fixed per day), then a designed order with smart hiding; "Arrange automatically" off lets the user reorder | `HomeFeed.swift`, `HomeShelves.swift` |
| Mixes | Covers are the lead artist's photo in grayscale with the mix colour and its name. Lists are frozen per day and change only on ratings (More Like This / Doesn't Fit) or a reroll. The mix page matches the playlist page exactly. | `MixDetailView.swift`, `MixCurator.swift` |
| Onboarding | "The tracklist": steps are numbered tracks on the left, a stage on the right, Continue is a CD skip, the scrubber is the only progress bar | `UI/Onboarding/*` |
| Menu bar player | "The road ahead": the seek line runs on into the next three tracks (hover names a segment, click jumps), plus an editable queue drawer | `MenuBarPlayerView.swift` |
| UI for nerds | "Click to inspect": a live miniature of each page; click a part to get its knobs; Esc walks back up | `UIForNerdsView.swift`, `UIStyle.swift` |
| Collection rack | Designed CD spines; the case is taken out on click | `AlbumRackView.swift`, `SpineDesign.swift` |
| Edit Spine | A workshop window (about 1200 × 800): click a part of the spine, "Surprise me", no locks | `EditSpineSheet.swift` |
| Downloads | One smart field: "Search or paste a link" | `DownloadTabView.swift` |
| Player | Corner glass puck → floating bar with staggered axes; tuck handle on Organizer | `CornerPlayerPuck.swift`, `PuckTuckHandle.swift` |

---

## 11. How design work is done here (process preferences)

1. **Use the Impeccable process for any new surface or redesign.** The steps:
   1. a **shape interview** first: audience, tasks, constraints, mood;
   2. then **two or three genuinely distinct directions** (a concept roll and decision page);
   3. the user locks one;
   4. then an HTML mockup with real data and Theme tokens, usually in `design_handoffs/<name>/index.html`, served by the `design-mockups` launch config;
   5. then the SwiftUI build;
   6. then a finish review.

   Briefs live in `.impeccable/surfaces/` and decisions in `.impeccable/decisions/`. Skipping the process for ad-hoc mockups was explicitly called out by the user.
2. **Ask before building** when a request says "don't build yet" or "brainstorm". Research and options come first; often "conjure up some ideas before building anything".
3. **Inventory first** for refinements: report what exists before you change it.
4. **Match the app exactly** in mockups: real `Theme.swift` values, shipped sizes, real fonts and covers. Don't "improve" tokens on the way.
5. **Ask for on-screen feedback.** The user checks builds by hand and sends screenshots. Don't polish blind.
6. **Tests first** for behaviour. Run the full suite. Golden masters, such as the display baseline, are re-recorded only with approval.
7. **Git etiquette:**
   - Commit only when asked, in measured single-concern commits.
   - **Never touch the git index** unless asked: delete files with plain `rm`, no `git add` or `git rm`.
   - Exclude `.claude/` and `.impeccable/` from commits.
8. **Respect the user's data.** Fill-if-empty and append-only writes, no writes into a playing file, and explicit destructive actions.

---

## 12. Known drift & open questions (as of 2026-11-11)

- **`DESIGN.md` is behind the code.** It doesn't cover:
  - the corner puck and staggered-axes animation;
  - mixes and the mix page;
  - Accent modes (Artist / Mono / Custom);
  - the `tierColours`, `glass` and `animationSpeed` knobs;
  - the genre-scan summary sheet;
  - the Organizer tuck handle.

  It needs a refresh (Impeccable `document`).
- **Sync uses `FLPageHeader`,** an eyebrow plus a 32 pt bold title. That breaks "no eyebrow on page titles" and the heavy-title scale. It's an older component; new pages should use the heavy 40 pt headline.
- **`PillButtonStyle`** (13 medium on `surfaceElevated`) is a legacy twin of `SheetPillStyle` and `FLActionPillStyle`. Prefer the newer two.
- **`Theme.Radius`** only names 4 / 8 / 12. Larger radii are literals; see section 6 for the steps.
- **Pending decisions:**
  - P4: drop the entrance blur on detail pages?
  - The loading-chroma pick (seven loader mockups; three styles are shipped).
  - Several built surfaces haven't been seen on screen yet: Download search, multi-value tags review, the server UI.

---

## 13. Quick checklist for any new UI

- [ ] Colours from `Theme`, or `textPrimary` at the opacity ladder. Checked in **both** light and dark.
- [ ] Any hue is a quality tier, the Home palette or album art. Nothing else.
- [ ] One heavy title per page, left-aligned, with negative tracking. No eyebrow above it.
- [ ] Existing components used (FLSheet, SheetPillStyle, FLSwitchStyle, FLPillToggle, QuietFieldStyle, BrandLoader, `.flContextMenu`, RackBox / RackDisc).
- [ ] Continuous corners; capsules for controls.
- [ ] Shadows only on physical objects.
- [ ] House ease for arrivals. A Reduce Motion path. No idle motion after a showpiece.
- [ ] Copy is one short natural line, with no tagline.
- [ ] Context menus work anywhere on the row and match the context.
- [ ] New appearance knobs go in `UIStyle` and the NerdCatalog, and inspectable regions are tagged `.nerdPart`.
- [ ] No live blur or mask while scrolling; heavy work stays off the main thread.
