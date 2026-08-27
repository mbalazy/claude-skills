---
name: simulator-verify
description: Verify a view or feature on the live iOS simulator of a React Native / Expo app. Launches the dev build, navigates to the target screen, inspects the accessibility element tree + screenshot, and reports PASS or concrete discrepancies. Use after implementing UI, as the verification step inside a feature or bugfix flow, or when the user says "/simulator-verify", "sprawdź na symulatorze", "zweryfikuj ekran X", "czy to działa na symulatorze". Generic across RN/Expo projects; reads per-repo config from .simulator-verify/.
---

# simulator-verify

Reusable verification atom for any React Native / Expo app on the iOS simulator. Drives the live simulator to confirm a screen or feature actually renders and behaves correctly - not by guessing from code, but by observing the running app. Called standalone, or as the verify step inside a feature / bugfix flow.

The skill is generic: everything app-specific (bundle id, device, Metro port, screen map, deep links) lives in the per-repo config, never in here.

## Prerequisites

- **`scripts/rig-check.sh`** - proves the app is running the code you are testing. Run it before anything else (see Rig gate).
- **`scripts/sim-ui.sh`** - the driver for everything: observation and interaction via WebDriverAgent's HTTP API (localhost:8100), lifecycle via `xcrun simctl`. No MCP server needed. Run it with no args for the command list. It auto-starts WDA (`com.facebook.WebDriverAgentRunner.xctrunner` must be installed on the sim).
- **`scripts/simbench.sh`** and **`scripts/regress.sh`** - only needed when changing the driver itself: `simbench.sh` separates tool time from round-trip time (its header carries the reference numbers), `regress.sh` captures the driver's whole observable surface so a change can be shown not to alter it.
- The app's dev build installed on a booted simulator. If not installed / Metro down, see Cold start in `.simulator-verify/config.md`.
- **In a throwaway `git worktree`, none of this exists locally.** Both the skill directory and `.simulator-verify/` are typically git-ignored, so a fresh worktree of the same repo has neither - and no amount of re-running will create them. Call the scripts by their absolute path from wherever the skill is installed and point them at the tree under test: `<skill-dir>/scripts/rig-check.sh --repo <worktree>`. `rig-check.sh` then reads the project config from the repo's MAIN worktree by itself, so `--bundle-id` is only needed when even that has no config. For `sim-ui.sh`, export `SIM_UDID` and `WDA_PORT` - it derives nothing.
- **A simulator is named after what it serves.** With two or three booted, a model name ("iPhone 17 Pro") identifies nothing - and picking the wrong sim produces confident, false readings. The device name is the one thing visible at a glance (Simulator window title, `simctl list`, the candidate list `rig-check.sh` prints when it refuses to guess), so make it carry the answer: `xcrun simctl rename <udid> "<model> - <worktree basename>"`, run the moment a sim is built for a worktree. Treat it as a label, not as evidence - confirm by connection when a wrong answer would be expensive.

## Setup gate (first thing, every run)

Look for `<repo-root>/.simulator-verify/config.md`. It holds everything project-specific: bundle id, scheme, device, Metro port, screen map, deep links, design system pointers.

- **Missing?** Copy `references/config-template.md` to `<repo-root>/.simulator-verify/config.md`, fill what you can infer from the repo (bundle id and scheme from the iOS project / `app.config.js`, Metro port from the start script), then ask the user to confirm the bundle id and device before driving anything. Also make sure `.simulator-verify/` is git-ignored - it accumulates real account data (test users, appointments, phone numbers) that must not be committed.
- **Present?** Read it first. Keep it current: whenever you learn a new screen, deep link or gotcha, append it there rather than to this skill.

## Rig gate (second thing, every run) - no green rig check, no report

The simulator will happily run **different code than the tree you are testing** - a Release build with an embedded `main.jsbundle` that never contacts Metro, a Metro serving another worktree, a stale binary after a native upgrade, a persisted store masking the change. Every one of those looks completely normal and produces a confident, false result. The worst is silence from instrumentation, which reads as "the feature never runs" and sends you off fixing an imaginary bug.

So before observing anything, prove your code reaches the running app:

```
scripts/rig-check.sh                     # from the repo under test
scripts/rig-check.sh --reload            # keeps navigation state, needs the right --port
scripts/rig-check.sh --repo <worktree> --udid <udid> --port <n>
```

On its default trigger (terminate + launch) it starts the app with `-RCT_jsLocation localhost:<port>`, so the app comes back on the Metro serving `--repo` instead of the port baked into the binary; `--launch-arg` adds any other argument the app needs, `--no-jslocation` turns the redirect off. Without that, the check used to undo a redirect somebody had set by hand and then report `RIG DEAD` for a live rig.

It injects a unique marker as the first line of the entry file, makes the app pick JS up again, reads the marker back out of the simulator log, and always removes the marker (also on Ctrl-C). `RIG OK` = your tree reaches the app; `RIG DEAD` names the cause it could identify (no booted sim, app not installed, embedded `main.jsbundle`, a wedged Metro, no Metro serving this tree, the app terminating, or the app alive but its JS throwing while the bundle loads) and prints every listener with its working directory.

**"No marker" and "no app" are different answers.** The check watches the launched process while it waits, so an app that dies gets its own verdict within seconds instead of a 30-second silence: it reports that the app TERMINATED, and reads the reason out of the crash report that iOS wrote for the bundle during this run (e.g. `Abort trap: 6 (SIGABRT)`, with the `.ips` path). When no report exists it says so, because that means something outside killed the app rather than the app crashing. A native abort is worth one specific suspicion first: **pure JS/TS changes cannot abort natively**, so a crash right after a branch switch is a JS/native version skew - reinstall `node_modules` and rebuild before blaming the branch.

**"Alive but silent" has a name too.** When the process lives, Metro serves the tree, and the marker still never arrives, the check reads the app log for a JS throw during bundle load (imports are hoisted above the marker line, so a module that cannot load takes the marker down with it) and prints it as `js-error`. If that is a native module the JS asks for and the binary does not carry (`TurboModuleRegistry.getEnforcing(...): 'X' could not be found`), the verdict says **JS/native skew** outright and prints the evidence: when the installed binary was built, when this tree's native dependencies last changed (`ios/Podfile.lock`, `package.json`), and every newer simulator build of the same bundle id already sitting in DerivedData, with the `xcrun simctl install <udid> <app>` that swaps it in - seconds, same bundle id = upgrade in place, the data container and the logged-in session survive. Read that list before starting a 15-40 minute rebuild: on 2026-08-20 the verdict was read as "not installed", and the usable build had been on disk for a week.

**It never guesses which simulator is yours.** With several booted it resolves the sim from the Metro that serves this repo (a simulator app runs as a host process whose path carries its device UDID, so the connection identifies it); if that does not single one out it exits **2** with the booted candidates and their Metro ports, and says plainly that this is a question, not a dead rig. Answer it with `--udid` / `SIM_UDID`. Taking "the first booted one" is what made this script report `RIG DEAD` for a perfectly live rig on 2026-08-03 - a false verdict is worse than no verdict.

**The gate:** on `RIG DEAD`, fix the rig and re-run. Do not navigate, do not screenshot, do not report - and never report an observation, PASS, FAIL, or "the screen looks right", from a session whose rig check did not pass. Silence from instrumentation is never evidence about the code; it is a suspicion about the rig. Re-run the check after anything that could swap what the app runs (a rebuild, a reinstall, a branch switch, a Metro restart).

## What actually costs the time - one command per step is the bug

Measured 2026-08-27 on an idle iPhone 17 Pro Max simulator, and it is not what it looks
like. The tools are fast: an element tree is ~1.1s (almost all of it the app answering
`/source`), a tap 0.7s, a screenshot 0.3s, `rig-check.sh` 8.6s cold or 5.7s with
`--reload`. What is slow is the **round trip**: every separate Bash call costs ~3.6s of
model time before its command even starts. A perfectly ordinary reach - relaunch, wait,
three tab taps, open a row, four tree reads to confirm each one - ran as eleven calls
took **62s, of which 36s was gaps between calls and only 26s was work**.

The same route as ONE `sim-ui.sh do ...` call took **25s**, three runs in a row, with the
fixed sleeps replaced by `waitfor`. Nothing about the simulator got faster; ten round
trips stopped existing.

So the rule for this loop:

- **Batch every step whose coordinates you already know into one `do` call.** Only break
  out of the batch when the next coordinate genuinely depends on reading the last result.
- **Never a bare `sleep` after a relaunch or a tap.** `waitfor 'REGEX'` polls the tree
  and returns the moment the thing is there, and it FAILS LOUDLY when it is not - a fixed
  `sleep 5` that happens to be long enough today silently becomes a flake tomorrow.
- **A tap is not a checkpoint.** Follow it with `waitfor` on something only the new screen
  has, inside the same batch - that is what makes a batch safe to run unattended.
- **Prefer the element tree to a screenshot** when the tree can answer: ~750 bytes of text
  against an 870KB image, and a screenshot also costs you the tokens to look at it.
- **After a code change, reach for `rig-check.sh --reload` first.** It keeps the app's
  navigation state, so the whole re-navigation - the expensive part - does not happen at
  all. The default terminate+launch trigger throws the screen away and makes you drive
  back to it.

The benchmark that produced those numbers is `scripts/simbench.sh` (see its header). Re-run
it before and after touching this loop instead of guessing; `scripts/regress.sh` captures
the 16 stdout/stderr/rc cases that prove the driver still behaves identically.

## The loop

Run these phases in order. Each iteration of fix-and-recheck repeats observe -> assert.

### 0. Enumerate instances (do this FIRST for any reused / multi-instance component)

The most expensive miss is verifying ONE render site of a shared component and shipping - the bug lives in an instance you never opened. This is exactly how ACME-1164's first attempt shipped a bug to review: the search input was verified on the CLIENT step but broken on APPOINTMENT_TYPE - same `SuggestionChips` component, different layout context. The ticket title ("Select a client") anchored verification to one screen while the change touched all of them.

Before verifying, build an **instance checklist** whenever the changed component (a) lives in `src/components/`, (b) renders via a `switch` / `map` / enum, or (c) is imported by more than one screen:

- **Render sites:** `grep -rn "<ComponentName>" src/ --include=*.tsx`
- **State/variant axis:** if it switches on an enum/type (e.g. `CHIP_TYPE`), list the members; cross-reference the flow config (e.g. `FLOW_STEPS`) for which are reachable in the live app.

**Coverage rule:** verify every instance that exercises a **different code path or layout context** - NOT every data permutation. (ACME-1164: CLIENT renders avatar chips in normal flow, APPOINTMENT_TYPE renders `position:absolute` cards -> different layout context -> verify BOTH. Two appointment types with different names -> same path -> one is enough.) Instances that disable the feature (e.g. input hidden on DATE/TIME) -> mark **N/A explicitly**, never skip silently.

PASS requires every enumerated instance checked or marked N/A. For layout-sensitive sweeps, instrument once (3c) and read the frame numbers per instance instead of eyeballing each screen.

### 1. Reach
All commands below are `S=.claude/skills/simulator-verify/scripts/sim-ui.sh`. **Set `SIM_UDID`** - with more than one simulator booted the script refuses to run rather than pick one, and it checks that the WebDriverAgent answering on `WDA_PORT` really drives that device (a stranger's WDA on the port used to return the other simulator's screen without a word).
- Resolve the device: `$S devices` -> pick the booted simulator.
- Launch the app: `$S launch <bundle-id>` (the bundle id from `config.md`; foregrounds if already running). Use `$S relaunch <id>` when you changed code - it terminates first, so the sim fetches a fresh JS bundle from Metro. A cold start measured 8-9s on this app, so do not guess it: `$S waitfor '<something on the first screen>' --timeout 30` returns as soon as it is up and tells you if it never is.
- Navigate to the target screen by tapping element rects from the tree: `$S tap X Y` (tap the rect center: `x + w/2`, `y + h/2`). Prefer deep links via `$S openurl` only if the config confirms a registered scheme - and only if a probe shows the URL actually reaches JS, which is a separate question from the scheme being registered (see Gotchas).
- **Run the whole known route in one call.** Steps are this script's own subcommands; a
  step whose own arguments contain spaces needs inner quotes, a `?` prefix lets a step
  fail without aborting the batch, and `#` starts a comment:

  ```sh
  $S do "relaunch $BUNDLE -RCT_jsLocation localhost:$PORT" \
        'waitfor "Search clients" --timeout 30' \
        'tap 220 904' 'waitfor "StaticText Schedule"' \
        'tap 220 317' 'waitfor "Button Back"'
  ```

  `waitfor` matches its regex, case-insensitively, against each element's
  `type label name value` joined with spaces - which is why `'StaticText Schedule'` finds
  a screen title without also matching the tab button of the same name. It prints the
  elements it matched, so a batch leaves a readable trail of what each step reached.
- Once a route is known, write it into `config.md` next to the screen map. Re-deriving tab
  coordinates from `elements --all` is a round trip you only need to pay once per device.

### 2. Observe
- `$S elements` -> the accessibility tree as compact JSON (`rect` is `[x,y,w,h]` in pt). This is the primary signal: assert on real elements, not pixels.
- **`$S elements --all`** -> the FULL visible tree including unlabeled `Other`/container nodes. Use it whenever an element you can see isn't in the filtered tree - RN rows, glass buttons, and icon-only controls usually live there as `type:"Other"` with an exact rect (e.g. client list rows, the search-field clear button). Reach for `--all` BEFORE falling back to screenshot-and-guess coordinates.
- `$S screenshot [out.png] [--width N]` then Read the file -> visual confirmation of layout, spacing, glass surfaces, anything the tree can't express. By default the image is resampled to the device's point width (px ÷ SIMULATOR_MAINSCREEN_SCALE), so **1px == 1pt on any simulator** and coordinates read straight off the image. `--width 0` = full res (for 3b measurement).
- After any tap that should change the screen, re-run `$S elements` and confirm the content actually changed (e.g. header label flipped) - a registered click is not proof of navigation.
- Interactions: `$S tap|doubletap|longpress|swipe|type|button` (see script header for signatures). Coordinates are POINTS; a coordinate measured on a full-res screenshot must be divided by the scale first. Out-of-range coordinates are rejected rather than silently doing nothing.
- **Alerts queue and arrive late.** One read a few seconds after a tap that says "no alert" is not evidence the tap did nothing. Use `$S alert wait [seconds]` to wait for one, and `$S alert accept --all` afterwards - if it drains more alerts than you ever saw, every tap landed.
- `$S elements` is not a passive read: answering it makes `UITabBarController` instantiate every child controller, so it can mount the very screen you are testing for. Never use it to prove a screen was NOT mounted.

### 3. Assert
Check against the stated expectation:
- **Presence**: every element the feature requires is in the tree (correct label / type).
- **Behavior**: taps navigate / mutate state as intended (verified by the re-list, not assumed).
- **Visual**: screenshot matches design intent - layout, alignment, token-correct colors/spacing, no overflow or cut text.
- **No errors**: no error banner, no blank/crash screen, no red box.

### 3b. Measure (pixel-perfect bugs) - numbers, not eyeballing

When the bug is about alignment/centering/spacing of a **small** element (a label "not centered", a badge "off by a bit"), the eye is unreliable and the JPEG compounds it - a 1-2pt offset is real but invisible at a glance. Do not report "looks ok" or "looks off"; produce a **number**.

1. Full-res screenshot: `xcrun simctl io booted screenshot shot.png` (device px, e.g. iPhone @3x = 3px/pt).
2. Find the element's px region. Use the element tree coordinates (a11y coords are in pt -> x3), or crop-and-zoom (`sips -c H W --cropOffset Y X ...`) to read it off.
3. Measure with the bundled script:
   ```
   python3 .claude/skills/simulator-verify/scripts/measure-element.py shot.png \
       --region X,Y,W,H --container dark --inset 20 --scale 3
   ```
   It returns container vs inner-content center delta in px **and pt**, plus inner top/bottom padding. Negative vertical = content rides HIGH; positive = LOW.
4. **Verdict from the number**: `|delta| < ~0.5pt` = centered (PASS). `|delta| >= ~1pt` = real defect; report the exact value and the asymmetric padding (e.g. "text 1.5pt high: 2pt top vs 5pt bottom").
5. Confirm stability: re-run at 2-3 `--inset` values; a real geometric offset is constant, a measurement artifact wobbles.

After a fix, re-measure the same region and show the before/after delta (e.g. `-1.5pt -> 0.0pt`) as proof.

For elements that resist pixel detection (low contrast, anti-aliasing), prefer **layout instrumentation** (see 3c). Remove all instrumentation before committing.

### 3c. Instrument (overlap / collapse / "invisible box" bugs) - ground truth, not guesses

When a layout bug is about **where boxes actually are** (an element overlapping another, a view collapsing, something rendering "under" something else), STOP theorizing. Two throwaway techniques give you exact ground truth - both were what cracked ACME-1164 (a search input silently collapsing to 0 height, so its glass painted over the chips below it - looked like z-order, was actually a height collapse):

**1. Colored background overlays (you read these yourself from a screenshot).** Temporarily give each suspect box a translucent bg via inline `style` and screenshot it. Distinct colors = instantly see each box's real frame and any overlap:
```tsx
style={{ backgroundColor: 'rgba(255,0,0,0.35)' }}   // box A (e.g. red = input)
style={{ backgroundColor: 'rgba(0,0,255,0.35)' }}   // box B (e.g. blue = cards)
style={{ backgroundColor: 'rgba(0,255,0,0.2)' }}    // box C (e.g. green = container)
```
Crop+zoom the screenshot (`python3` + PIL, or `sips`) to compare the bands. No copy-paste from anyone needed - you see it.

**2. `onLayout` logging that you read yourself (no Metro copy-paste).** Add a throwaway logger and read the numbers straight off the simulator's system log:
```tsx
const logLayout = (tag: string) => (e: LayoutChangeEvent) => {
  const { x, y, width, height } = e.nativeEvent.layout;
  console.log(`[LAYOUT] ${tag} ${JSON.stringify({ x, y, width, height })}`);
};
// ...on each suspect box:
<Flex onLayout={logLayout('SEARCH_INPUT')} ...>
```
RN routes `console.*` to Apple os_log (`subsystem com.facebook.react.log`, `category javascript`). Read it without the user pasting anything:
```
# record time, trigger the action (reload / navigate), then read only-new logs:
set TS (date '+%Y-%m-%d %H:%M:%S'); curl -s localhost:8081/reload >/dev/null; sleep 6
.claude/skills/simulator-verify/scripts/read-rn-logs.sh --since "$TS" --grep '[LAYOUT]'
# or just grab the last N seconds:
.claude/skills/simulator-verify/scripts/read-rn-logs.sh 8
```
The `--since "$TS"` (timestamp captured before the action) is the "which logs are new" mechanism - everything older is filtered out. `--info --debug` is baked in (JS logs are INFO level; plain `log show` drops them). Gotcha: multi-arg `console.log(a, b)` prints comma-separated quoted args - prefer one template string for clean grepping. Script: `scripts/read-rn-logs.sh` (`--all` also includes native-bridge logs, `--grep` filters).

**Device selection is not the same variable as `sim-ui.sh`'s.** `read-rn-logs.sh` takes `--udid`, `$SIMCTL_DEVICE` or `$SIM_UDID`; with several simulators booted and none of them set it refuses instead of reading an arbitrary device. An empty result now prints the device and the time window it searched - read that before concluding the instrumentation never fired, because "no logs" from the wrong simulator looks identical to "the code never ran".

**RN >= 0.77 (New Architecture + Hermes): os_log is DEAD for JS logs.** Fusebox routes `console.*` exclusively to React Native DevTools over CDP - nothing reaches `com.facebook.react.log` and Metro's terminal no longer prints client logs either, so `read-rn-logs.sh` comes back empty however correct the query is (verified on RN 0.83: LogBox showed a live warning while os_log had zero lines). Use the CDP tap instead:
```
# stream console.* straight from Metro's inspector proxy (stdlib only, no deps):
scripts/read-rn-logs-cdp.py --port 8090 --seconds 10 --grep '[LAYOUT]'
```
It auto-picks the app's MAIN JS runtime (`prefersFuseboxFrontend: true`; worklet runtimes like Reanimated's UI need `--all-runtimes`), refuses to guess between devices (`--device <name-substring>`), and `Runtime.enable` makes Hermes replay its buffered console history with original timestamps - so logs from just BEFORE the tap connected still show up. One debugger per page: if React Native DevTools is attached to the same app, close it first.

Reading the numbers beats reading the pixels: in ACME-1164 the logs showed `SEARCH_INPUT height=64` on one step and `height=16` on the buggy step - that single number ended ~3 sessions of guessing. When a layout bug survives one round of eyeballing, instrument immediately; don't iterate on hunches.

**3. An HTTP probe, when the log channel is not usable.** `console.log` is only worth instrumenting if you can read it back. On a **physical device** you usually cannot: on the New Architecture with Hermes, JS logs go to the DevTools inspector rather than to anything `idevicesyslog` relays. The same problem appears on the simulator whenever the payload is large - a whole element tree or a serialized object gets truncated and line-wrapped into something you cannot parse.

Sidestep the log entirely: have the app POST its data to a collector on the Mac, where the payload arrives whole and machine-readable.
```sh
scripts/probe-collector.py            # :8099 -> /tmp/probe.log, one JSON line per request
```
It prints the URL to use from the simulator (`localhost`) and from a physical device (the Mac's LAN address, which it looks up for you). Then, in the component under test:
```tsx
fetch('http://localhost:8099', { method: 'POST', body: JSON.stringify({ tag: 'SEARCH_INPUT', ...layout }) });
// a GET works too, so the shortest probe is: fetch('http://localhost:8099/?tag=mounted')
```
Read `/tmp/probe.log` yourself. It carries any size of payload, survives a device with no readable JS log, and needs no copy-paste from the user. Remove the `fetch` before committing, exactly like the other instrumentation.

**Native logs from a physical device**, when the question is about the OS rather than about JS (audio session state, permissions, CoreAudio):
```sh
xcrun devicectl device process launch --console --terminate-existing --device <udid> <bundle-id>
```
`xcrun devicectl device console` does not exist - it fails with `Error: Unknown option '--device'`. `idevicesyslog -u <udid>` is the other channel and picks up native `NSLog` from libraries, but not RN's `console.log`.

### 3d. Reaching a state ≠ free (check side effects BEFORE driving creation flows)

Some UI states are only reachable by creating real entities, and in a real app creation flows are often **outward-facing** - they text, email or charge a real person. Before driving any create/submit flow just to reach a visual state, check what it fires; the screen's own copy usually tells you ("How do you want to send the invite?"). Record every outward-facing flow you find in `config.md` so the next session does not have to rediscover it the hard way.

If the state is driven by **local state/props** (not server data), skip the real flow entirely: temporarily hardcode the prop at the render site (e.g. `isNewUser={true}` on the screen component), `curl -s localhost:PORT/reload`, screenshot, revert, `git status` to confirm clean. Same throwaway-instrumentation discipline as 3c - and mocking the API would not even work for these states, since the data never comes from the API. Real case (ACME-1287): a "new" badge verified and pixel-sampled in one iteration, zero SMS sent.

### 3e. Anchored overlays (popover / menu / picker) - three channels, never the eye

A popover placed next to a trigger has TWO independent failure modes, and a screenshot cannot separate them: the **anchor** it was handed can be wrong, and the **offset math** applied to that anchor can be wrong. A tall popover makes a badly-anchored one still look "roughly next to" the trigger - ACME-1368's business-hours picker sat 358pt off its row and read as fine at a glance. Do not report an anchored overlay as correct from a screenshot.

Run all three channels; they must agree on the same number:

**1. Anchor-truth protocol** (catches a wrong anchor). The a11y tree is ground truth for the trigger's real screen rect:
```
$S elements --all   # BEFORE tapping: record the trigger's rect [x,y,w,h]
```
then tap it and log the anchor the overlay actually received. `delta = trigger.y - anchor.y`. **0 = correctly anchored; anything else is the bug**, and the delta itself names the cause (a delta equal to a sheet's top edge = a missing sheet-to-screen coordinate translation - inside an RN-Screens form sheet `measureInWindow` returns SHEET-relative coordinates, while an RN `Modal` positions in full-screen space).

**2. Colored boxes drawn in the overlay's own coordinate space** (makes the gap literal). Inside the overlay component, draw the anchor rect it believes in, and outline the frame it actually rendered. The outline must NOT disturb layout - use an absolutely-positioned child, never `borderWidth` on the measured view (that changes its height and corrupts channel 3):
```tsx
{/* red = the anchor as the overlay sees it */}
<View pointerEvents="none" style={{ position:'absolute', left:a.x, top:a.y, width:a.width, height:a.height,
  backgroundColor:'rgba(255,0,0,0.4)', borderWidth:1, borderColor:'red', zIndex:9998 }} />
{/* lime = the rendered frame, drawn as a fill-parent overlay so geometry is untouched */}
<View pointerEvents="none" style={{ position:'absolute', top:0,left:0,right:0,bottom:0,
  borderWidth:2, borderColor:'lime', zIndex:9999 }} />
```
Then measure the boxes instead of squinting at them (`scripts/measure-boxes.py`, full-res shot via `xcrun simctl io <udid> screenshot`): it reports each box's top/bottom/height in pt and the gap between them.

**3. `onLayout` on the popover frame** (catches an estimated-height lie). Log `renderedH` next to the `estimatedHeight` the caller passed, plus the computed `top`:
```
[FLOAT-RENDER] renderedH=303 estH=360 top=486 anchorY=866 gapAbove=77
```
A flip-above popover positioned from an over-estimated height gets a gap of `estH + offsetAbove - renderedH` - that arithmetic is where "pojawia się zbyt wysoko" complaints come from, and the number tells you the whole story.

**A/B a refactor in ONE build.** When the change is "same math, moved/parameterised", do not switch branches to compare: compute the OLD formula inline next to the new one and log `SAME_AS_LEGACY` / `DIFFERS_FROM_LEGACY`. Every real interaction then becomes a live equivalence test on real anchors, and a `DIFFERS` line on a caller you did not intend to change is the regression, caught immediately. Pair it with an exhaustive sweep unit test (sweep anchor y over the full screen × several anchor heights × each caller's config) - the sweep proves the whole domain, the logs prove the domain the device actually visits.

Remove every bit of this before committing (`git status` clean); instrument in a scratch worktree with its own Metro port so the main checkout stays untouched.

### 3f. What the simulator cannot prove (say so instead of passing)

A PASS here means "correct on the simulator". For most UI that is the whole story, but one class of behaviour genuinely does not carry over: anything whose input is produced by **another app**. The simulator has no real Notes, Photos, Mail or share extensions, so whatever you feed the app you had to synthesize on the Mac - and a synthetic input is not the same object a real source app hands over.

Measured case (ACME-1582, 2026-08-14, clipboard carrying text and an image at once):

- simulator, clipboard built on the Mac via `osascript` + `xcrun simctl pbsync`: the image pasted correctly, the text was lost;
- iPhone 12, the same clipboard copied out of Notes: a zero-length file and a grey placeholder instead of a thumbnail.

Two different bugs from one logically identical case. The likely mechanism is that a real source app can put a *promise* on the pasteboard (a lazy item provider that materializes on request) while a clipboard synthesized on the Mac always carries finished bytes - but whatever the mechanism, the observation stands on its own: the simulator did not reproduce the device's bug.

So when the feature under test consumes clipboard content, a share sheet, a document picker, a photo from the library or any other system hand-off, report the simulator result **and name the device check as still outstanding**. Do not let a green simulator run close such a ticket.

### 4. Report
- **Rig first**: state that the rig check passed (marker seen). A report without it is not a result - see the Rig gate.
- **PASS**: state what was verified and how (which elements, which navigation). If any part of it depends on input produced by another app (3f), say explicitly that the device check is still outstanding.
- **FAIL**: concrete, ordered list of discrepancies - element, expected vs actual, coordinates/screenshot reference. Enough for the calling flow to fix without re-observing.

## Fallback (WDA unavailable)

If WDA won't come up (`sim-ui.sh` errors on `ensure_wda`), read its diagnostics first: a device without a Simulator.app window cannot host the XCTest runner, and the error names that and prints the move that gives it one (`open -a Simulator --args -CurrentDeviceUDID <udid>` when Simulator.app is not running; `xcrun simctl shutdown <udid> && xcrun simctl boot <udid>` when it is - a running Simulator.app ignores `--args` but opens a window for every device booted while it runs) - that is a fix, not a fallback. Only then fall back: the visual loop still works with plain simctl:
```
xcrun simctl io booted screenshot /tmp/sv.png
```
then Read the PNG. You lose the element tree and tap control (observe-only), but screenshot + Read is enough for a visual compare loop. Lifecycle commands (`launch`/`relaunch`/`terminate`/`openurl`/`screenshot`) never need WDA. The `mobile-mcp` MCP server is the legacy path (same WDA backend, less control) - removed from the project config 2026-07-06; re-register only if a physical device ever enters the picture: `claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest`.

## Gotchas

- After a CC restart the app is often backgrounded to the iOS home screen - always `$S launch` to bring the app forward; don't assume it's foregrounded.
- Springboard icon taps are fragile (coordinates land between icons). Launch by bundle id, not by tapping the home-screen icon.
- Element rects are `[x, y, width, height]` (top-left + size). Tap the center: `x + width/2`, `y + height/2`.
- `$S launch` on a running app just foregrounds it - it does NOT fetch a fresh JS bundle. After code changes use `$S relaunch` (or `curl -s localhost:PORT/reload`).
- **Metro ports are NOT fixed.** With more than one RN project (or worktree) open, ports get taken in whatever order things started, so never assume the number in `config.md` is live - identify the owner by working directory: `lsof -ti tcp:PORT -s tcp:listen`, then `lsof -a -p PID -d cwd -Fn`. Never kill or restart a Metro belonging to another project or another session. A white screen with no elements usually means Metro isn't reachable; a redbox naming a DIFFERENT app's module means this app is talking to the wrong Metro.
- **A persisted store can mask a working fix, and no tool will warn you.** State rehydrated from an older build makes a screen render the old value, and screens that fetch only when their slice is empty never reach the fixed path at all - so the fix "does not work", and a later run can PASS for reasons unrelated to it. The rig check cannot catch this: it would have to know which value you expect. Nor does the store's file give its age away - MMKV is rewritten on every run, so its timestamp is always fresh no matter how old the values inside are (measured: store written today, binary installed the day before). The only defence is procedure - test with a value that differs from the default, and force a fresh fetch rather than trusting the first render.
- **A redbox naming a missing native module is a stale BINARY - not a broken branch, and not "not installed".** The JS comes from your tree, the binary on the sim is whatever was installed last; when a native dependency lands in the tree after that install, the app throws at load and shows nothing of yours. Before rebuilding, list simulator builds of the bundle id already in DerivedData (`rig-check.sh` does, with dates) - one built after the dependency change installs in seconds with `xcrun simctl install <udid> <path>` and keeps the data container. Only when none exists is `pod install` + one build the move. Check the bundle id you query against `config.md` first: `get_app_container` for a wrong id says "No such file or directory", which reads exactly like "not installed".
- **A Metro can wedge while still holding its port**: it keeps listening but `/status` stops answering `packager-status:running`, and the app comes up on a redbox saying no script URL was provided. Curling the full `/index.bundle` is one way to get there. `rig-check.sh` names this case explicitly ("WEDGED Metro") instead of reporting a broken build - restart that Metro.
- **An installed simulator build CAN be repointed at another Metro** - pass it as a launch argument, no rebuild:
  ```
  xcrun simctl launch <udid> <bundle-id> -RCT_jsLocation localhost:<port>
  # same thing through the driver:  $S relaunch <bundle-id> -RCT_jsLocation localhost:<port>
  ```
  `simctl` turns `-key value` launch arguments into NSUserDefaults argument-domain values, which is where `RCTBundleURLProvider` reads `RCT_jsLocation` from. It costs one launch instead of the 15-40 minutes a second build with a different `RCT_METRO_PORT` takes. Because it is the *argument* domain it is never persisted: **every** launch needs the flag again, and any plain `simctl launch` in between silently drops the app back to its baked-in port. `rig-check.sh` re-asserts it for you on its relaunch trigger.
- **The same redirect, made to stick**, for a simulator that should stay on one port for a whole session:
  ```
  xcrun simctl spawn <udid> defaults write <bundle-id> RCT_jsLocation -string "localhost:<port>"
  xcrun simctl spawn <udid> defaults delete <bundle-id> RCT_jsLocation     # back to the baked port
  ```
  This survives relaunches. Pick between the two deliberately: the launch argument leaves no residue but has to be repeated, while the written default is invisible sticky state - a later session finding the app on a port it did not choose has nothing to look at. The argument domain wins over the written default when both are present (measured: default `8090` + argument `8081` → the app loaded from 8081).
  A third route people try - editing a plist inside the installed `.app` bundle - was reported not to work in an earlier session and has not been re-tested; with these two working there is no reason to.
- **On a physical device the same flag is not reliable.** A device build carries an `ip.txt` inside its bundle holding the Mac's address (`react-native-xcode.sh` writes it only when `PLATFORM_NAME` is not a simulator - which is why a simulator build never has one). Stock `RCTBundleURLProvider` still prefers `jsLocation` over that file, but it drops `jsLocation` whenever its own packager-reachability probe fails, and an app with a custom `bundleURL()` in its AppDelegate may read `ip.txt` FIRST and overwrite `jsLocation` with it - that is what one app does when `ip.txt` lists more than one candidate. Before relying on the flag on a device, read the app's `bundleURL()`; otherwise move Metro to the address the build expects.
- **WebDriverAgent ports belong to a simulator, and the assignment changes between sessions.** Any WDA answering on `WDA_PORT` will happily serve a tree from ITS device, so a stale port number in `config.md` used to produce a confident description of the wrong screen. `sim-ui.sh` now compares the port's owning device against `SIM_UDID` (CoreSimulator runs simulated processes out of `.../Devices/<UDID>/...`, so `lsof -ti tcp:PORT` plus `ps -o command=` answers it) and refuses on a mismatch, naming the port that does serve your device. Start a runner on a free port with `SIMCTL_CHILD_USE_PORT=<port> xcrun simctl launch <udid> com.facebook.WebDriverAgentRunner.xctrunner`.
- **WDA refuses to start on a simulator that has no Simulator.app window** (`XCTest 10300, failed to background test runner`): a sim booted by `simctl boot` while Simulator.app is closed, or created fresh and never opened - building a dedicated sim alongside a slot pool puts you there by default. `sim-ui.sh` now says so when the runner does not come up (it checks Simulator.app and its window list) and prints the move that gives the device a window: `open -a Simulator --args -CurrentDeviceUDID <udid>` when Simulator.app is not running, `xcrun simctl shutdown <udid> && xcrun simctl boot <udid>` when it is (a running Simulator.app ignores `--args` - verified 2026-08-20 - but opens a window for every device booted while it runs). The booted COUNT is not a cause on its own - three windowed sims hosted WDA fine on 2026-08-20 - so the error lists the booted devices as context only.
- **A registered URL scheme is not proof `openurl` reaches JS, and the failure is silent.** Measured on this app 2026-08-27: `CFBundleURLSchemes` contained `orbit`, `xcrun simctl openurl` returned 0, `SceneDelegate` forwarded `openURLContexts` to the AppDelegate, and `Linking.addEventListener('url', ...)` still never fired - for the app's own documented debug link, for a bare `scheme://`, for anything. A `fetch` probe (3c technique 3) placed both at listener-install time and inside the handler proved it: the install probe arrived, the handler probe never did. So before building any workflow on a deep link, prove ONE link end to end with a probe; and when a deep link "does nothing", suspect the native forwarding chain rather than your URL. The consequence for this loop is real - deep links would collapse a multi-tap reach into one command, and on an app where they do not reach JS that option simply is not available.
- Glass buttons sometimes don't expose an accessibility label - if an expected button is missing from the filtered tree, check `$S elements --all` first (unlabeled controls show up as `type:"Other"` with an exact rect), then screenshot, before reporting it absent.
