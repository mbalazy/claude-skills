# Benchmarks - the numbers behind the rules

Every measurement the rules in SKILL.md and `driver.md` rest on, with its date, hardware and versions. Re-measure before changing the loop (`scripts/simbench.sh`, its header carries the reference numbers) and prove the driver unchanged with `scripts/regress.sh`.

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
