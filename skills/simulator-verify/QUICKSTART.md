# simulator-verify - first run

From a clone of this repo to the first `RIG OK`: the proof that the app on the simulator
or emulator runs the code of your tree. Everything after that - driving screens, reading
the element tree, measuring - builds on it, and the skill refuses to report anything
without it.

Requirements per platform are in the repo's README ("Install"). Below, `SV` is the
skill's scripts directory after `install.sh`:

```sh
SV=~/.claude/skills/simulator-verify/scripts     # or $CLAUDE_CONFIG_DIR/skills/...
```

## Once per app repo

1. **Link the skills into the repo** (from your clone of this repo):
   `./install.sh --project /path/to/app-repo`.
2. **Config.** In the app repo:
   ```sh
   mkdir -p .simulator-verify
   cp $SV/../references/config-template.md .simulator-verify/config.md
   echo .simulator-verify/ >> .git/info/exclude
   ```
   Fill the `bundle id` line with the dev build's id, in backticks:
   ``- **bundle id**: `com.example.app.dev` ``. For Android, fill the `android package`
   line the same way, or delete it when the package equals the bundle id. Leave a
   section you do not use as it is: a placeholder is read only by the platform it
   belongs to. The directory stays out of git because it fills up with real account
   data as you work.

## iOS simulator

3. **The app, the project's own way**: boot a simulator, install the app's Debug build,
   start Metro from the app repo (for example `npx expo run:ios` and `npx expo start`,
   or `npx react-native run-ios` and `npx react-native start`). These skills never
   build the app or start Metro.
4. **Rig check**, from the app repo: `$SV/rig-check.sh` -> `RIG OK`.
5. **WebDriverAgent**, for driving the screen: `$SV/wda-sim.sh build` once per machine
   (minutes), then per simulator `$SV/wda-sim.sh ensure <udid> --port 8100` -> `READY`
   (the udid from `xcrun simctl list devices booted`). After that:
   `SIM_UDID=<udid> WDA_PORT=8100 $SV/sim-ui.sh elements`.

## Android emulator

3. **The app, the project's own way**: start an emulator, install the debug APK, start
   Metro from the app repo.
4. **Pick the device and start the driver**: `export ANDROID_SERIAL=emulator-5554` (the
   serial from `adb devices`), then `$SV/uia2-server.sh ensure` -> `READY`. The first
   run downloads the pinned UiAutomator2 server through npm.
5. **Rig check**, from the app repo: `$SV/android-rig-check.sh` -> `RIG OK`. It points
   the app at this tree's Metro (`10.0.2.2:<port>`) and leaves it so.

## A phone on the USB cable

The same scripts, with more to set up once: an iPhone in `references/device.md`, an
Android phone in `references/android.md` ("A phone on the USB cable").

## When it is not `RIG OK`

The check prints its cause in one line; exit 2 means it could not start, exit 1
(`RIG DEAD`) that it ran and the app is not running your code. The five a first run
meets:

| It says | Do |
|---|---|
| `RIG DEAD: xcrun simctl does not run: ... command line tools` | install the Xcode app, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| the `bundle id` (or `android package`) line `is still the template's placeholder` / `has no id in backticks` / `no config` | step 2: the id in backticks, or pass `--bundle-id` / `--package` |
| `entry file not found` | the file the bundle starts from is neither `index.js` nor `package.json` `main`: pass `--entry <file>` or add ``- **entry**: `<file>` `` to the config. An Expo Router app: its root layout, as the message names it |
| `RIG DEAD: no Metro is serving <repo>` | start Metro from that directory - the check finds it by its working directory, on a port in 8080-8110 (iOS) or 8080-8199 (Android); elsewhere pass `--port` |
| `CANNOT TELL WHICH SIMULATOR IS YOURS` (exit 2), or several Android devices listed | name one: `--udid` / `SIM_UDID`, or `--serial` / `ANDROID_SERIAL` |

Every other verdict, and what to do about it: `references/rig-check.md` (iOS) and
`references/android.md` (Android).
