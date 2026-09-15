# SimHammer

SimHammer is a monkey-testing agent skill for iOS apps. Point it at your app
running in the Simulator and it taps, swipes, and long-presses random points
on screen for however long you like, watching for crashes and hangs. When it
finds one, it hands you back the exact tap sequence that caused it — and a
seed you can replay to confirm your fix actually works.

## Why this exists

Scripted UI tests only exercise the paths you thought to write a test for.
App Review doesn't care which paths you thought of — a crash on a screen
you didn't test is still a crash, and it's still a rejection (or, worse, a
1-star review from a real user who hit it in the wild). Monkey testing is
cheap, dumb, and good at exactly the thing scripted tests are bad at:
finding the tap sequence nobody wrote a test for, in the ten minutes before
you archive a build.

For a solo or small-team indie dev, that's the whole pitch: you don't have
a QA team clicking through every screen combination before each release.
SimHammer is a rough stand-in for one, driven by an AI coding agent that can
also read the crash it finds and propose the fix.

## What you get

- A reproducible, seeded random tap/swipe/long-press sequence — not
  flaky, one-off fuzzing you can't replay.
- An action log of every interaction, so a crash traces back to exactly
  what caused it.
- Automatic dismissal of system alerts (permission prompts, notification
  opt-ins) so the monkey doesn't get stuck immediately.
- A crash report with the last ~10 actions before the crash and a stack
  trace snippet, formatted by `scripts/report.sh`.
- A workflow built for an AI coding agent: run → crash found → agent reads
  the stack trace and proposes a fix → re-run with the same seed to confirm.

## Install

Clone this repo, or copy the `SimHammer/` directory into your project (or
wherever your coding agent's skills live):

```bash
git clone https://github.com/lambertsj/AppleHammer.git
cp -r AppleHammer/SimHammer /path/to/your/project/.claude/skills/SimHammer
```

If you're using a skills.sh-style installer:

```bash
npx skills add SimHammer
```

Either way, an agent with the skill available will pick it up automatically
when you ask it to test, hammer, or monkey-test your app — see
[`SimHammer/SKILL.md`](SimHammer/SKILL.md) for the full trigger list and the
steps it follows.

## Quick start

Once `SimHammer/MonkeyTests.swift` is added to a UI test target in your
project (see `SKILL.md` Steps 2–3 — most of this is meant to be done by your
coding agent, but you can run it by hand too):

```bash
cd SimHammer
scripts/run.sh -s YourAppScheme -d "iPhone 15"
```

That boots the simulator, hammers your app for 60 seconds, and prints the
seed it used. If it finds a crash:

```bash
scripts/report.sh .simhammer
```

prints a summary: seed, duration, how many actions ran, the crash point,
the last several actions leading up to it, and any stack trace found. Fix
the bug, then confirm it with the exact same sequence:

```bash
scripts/run.sh -s YourAppScheme -d "iPhone 15" -e <the seed from before>
```

No crash report on the re-run means the fix holds.

## Requirements

- Xcode 15+ / Swift 5.9+, targeting iOS 17+ Simulator runtimes.
- A scheme that builds and runs your app in the Simulator.
- A UI test target for `MonkeyTests.swift` to live in (SimHammer's skill
  workflow will create one or walk you through adding it if you don't have
  one yet).
- No third-party dependencies — `MonkeyTests.swift` uses only `XCTest`,
  `Foundation`, and `CoreGraphics`.

## Recommended: the `--uitesting` launch hook

SimHammer works better if your app can tell it's being hammered and skip
anything a monkey can't get through on its own (login, paywalls,
onboarding). Add this near app launch:

```swift
if ProcessInfo.processInfo.arguments.contains("--uitesting") {
    // skip login/onboarding, load fixture data, disable first-run prompts
}
```

This is optional, but without it the monkey may spend its entire run stuck
on your first screen. See `SKILL.md` for details.
