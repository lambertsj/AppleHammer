---
name: applehammer
description: Randomly "monkey test" an iOS app in the Simulator to shake out crashes and hangs before they ship. Use this skill before an App Store submission, after landing a major UI change, when the user asks to "test", "hammer", "monkey test", "fuzz", or "stress test" their iOS app, or when they mention wanting to find crashes or unresponsive screens in a SwiftUI/UIKit app that runs in Xcode's iOS Simulator.
---

# AppleHammer

AppleHammer drives a running iOS app in the Simulator with randomized taps,
swipes, and long-presses, watches for crashes or hangs, and turns each one
into a concrete bug report — including the exact seed needed to replay the
crashing sequence.

## When to use this skill

- Before submitting a build to App Store review.
- After a significant UI change (new screen, navigation restructure, big
  refactor of view state).
- Whenever the user says something like "hammer my app", "monkey test this",
  "fuzz the UI", "stress test the app", or "find crashes in my app".

## What this skill needs from the host project

1. An Xcode project or workspace with a scheme that builds and runs in the
   iOS Simulator.
2. A UI test target (XCUITest) that the `MonkeyTests.swift` file can be added
   to. If one doesn't exist, create it (see Step 2).
3. Ideally, the host app checks for a `--uitesting` launch argument at
   startup (see "App-side hook" below). This is optional but strongly
   recommended — without it the monkey may get stuck behind a login screen
   or onboarding flow it can't complete.

## Steps

### 1. Detect the project, workspace, and scheme

- Look for a `*.xcworkspace` first, then a `*.xcodeproj`, in the repository
  root (CocoaPods/SPM-workspace projects use the workspace; plain projects
  use the `.xcodeproj` directly).
- List available schemes:
  ```
  xcodebuild -list -project <Name>.xcodeproj
  # or
  xcodebuild -list -workspace <Name>.xcworkspace
  ```
- Pick the scheme that matches the app target (not a framework/package
  scheme). If more than one plausible scheme exists, ask the user which one
  to hammer.
- List available simulators with `xcrun simctl list devices available` and
  pick an iOS 17+ iPhone runtime, preferring one already booted.

### 2. Ensure a UI test target exists

Check the scheme's targets (`xcodebuild -list`, or inspect
`project.pbxproj`/`project.yml` if the project is generated) for an existing
XCUITest target (a target whose product type is
`com.apple.product-type.bundle.ui-testing`).

- **If one exists**: reuse it. Note its name — you'll pass it to
  `scripts/run.sh -x <target>` if it isn't named `AppleHammerTests`.
- **If none exists and the project is Tuist/XcodeGen/`project.yml`-based**:
  add a new UI test target to the project manifest (product type
  `.uiTesting`, depends on the app target) and regenerate the project.
- **If none exists and the project is a hand-maintained `.xcodeproj`**:
  Xcode's own "New Target" flow for a UI test bundle isn't something
  `xcodebuild` can do from the command line. Tell the user:
  > "Your project doesn't have a UI test target yet. In Xcode: File → New →
  > Target… → UI Testing Bundle, name it `AppleHammerTests`, attach it to your
  > app's scheme, then re-run this skill."
  Do not attempt to hand-edit `project.pbxproj` to add a target unless the
  project already documents a supported way to regenerate it (as some
  projects do via a `Scripts/generate_xcodeproj.py`-style script) — a
  hand-edited target is easy to get subtly wrong and hard to debug.

### 3. Inject MonkeyTests.swift

Copy `Sources/AppleHammerTests/MonkeyTests.swift` from this skill into the
project's UI test target group/folder (e.g. `<Project>UITests/` or
`AppleHammerTests/`), so it's compiled as part of that target. If the target
uses Xcode 16 file-system-synchronized groups, dropping the file into the
folder on disk is enough — no `project.pbxproj` edit needed. Otherwise add
it to the target's "Compile Sources" build phase.

### 4. Add the app-side hook (ask the user if you can't do it yourself)

The host app should skip anything the monkey can't get past on its own —
login walls, paywalls, permission-priming screens, onboarding carousels —
when launched with the `--uitesting` argument, and load deterministic
fixture data instead of live network/auth state. Ask the user to add
something like this near app launch (SwiftUI `App` init, or
`AppDelegate.application(_:didFinishLaunchingWithOptions:)`):

```swift
if ProcessInfo.processInfo.arguments.contains("--uitesting") {
    // Skip login/onboarding, seed fixture data, disable first-run prompts.
}
```

If the user has already wired this up under a different flag, pass it via
`scripts/run.sh -a <flag>` (it's forwarded to the app as
`APPLEHAMMER_LAUNCH_ARG`, defaulting to `--uitesting`).

### 5. Run the monkey

```
scripts/run.sh -s <scheme> -d "<simulator name>" [-t <seconds>] [-e <seed>]
```

This boots the simulator if needed, builds, and runs only the `MonkeyTests`
UI test for the given duration. The seed is always printed — generated from
the current time if you didn't pass `-e`.

### 6. Parse the results and propose a fix

Run:

```
scripts/report.sh <output-dir> [seed]
```

(`<output-dir>` defaults to `.applehammer/` next to `scripts/`, printed by
`run.sh` at the end of its own output.) This prints:

- Whether a crash/hang was detected, and when.
- The action count and requested duration.
- The last ~10 actions before the crash (type, coordinates, timestamp).
- Any stack trace / fatal-error snippet found in the `xcodebuild` log.

Cross-reference the stack trace with the source file/line it names, read
that code, and propose a fix (the classic ones: a force-unwrap on state that
can legitimately be nil during a fast tap sequence, an index into an array
that raced with a mutation, a gesture handler firing on a view that's mid-
transition/already dismissed). Show the user the proposed diff before
applying it, same as any other bug fix.

### 7. Re-run with the same seed to confirm the fix

```
scripts/run.sh -s <scheme> -d "<simulator name>" -t <seconds> -e <seed>
```

Reusing the seed from the crashing run replays the *exact* same tap/swipe/
long-press sequence. If the app now survives the full duration without a
crash report being written, the fix is confirmed. If it still crashes,
`scripts/report.sh` will show the same or a new crash point — keep
iterating.

## The seed / reproduce workflow

Every run has a seed (`APPLEHAMMER_SEED`, a `UInt64`), which entirely
determines the sequence of taps, swipes, and long-presses via a seedable
SplitMix64 PRNG. This makes crashes reproducible:

- **You don't need to pass a seed to find a crash.** `scripts/run.sh`
  generates one from the current time if you omit `-e`, and always prints it
  (`APPLEHAMMER_SEED=...`) — both in its own output and in the test's stdout,
  so it's visible even in captured/piped logs.
- **To reproduce a crash**, re-run with `-e <the seed>` and the same `-t
  <duration>`. The action sequence up to the point of the crash will be
  identical (same taps, same swipes, same long-presses, same order).
- **The action log** (`.applehammer/action-log-<seed>.jsonl`) is the full,
  ordered record of every action taken that run — useful for manually
  walking through what happened even without re-running.
- **The crash report** (`.applehammer/crash-report-<seed>.json`) is written
  only when a crash/hang is detected, and already contains the last 10
  actions plus the detected reason — `scripts/report.sh` is just a
  convenient formatter for it.

## Files in this skill

```
AppleHammer/
├── SKILL.md                                 this file
├── Sources/AppleHammerTests/MonkeyTests.swift  the XCUITest monkey
└── scripts/
    ├── run.sh                                boots sim, runs xcodebuild test
    └── report.sh                             summarizes a run's output
```

## Troubleshooting

- **Monkey gets stuck on a system alert it doesn't recognize**: the
  interruption monitor taps the first button it finds on any alert it
  doesn't have a canned response for, as a last resort — if that's
  consistently wrong for a particular alert in this app, add that button's
  label near the top of the `commonButtons` list in `MonkeyTests.swift`.
- **`-only-testing:AppleHammerTests/MonkeyTests` fails to find the target**:
  the UI test target isn't named `AppleHammerTests` — pass its real name with
  `-x <target>`.
- **No crash, but the app clearly misbehaved (visual glitch, wrong screen)**:
  AppleHammer only detects hard crashes and hangs (`app.state` leaving
  `.runningForeground`, or XCTest's own hang/crash detection). Visual-only
  regressions need a human (or a screenshot-diff tool) to catch — check the
  action log around the time it happened and reproduce manually with the
  seed.
- **Every run "crashes" at action 0**: the app likely launched into a state
  the monkey can't interact with at all (e.g. a modal permission prompt
  XCUITest didn't catch in time). Increase realism of the app-side
  `--uitesting` hook (Step 4) so the app reaches an interactive screen
  before the monkey starts tapping.
