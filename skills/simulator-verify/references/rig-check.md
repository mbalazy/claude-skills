# Rig check - what each verdict means

Read when `rig-check.sh` did not print `RIG OK`, or when you need its flags. The gate itself - no green rig check, no report - is stated in SKILL.md; this file is the detail behind it.

The simulator will happily run **different code than the tree you are testing** - a Release build with an embedded `main.jsbundle` that never contacts Metro, a Metro serving another worktree, a stale binary after a native upgrade, a persisted store masking the change. Every one of those looks completely normal and produces a confident, false result. The worst is silence from instrumentation, which reads as "the feature never runs" and sends you off fixing an imaginary bug.

So before observing anything, prove your code reaches the running app:

```
scripts/rig-check.sh                     # from the repo under test
scripts/rig-check.sh --reload            # keeps navigation state, needs the right --port
scripts/rig-check.sh --repo <worktree> --udid <udid> --port <n>
```

On its default trigger (terminate + launch) it starts the app with `-RCT_jsLocation localhost:<port>`, so the app comes back on the Metro serving `--repo` instead of the port baked into the binary; `--launch-arg` adds any other argument the app needs, `--no-jslocation` turns the redirect off. Without that, the check used to undo a redirect somebody had set by hand and then report `RIG DEAD` for a live rig.

**Which entry file.** `--entry`, else the config's `- **entry**: \`path\`` line, else `index.js` (an RN CLI app's bundle starts there whatever `package.json` says), else the file `package.json` `main` names (`index.ts` in Expo's TypeScript template); `android-rig-check.sh` tries `main` before `index.js`. An Expo Router app has no entry file in the repo (`main` is `expo-router/entry`, a module): the check stops with exit 2 and names the root layout to mark instead - `--entry app/_layout.tsx` or the config line. Marking the root layout is not yet measured on a real Expo Router app.

**Before any device:** a Mac whose developer directory is the command line tools runs no `simctl`, and the check says so (`RIG DEAD: xcrun simctl does not run ...` with the `xcode-select -s` that fixes it) instead of reporting no booted simulator while one is on the screen. A config it cannot read gets one line naming which of four it is: no file, no `bundle id` line, the template's placeholder still there, no value in backticks (exit 2).

It injects a unique marker as the first line of the entry file, makes the app pick JS up again, reads the marker back out of the simulator log, and always removes the marker (also on Ctrl-C). `RIG OK` = your tree reaches the app; `RIG DEAD` names the cause it could identify (no booted sim, app not installed, embedded `main.jsbundle`, a wedged Metro, no Metro serving this tree, the app terminating, or the app alive but its JS throwing while the bundle loads) and prints every listener with its working directory.

**"No marker" and "no app" are different answers.** The check watches the launched process while it waits, so an app that dies gets its own verdict within seconds instead of a 30-second silence: it reports that the app TERMINATED, and reads the reason out of the crash report that iOS wrote for the bundle during this run (e.g. `Abort trap: 6 (SIGABRT)`, with the `.ips` path). When no report exists it says so, because that means something outside killed the app rather than the app crashing. A native abort is worth one specific suspicion first: **pure JS/TS changes cannot abort natively**, so a crash right after a branch switch is a JS/native version skew - reinstall `node_modules` and rebuild before blaming the branch.

**"Alive but silent" has a name too.** When the process lives, Metro serves the tree, and the marker still never arrives, the check reads the app log for a JS throw during bundle load (imports are hoisted above the marker line, so a module that cannot load takes the marker down with it) and prints it as `js-error`. If that is a native module the JS asks for and the binary does not carry (`TurboModuleRegistry.getEnforcing(...): 'X' could not be found`), the verdict says **JS/native skew** outright and prints the evidence: when the installed binary was built, when this tree's native dependencies last changed (`ios/Podfile.lock`, `package.json`), and every newer simulator build of the same bundle id already sitting in DerivedData, with the `xcrun simctl install <udid> <app>` that swaps it in - seconds, same bundle id = upgrade in place, the data container and the logged-in session survive. Read that list before starting a 15-40 minute rebuild: on 2026-08-20 the verdict was read as "not installed", and the usable build had been on disk for a week.

**It never guesses which simulator is yours.** With several booted it resolves the sim from the Metro that serves this repo (a simulator app runs as a host process whose path carries its device UDID, so the connection identifies it); if that does not single one out it exits **2** with the booted candidates and their Metro ports, and says plainly that this is a question, not a dead rig. Answer it with `--udid` / `SIM_UDID`. Taking "the first booted one" is what made this script report `RIG DEAD` for a perfectly live rig on 2026-08-03 - a false verdict is worse than no verdict.

**The gate:** on `RIG DEAD`, fix the rig and re-run. Do not navigate, do not screenshot, do not report - and never report an observation, PASS, FAIL, or "the screen looks right", from a session whose rig check did not pass. Silence from instrumentation is never evidence about the code; it is a suspicion about the rig. Re-run the check after anything that could swap what the app runs (a rebuild, a reinstall, a branch switch, a Metro restart).

**Android emulator:** `scripts/android-rig-check.sh` is the counterpart; its verdicts and what it changes on the device (the app's Metro host pref) are in `android.md`.
