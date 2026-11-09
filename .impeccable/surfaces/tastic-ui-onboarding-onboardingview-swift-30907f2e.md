---
version: 1
slug: "tastic-ui-onboarding-onboardingview-swift-30907f2e"
primary_target: "Sources/flactastic/UI/Onboarding/OnboardingView.swift"
related_targets: ["Sources/flactastic/UI/Onboarding/OnboardingSteps.swift","Sources/flactastic/UI/Onboarding/OnboardingComponents.swift"]
---

# Onboarding

Scope: the first-run flow shown before the app (OnboardingView and its steps). Mode Experience: the motion is the welcome. Replaces the current five-step stage (static cover fan, 26pt cross-fade).

Audience: listeners moving off Spotify / Apple Music setting up a local lossless library; also returning users bringing a `.flactastic` backup to a new Mac. From the interview (2026-11-09): flashy, lots of smooth motion graphics, monochrome like the rest of the app; Follow System is the default look; restore is a fork at the start (a backup carries theme, folder and the onboarding flag, so restoring after Look/Library would undo them); cinematic intro and finale; default folder `~/Music/FLACtastic`. Extras: no preference; live scan reveal (real Fidelidex score and tiers while the folder scans) folded into the Library track.

Constraints: inherit the app's world (monochrome ladder from Theme.swift, SF Pro heavy titles, SheetPillStyle pills, the rack's RackBox/RackDisc jewel case, BrandLoader for waits); light and dark first-class; every motion has a Reduce Motion version; window minimum 1000×650. Restore is applied at the finale, then FLACtastic restarts (user decision 2026-11-09: "Keep the quick restart. Advise the user that the restart is required"); the Restore summary and the last track both say a restart is needed, and the last button reads "Restart FLACtastic". Spotify sign-in is never in a backup, so Spotify follows both branches.

## Direction contract

THESIS: Setup is an album: the steps are numbered tracks down the left, and the current one plays out on the stage beside it. Refuses the centred wizard card with dots and Next.

OWN-WORLD: A CD back insert in the app's monochrome ink: heavy SF track numbers and titles with mono running times, hairline rules, the rack's jewel case and disc as the stage's object, the scrubber as the only progress bar.

STORY: Intro lands the wordmark and throws the case in; New here or Coming back rewrites the tracklist (Look, Library, Spotify / Restore, Spotify); each Continue skips to the next track; the outro throws the case into Home's banner.

FIRST VIEWPORT: Wordmark top left; tracklist 01–05 with running times down the left third; the playing track's title huge across the stage top; choices and motion below it in the right two thirds; scrubber, Back and Continue along the bottom.

FORM: Surface roll seed 18703718, mode experience, dealt 4/6/2; the user locked "The tracklist" (rank 4 of 7). Code-led. Signature move: Continue is a CD skip, the scrubber runs off its row and the stage cuts.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
