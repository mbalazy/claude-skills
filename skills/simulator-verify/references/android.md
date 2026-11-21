# Android - the emulator path

Read before the first Android run in a session, and whenever an Android command surprised you. The loop in SKILL.md is the same on both platforms: rig gate first, reach with `do`, observe text before a screenshot, assert, report. This file is what differs. The measurements behind it are in `android-phase2-2026-11-20.md` (and the phase-1 analysis `android-analysis-2026-11-20.md`); the dated numbers are collected in `benchmarks.md`.

## Setup

```sh
SV=<skill-dir>/scripts
A=$SV/android-ui.sh
export ANDROID_SERIAL=emulator-5554        # which device; `$A devices` lists them with their AVD names
$SV/uia2-server.sh ensure                  # install (pinned 11.2.4, sha256-checked), start, forward, prove: READY
$SV/android-rig-check.sh                   # from the repo under test: RIG OK / RIG DEAD: <cause>
$A do "relaunch $PKG" 'waitid Home-title --timeout 60' 'tapid Home-search' 'waitid Search-input'
```

- **Device: `ANDROID_SERIAL`** (or `--serial` on the rig check). With one device attached every script finds it; with several and none named they exit **2** with the serials and AVD names. Two emulators made from one system image answer every question identically, so the scripts never guess.
- **Server: `uia2-server.sh ensure`** before the first `android-ui.sh` call. `android-ui.sh` never starts the server itself; its errors name `ensure`. The server is the open-source appium-uiautomator2-server run WITHOUT Appium (`am instrument` + `adb forward` + HTTP). The APKs live in a host cache (`$UIA2_SERVER_HOME`, default `~/.cache/uia2-server/<version>`), never in a repo; `uia2-server.sh fetch` fills it. `check` proves without starting anything, `stop` stops the server and removes only this driver's forward. READY means a real `/source` came back within 3 s - `/status` alone says ready after an adbd restart while `/source` hangs.
- **Port: `U2_PORT`**, else the device's existing forward to `tcp:6790`, else (ensure only) the first free port in 8210-8229. A port forwarded for another device is refused (exit 2).
- **Another UiAutomation client** (Maestro, Appium, agent-device, a test runner) holds the device's one UiAutomation: `ensure` names it and refuses instead of stealing it. One driver per device, as on iOS.
- **Metro: one per emulator, each on its own port.** An emulator reaches the Mac's Metro at `10.0.2.2:<port>`; which one is the app's `debug_http_host` pref (`shared_prefs/<package>_preferences.xml`), and the rig check writes it (merging that one key, every other key kept) and leaves it set. There are no launch arguments on Android: `-RCT_jsLocation` has no counterpart, so `relaunch PACKAGE ARG` is refused.
- **Package**: `--package`, else the config's `android package` line (`references/config-template.md`), else its `bundle id` line, with the same main-worktree fallback as `rig-check.sh`. `openurl` takes `--package` or `$ANDROID_PACKAGE`.
- **Units**: every coordinate the driver prints or takes is dp (density-independent pixels, the logical unit `measureInWindow` reports): px / scale, where the scale is the screen density / 160 (2.625 on a Pixel 9 profile, 420 dpi). `screenshot` is resampled to the screen's dp width by default, so 1 px = 1 dp, as 1 px = 1 pt on iOS.
- **Expo dev-client** (an `exp+<slug>` scheme on a debuggable package): `launch` / `relaunch` and the rig check start it with its `exp+<slug>://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A<port>` link, because a plain start lands on the launcher's server list. Its FIRST start after an install covers the app with the dev menu's intro sheet - tap its Continue once.
- **Never** `adb kill-server` (other sessions' devices and forwards share one adb server), never `--no-window-animation` (it sets every animation scale to 0 while the server runs - the app then sees reduce motion - and writes 1.0 back after), and every adb call carries `-s <serial>`.

## Rig check

`android-rig-check.sh [--repo DIR] [--package PKG] [--entry FILE] [--serial S] [--port N] [--reload] [--timeout S]`. Exit 0 `RIG OK`, 1 `RIG DEAD: <cause>`, 2 ambiguous device or bad usage. The gate in SKILL.md applies unchanged.

What it does, in order: lists every listener on 8080-8199 with its working directory (this repo's Metro, another tree's, a wedged one); checks the package is installed, debuggable (`run-as`) and not waiting for install consent; reads the installed APK (`base.apk` of a split install) for an embedded `assets/index.android.bundle` and compares its sha256 with the APKs under `android/app/build/outputs/apk` (newer, older, or no local build - a note, not a failure); merges `debug_http_host = 10.0.2.2:<port>` into the prefs with the app force-stopped (`was X, now Y (left set)`); writes a marker as the first line of the entry file (`main` of `package.json`, else `index.js`), cold-starts the app, reads the marker from `logcat -s ReactNativeJS` of THAT app's pid, restores the entry file on every exit path, and cold-starts once more without the marker to leave the app on clean code. `--reload` broadcasts `<package>.RELOAD_APP_ACTION` instead of the cold start - only on an app that is already up; never during startup (a reload while the bundle loads leaves a persistent redbox).

| verdict | what it means |
|---|---|
| `RIG OK` | the marker of this tree reached the app. With an embedded bundle in the APK the note says it was not used this time |
| not installed / waiting for consent | `pm path` has no package, or Play Protect / an active install session of this package holds it (for a reinstall the PREVIOUS APK runs until a person approves) |
| not debuggable | `run-as` refused: the pref cannot be set and a release build does not load JS from Metro |
| no Metro is running / no Metro for this tree / WEDGED | nothing listens; or the listeners serve other trees (their cwd is printed); or this tree's node holds the port but `/status` is silent |
| EMBEDDED bundle | the APK carries one and the app logged that it found no Metro (or no Metro serves the tree): it runs JS frozen at build time |
| TERMINATED | the process is gone, or its crash line is in, within seconds; the exit-info reason of that process and the crash lines are printed |
| JS threw while loading / JS/native skew | the process lives, `ReactNativeJS:E` has a `runtime not ready` error; `TurboModuleRegistry.getEnforcing(...) ... could not be found` = a native module the JS needs is not in the binary - install this tree's APK |
| Expo LAUNCHER | the dev-client shows its server list instead of the app |

A phone serial is refused: a phone reaches the Mac's Metro through `adb reverse`, which the check does not set up.

## Commands: iOS vs Android

Same names, flags and exit codes as `sim-ui.sh` (0 OK, 1 the step failed, 2 bad usage or ambiguous device, 3 `elements --settled` saw a change); `android-ui.sh` with no arguments prints the list.

| command | iOS (`sim-ui.sh`) | Android (`android-ui.sh`) - what differs |
|---|---|---|
| `elements [--all] [--grep] [--names]` | WDA `/source`, type filter | UiA2 `/source` XML: id = resource-id (the testID), type = class, label = text or content-desc. Default filter keeps a node with an id, text or content-desc, or a clickable Button / EditText / Switch / CheckBox; `--all` = every visible node. Off-screen rows have NO node at all (iOS: `displayed:false`). Only the focused window: a permission dialog hides the app's tree, and the output says so |
| `elements --settled` | two reads 2 s apart, exit 3 if they differ | same rule, `$SIMUI_SETTLE_SECONDS` (2). A pause longer than the gap in the middle of an animation reads as settled |
| `waitid ID [--timeout] [--exists]` | polls WDA find | polls one `/source` snapshot: hit = displayed, inside the screen, in the focused app's window. `--exists` cannot tell "scrolled out of a list" from "absent" |
| `el ID` | type/label/value/rect | adds `checked` (Switch, CheckBox) and `hint`: an empty TextInput reports its placeholder as text, `hint: true` says the real value is empty |
| `tapid ID` | taps the hittable element | taps the one element `waitid` would accept; refused when none, or two apart. No occlusion detection on either platform |
| `typeid ID TEXT [--append] [--expect]` | types per character, reads back | sets the whole text at once (one `onChangeText`), reads back until two reads 0.25 s apart agree (a mask re-renders a frame later). A trailing newline is Return, pressed after the read-back; a literal backslash-n in the text is refused (the server would press Enter early) |
| `type TEXT` | keys to the focused element | sets the focused field's text, APPENDED at its end (not at the cursor); exit 1 when nothing has focus. Unicode works; `adb shell input text` would not |
| `tap`, `doubletap`, `longpress`, `swipe`, `drag` | points | dp; doubletap and drag are W3C pointer actions (a held drag needs the hold) |
| `button HOME\|ENTER\|VOLUME_*` | WDA | key events; plus `BACK`, Android's system back (closes a Modal; on a root screen it sends the app to the background, the process lives) |
| `lock \| unlock \| locked` | WDA | sleep / wake + dismiss keyguard; no PIN (a phone with a PIN cannot be unlocked) |
| `foreground` | active app | package, pid, activity of the task in front; a system window holding focus (permission dialog, chooser, browser) is named on a `focus:` line |
| `launch / relaunch / terminate PACKAGE` | simctl | `am start` / force-stop + start / force-stop. No launch arguments. Expo dev-client through its link. `terminate` of an app not running = exit 1 |
| `activate PACKAGE` | WDA activate | to the front without a restart (same pid) |
| `openurl URL [--package]` | simctl openurl | always INTO a package (else two apps with the scheme raise the chooser); `am start` exits 0 on its own errors, so its output is parsed. A link sent while the JS bundle is still loading is lost: `waitid` first |
| `orientation` | WDA | PORTRAIT / LANDSCAPE from the current screen size |
| `alert [buttons\|wait\|accept\|dismiss] [--all]` | WDA alerts | system windows only (permission dialog, app chooser, Play Protect, an unknown system window names itself). An app's own `Alert.alert` is part of its window: `elements` / `tapid`. Play Protect is named, never answered |
| `screenshot [OUT] [--width N]` | simctl io, in pt | `screencap`, resampled to the dp width; `--width 0` = full resolution |
| `devices`, `wait`, `do`, `waitfor` | | same; `devices` prints serial, AVD name, state. A failed `do` prints the front app and the visible labelled elements |
| `session` | (none) | the UiAutomator2 session every command reuses, with its two settings (a new session resets them) |

The JS-side tools need no Android variant: `rn-devtools.mjs` and `read-rn-logs-cdp.py` work through Metro's inspector. With two emulators on one image their `/json/list` entries look identical - pick the target by Metro port, one Metro per emulator.

## Tested matrix

Tested: API 34, 35 and 36 `google_apis` arm64-v8a emulators (Pixel 9 profile, 1080x2424, 420 dpi) on Apple Silicon; React Native 0.88.1 (RN CLI and Expo SDK 58 dev-client) and a real RN 0.81.1 app (read-only, its embedded-bundle and prefs checks); UiAutomator2 server 11.2.4. Other versions are not blocked - they are simply not measured.

**Physical phone: not tested yet.** The first install needs a human (Play Protect), so does an unlock with a PIN; the rig check refuses a non-emulator serial until the `adb reverse` path is built and measured.

## Unverified

Implemented or documented, not proven on a device:

- "Change Bundle Location" in the RN dev menu: whether it persists (the code says it uses the same pref setter).
- Expo `<scheme>://?__expo_url=...` (only `exp+<slug>://expo-development-client/?url=` is measured).
- BACK with `targetSdk` 35 on API 36 (measured with `targetSdk` 36 on API 34/35/36).
- Rotation of the app itself: `orientation` reads the screen size; a rotated layout was not measured.
- Telling emulators apart with a `-prop qemu.<tag>` label (`emu avd name` works and suffices).
- A real photo picker selection (only MediaStore indexing was checked).
- Pixel tolerance of measurements at the non-integer scale 2.625 (two measurements only).
- Process names of Maestro and agent-device in `ps` (the foreign-client check matches package names).
- The consent-pending verdict (only happens on a phone), and the allow-all / allow-always permission buttons (their ids are from the AOSP source, not seen on a device).
- The phone as a whole: `adb reverse` JS loading, the Expo dev-client over `localhost`, the scale read from the device.

Measured since the phase-2 report: double tap and drag (W3C actions, 10/10), type into the focused field, split installs (`base.apk` carries the bundle and the sha), a window without edge-to-edge (UiA2 rects are screen coordinates: 24 dp below `measureInWindow` without edge-to-edge, equal with it), longer transitions (a native-stack push shows no middle frame; 1.5 s and 4 s slides give `--settled` exit 3), the prefs merge on the real app (its keys survive), and where the local APK lives for the binary-age note (`android/app/build/outputs/apk`).

## Pitfalls

- `am start` and `uiautomator dump` exit 0 on their own errors: parse the output.
- `adb shell` joins its arguments and runs them in the device shell: quote every argument (`&` in a URL ends the command), and pass a `date` format with a space as one string. It also eats stdin: `</dev/null` inside `while read` loops.
- `X | grep -q` under `pipefail` is false when grep matches early (X dies of SIGPIPE): read the output into a variable first.
- logcat is the whole device's: filter by the app's pid, or another app on the same Metro answers for it (Fast Refresh re-runs the entry file in every app connected to that Metro).
- The prefs file must be read whole, merged on the host and written back with the app stopped: a `cat F | ... > F` pipeline truncates it first (0 bytes), and a live process writes its own copy back. A leftover `.bak` is what the app loads.
- `pm revoke` kills the app; `pm clear` deletes the host pref with the rest of its data.
- Metro's `/reload` reaches only the app in front. A Metro started with `CI=1` has no file watcher, so a changed file (the rig marker) never reaches the bundle.
- A deep link sent while the JS is still loading is lost.
- A new UiAutomator2 session resets its settings; the driver reuses one session (`session` shows it).
- `/status` of the server lies after an adbd restart: health is a real `/source`.
- An external browser, a Custom Tab or a document picker takes the foreground: `foreground` names it, `alert` does not treat it as a dialog.
- The emulator's network process (`netsimd`) is shared, so `lsof` does not say which emulator talks to which Metro: the device comes from the serial, the port from the tree.
- During the first ~0.4 s after a start the tree still belongs to the app underneath; `waitid` only hits in the focused app's window.
