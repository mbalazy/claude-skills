# Native apps (Swift / Objective-C, Kotlin / Java) - no Metro

Read before the first run on an app that is not React Native: an iOS app built with
Xcode alone, an Android app built with Gradle alone. The drivers (`sim-ui.sh` over
WebDriverAgent, `android-ui.sh` over UiAutomator2) work on such an app unchanged - they
read the accessibility tree of whatever is on the screen. What changes is the rig gate
and everything that talks to a JS runtime.

## Why the Metro rig check cannot work here

`rig-check.sh` and `android-rig-check.sh` write a marker into the JS entry file and read
it back from the app's log. A native app has no entry file, no Metro and no bundle: the
code IS the installed binary. Before the native mode existed, both checks stopped with
exit 2 ("entry file not found: <repo>/index.js"), which reads as a setup gap to fix -
the tempting fix (passing a source file as `--entry`) writes a line of JavaScript into
it and then waits for a Metro that will never come.

A hand-written replacement is worse than none when it compares DATES. "The installed
binary is newer than the last commit" passes after a switch to a branch whose newest
commit is older than the build, and a build directory shared by two checkouts (one
DerivedData path, one `build/`) hands one checkout's binary to the other.

## What the native mode proves

By content, never by a date (`lib/native.sh`):

1. **The tree's fingerprint** - sha256 over HEAD's tree, `git diff HEAD` and every
   untracked, not-ignored file. Same content = same fingerprint in any checkout; a
   branch switch or one edited line changes it.
2. **The artifact's hash** - sha256 over every file of the built `.app` (by relative
   path) or of the `.apk`. `simctl install` and `adb install` copy the artifact byte for
   byte, so the installed copy hashes the same as the one on disk (measured 2026-11-23:
   an iOS 26.4 simulator, a 115 MB `.app` hashed in 0.35 s; an API 36 emulator,
   `adb shell sha256sum` on `base.apk`).
3. **A live process** - after a fresh start the app's process stays alive for
   `--settle` seconds (default 5); a death is named, with the crash report when there is
   one.

`native-build.sh` records 1 and 2 for the build it made and installed;
`native-rig-check.sh` recomputes both and compares. RIG OK = the installed app is byte
for byte the build of this tree as it is right now. For a native app that is what the
Metro marker proves for JS.

The record is one file in the checkout's own git dir (`<git-dir>/simulator-verify-native`):
never committed, and a linked worktree has its own, so two worktrees sharing a build
directory or a simulator never vouch for each other's builds.

## Config

Three lines next to `bundle id` (or `android package`) in `.simulator-verify/config.md`:

```markdown
- **app type**: `native`
- **build**: `xcodebuild -workspace MyApp.xcworkspace -scheme Dev -destination 'generic/platform=iOS Simulator' -derivedDataPath /Users/alice/.cache/myapp-dd CODE_SIGNING_ALLOWED=NO build`
- **artifact**: `/Users/alice/.cache/myapp-dd/Build/Products/Dev-iphonesimulator/MyApp.app`
```

```markdown
- **app type**: `native`
- **build**: `./gradlew assembleDebug --console=plain`
- **artifact**: `app/build/outputs/apk/debug/app-debug.apk`
```

- `build` runs from the repo root through `bash -c`; it keeps its spaces and quotes (the
  value is everything between the first and the last backtick). Prefix environment it
  needs (`JAVA_HOME=... ./gradlew ...`).
- `artifact` is repo-relative or absolute; `.app` means iOS simulator, `.apk` means
  Android. An explicit `-derivedDataPath` keeps the `.app` at a path that does not move.
- The build must not write untracked, not-ignored files into the tree: the build is
  recorded only when the fingerprint is the same before and after it.

## The loop

```sh
$SV/native-build.sh                  # build, install, record (run under a timeout fit for a cold build)
$SV/rig-check.sh                     # iOS: hands over to native-rig-check.sh by itself
$SV/android-rig-check.sh             # Android: same
$SV/rig-check.sh --no-relaunch       # keep the running app and its navigation state
$SV/native-build.sh --install-only   # put the recorded build back without building
```

- After every code change: `native-build.sh`, then the rig check. Unlike JS there is no
  reload - a change reaches the app only through a build and an install.
- `--install-only` refuses unless the tree still has the recorded fingerprint AND the
  artifact on disk still hashes as recorded (another checkout's build may have
  overwritten a shared build directory).
- The Metro flags the RN checks take (`--port`, `--entry`, `--host`, `--no-jslocation`,
  `--timeout`) are accepted and ignored with a note, so a caller written for RN does not
  stop on exit 2; `--reload` means `--no-relaunch`.
- Device choice is the RN checks' rule: `--udid` / `SIM_UDID`, `--serial` /
  `ANDROID_SERIAL`, else the only booted simulator / attached device. With several, the
  one the last `native-build.sh` installed on is taken (a recorded fact, not a guess);
  otherwise exit 2 with the list.
- `native-build.sh` installs only on a simulator (iOS) or on an `adb` device (Android).
  A physical iPhone needs a signed device build - outside this mode.

## Verdicts

| verdict | what it means | do |
|---|---|---|
| RIG DEAD: no native build is recorded | nothing ties the installed app to a tree (first run, a new worktree) | `native-build.sh` |
| RIG DEAD: the tree changed since the recorded build | an edit, a new file, a branch switch | `native-build.sh` |
| RIG DEAD: the installed app is NOT this checkout's recorded build | another checkout, branch or build was installed over it | `native-build.sh --install-only`, else `native-build.sh` |
| RIG DEAD: not installed | wiped simulator, uninstalled app | `native-build.sh --install-only` |
| RIG DEAD: the app TERMINATED | it died within `--settle` s of its start: a finding about the build | read the crash it names first |
| RIG DEAD: the recorded build was never installed | `--no-install` run | `native-build.sh --install-only` |
| exit 2 | no config, not `app type: native`, no artifact line, wrong script for the platform, several devices and none identifiable | answer it and re-run |

"Which app is in front" is a note on Android, never a verdict: a system dialog (the
notification permission on the first start) legitimately covers a healthy app.

## What it does not prove

- **Git-ignored build inputs** (an ignored `Pods/`, `local.properties`, an ignored
  `.xcconfig` with keys) are outside the fingerprint: after changing one, run
  `native-build.sh` by hand.
- **Persisted state** - a logged-in session, user defaults, a database in the app's
  container - survives an install, exactly as with RN (`gotchas.md`).
- **Which backend** the build talks to is the scheme's or flavor's business; the config
  names it.

## What changes in the rest of the skill

- `rn-devtools.mjs`, `read-rn-logs.sh` and `read-rn-logs-cdp.py` need a JS runtime -
  not available. Native logs: `xcrun simctl spawn <udid> log stream --predicate
  'process == "<executable>"' --level debug` on iOS, `adb -s <serial> logcat
  --pid=$(adb -s <serial> shell pidof <package>)` on Android (crashes: `logcat -d -b
  crash`).
- IDs: on iOS `waitid` / `tapid` take the `accessibilityIdentifier`; on Android the
  resource id arrives with its package prefix (`com.example.app:id/login`) - pass it whole.
- Launch arguments for iOS go through `--launch-arg` (the check starts the app itself).
- Timing: a cold native iOS build can take 10 minutes or more, an incremental one tens of
  seconds; give `native-build.sh` its own, longer timeout than a driver call.
