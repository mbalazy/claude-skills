---
name: simulator-verify
description: Verify a view or feature on the live iOS simulator - or on a physical iPhone over USB, driven by the same scripts - of a React Native / Expo app (iOS only, no Android). Launches the dev build, navigates to the target screen, inspects the accessibility element tree + screenshot, and reports PASS or concrete discrepancies. Use after implementing UI, as the verification step inside a feature or bugfix flow, or when the user says "/simulator-verify", "sprawdź na symulatorze", "sprawdź na telefonie", "zweryfikuj ekran X", "czy to działa na symulatorze". Generic across RN/Expo projects; reads per-repo config from .simulator-verify/.
---

# simulator-verify

Reusable verification atom for any React Native / Expo app on the iOS simulator (iOS only - there is no Android path). Confirms a screen or feature renders and behaves correctly by observing the running app, not by reading code. Called standalone, or as the verify step inside a feature / bugfix flow.

The skill is generic: everything app-specific (bundle id, device, Metro port, screen map, deep links) lives in the per-repo config, never in here.

## Scripts and where they live

`<skill-dir>` is the directory holding this SKILL.md (user-wide `~/.claude/skills/simulator-verify` or a project's `.claude/skills/simulator-verify`). Every command below uses

```sh
SV=<skill-dir>/scripts      # absolute path; works from any cwd and any worktree
S=$SV/sim-ui.sh
```

| script | what for |
|---|---|
| `$SV/rig-check.sh` | proves the app runs the code you are testing (Rig gate) |
| `$SV/sim-ui.sh` | the driver (WebDriverAgent + `simctl` / `devicectl`); no args = command list |
| `$SV/rn-devtools.mjs` | the app's JS runtime: eval, React component tree, JS network log |
| `$SV/wda-sim.sh` | WebDriverAgent on a simulator (`ensure <udid> --port <p>` = install + start + proof) |
| `$SV/wda-device.sh` | WebDriverAgent on a physical iPhone over USB |
| `$SV/read-rn-logs-cdp.py`, `$SV/read-rn-logs.sh` | JS console logs (CDP for RN >= 0.77, os_log before) |
| `$SV/measure-*.py`, `$SV/probe-collector.py` | pixel measurement and instrumentation |
| `$SV/simbench.sh`, `$SV/regress.sh`, `$SV/test-wda-diagnostics.sh` | only when changing the driver itself |

The Metro port and the bundle id always come from `.simulator-verify/config.md` (`$PORT`, `$BUNDLE` below) - never from an example in this skill.

## Setup gate (first thing, every run)

Look for `<repo-root>/.simulator-verify/config.md`. It holds everything project-specific: bundle id, scheme, device, Metro port, screen map, deep links, design system pointers.

- **Missing?** Copy `references/config-template.md` to `<repo-root>/.simulator-verify/config.md`, fill what you can infer from the repo (bundle id and scheme from the iOS project / `app.config.js`, Metro port from the start script), then ask the user to confirm the bundle id and device before driving anything. Also make sure `.simulator-verify/` is git-ignored - it accumulates real account data (test users, appointments, phone numbers) that must not be committed.
- **Present?** Read it first. Keep it current: whenever you learn a new screen, deep link, route or gotcha, append it there rather than to this skill.
- The app's dev build must be installed on a booted simulator; if it is not, or Metro is down, follow Cold start in `config.md`.

## Rig gate (second thing, every run) - no green rig check, no report

The simulator will happily run **different code than the tree you are testing** (an embedded `main.jsbundle`, a Metro serving another worktree, a stale binary, a persisted store) and every one of those produces a confident, false result. So before observing anything, prove your code reaches the running app:

```sh
$SV/rig-check.sh                                    # from the repo under test
$SV/rig-check.sh --reload                           # after a code change: keeps navigation state, needs the right --port
$SV/rig-check.sh --repo <worktree> --udid <udid> --port <n>
```

- `RIG OK` = your tree reaches the app. `RIG DEAD` names the cause it found (no sim, app not installed, embedded bundle, wedged Metro, no Metro for this tree, app terminated, JS throwing at load, JS/native skew) - read it before rebuilding anything.
- Exit **2** is a question, not a dead rig: several simulators booted and none identifiable. Answer with `--udid` / `SIM_UDID`.
- **The gate:** on `RIG DEAD` fix the rig and re-run. Do not navigate, do not screenshot, do not report - never report an observation, PASS, FAIL or "the screen looks right" from a session whose rig check did not pass. Silence from instrumentation is a suspicion about the rig, never evidence about the code.
- Re-run it after anything that could swap what the app runs: a rebuild, a reinstall, a branch switch, a Metro restart.

What each verdict means: `references/rig-check.md`; the Metro, binary and store causes behind them: `references/gotchas.md`.

**One driver at a time.** WebDriverAgent holds one session per simulator and Metro lets one debugger hold an app: two sessions on one simulator take turns, they do not overlap (nothing locks this - see `references/driver.md`).

**Simulator or phone.** A physical iPhone on the USB cable is the same loop with the same scripts: put its udid in `SIM_UDID`. Read `references/device.md` before the first phone run.

## The loop

Run these phases in order. Each iteration of fix-and-recheck repeats observe -> assert.

### 0. Enumerate instances (FIRST for any reused / multi-instance component)

The most expensive miss is verifying ONE render site of a shared component - the bug lives in an instance you never opened. When the changed component lives in a shared components directory, renders via a `switch` / `map` / enum, or is imported by more than one screen, build an **instance checklist**: render sites (`grep -rn "<ComponentName>" src/`) and the variant axis (enum members the live flow can reach).

Verify every instance with a **different code path or layout context** - not every data permutation. Instances that disable the feature are marked **N/A explicitly**, never skipped silently. PASS requires every enumerated instance checked or N/A. For layout sweeps, instrument once (`references/measurement.md`) and read the numbers per instance.

### 1. Reach

- **Set `SIM_UDID`** (and `WDA_PORT` when not the default): with several simulators booted the driver refuses to pick one, and it refuses a WebDriverAgent port that belongs to another device. `$S devices` lists the booted ones.
- Launch by bundle id: `$S launch $BUNDLE` (foregrounds only); `$S relaunch $BUNDLE` after a code change. Never tap a home-screen icon.
- Navigate with `$S tapid ID` where the control has a testID, else `$S tap X Y` at the centre of its rect (points). Deep links via `$S openurl` only when `config.md` confirms the scheme AND one link was proven to reach JS (`references/gotchas.md`).
- **Run the whole known route in ONE `do` call** - every separate call costs a model round trip, most of a verification's time:

  ```sh
  $S do "relaunch $BUNDLE -RCT_jsLocation localhost:$PORT" \
        'waitid Home-title --timeout 60' \
        'tapid Home-search' 'waitid Search-input' \
        'typeid Search-input shoes' 'button ENTER' \
        'waitid Search-result-1 --timeout 30'
  ```

  `?step` may fail without aborting, `#` starts a comment, a step whose arguments contain spaces needs inner quotes. A batch stops at the first failing step and exits non-zero. Command reference and traps: `references/driver.md`.
- Once a route is known, write it into `config.md` next to the screen map.

### 2. Observe - text first, screenshot last

- **Never a bare `sleep` after a relaunch or a tap.** `waitid ID` (or `waitfor 'REGEX'` without a testID) returns the moment the thing is there and FAILS LOUDLY when it is not. `wait N` only when the pause IS the test.
- **A tap is not a checkpoint.** Follow it with `waitid` / `waitfor` on something only the new screen has, inside the same batch.
- **When the app has testIDs, wait, tap and type by testID** (`waitid`, `tapid`, `el`, `typeid`). Type with `typeid` - it reads the field back and fails on any difference; `type` reports "typed" whatever reached the field.
- **Never silence the driver** (no `2>/dev/null`, no `>/dev/null`): stderr carries refused taps and timed-out waits. Filter with `elements --grep` / `--names`; check the exit code of every step outside a batch.
- **No raw `curl` to WebDriverAgent** when the driver has the command.
- **After a failed batch, read what it printed** (front app + visible labelled elements) instead of spending a call on `elements` or a screenshot.
- **Prefer text to a screenshot** whenever text can answer: ~750 bytes against an ~870KB image, and every screenshot costs ~8 s of looking at it (`references/benchmarks.md`). Pick the cheapest command that answers the question:

  | question | command |
  |---|---|
  | is X on screen now / did the tap get there | `waitid X` (in the same batch as the tap) |
  | what does X say, what is in the field | `el X` |
  | what is on this screen, which ids | `elements --names` (`--all` for unlabelled containers) |
  | did the screen stop moving | `elements --settled` |
  | which app is in front | `foreground` |
  | which React component renders testID X | `node $SV/rn-devtools.mjs tree --id X` |
  | what a store, global or flag holds | `node $SV/rn-devtools.mjs eval EXPR` |
  | which requests the JS sent | `node $SV/rn-devtools.mjs net start` ... `net read` |
  | how does it LOOK - layout, spacing, colour, clipping | `screenshot`, and only then |

- An element you can see but the filtered tree lacks: `elements --all` - RN rows, pressables, glass and icon-only buttons usually live there as `type: "Other"` with an exact rect.
- One read right after a tap is a frame of an animation: assert transitions with `elements --settled` (two reads that agree).
- `elements` is not a passive read: answering it makes `UITabBarController` instantiate every child controller, so it can mount the very screen you test for. Never use it to prove a screen was NOT mounted (an element missing from a mounted screen is fine to read from it).

### 3. Assert

Check against the stated expectation:
- **Presence**: every element the feature requires is in the tree (correct label / type).
- **Behavior**: taps navigate / mutate state as intended - verified by a re-read, not assumed.
- **Visual**: screenshot matches design intent - layout, alignment, token-correct colors/spacing, no overflow or cut text.
- **No errors**: no error banner, no blank/crash screen, no red box.

When the eye is not enough, read the reference before reporting:
- alignment off by a point or two, overlap, collapse, a popover next to its trigger -> `references/measurement.md` (a number, never "looks ok"; never an anchored overlay from a screenshot alone);
- a state that is only reachable by creating real data, sending a code or paying -> `references/gotchas.md` "Reaching a state" (check what the flow fires and which backend the BUILD talks to first);
- input produced by **another app** (clipboard, share sheet, document or photo picker) -> the simulator cannot prove it: report the simulator result AND name the device check as outstanding (`references/gotchas.md` "What the simulator cannot prove").

Every bit of instrumentation (overlays, logs, hardcoded props, probes) comes out before the commit; `git status` clean.

### 4. Report

- **Rig first**: state that the rig check passed (marker seen). A report without it is not a result.
- **PASS**: what was verified and how (which elements, which navigation, which instances). If any part depends on input produced by another app, say the device check is still outstanding.
- **FAIL**: concrete, ordered list of discrepancies - element, expected vs actual, coordinates / screenshot reference. Enough for the calling flow to fix without re-observing.

## Fallback (WDA unavailable)

If WebDriverAgent will not come up, read the driver's diagnostics first - they are a fix, not a fallback (an install command, or `$SV/wda-sim.sh ensure <udid> --port <p>`; on a phone `$SV/wda-device.sh <udid> --status`). Only then fall back to observe-only: `$S screenshot /tmp/sv.png` (or `xcrun simctl io booted screenshot`) and Read the PNG. Lifecycle commands (`launch`, `relaunch`, `terminate`, `openurl`, `screenshot`) never need WDA. Details: `references/wda.md`.

## References - read when...

| file | read when |
|---|---|
| `references/config-template.md` | creating `.simulator-verify/config.md` |
| `references/rig-check.md` | a rig check is not `RIG OK`, or you need its flags (`--launch-arg`, `--no-jslocation`, `--host`) |
| `references/driver.md` | before your first batch in a session; a command surprised you; `rn-devtools.mjs` |
| `references/device.md` | the target is a physical iPhone |
| `references/wda.md` | WebDriverAgent will not start, a new simulator, the pinned WDA version, updating WDA |
| `references/measurement.md` | pixel-level alignment, overlap / collapse, anchored overlays, reading logs and layout numbers out of the app |
| `references/gotchas.md` | a result surprised you; wrong Metro, stale binary, persisted store, deep links, typing traps, side effects, simulator limits |
| `references/executor.md` | (optional) you run inside a `pm run-epic` / `pm work` executor worker |
| `references/benchmarks.md` | the measured numbers behind the rules (dates, hardware, versions); before changing the driver |
| `references/history.md` | an old note mentions `mobile-mcp` |
