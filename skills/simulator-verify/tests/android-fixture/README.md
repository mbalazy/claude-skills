# Android test fixture

The screen source the Android driver (`scripts/android-ui.sh`) and the Android rig check
were measured and tested against. Only the source files live here; the app around
them is generated, because a generated RN project is ~1 GB of `node_modules`, Gradle
output and native folders that would be stale the day after it was committed.

- `App.tsx` - every screen answers one question about the driver (components, inputs,
  list, anim, back, perm, big, badge, network ...). Navigate with the `Nav-<screen>`
  buttons or a deep link `<scheme>://screen/<name>`.
- `rigswitch.ts` - switches for rig experiments (throw at load, a missing TurboModule,
  the network probe port). Imported FIRST by the entry file.
- `navstack.tsx` - an optional react-navigation variant (one native-stack push), used
  only by the variant build described under the RN CLI app.

The same two files serve both apps below. The versions are the tested ones; the project
generator commands are the standard ones for those versions (the original runs did not
record them verbatim), while the edits listed after them and the build commands are
exactly what the tested apps carry.

## RN CLI app (`com.example.svcli`, scheme `svp2cli`, Metro :8121)

Tested with React Native 0.88.1, `@react-native-community/cli` 20.2.0.

```sh
npx @react-native-community/cli@20.2.0 init SvCli --version 0.88.1 \
  --package-name com.example.svcli --directory f-cli --skip-git-init
cd f-cli
npm install react-native-reanimated@4.7.1 react-native-worklets@0.13.0
cp <this dir>/App.tsx <this dir>/rigswitch.ts .
```

Then, by hand:

- `index.js`: `import './rigswitch';` as the first line.
- `babel.config.js`: `plugins: ['react-native-worklets/plugin']`.
- `android/app/src/main/AndroidManifest.xml`: `POST_NOTIFICATIONS` and `CAMERA`
  `<uses-permission>`, and on the main activity a second intent filter
  (`VIEW`, categories `DEFAULT` + `BROWSABLE`, `<data android:scheme="svp2cli" />`).
- `android/gradle.properties`: `reactNativeArchitectures=arm64-v8a` (Apple Silicon
  emulators; faster builds).
- Optional, for the embedded-bundle case: in `android/app/build.gradle`, inside
  `android { }` after `signingConfigs`, a flavor block that only exists with
  `-PsvFlavors`. Its debug variants are named `plainDebug` / `devDebug`, which are NOT
  in React Native's default `debuggableVariants`, so they ship with a bundle in assets:

  ```groovy
  if (project.hasProperty('svFlavors')) {
      flavorDimensions "env"
      productFlavors {
          plain { dimension "env" }
          dev { dimension "env"; applicationIdSuffix ".dev" }
      }
  }
  ```

Build (from `f-cli/android`):

```sh
./gradlew assembleDebug -PreactNativeDevServerPort=8121
./gradlew assembleDevDebug -PsvFlavors -PreactNativeDevServerPort=8121   # embedded bundle
```

Metro: `npx react-native start --port 8121 --no-interactive` in `f-cli`.

Variants of the same app, built from a copy of `f-cli` (`cp -cR f-cli f-nav` on APFS is
instant) so the main fixture stays as it is:

- Without edge-to-edge (status bar outside the app's window, to compare the tree's
  screen coordinates with `measureInWindow`): `./gradlew assembleDebug
  -PreactNativeDevServerPort=8121 -PedgeToEdgeEnabled=false`, run on API 34 (API 35+
  enforces edge-to-edge for apps targeting it).
- react-navigation (one native-stack push, `navstack.tsx`): `npm install
  @react-navigation/native @react-navigation/native-stack react-native-screens`, copy
  `navstack.tsx`, and in `index.js` import `./navstack` in place of `./App`. Build the
  embedded-bundle variant (`assembleDevDebug -PsvFlavors`) and, before its first start,
  point its `debug_http_host` at a port nothing listens on - a debug build that finds
  the Metro on 8121 loads that Metro's bundle (the main App) instead of its own.

## Expo dev-client app (`com.example.svp2expo`, scheme `svp2expo`, Metro :8120)

Tested with Expo SDK 58, `expo-dev-client` 58.0.x, React Native 0.88.1.

```sh
npx create-expo-app@latest f-expo --template blank-typescript
cd f-expo
npx expo install expo-dev-client react-native-reanimated react-native-worklets
cp <this dir>/App.tsx <this dir>/rigswitch.ts .
```

- `index.ts` (the `main` entry): `import './rigswitch';` as the first line.
- `app.json`: `"scheme": "svp2expo"`, `android.package` `com.example.svp2expo`,
  `android.permissions` `POST_NOTIFICATIONS` and `CAMERA`.

Build:

```sh
CI=1 npx expo prebuild --platform android --no-install
sed -i '' 's/^reactNativeArchitectures=.*/reactNativeArchitectures=arm64-v8a/' android/gradle.properties
cd android && ./gradlew assembleDebug -PreactNativeDevServerPort=8120
```

Metro: `npx expo start --port 8120 --dev-client` in `f-expo`. A plain start of a
dev-client build shows the launcher; open the app with
`exp+svp2expo://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A8120`.

## Installing

`adb -s <serial> install -r android/app/build/outputs/apk/debug/app-debug.apk`. The skill's
scripts never build or install the app; this is the test bench's own setup.
