# simulator-verify

Lets Claude Code check a React Native / Expo screen - or a screen of a native Swift /
Kotlin app - on a live device instead of trusting the code: an iOS simulator, an iPhone on the USB cable, an Android emulator or an Android
phone on the cable. It proves the app runs the code of your tree, drives it to the screen,
reads the accessibility tree and a screenshot, and reports PASS or a list of concrete
discrepancies.

Two ideas carry it:

- **No green rig check, no report.** A simulator happily runs different code than the
  tree under test: a JS bundle embedded at build time, a Metro serving another worktree, a
  stale binary. Every one of those gives a confident, false result. So before looking at
  anything, the skill writes a marker into the app's entry file, makes the app load JS
  again and reads the marker back from the app's log. `RIG OK` or nothing. A native app
  has no JS to mark: there the skill proves by content that the installed app is byte for
  byte the build of the tree as it is now (`references/native.md`).
- **A number instead of an opinion.** A 1-2 pt offset is a real defect that nobody sees
  at a glance. When the eye is not enough, the skill measures off a full-resolution
  screenshot or asks the app's layout, and reports the number.

`SKILL.md` is the procedure Claude follows. This file is for the person setting it up.

## How it works

```
Claude Code
 |
 |- rig-check.sh / android-rig-check.sh
 |     marker -> entry file -> Metro -> app -> app log      => RIG OK | RIG DEAD: <cause>
 |     native app: tree fingerprint + installed artifact hash (native-rig-check.sh)
 |
 |- sim-ui.sh      --HTTP-->  WebDriverAgent on the simulator / iPhone   (tree, taps, typing)
 |                 --------> xcrun simctl / devicectl                    (launch, deep link, screenshot)
 |
 |- android-ui.sh  --HTTP (adb forward)-->  UiAutomator2 server on the device   (tree, taps, typing)
 |                 --------> adb                                          (launch, deep link, screenshot)
 |
 '- rn-devtools.mjs, read-rn-logs-cdp.py
       --> Metro's debugger connection (CDP) -> the app's JS runtime
           (eval, React component tree, JS network log, console)
```

Every verification runs the same loop: **rig gate -> reach the screen in one batched
call -> observe (text first, screenshot last) -> assert -> report**. The report opens with
the rig verdict; a report without it is not a result.

What the skill does NOT do: build an RN app, start Metro, boot a simulator or an emulator.
That is the project's own tooling. A native app is the exception: `native-build.sh` runs
the build command from the config, installs the result and records which tree it is. What it does touch:

- it installs its own driver: WebDriverAgent on a simulator or iPhone, the UiAutomator2
  server on an Android device;
- the rig checks relaunch the app and put the entry file back on every exit path,
  Ctrl-C included;
- on Android the rig check writes the app's Metro host (`debug_http_host`) and, on a
  phone, an `adb reverse` rule, and leaves both set (the output prints how to remove them).

## What works where

| | iOS simulator | iPhone (USB) | Android emulator | Android phone (USB) |
|---|---|---|---|---|
| rig check | `rig-check.sh`, marker from the simulator log | `rig-check.sh --udid <phone>`, marker over Metro's CDP; cannot see an embedded bundle or the build date | `android-rig-check.sh` | `android-rig-check.sh`, Metro through `adb reverse` |
| rig check, native app (no Metro) | `rig-check.sh` -> `native-rig-check.sh` | no (a signed device build is outside `native-build.sh`) | `android-rig-check.sh` -> `native-rig-check.sh` | same as the emulator |
| driver | `sim-ui.sh` + WebDriverAgent (`wda-sim.sh ensure`) | `sim-ui.sh` + WebDriverAgent (`wda-device.sh`, an Apple team that can sign for the phone) | `android-ui.sh` + UiAutomator2 (`uia2-server.sh ensure`) | same as the emulator |
| launch arguments (`-RCT_jsLocation`) | yes | yes | no, the rig check sets the Metro host instead | no, same |
| JS console logs | `read-rn-logs-cdp.py` (RN >= 0.77), `read-rn-logs.sh` (older RN) | `read-rn-logs-cdp.py --device iPhone` | `read-rn-logs-cdp.py` | `read-rn-logs-cdp.py` |
| JS runtime (`rn-devtools.mjs`) | yes | not measured | yes | yes |
| screenshot, measuring | yes, 1 px = 1 pt | yes | yes, 1 px = 1 dp | yes |
| needs a person | - | the passcode for "Enable UI Automation", once | - | a PIN unlock, a Play Protect prompt |

**Tested on** (other versions are not blocked, only not measured; dates and numbers in
`skills/simulator-verify/references/benchmarks.md`):

- iOS: iPhone 17 and 17 Pro Max simulators, iOS 26.2; Xcode 26 and 27; an iPhone 12 on
  iOS 27; WebDriverAgent (`appium-webdriveragent`) 16.18.5, pinned.
- Android: API 34, 35 and 36 `google_apis` arm64 emulators; one Android 16 retail phone;
  UiAutomator2 server 11.2.4, pinned.
- Apps: React Native 0.83 and 0.88.1 (RN CLI), Expo SDK 58 dev-client, and a real RN 0.81.1
  app (read-only checks).

## Install

```sh
git clone https://github.com/mbalazy/claude-skills ~/repos/claude-skills
cd ~/repos/claude-skills
./install.sh                                # links the skills into ~/.claude/skills
./install.sh --project /path/to/app-repo    # also into <app-repo>/.claude/skills
```

The project link is needed only for pm-cli's executor (`pm executor doctor` looks the
runtime skill up under `<repo>/.claude/skills`). For plain Claude Code use, the user-wide
link is enough.

Requirements:

- **All platforms**: Python 3; Node >= 22.4 for `rn-devtools.mjs`, >= 23.6 for its `tree`
  and `net` commands. The two measuring scripts need Pillow and set it up themselves: on
  the first run they build a small venv at `~/.local/share/claude-skills/venv` (with `uv`
  when it is on PATH, else `python3 -m venv`), because `pip install` into a Homebrew
  Python is refused under PEP 668.
- **iOS simulator**: macOS with the **full Xcode app**, selected (`xcode-select -p`
  points inside `Xcode.app`). The command line tools alone have no `xcrun simctl`, and the
  rig check says so. WebDriverAgent is built once per machine with
  `scripts/wda-sim.sh build` (minutes, into `~/.cache/wda-device`) and installed per
  simulator with `scripts/wda-sim.sh ensure <udid> --port <port>`.
- **iPhone**: everything above, plus `iproxy` (libimobiledevice), an Apple team that can
  sign for the phone and Developer Mode on the phone
  (`skills/simulator-verify/references/device.md`).
- **Android**: the SDK's `adb` (from `$ANDROID_HOME`, PATH or `~/Library/Android/sdk`), an
  emulator from an AVD or a phone with USB debugging on, and npm for the one-time download
  of the UiAutomator2 server (`skills/simulator-verify/references/android.md`).

Then follow `skills/simulator-verify/QUICKSTART.md`: config, driver and the first
`RIG OK` on a simulator or an emulator, plus the five problems a first run meets.

## Per-repo config

Everything app-specific lives in `<app-repo>/.simulator-verify/config.md`: bundle id and
Android package, scheme, device, Metro port, screen map, known routes, deep links, which
flows send a real SMS or email, test data. The skill offers to create it from
`skills/simulator-verify/references/config-template.md` on the first run and keeps it
current as it learns screens and routes.

**Keep `.simulator-verify/` out of git** (`echo .simulator-verify/ >> .git/info/exclude`).
It fills up with real account data. A wrong value there is worse than a placeholder: the
skill trusts the file, and it asks when it meets a placeholder.

## Using it

In Claude Code, from the app repo, with the app installed and Metro running:

```
/simulator-verify the search screen shows results for "shoes" and the clear button empties the field
```

or as the last step of a feature: "check it on the simulator", "check it on the emulator",
"does it work on Android". `solo`, `batch-finish` and `developing-features` (through its
config) use it as their runtime verification step.

What comes back has this shape (an example, not a captured run):

```
Rig: RIG OK - the app is running code from /path/to/app-repo
PASS: search screen
  - reached Home -> Search by testID (Home-search), typed "shoes" with typeid (read back)
  - Search-result-1..3 present, labels match the query
  - Search-clear empties Search-input (el Search-input: value "")
```

A FAIL is an ordered list of discrepancies (element, expected vs actual, coordinates or a
screenshot path), enough for the calling flow to fix without looking again. A check the
simulator cannot prove (clipboard, share sheet or a picker filled by another app) is named
as an outstanding device check, never passed.

You can run the scripts by hand too; each prints its commands when run with no arguments:

```sh
SV=~/.claude/skills/simulator-verify/scripts
$SV/rig-check.sh                                   # from the app repo
SIM_UDID=<udid> WDA_PORT=8100 $SV/sim-ui.sh elements --names
$SV/sim-ui.sh do "relaunch com.example.app" 'waitid Home-title --timeout 60' 'tapid Home-search'
node $SV/rn-devtools.mjs tree --id Home-search --port 8081
```

## Environment variables

| variable | what it does | default |
|---|---|---|
| `SIM_UDID` | which simulator or iPhone (a phone udid switches every script to the phone) | the only booted one; with several, the scripts refuse to guess |
| `WDA_PORT` | WebDriverAgent port of that device; a port owned by another device is refused | 8100 (a phone: the port of its `iproxy` tunnel) |
| `ANDROID_SERIAL` | which Android device (`adb devices`) | the only attached one |
| `U2_PORT` | UiAutomator2 server port on the Mac | the device's existing forward, else the first free port in 8210-8229 |
| `ANDROID_PACKAGE` | package for `android-ui.sh openurl` | from `--package` |
| `WDA_VERSION`, `UIA2_VERSION` | override the pinned driver version for one run | 16.18.5, 11.2.4 |
| `WDA_DEVICE_HOME`, `UIA2_SERVER_HOME` | where the driver sources and APKs are cached | `~/.cache/wda-device`, `~/.cache/uia2-server` |
| `SIMUI_TYPE_DELAY` | per-character delay for `type` (a phone gets 0.35 s by itself) | none on a simulator |
| `SIMUI_SETTLE_SECONDS` | gap between the two reads of `elements --settled` | 2 |
| `WDA_KEEP_KEYBOARD` | `0` lets WebDriverAgent switch off the phone's Auto-Correction, as upstream does | the phone keeps its settings |

The Metro port comes from `--port` or from the config; without one, the rig checks find
the Metro whose working directory is the repo, on 8080-8110 (iOS) or 8080-8199 (Android).
Inside a pm-cli executor run the slot variables are already set:
`skills/simulator-verify/references/executor.md`.

## Scripts

All in `skills/simulator-verify/scripts/`.

**Claude calls these during a verification**

| script | what it does |
|---|---|
| `rig-check.sh`, `android-rig-check.sh` | the rig gate: `RIG OK`, `RIG DEAD: <cause>`, or exit 2 for a setup gap or an ambiguous device; a native app's config hands them over to `native-rig-check.sh` |
| `native-build.sh` | a native app: build with the config's command, install, record the tree fingerprint and the artifact hash |
| `sim-ui.sh` | iOS driver: tree, tap, type, swipe, alerts, screenshot, launch, deep links, `do` for a whole route in one call |
| `android-ui.sh` | Android driver: the same commands and exit codes, plus `button BACK` |
| `rn-devtools.mjs` | the app's JS runtime over Metro: `eval`, React component `tree`, JS `net` log |
| `read-rn-logs-cdp.py`, `read-rn-logs.sh` | the app's `console.*` output (CDP for RN >= 0.77, os_log before) |
| `measure-element.py` | how far off-centre the content of a region is, in px and pt |
| `measure-boxes.py` | an anchored overlay (popover, menu, picker) against its anchor |
| `probe-collector.py` | a local HTTP sink for instrumentation when the log channel is not usable |

**You run these once, when setting up a device**

| script | what it does |
|---|---|
| `wda-sim.sh` | WebDriverAgent on a simulator: `build` once per machine, `ensure <udid> --port <p>` per simulator, `status`, `check` |
| `wda-device.sh` | WebDriverAgent on an iPhone: `<udid> --team <id>` to bring it up, `--status` |
| `uia2-server.sh` | the UiAutomator2 server on an Android device: `ensure`, `check`, `stop`, `fetch` |

**Only when changing the skill itself**: `regress.sh`, `android-regress.sh` (the whole
driver surface on a live device, before and after a change), `simbench.sh` (tool time vs
round-trip time), and the device-free tests below. `android-lib.sh`, `android_prefs.py`,
`u2_*.py`, `wda_*.py` and `devtools/` are internals of the scripts above.

## References

`skills/simulator-verify/references/` holds the detail `SKILL.md` points to, one file per
situation:

| file | covers |
|---|---|
| `config-template.md` | the per-repo config, every section explained |
| `rig-check.md` | every iOS rig verdict, its flags, how the entry file is chosen |
| `driver.md` | `sim-ui.sh` and `rn-devtools.mjs` in depth, and why a route is one call |
| `device.md` | the iPhone on USB: what differs, the Local Network prompt, phone logs |
| `native.md` | a native app (Swift / Kotlin, no Metro): what its rig check proves, config lines, verdicts, native logs |
| `android.md` | emulator and phone: setup, rig verdicts, iOS vs Android per command, tested matrix, what is unverified |
| `wda.md` | WebDriverAgent will not start; the pinned version and how to move it |
| `measurement.md` | pixel measurement, instrumentation, reading logs and layout numbers |
| `gotchas.md` | wrong Metro, stale binary, persisted store, deep links, side effects, simulator limits |
| `benchmarks.md` | the measured numbers behind the rules, with date, hardware and versions |
| `executor.md` | running inside a pm-cli executor worker |
| `history.md` | the MCP server this skill replaced |

`skills/simulator-verify/research/` holds the dated analyses the Android support was
designed from (in Polish, as written at the time). They are history: the current truth is
in `references/`.

`skills/simulator-verify/tests/android-fixture/` is the RN screen source the Android
driver was measured against, with the steps to generate the app around it.

## Tests

The device-free suites run in about half a minute and touch nothing outside a temp dir:

```sh
cd skills/simulator-verify/scripts
./test-rig-check.sh                       # both rig checks' setup paths and the native mode, on stubs
./test-wda-diagnostics.sh                 # WebDriverAgent failure branches, on stubs
python3 -m unittest test_u2_tree test_u2_client test_android_prefs
node --test rn-devtools.test.mjs devtools/*.test.mjs
```

A change to a driver also needs its live run before and after
(`SIM_UDID=<udid> WDA_PORT=<port> ./regress.sh <outdir>`, or
`ANDROID_SERIAL=<serial> ./android-regress.sh <outdir>` with the fixture app), and a
change that could move timing a `simbench.sh` run, recorded in
`skills/simulator-verify/references/benchmarks.md`.

## License

MIT, as the rest of the repo. `scripts/devtools/vendor/argent` is Apache-2.0 (its
`LICENSE.txt` and `NOTICE` list the copied and ported files).
