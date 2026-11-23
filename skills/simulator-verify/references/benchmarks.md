# Benchmarks - the numbers behind the rules

Every measurement the rules in SKILL.md and `driver.md` rest on, with its date, hardware and versions. Re-measure before changing the loop (`scripts/simbench.sh`, its header carries the reference numbers) and prove the driver unchanged with `scripts/regress.sh`.

- **`scripts/simbench.sh`** and **`scripts/regress.sh`** - only needed when changing the driver itself: `simbench.sh` separates tool time from round-trip time (its header carries the reference numbers), `regress.sh` captures the driver's whole observable surface so a change can be shown not to alter it, `test-wda-diagnostics.sh` runs the WDA failure branches and the `wda-sim.sh` gate against stubbed tools (no simulator touched).

## Round trips vs tool time (2026-08-27 and 2026-11-13/14)

Measured 2026-08-27 on an idle iPhone 17 Pro Max simulator, and it is not what it looks
like. The tools are fast: an element tree is ~1.1s (almost all of it the app answering
`/source`), a tap 0.7s, a screenshot 0.3s, `rig-check.sh` 8.6s cold or 5.7s with
`--reload`. What is slow is the **round trip**: every separate Bash call costs ~3.6s of
model time before its command even starts. A perfectly ordinary reach - relaunch, wait,
three tab taps, open a row, four tree reads to confirm each one - ran as eleven calls
took **62s, of which 36s was gaps between calls and only 26s was work**.

Those two numbers are the floor, not the rule (re-measured 2026-11-13/14 on a larger
React Native app, iPhone 17 simulator, and on 573 real calls from ten days of
transcripts): **the tree read scales with the screen** - 1.7s, 2.1s and 3.2-4.2s on three
screens of 195-248 nodes, 3.6s median on a phone - because WebDriverAgent asks the app for
the `visible` attribute of every node, one blocking accessibility query each (that
attribute alone is ~3.5s of a 4s read). And the **gap between two calls was 7.4s median**
(p90 14s), about double the 3.6s above. Both make the rules below matter more, and they
are why one element is addressed by its testID instead of through a tree read.

The same route as ONE `sim-ui.sh do ...` call took **25s**, three runs in a row, with the
fixed sleeps replaced by `waitfor`. Nothing about the simulator got faster; ten round
trips stopped existing.

## WebDriverAgent version (2026-11-17)

- **WDA version is pinned**: both `wda-sim.sh` and `wda-device.sh` fetch `appium-webdriveragent@$WDA_VERSION` (default 16.18.5; unpinned, npm hands out 17.x, which wants Node 22/24/26+). Against 16.17.10 on an iPhone 17 simulator (2026-11-17, 5 rounds each): `findElements` with 134 matches 5.5 s -> 0.44 s and with 20 matches 0.74 s -> 0.13 s; `elements`, `el`, `waitid` and `screenshot` unchanged; `regress.sh` output identical apart from session ids and `waitid` fitting one more poll into its second. A sources checkout of another version (`~/.cache/wda-device/package`) is never replaced by the scripts - they print a NOTE saying how to switch.

## Android driver (2026-11-21)

Apple Silicon Mac (M5 Pro, 64 GB), API 34/35/36 `google_apis` arm64 emulators (Pixel 9
profile, 420 dpi, scale 2.625), UiAutomator2 server 11.2.4 run without Appium, fixture app
RN 0.88.1 (RN CLI and Expo SDK 58 dev-client) and a real RN 0.81.1 app. The phase-2
measurements behind the design are in `../research/android-phase2-2026-11-20.md`.

- **Server**: `uia2-server.sh ensure` 1.6 s from scratch, 0.45 s on a running server;
  repair after an adbd restart 4.7 s; a foreign UiAutomation client refused in ~1 s.
- **Tree read**: `elements` 0.16-0.18 s on a screen with an `Animated.loop` and a
  Reanimated loop both running (raw `/source` 7 ms) - an app that never idles does not
  slow it, unlike `tapid` on iOS.
- **Default filter**: the fixture's big screen 63 nodes / 59 visible / 46 kept; the real
  app's first screen 54 / 37 / 25.
- **After a start**: focus is empty for ~0.31 s, the new app owns it from 0.36 s and its
  tree from 0.39 s; `waitid` hit only in the new window, 3/3.
- **Gestures**: double tap as W3C actions 10/10 (and `input tap` x2 10/10) on API 34/36;
  a drag held 502 ms as W3C actions, against 419 ms `draganddrop` and 40 ms `swipe`.
- **Expo dev-client relaunch** through its link: 0.5-1.3 s into the app, 3/3.
- **Coordinates**: UiA2 rects are screen coordinates; equal to `measureInWindow` with
  edge-to-edge (API 36), 24 dp apart without it (API 34 build with edge-to-edge off).
- **Transitions**: a native-stack push shows no middle frame (final rect within 0.1 s);
  1.5 s and 4 s slides and a Modal slide give `--settled` exit 3; a 2.5 s pause in the
  middle of an animation reads as settled.
- **Rig check**: the marker arrives 1-3 s after the cold start; an embedded bundle is
  found by `unzip -l` on the device in 0.03 s; an `am crash` during the wait is reported as
  TERMINATED in 8-9 s.

## Android driver on a phone (2026-11-21)

The same Mac and server, one Android 16 (API 36) retail phone on USB, `user` build,
1080x2400 at 480 dpi (scale 3.0), vendor launcher, Google permission controller; the RN
0.88.1 RN CLI fixture loading JS from a Metro through `adb reverse`.

- **`android-regress.sh` on the phone**: core 27 passed / 2 skipped in 20 s (the sha256
  case uninstalls and reinstalls both server packages), read 32 in 49 s, input 56 / 5
  skipped (lock) in 79 s, app 43 / 7 skipped in 71 s; no failure. The same four groups on
  an API 36 emulator: 162 passed in 131 s.
- **Scale**: 17 testIDs of one screen, driver rect vs JS layout: 0 dp apart at 3.0; the
  same pixels at 2.625 would be up to 108 dp off.
- **Cold start into JS** over `adb reverse`: `launch` + `waitid Home-title` 3.0 s.
- **Rig check on the phone**: marker 3 s after the cold start for RN CLI and for the Expo
  dev-client, the whole check 15-17 s; dead verdicts without a start (no listener on the
  port, `--reload` without a reverse rule, a rule leading elsewhere) in 3 s.
- **Installs** on the unlocked phone: 2-4 s, no consent dialog for the first ones; after
  about five uninstall-and-install rounds of one debug APK in 25 minutes, Play Protect asked
  to send it for a check and the install waited (killed after 180 s, not installed).
- **Locked phone** (2026-11-22, PIN keyguard, `LOCK_ON_DEVICE=1`): input group 63 passed in
  one run; `waitid` / `waitfor` with `--timeout 30` named the lock in 1 s (on the emulator
  0 s; before the race with the lock check, the first `/source` on an asleep screen hung
  10 s); `unlock` exit 1 naming the PIN; the rig check's locked verdict in 3 s. A new
  install of the 57 MB debug APK on the locked phone: 3 s, no consent dialog.

## Where the other dated numbers live

Numbers that justify one specific rule stay next to that rule, with their date:

| measurement | date, hardware / versions | file |
|---|---|---|
| `tapid` ~21 s on an app that never idles; coordinate tap 2.5 s | 2026-11-14, iPhone 17 simulator | `driver.md` (2. Observe) |
| `type` cut words 3/5 and 10/10, `typeid` exact 25/25, 1.2-1.6 s | 2026-11-14/15, iPhone 17 simulator | `driver.md` (2. Observe) |
| `displayed` agreed with the tree on 81/85/117 ids | 2026-11-13/14 | `driver.md`, `scripts/wda_el.py` header |
| fixed pauses 663 vs 101 waits, 78 of 197 min; 47% of calls silenced; 148 screenshots in 11 sessions | transcripts 2026-11-05..14 | `driver.md` (rules for the loop) |
| cold start 8-9 s; deep link 0.2 s vs 16.1 s for four taps | 2026-08-27/28, iPhone 17 Pro Max simulator | `driver.md`, `gotchas.md` |
| rig-check on a phone ~12 s; Local Network prompt accept | 2026-09-25/29, iPhone 12, iOS 27 | `device.md` |
| simulator vs device clipboard | 2026-08-14, simulator vs iPhone 12 | `gotchas.md` |
| runner copied between simulators of one runtime | 2026-09-28/29, iOS 26.2 | `wda.md` |
| reference numbers of the benchmark itself | 2026-08-27, iPhone 17 Pro Max simulator, RN 0.83 | `scripts/simbench.sh` header |
