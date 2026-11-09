---
name: FLACtastic
description: A monochrome native macOS player that makes a local lossless library feel as alive as a streaming home.
colors:
  background-dark: "#000000"
  background-light: "#F5F5F5"
  surface-dark: "#141414"
  surface-light: "#E6E6E6"
  surface-elevated-dark: "#1F1F1F"
  surface-elevated-light: "#D6D6D6"
  surface-hover-dark: "#292929"
  surface-hover-light: "#C7C7C7"
  ink-primary-dark: "#F2F2F2"
  ink-primary-light: "#141414"
  ink-secondary-dark: "#A6A6A6"
  ink-secondary-light: "#595959"
  ink-tertiary-dark: "#737373"
  ink-tertiary-light: "#8C8C8C"
  hairline-dark: "#2E2E2E"
  hairline-light: "#CCCCCC"
  accent-dark: "#FFFFFF"
  accent-light: "#000000"
  quality-hires-dark: "#00E6CC"
  quality-hires-light: "#008073"
  quality-cd-dark: "#4DD966"
  quality-cd-light: "#268040"
  quality-mid-dark: "#F2BF33"
  quality-mid-light: "#AD7A0D"
  quality-low-dark: "#F24D4D"
  quality-low-light: "#B82E2E"
typography:
  display:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "80px"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-0.0375em"
  stage-title:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "56px to 76px (10% of window height)"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-0.04em"
  headline:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "40px"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-0.035em"
  numeral:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "34px to 54px"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-0.035em"
    fontFeature: "tnum"
  title:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "18px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.3px"
  row-title:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "15px"
    fontWeight: 700
    lineHeight: 1.25
  body-lead:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.35
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
  label:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "12.5px"
    fontWeight: 400
    lineHeight: 1.3
  button:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1
  group-label:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "11px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "1.4px"
rounded:
  sm: "4px"
  thumb: "7px"
  md: "8px"
  field: "10px"
  lg: "12px"
  card: "14px"
  row: "16px"
  choice: "18px"
  pill: "9999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  xxl: "32px"
components:
  pill-primary:
    backgroundColor: "{colors.ink-primary-dark}"
    textColor: "{colors.background-dark}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: "0 22px"
    height: "40px"
  pill-secondary:
    backgroundColor: "rgba(242,242,242,0.08)"
    textColor: "{colors.ink-primary-dark}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: "0 22px"
    height: "40px"
  pill-destructive:
    backgroundColor: "#FF453A"
    textColor: "#FFFFFF"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: "0 22px"
    height: "40px"
  quiet-text-button:
    backgroundColor: "transparent"
    textColor: "{colors.ink-tertiary-dark}"
    rounded: "{rounded.pill}"
    padding: "0 10px"
    height: "26px"
  quiet-text-button-hover:
    backgroundColor: "rgba(242,242,242,0.06)"
    textColor: "{colors.ink-primary-dark}"
  toggle-pill-on:
    backgroundColor: "{colors.ink-primary-dark}"
    textColor: "{colors.background-dark}"
    rounded: "{rounded.pill}"
    padding: "0 13px"
    height: "30px"
  toggle-pill-off:
    backgroundColor: "transparent"
    textColor: "{colors.ink-secondary-dark}"
    rounded: "{rounded.pill}"
    padding: "0 13px"
    height: "30px"
  option-row:
    backgroundColor: "rgba(242,242,242,0.05)"
    textColor: "{colors.ink-primary-dark}"
    typography: "{typography.row-title}"
    rounded: "{rounded.row}"
    padding: "14px 16px 14px 14px"
  option-row-hover:
    backgroundColor: "rgba(242,242,242,0.08)"
  radio-card:
    backgroundColor: "rgba(242,242,242,0.05)"
    textColor: "{colors.ink-primary-dark}"
    rounded: "{rounded.choice}"
    padding: "20px"
  radio-card-selected:
    backgroundColor: "rgba(242,242,242,0.08)"
  quiet-field:
    backgroundColor: "transparent"
    textColor: "{colors.ink-primary-dark}"
    rounded: "{rounded.field}"
    padding: "6px 10px"
  quiet-field-focus:
    backgroundColor: "rgba(242,242,242,0.07)"
  switch-on:
    backgroundColor: "{colors.ink-primary-dark}"
    rounded: "{rounded.pill}"
    width: "40px"
    height: "24px"
  switch-off:
    backgroundColor: "rgba(242,242,242,0.16)"
    rounded: "{rounded.pill}"
    width: "40px"
    height: "24px"
---

<!-- Platform: native macOS (SwiftUI / AppKit, macOS 14+). Not a web surface. Every "px" value in this file is a macOS point; every colour is an adaptive pair (the -dark and -light tokens are one Theme colour each). Component tokens show the dark-mode value; the light-mode value is the -light twin of the same token. Source of truth: Sources/flactastic/UI/Theme/Theme.swift. -->

# Design System: FLACtastic

## Overview

**Creative North Star: "The CD Back Insert"**

FLACtastic is drawn in one ink on one ground, the way a CD's back insert is printed: heavy SF Pro titles and track numbers, hairline rules, plain lists, and no chrome that doesn't do anything. In dark mode the ink is near-white on true black; in light mode it is near-black on paper grey. Both are first-class, and every surface is checked in both. The interface itself stays colourless. Colour comes from the music: the Home banner's sampled artist palette, the quality tiers, and the album art.

The one physical object in this world is the jewel case. The Collection rack draws albums as real clear-plastic cases with designed spines and printed discs (`RackBox`, `RackDisc`), and that same case comes back as the signature object elsewhere: it is thrown onto Home once per launch, and it rides through onboarding, turning to a new mark on every step. The motion has weight. Things are thrown, caught with a small jolt, and come to rest. Transitions borrow from the player: a step change is a CD skip, and a theme change floods out from the click.

Density is generous at the top of a page and tighter in lists. One huge heavy title, a quiet line under it, then content. Surfaces sit flat on the ground. Depth comes only from the physical objects (case, disc, artwork), which cast soft floor shadows.

**Key Characteristics:**
- One adaptive ink on one adaptive ground; the accent is that same ink (white in dark mode, black in light mode).
- Heavy (800) SF Pro titles with tight negative tracking, scaled to the space.
- Fills and strokes are the primary ink at low opacity (5%, 8%, 10%, 12%, 16%), so the same component works on either ground.
- Capsule buttons and continuous-corner rows; no outlined chrome boxes around groups.
- The jewel case and disc are the recurring physical signature.
- Motion: one house ease (`timingCurve(0.16, 1, 0.3, 1)`), throws that end in a caught jolt, and a Reduce Motion version for every move.

## Colors

The palette is a monochrome ladder of nine adaptive greys. Two non-UI colour sources sit outside it: four fixed quality-tier hues, and per-song palettes sampled from album and artist art.

### Primary
- **The Ink** (accent-dark / accent-light, with ink-primary as its everyday form): the one accent. It fills the primary pill, the on switch, the selected radio, the scrubber, the done tick tile and the playing track's equalizer. Text uses ink-primary rather than pure white or black, so headings sit a step below full contrast.

### Secondary
- **Quality tiers** (quality-hires, quality-cd, quality-mid, quality-low; turquoise, green, amber, red). Each tier has a bright dark-mode value and a deeper, muted light-mode value. They appear only where audio quality is being shown: badges, the Fidelidex, the tier bar and dots in the scan reveal, and spine quality marks. Quality-low also serves as the inline error ink (a failed restore, a wrong password). The only other red is the system red on destructive pills.

### Tertiary
- **The banner palette.** Home samples up to four hues from the artist image (`HomePalette`). They colour the highlighted figures, the number-one ranks, the genre chart, the Fidelidex, and a soft glow behind the thrown case. A grey or missing image leaves Home monochrome. The disc and spine artwork carry their own colours sampled from the cover (`RackDisc.colors`). A blank disc has a pale iridescent pressing, which belongs to the object's material, not to the UI.

### Neutral
- **Ground** (background): window and stage background. True black in dark mode, paper grey in light mode.
- **Surface / Surface Elevated / Surface Hover**: three tonal steps used for older containers, pill toggles and press states. Each step is one notch further from the ground.
- **Ink Secondary**: subtitles, detail lines, action words on option rows.
- **Ink Tertiary**: running counts, hints ("Return to continue"), unplayed track numbers, group labels, detail under row titles. Keep it at its Theme value; the user confirmed on 2026-11-02 that it should not be raised for contrast.
- **Hairline** (divider): 0.5px row dividers in settings groups. On newer surfaces the same role is drawn as ink-primary at 10% opacity, 1px.

### Named Rules
**The One Ink Rule.** The interface has a single accent, and it is the text colour. No UI element takes a hue for emphasis. Emphasis comes from inverting the fill (ink fill with ground-coloured text).

**The Colour Means Something Rule.** A hue on screen is either a quality tier, the banner palette, or album art. Quality colours never become a general accent, and the banner palette never leaves Home.

**The Opacity Ladder Rule.** New fills and strokes are ink-primary at a fixed opacity: 5% for a resting card fill, 8% for hover or a secondary fill, 10% for a resting stroke or rule, 12% for a strong hover, 16% for an off switch track. This is what keeps one component correct on both grounds.

## Typography

**Display Font:** SF Pro (system), Heavy 800
**Body Font:** SF Pro (system), Regular to Bold
**Numerals:** SF Pro with monospaced digits (`.monospacedDigit()`), not a separate mono face

**Character:** A single family pushed to its extremes. Titles are heavy and tightly tracked, set like a record sleeve. Everything else is small, plain and quiet.

### Hierarchy
- **Display** (800, 80px, tracking -3): album, playlist and mix detail titles. These titles are the page.
- **Stage title** (800, 56 to 76px scaled to 10% of window height, tracking -4% of size, line spacing pulled in by 16% of size): onboarding's playing-track title. It is revealed word by word.
- **Headline** (800, 40px, tracking -1.4 to -1.6): tab page titles (Collection, Settings, Playlists, Home sections). Organizer, Artist and Downloads push the same treatment to 56 to 72px.
- **Lyric** (800, 50px by default and user-adjustable, tracking -1.2): the Home lyric, with italic heavy quote marks.
- **Numeral** (800, 34 to 54px, tracking -3.5% of size, monospaced digits): counters such as the Fidelidex score and track and album counts. They animate with `.numericText` content transitions.
- **Title** (700, 18 to 19px, tracking -0.3): tracklist names and radio-card titles.
- **Row title** (700, 15px): option and done-row titles. The quiet field uses 15px semibold.
- **Body lead** (400, 17px, line spacing +4): the line under a stage title, capped at 520px.
- **Body** (400, 13px): card detail text.
- **Label** (400, 12 to 12.5px): row details, running counts, hints, tier legends. Action words on rows use 12.5px semibold.
- **Button** (600, 14px): sheet and transport pills. Older pills use 13px medium.
- **Group label** (700, 11px, uppercase, kerning 1.4, ink tertiary): names a settings group or a field in an edit sheet, sitting directly above its rows.

### Named Rules
**The Heavy Title Rule.** Every page has one heavy (800) title with negative tracking proportional to its size (about -0.035 to -0.04em). Nothing else on the page competes with it in weight.

**The Counting Digits Rule.** Any number that changes or lines up in a column uses monospaced digits. Numbers that count up use the numeric-text transition.

## Layout

Native macOS windows with a 1000×650 minimum. Spacing follows the Theme scale (4 / 8 / 12 / 16 / 24 / 32). Larger surfaces add their own literal insets on the same rhythm.

- **Page tops are tall and left-aligned.** The heavy title sits at the top left, a quiet subtitle follows, then content. Nothing is centred in a card.
- **The tracklist split** (onboarding): a 372px left column holds the wordmark, the numbered tracks (74px rows, each with a scrubber along its foot) and a running count at the bottom, separated from the stage by a 1px rule at 10% ink. The stage on the right is inset 68px left and 64px right, its top set at 14.7% of window height. The body column is capped at 450px or half the stage width, and a transport row (Back, hint, pills) runs along the bottom.
- **Home top:** a 60pt wordmark with the date beside it. Below it, the lyric takes the left 54% and the thrown case sits on the right.
- **Settings groups have no box.** A group label, then rows straight on the sheet, split by 0.5px hairlines inset 16px. The stack is pulled out 16px so row text aligns with the label.
- **Stacks of choices:** option rows stack with about 10 to 12px between them, and radio cards sit side by side.

**The Left-Edge Rule.** Content hangs from a left edge, like the text on an insert. Titles, subtitles, bodies and lists share one left alignment. The rare centred element is a transient moment, such as the intro wordmark before it lifts away.

## Elevation & Depth

Interface surfaces are flat: tonal fills on the ground, with no shadows on cards, rows or pills. Depth belongs to physical things. The jewel case, the disc, artwork and rack spines are lit like objects and cast soft, low, black floor shadows. Glow is reserved for real light sources: the case's palette glow on Home, the skip laser, and the loader's optional bloom.

### Shadow Vocabulary
- **Case floor** (black 50%, radius 22, y 20): a `RackBox` resting in the scene.
- **Disc floor** (black 50%, radius 24, y 16): a `RackDisc` out of its case.
- **Taken from the shelf** (black 45%, radius 14, y 10): a case lifted off the rack.
- **Spine hover** (black 60%, radius 14, y 12): a rack spine under the pointer.
- **Thumbnail drop** (black 30%, radius 7, y 6): small covers arriving in the scan reveal.
- **Elliptical floor shadow** (radial black 50% to clear): the onboarding case's shadow, which grows as the case comes nearer.
- **Palette glow** (radial banner colour 32% to 8% to clear): behind the Home case only.

**The Objects Cast Shadows Rule.** If it isn't a physical thing (case, disc, cover, spine), it doesn't cast a shadow. Controls show state by changing fill and stroke opacity.

## Shapes

Two shape families. Controls are capsules: pills, switches, quiet buttons, tags and the scrubber fill. Containers are continuous-corner rounded rectangles that grow with size: 7px for thumbnails and segments, 10px for fields and segmented controls, 12px for icon tiles and inputs, 14px for theme tiles, 16px for option rows, 18px for radio cards. Older Theme radii (4 / 8 / 12) still cover small chrome. The physical objects keep their real geometry: square cases with crisp 1px edge highlights, and round discs with a hub and rim.

**The Continuous Corner Rule.** Every rounded rectangle uses `style: .continuous`, so corners follow the macOS squircle. A larger container gets a larger radius.

## Components

### Buttons
Tactile and plain: a capsule that dips slightly when pressed.
- **Shape:** capsule, 40px tall, 22px horizontal padding (`SheetPillStyle`).
- **Primary:** ink fill with ground-coloured text, 14px semibold. Used once per transport row (Continue, Save, Enter FLACtastic), optionally followed by a small bold SF Symbol.
- **Secondary:** ink at 8% with ink text (Cancel, Skip for now).
- **Destructive:** system red with white text, only for actions that delete permanently.
- **Press / Disabled:** scale 0.96 and 80% opacity, eased out over 0.08s. Disabled pills drop to 40% opacity.
- **Quiet text button** (`QuietTextButtonStyle`): 12px tertiary text in a 26px capsule. On hover the text turns primary and a 6% fill appears. Used for Back, "Remove cover" and other minor actions.
- **Toggle pill** (`SheetTogglePill`): 30px capsule. Off is a 14% ink outline with secondary text. On is a solid ink fill.
- **Close** (`SheetCloseButton`): a 30px circle at 7% ink (12% on hover) holding a bold 11px `xmark`. It answers Esc.

### Switches and segmented controls
- **Switch** (`FLSwitchStyle`): a 40×24 capsule. On is filled with ink and has a ground-coloured knob. Off is ink at 16% with a knob at 55%. It moves over 0.2s.
- **Pill toggle** (`FLPillToggle`): a 10px-radius surface well with a hairline stroke. The active segment is a surface-elevated 7px block that slides between segments on a spring (response 0.3, damping 0.78).

### Option rows and radio cards
- **Option row** (`OnboardingOption`): 16px continuous rectangle at 5% ink with a 10% stroke, padded 14 to 16px. It holds a 44px icon tile (12px radius, 8% ink, or solid ink when it is the prominent choice), a 15px bold title over a 12.5px tertiary detail, and an optional 12.5px semibold action word at the right. Hover raises the fill to 8%. As a drop target, the stroke becomes 1.5px solid ink. Press scales to 0.985.
- **Done row** (`OnboardingDoneRow`): the same layout with a solid ink 44px tile and a ground-coloured checkmark. It states something that is finished.
- **Radio card** (`OnboardingChoice`): 18px continuous rectangle with 20px padding. It holds a 22px SF Symbol, a 19px heavy title and a 13px secondary detail, with an 18px radio in the top-right corner. When selected, the stroke is 2px solid ink, the fill rises to 8%, and the radio ring thickens to 5.5px on the house ease.

### Inputs / Fields
- **Quiet field** (`QuietFieldStyle`): reads as plain 15px semibold text until you interact with it. Hover adds a 4.5% fill. Focus adds a 7% fill and a 12% 1px stroke, with a 10px radius, eased over 0.15s. Its 10px padding is pulled back out so the text aligns with its label.
- **Boxed field** (password): 8% ink fill with a 12px radius, used where the field has to read as a field.

### Navigation and progress
- **Tracklist** (onboarding): numbered rows. Each row shows either a 30px heavy tertiary number, a four-bar equalizer while that step is playing, or a bold check once it is done. The title is 18px bold, with the step's answer underneath in tertiary. Under every row runs a scrubber: a 1px rule at 10% ink, a 3px ink capsule fill, and a 9px playhead. The scrubber is the only progress indicator. Finished rows can be clicked to go back, and they underline on hover.

### The Jewel Case and Disc (signature)
The clear-plastic CD case (`RackBox`) is built from separately projected 3D faces (perspective m34 = -1 / (size × 3.2)): a front with the cover under layered white sheen gradients and a 1px top highlight, a designed spine, and, in onboarding, a back face that lists the steps. The disc (`RackDisc`) is printed with colours sampled from the cover and slides out of the case by a set fraction of the case's size. In onboarding, before any library exists, the insert shows the FLACtastic mark on a dark radial ground and the disc is a blank iridescent pressing. The disc spins while something is being read: 520°/s during a library scan, 300°/s while Spotify connects. Every case pose (offset, zoom, tilt, roll, turn, disc) is one animatable value, so a single animation moves the whole object.

### Brand marks and loader
- **Wordmark**: a template PNG tinted with ink-primary at any height (15 by default, 19 in the tracklist, 60 on Home, 62 in the intro).
- **BrandMark**: the menu bar glyph, in one ink.
- **BrandLoader**: the mark animated in Core Animation, in one of three styles chosen in UI for nerds or at random per launch. It sizes to the mark's height (40pt in a panel up to full screen), can add an optional bloom when it is alone on screen, and holds still under Reduce Motion. Use it for every wait instead of a system spinner.

### Motion vocabulary
- **House ease** `timingCurve(0.16, 1, 0.3, 1)` (`MotionCurve.flactastic`): arrivals, reveals, scrubber fills, the radio, case glides. Durations run 0.35 to 1.15s.
- **Exit ease** `timingCurve(0.6, 0, 0.9, 0.4)`: things leaving, such as the stage tearing off and the tracklist folding away (0.24 to 0.5s).
- **Wipe ease** `timingCurve(0.7, 0, 0.2, 1)`: the wordmark wiping on (1.1s) and the theme flood (0.9s).
- **Throw and catch:** the case flies in linearly from far right, small and tumbling, then lands on the house ease (Home also overshoots slightly back). It is caught with a jolt: a short keyframed shake of about 4px by 3px, decaying over 0.16 to 0.2s. Settling moves use springs (response 0.8 to 1.0, damping 0.6 to 0.72). Home throws once per launch; after that, the case is perfectly still.
- **CD skip** (Continue): the case spins a full extra turn toward its next mark. A 2px read laser sweeps the stage (0.42s) with a 7% light pop. The old content stutters (four linear jumps of -12, 5, -20 and -8px), then tears off sideways (x -140, skew -12°, blur 20, stretch 1.1). The finished row's scrubber runs to the end with a glow, and a sheen sweeps across that row. The new title springs in word by word from the direction of travel, and the case jolts when it lands.
- **Theme flood:** the scene is drawn twice, with the old look on top, and a circle cut out of the old look grows from the click until it covers the window. The new theme pours out of the point you clicked.
- **Word reveal:** each title word starts blurred 10px and offset, then eases into place in a 0.045 to 0.06s stagger. The detail text follows on the house ease.
- **Micro:** press 0.08 to 0.12s ease-out; hover 0.15s ease-out; selection 0.2s ease-out.
- **Reduce Motion:** every move has a still version. Pose changes become 0.15 to 0.25s ease-out fades or moves. Spins, jolts, floating, the laser, the stutter, the equalizer bounce, disc rotation, the throw and the theme flood all turn off; the theme switches instantly. The intro jumps straight to its end state, and the loader holds still.

## Do's and Don'ts

### Do:
- **Do** take every colour from `Theme` adaptive pairs and check the surface in both light and dark.
- **Do** build fills and strokes from ink-primary at the opacity ladder (5 / 8 / 10 / 12 / 16%).
- **Do** give each page one heavy 800 title with negative tracking, and keep everything else small.
- **Do** use `SheetPillStyle` for actions (one primary per row) and `QuietTextButtonStyle` for minor ones.
- **Do** use the house ease `timingCurve(0.16, 1, 0.3, 1)` for arrivals, and give every animation a Reduce Motion path.
- **Do** reuse `RackBox` / `RackDisc` whenever an album needs to appear as an object, and `BrandLoader` for waits.
- **Do** write copy that is short, warm and plain ("Files only move when you say so.", "Skipped, connect any time").

### Don't:
- **Don't** introduce a hue as a UI accent. Quality colours mean quality, and the banner palette stays on Home.
- **Don't** put shadows on controls, rows or cards. Only physical objects cast them.
- **Don't** wrap settings groups in boxes. Use a group label, hairline-split rows, and the sheet behind them.
- **Don't** put a spaced-capitals label above a page or display title. Group labels name a group of rows or a field only.
- **Don't** use system spinners, segmented pickers or switches where the app has its own (`BrandLoader`, `FLPillToggle`, `FLSwitchStyle`).
- **Don't** let the thrown case move once it has landed: one throw per launch, then completely still.
