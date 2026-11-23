# Android w simulator-verify - analiza przed implementacją (faza 1, 2026-11-20)

Faza 1 = analiza bez uruchamiania emulatora. Nic w tym dokumencie nie zostało zmierzone na
emulatorze ani na telefonie z Androidem. Faza 2 (z emulatorem) ma zweryfikować oznaczone niżej
założenia; jej plan jest w sekcji 9.

## 0. Wnioski w skrócie

1. **Pętla ze SKILL.md jest niezależna od platformy, narzędzia nie są.** Zasady (Rig gate,
   "text first", `waitid` zamiast `sleep`, jeden `do` na trasę, instancje komponentu, raport)
   przenoszą się 1:1. Do przepisania jest cała hydraulika: `sim-ui.sh` (WebDriverAgent +
   `simctl`/`devicectl`), `wda_el.py`, `wda_tree.py`, `wda-sim.sh`, `wda-device.sh`,
   `read-rn-logs.sh` (os_log) i połowa `rig-check.sh`. Bez zmian albo z drobną zmianą działają
   `rn-devtools.mjs`, `read-rn-logs-cdp.py`, `devtools/*`, `probe-collector.py`, `measure-*.py`.
2. **testID jest na Androidzie dobrze adresowalny.** RN wystawia `testID` jako `resource-id`
   węzła dostępności, dokładnie w tej postaci, w jakiej go napisano (bez prefiksu `pkg:id/`),
   od RN 0.64. Fabric nie spłaszcza widoku z testID. To jest odpowiednik iOS-owego
   `accessibilityIdentifier` i daje podstawę dla `waitid` / `tapid` / `el` / `typeid`.
3. **Nie ma odpowiednika `-RCT_jsLocation`.** Zbudowana aplikacja debug na emulatorze łączy się
   z `10.0.2.2:<port wpisany przy buildzie>`. Przekierowanie bez rebuildu wymaga zapisania
   preferencji `debug_http_host` w danych aplikacji (`run-as`). To trwały stan, nie argument
   jednego uruchomienia. Dla Expo dev client jest osobna droga: deep link z URL-em Metro.
4. **Logi JS są na Androidzie łatwiejsze niż na iOS.** W bridgeless RN 0.81 `console.*` trafia do
   logcat z tagiem `ReactNativeJS`. Na iOS ten kanał jest martwy od RN 0.77. Marker rig-checka da
   się czytać z logcat, z CDP jako drugim kanałem.
5. **Debug build po cichu wraca do wbudowanego bundla, gdy Metro nie odpowiada** (jeśli APK go
   ma). To ta sama klasa fałszywego wyniku, co `main.jsbundle` na iOS, i rig-check musi ją
   wykrywać inaczej (zawartość APK zamiast pliku w `.app`).
6. **Rekomendowany driver: serwer Appium UiAutomator2 uruchamiany samodzielnie** (bez Appium w
   Node), czyli najbliższy odpowiednik WebDriverAgent: HTTP/W3C na urządzeniu, port przez
   `adb forward`. Zapas: gołe `adb` (`uiautomator dump` + `input`), zero instalacji, ale
   wolniejsze i bez typowania unicode. Kandydat do porównania w fazie 2: `agent-device`
   (Callstack). Żadna z tych opcji nie ma zmierzonych liczb w tym środowisku.
7. **Jednostki: proponuję dp na wejściu i wyjściu drivera** (odpowiednik pt na iOS), z
   przeliczaniem na piksele w środku. Lokalny AVD ma gęstość 420 dpi, czyli współczynnik 2.625,
   nie liczbę całkowitą. Obecny kod zakłada całkowitą skalę w kilku miejscach.
8. **Struktura: jeden skill, osobne skrypty dla Androida z tym samym zestawem komend i tymi
   samymi kodami wyjścia**, wybór backendu po kształcie identyfikatora urządzenia (tak jak dziś
   iPhone vs symulator). Osobny skill odrzucam, bo zdublowałby pętlę i gotchas.

## 1. Zakres i metoda

Przeczytane w całości: `SKILL.md`, wszystkie pliki `references/` (bez dowodów speed-analysis),
`sim-ui.sh`, `rig-check.sh`, `read-rn-logs.sh`, nagłówki i logika wyboru celu w
`read-rn-logs-cdp.py` i `devtools/targets.mjs`, nagłówki `wda_el.py`, `wda_tree.py`,
`component-tree.mjs`, skryptów pomiarowych i `probe-collector.py`, szablon `config.md`, sekcje
Argent / agent-device / Maestro z `speed-analysis-2026-11-13/research-tools.md`.

Źródła zewnętrzne: kod React Native (lokalne `node_modules` w projektach RN 0.80.2 i 0.81.1,
plus GitHub v0.76.0 / v0.83.0 / main), kod `@react-native/gradle-plugin` i
`@react-native/dev-middleware` (lokalnie), AOSP `DumpCommand.java`, kod
`appium-uiautomator2-server` i `appium-uiautomator2-driver`, kod `expo-dev-launcher`,
dokumentacja Android Developers, zgłoszenia w issue trackerach. Pełna lista w sekcji 11.

Oznaczenia przy faktach:

- **[KOD]** - przeczytane w kodzie źródłowym (wersja podana przy fakcie).
- **[DOC]** - oficjalna dokumentacja.
- **[ZGŁ]** - issue, blog, Stack Overflow; nie potwierdzone kodem.
- **[WNIOSEK]** - mój wniosek z kodu lub dokumentacji; do sprawdzenia w fazie 2.

Lokalne środowisko (stan 2026-11-20, odczytane z plików, nic nie uruchomione): Android SDK z
`platform-tools` (adb 37.0.1), `emulator` 37.2.13, `cmdline-tools` (`avdmanager`,
`sdkmanager`), `build-tools` 35 i 36 (jest `aapt2`), JDK 17, Node 25.8. Jeden AVD: API 36,
obraz `google_apis` (bez Play Store, więc `adb root` powinien działać [ZGŁ]), arm64-v8a,
1080x2424, 420 dpi, `hw.keyboard=no`, `hw.gpu.mode=host`. Maestro nie jest zainstalowany.

## 2. Inwentarz: co w skillu jest związane z iOS

| element | zależność od iOS | co z nim na Androidzie |
|---|---|---|
| `SKILL.md` - pętla, zasady | prawie żadna (nazwy komend, `$BUNDLE`, `-RCT_jsLocation` w przykładzie) | zostaje; dopisać wybór platformy i przykład trasy dla Androida |
| `sim-ui.sh` (1016 linii) | całkowita: WDA HTTP, `simctl`, `devicectl`, `iproxy`, geometria z `simctl getenv`, `sips` | nowy backend o tej samej powierzchni komend (sekcja 6) |
| `wda_el.py`, `wda_tree.py` | protokół WDA, typy XCUIElement (`StaticText`, `Other`), semantyka `accessibility id` WDA | logika (poll, read-back, odmowa na niejednoznaczności) do skopiowania; zapytania i filtr typów nowe |
| `wda-sim.sh`, `wda-device.sh`, `test-wda-diagnostics.sh` | całkowita | odpowiednik: instalacja i start serwera UiAutomator2 (`u2-ensure`) |
| `rig-check.sh` (691 linii) | połowa: trigger, odczyt markera, crash report `.ips`, `main.jsbundle`, DerivedData, `Podfile.lock`, rozpoznanie symulatora po ścieżce procesu | szkielet (marker, restore, werdykty, Metro po cwd, `/status`, WEDGED) zostaje; reszta nowa (sekcja 7) |
| `read-rn-logs.sh` | całkowita (os_log) | zastąpić odczytem logcat (`ReactNativeJS`) |
| `read-rn-logs-cdp.py`, `rn-devtools.mjs`, `devtools/targets.mjs`, `devtools/cdp.mjs`, `network.mjs` | brak w protokole; dwa założenia w wyborze celu (nazwa urządzenia, "iPhone" jako fizyczny) | działa przez to samo Metro; trzeba poprawić rozróżnianie urządzeń (4.3) |
| `devtools/component-tree.mjs` (`tree`) | jednostki: zwraca pt i "tap = centrum w punktach" | na Androidzie zwraca dp; zgodne z proponowaną jednostką drivera; przesunięcie o pasek statusu do sprawdzenia (4.10) |
| `measure-element.py`, `measure-boxes.py` | domyślna skala 3, w opisie `simctl io` | działa na PNG z `screencap`; skala musi przyjmować ułamek (2.625) |
| `probe-collector.py` | adres `localhost` w przykładzie | z emulatora: `10.0.2.2:<port>` albo `adb reverse` (4.15) |
| `simbench.sh`, `regress.sh` | WDA / `sim-ui.sh` | odpowiedniki dla Androida dopiero, gdy driver się ustabilizuje |
| `references/device.md`, `wda.md` | całkowita | nowy `references/android.md` (emulator, telefon, serwer UiA2) |
| `references/gotchas.md` | część wspólna (Metro, store, instancje, efekty uboczne), część iOS (alert "Open in App?", `RCTLinkingManager`, pasteboard) | dopisać sekcję Androida |
| `config-template.md` | bundle id, scheme, `RCT_METRO_PORT`, `-RCT_jsLocation` | dodać sekcję `## Android` (sekcja 8) |
| skille wołające ten skill (`solo`, `batch-finish`, `epic-prep`, `developing-features`, `rn-profile`, `web-verify`, `pass-to`, `solo-prep`) | zmienne `SIM_UDID`, `WDA_PORT`; kontrakt slotu executora pm | zmienne dla Androida trzeba nazwać i przepuścić przez kontrakt slotu (sekcja 8) |

## 3. Mapa iOS -> Android, funkcja po funkcji

| funkcja | iOS dziś | Android - odpowiednik | pewność |
|---|---|---|---|
| identyfikator celu | `SIM_UDID` (kształt udid decyduje sim/telefon) | serial adb: `emulator-5554` dla emulatora, inny kształt dla telefonu; `ANDROID_SERIAL` lub `adb -s` | [DOC] |
| lista uruchomionych | `simctl list devices booted` | `adb devices -l` + `adb -s <serial> emu avd name` (nazwa AVD) | [DOC] |
| "symulator nazwany po tym, czemu służy" | `simctl rename` | `avdmanager move avd -n <stara> -r <nowa>` (tylko gdy emulator wyłączony [WNIOSEK]); albo etykieta instancji `-prop qemu.<tag>=<worktree>` przy starcie | [DOC] / [WNIOSEK] |
| start aplikacji | `simctl launch <udid> <bundle> [args]` | `adb shell am start -W -n <pkg>/<activity>` albo `monkey -p <pkg> -c android.intent.category.LAUNCHER 1`; aktywność z `cmd package resolve-activity --brief` | [DOC] / [WNIOSEK] |
| restart | `simctl terminate` + `launch` | `am start -S -W ...` albo `am force-stop` + `am start` | [DOC] |
| argumenty uruchomienia | `-RCT_jsLocation` itp. | brak odpowiednika dla RN core; extras intentu (`--es`) czyta tylko kod aplikacji, który ich szuka | [KOD] |
| foreground bez restartu | WDA `activate` | `am start` bez `-S` przywraca istniejący task [WNIOSEK] | [WNIOSEK] |
| jaka aplikacja z przodu | WDA `activeAppInfo` | `dumpsys activity activities` (`topResumedActivity`, fallback `mResumedActivity`); format zmienił się w Android 14 | [ZGŁ] |
| deep link | `simctl openurl` | `am start -W -a android.intent.action.VIEW -d <url> <pkg>` (pakiet na końcu omija okno wyboru aplikacji) | [DOC] / [WNIOSEK] |
| drzewo elementów | WDA `/source` | UiA2 `GET /source` albo `uiautomator dump` | [KOD] |
| element po testID | WDA "accessibility id" | `resource-id == testID` (UiA2: strategia `id` z wyłączonym autouzupełnianiem prefiksu, albo xpath na `@resource-id`) | [KOD] |
| tap po elemencie | WDA `element/click` | UiA2 `element/:id/click` | [KOD] |
| tap po współrzędnych | WDA actions (pt) | `adb shell input tap X Y` (px) albo UiA2 actions | [DOC] |
| typowanie | WDA `/wda/keys`, `element/value` | UiA2 `element/:id/value` (`setText`, czyli zastąpienie tekstu, unicode działa); `adb shell input text` (tylko ASCII, spacja jako `%s`) | [KOD] / [DOC] |
| przyciski | HOME, ENTER, VOLUME_* | `input keyevent` HOME=3, BACK=4, ENTER=66, DEL=67, MOVE_END=123 i inne; BACK jest nowy i ważny (4.11) | [DOC] |
| zrzut ekranu | `simctl io screenshot` / `devicectl` | `adb exec-out screencap -p > f.png` (`exec-out`, nie `shell`) | [DOC] |
| geometria | `simctl getenv SIMULATOR_MAINSCREEN_*` | `wm size`, `wm density`; dp = px / (dpi / 160) | [DOC] |
| alerty systemowe | WDA `/alert/*` | brak API alertów; okno uprawnień to zwykłe elementy innego pakietu (kontroler uprawnień) w drzewie; zapobiegawczo `pm grant` | [WNIOSEK] / [DOC] |
| lock / unlock | WDA `/wda/lock` | `input keyevent` 223 (SLEEP), 224 (WAKEUP), 82 (MENU zdejmuje ekran blokady bez PIN-u); stan: `dumpsys power` (`mWakefulness`) | [WNIOSEK] |
| orientacja | WDA `orientation` | `settings put system accelerometer_rotation 0` + `user_rotation 0..3`; odczyt przez `dumpsys` / UiA2 | [WNIOSEK] |
| logi JS | os_log (martwe od RN 0.77), CDP | logcat `ReactNativeJS` (żywe w RN 0.81 bridgeless), CDP | [KOD] |
| crash | `~/Library/Logs/DiagnosticReports/*.ips` | `adb logcat -b crash`, `dumpsys activity exit-info <pkg>` (Android 11+), `pidof` | [DOC] |
| czy aplikacja żyje | `kill -0` pid z `simctl launch`, `launchctl list` | `adb shell pidof -s <pkg>` | [WNIOSEK] |
| wbudowany bundle | `main.jsbundle` w `.app` | `assets/index.android.bundle` w APK (`pm path` + `adb pull` + `unzip -l`) | [KOD] / [WNIOSEK] |
| wiek binarki | mtime pliku wykonywalnego w `.app` | `dumpsys package` `lastUpdateTime` (czas instalacji, nie buildu); mtime lokalnego APK | [ZGŁ] / [WNIOSEK] |
| nowsze buildy na dysku | DerivedData | `android/app/build/outputs/apk/**/*.apk` z `applicationId` z `aapt2 dump badging` | [WNIOSEK] |
| instalacja z zachowaniem danych | `simctl install` | `adb install -r` | [DOC] |
| przeładowanie JS | `curl localhost:PORT/reload` | to samo (rozgłoszenie przez websocket Metro do wszystkich klientów) albo `am broadcast -a <pkg>.RELOAD_APP_ACTION -p <pkg>` (tylko ta aplikacja) | [KOD] |

## 4. Kluczowe ustalenia

### 4.1 testID -> resource-id

- `BaseViewManager.setTestId` zapisuje testID pod tagiem widoku `R.id.react_test_id` i dodatkowo
  `view.setTag(testId)`. Nie woła `View.setId`. [KOD, RN 0.81.1 lokalnie]
- `ReactAccessibilityDelegate.setDelegate` instaluje delegata dostępności, gdy widok ma
  `react_test_id` (lub rolę, stan, akcje itp.), chyba że widok ma już innego delegata. Delegat w
  `onInitializeAccessibilityNodeInfo` wywołuje `info.setViewIdResourceName(testId)`. [KOD, RN
  0.81.1] Komentarz w kodzie mówi wprost, że to dla frameworków testowych "black-box".
- To samo robią osobno `ReactScrollView`, `ReactHorizontalScrollView`, `ProgressBarContainerView`
  i `ReactModalHostView` (testID modala trafia do `DialogRootViewGroup`). [KOD, RN 0.81.1]
- Funkcja weszła w RN 0.64.0 (PR #29610, cherry-pick na gałąź 0.64). [KOD, historia gita]
- Fabric: `ViewShadowNode` traktuje niepusty `testId` jako powód do zachowania widoku, więc nie
  jest on spłaszczany (view flattening). [KOD, RN main]
- Pułapka Appium: strategia `id` dokleja `<pkg>:id/` do identyfikatora bez prefiksu i wtedy
  goły testID RN nie pasuje. Trzeba ustawić `disableIdLocatorAutocompletion: true` albo szukać
  xpathem po `@resource-id`. [KOD, appium-uiautomator2-server master]
- Niepewne: czy widok z samym testID (bez etykiety, roli i handlera) przetrwa zrzut
  "skompresowany" (`--compressed` / `ignoreUnimportantViews`), który pomija węzły nieważne dla
  dostępności. Domyślnie UiA2 i `uiautomator dump` robią zrzut nieskompresowany, więc to ważne
  tylko, gdyby ktoś włączył kompresję dla szybkości. [WNIOSEK]
- Zgłoszenie z RN 0.64.3: `TextInput` bez resource-id. Nie sprawdzone dla 0.76+. [ZGŁ]

Konsekwencja: `waitid` / `tapid` / `el` / `typeid` mają na Androidzie czysty odpowiednik i
dopasowanie jest DOKŁADNE (bez iOS-owego "albo label, gdy brak identifier"). Różnica w
zachowaniu, którą trzeba opisać: na iOS `waitid "Popular now"` znajduje goły tekst przez label,
na Androidzie nie. Do tekstu służy `waitfor`.

### 4.2 Skąd aplikacja debug bierze adres Metro

Kolejność w RN 0.81.1 [KOD, `PackagerConnectionSettings.kt`, `AndroidInfoHelpers.kt`]:

1. Preferencja `debug_http_host` z domyślnych SharedPreferences aplikacji, pełne `host:port`.
   Plik: `shared_prefs/<pkg>_preferences.xml` w danych aplikacji [WNIOSEK, standardowa nazwa].
2. Inaczej: host z właściwości systemowej `metro.host` (odczyt `getprop`, zapamiętywany na czas
   życia procesu), inaczej `10.0.3.2` (Genymotion), inaczej `10.0.2.2` na emulatorze (fingerprint
   `generic` albo `google/sdk_gphone*`), inaczej `localhost`. Port zawsze z zasobu
   `react_native_dev_server_port`.
3. Port w zasobie ustawia plugin Gradle z właściwości `reactNativeDevServerPort` (domyślnie
   8081). `RCT_METRO_PORT` to nazwa z iOS. [KOD, gradle-plugin dla RN 0.81]

Wersje różnią się w punkcie 1 [KOD, GitHub, agent researchu]:

- RN 0.76 i 0.81: dialog "Change Bundle Location" zapisuje preferencję (trwale).
- RN 0.83.0: setter trzyma host tylko w pamięci procesu (`cachedHost`), getter nadal czyta
  preferencję. PR #57425 (2026-07) przywraca trwały zapis. W której wersji wydanej, nie wiem.

Wnioski dla przekierowania bez rebuildu:

- **`adb reverse` nie działa na emulatorze w domyślnej konfiguracji**, bo aplikacja łączy się z
  `10.0.2.2`, czyli wprost z loopbackiem Maca, a nie z `localhost` urządzenia. [WNIOSEK z kodu]
- **Działa zapis `debug_http_host=10.0.2.2:<PORT>`** przez `adb shell run-as <pkg>` (aplikacja
  debuggable), po `am force-stop` (SharedPreferences są w pamięci procesu i `apply()` mógłby
  nadpisać edycję). Plik trzeba scalić, nie nadpisać: siedzą w nim inne ustawienia dev. [WNIOSEK]
- Ten zapis jest TRWAŁY. To odpowiednik iOS-owego `defaults write`, nie argumentu jednego
  uruchomienia. Odpowiednika "argument domain" nie ma. Rig-check musi więc mówić w notatkach, co
  zapisał, a `config.md` musi to odnotować.
- `metro.host` zmienia tylko host, nie port, a `setprop` dowolnej nazwy z powłoki zwykłego
  użytkownika prawdopodobnie nie przejdzie bez `adb root`. Na obrazie `google_apis` root jest
  dostępny. [WNIOSEK]
- **Expo dev client**: URL Metro przychodzi deep linkiem
  `exp+<slug>://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A<PORT>`, a launcher
  pamięta ostatni URL w swoich SharedPreferences i po zimnym starcie ładuje go ponownie
  (domyślnie). Restart w stylu "terminate + launch" zostaje więc na ostatnim URL-u. [KOD, expo
  main]
- Port wpisany w APK da się odczytać na Macu z zasobów: `aapt2 dump resources <apk>` i szukanie
  `react_native_dev_server_port` [WNIOSEK]. Gdy port Metro dla drzewa równa się portowi z APK i
  nikt nie zapisał preferencji, przekierowanie nie jest potrzebne.

### 4.3 Które urządzenie jest czyje (Metro <-> emulator)

Na iOS rig-check wiąże symulator z Metro przez `lsof`: aplikacja symulatora to proces Maca, a
jego ścieżka zawiera UDID. Na Androidzie:

- **Nazwa w inspektorze nie odróżnia dwóch emulatorów z tego samego obrazu.** `deviceName` w
  `/json/list` to `"<Build.MODEL> - <Android release> - API <SDK>"` (na Apple Silicon
  prawdopodobnie `sdk_gphone64_arm64 - 16 - API 36` [WNIOSEK]). [KOD, `DevServerHelper.kt` RN
  0.81.1] Dwa emulatory z jednego obrazu mają identyczną nazwę, więc obecna logika `--device`
  (substring nazwy) ich nie rozdzieli.
- `reactNative.logicalDeviceId` jest unikalny: SHA-256 z `android-<pkg>-<ANDROID_ID>-fusebox`
  (lub `-legacy`). [KOD, RN 0.81.1 + `InspectorProxy.js`] Na API 26+ `ANDROID_ID` widziany przez
  aplikację zależy od klucza podpisu i użytkownika, więc z Maca nie da się go tanio policzyć
  [WNIOSEK]. Praktyczna droga: rozróżniać po `logicalDeviceId`, a mapowanie na serial zrobić
  przez CDP (np. `eval` czegoś, co aplikacja zna o swoim urządzeniu) albo przez połączenie TCP.
- **Połączenie TCP**: przy hoście `10.0.2.2` ruch emulatora wychodzi na Macu z procesu emulatora
  (NAT w trybie użytkownika), więc `lsof -iTCP:<port> -sTCP:ESTABLISHED` powinien pokazać PID
  procesu `qemu-system-aarch64`, a jego linia poleceń nazwę AVD [WNIOSEK, faza 2]. To byłby
  odpowiednik `sims_on_port`. Przy `adb reverse` (telefon, Expo CLI) połączenie wychodzi z
  serwera adb i nic nie mówi o urządzeniu.
- Ścieżka "fizyczne urządzenie = dokładnie `iPhone`" w `targets.mjs` / `read-rn-logs-cdp.py`
  nie ma odpowiednika: telefon z Androidem podaje swój model.

### 4.4 Logi JS i marker

- W bridgeless RN 0.81.1 `JReactInstance.cpp` wiąże `nativeLoggingHook` z
  `reactAndroidLoggingHook`, które robi `__android_log_write(..., "ReactNativeJS", msg)`.
  Polyfill `console` w `@react-native/js-polyfills` kieruje `console.*` do `nativeLoggingHook`,
  gdy ten istnieje. [KOD, RN 0.81.1] Ten sam łańcuch potwierdził agent researchu dla 0.83.0.
- Na iOS ten sam hook istnieje (`RCTInstance.mm` -> `_RCTLogJavaScriptInternal`), a mimo to
  skill zmierzył pusty os_log od RN 0.77. Czemu - nie ustaliłem. Dlatego logcat na Androidzie to
  [WNIOSEK z kodu] do potwierdzenia w fazie 2, a nie fakt.
- Odczyt: `adb logcat -d -T '<MM-DD hh:mm:ss.mmm>' -s ReactNativeJS:V` (zrzut od chwili) albo
  `--pid=$(adb shell pidof -s <pkg>)`. Po restarcie aplikacji PID się zmienia, więc dla markera
  lepiej filtr po tagu i czasie niż po PID. [DOC]
- CDP (`read-rn-logs-cdp.py`) działa przez to samo Metro i zostaje drugim kanałem. Strona
  bridgeless rejestruje się jako "React Native Bridgeless" z `prefersFuseboxFrontend: true`, więc
  obecna heurystyka wyboru głównego runtime'u pasuje. [KOD, RN 0.83.0 wg agenta]

### 4.5 Wbudowany bundle i ciche przejście na niego

- Plugin Gradle nie bundluje wariantów z listy `debuggableVariants`: domyślnie `['debug']` w RN
  0.81 [KOD lokalnie], `['debug', 'debugOptimized']` w RN 0.83 [KOD, GitHub]. Projekt może tę
  listę zmienić w bloku `react {}`.
- W bridgeless `ReactHostImpl` przy włączonym dev support pyta Metro o `/status`. Gdy Metro nie
  odpowiada, **po cichu ładuje bundle z assetów**. Gdy w APK go nie ma, rzuca "Unable to load
  script...". [KOD, RN 0.83.0 wg agenta]
- Wniosek: wariant debug ze zbundlowanym JS (np. przez zmienioną `debuggableVariants` albo
  wariant typu "debugOptimized") przy martwym lub nieosiągalnym Metro pokaże stary JS bez
  żadnego błędu. Rig-check wykryje to po braku markera, ale werdykt musi umieć nazwać przyczynę:
  `assets/index.android.bundle` w APK.
- Wykrycie z Maca: `adb shell pm path <pkg>`, `adb pull` ścieżki `base.apk`, `unzip -l` i szukanie
  `assets/index.android.bundle`. Taniej: ten sam test na lokalnym APK, jeśli wiadomo, który został
  zainstalowany. Flaga `DEBUGGABLE` w `dumpsys package <pkg>`. [WNIOSEK]

### 4.6 Crash i śmierć procesu

- Java/Kotlin: `FATAL EXCEPTION` w buforze `adb logcat -b crash`. Natywny SIGABRT: backtrace z
  tagiem `DEBUG` w logcat, tombstone w `/data/tombstones` (odczyt wymaga roota). [DOC]
- Android 11+: `adb shell dumpsys activity exit-info <pkg>` podaje powód (CRASH, CRASH_NATIVE,
  ANR, LOW_MEMORY, ...), PID i czas. To bliski odpowiednik czytania `.ips` w rig-checku. [DOC]
- "Proces zniknął": puste `pidof -s <pkg>`. [WNIOSEK]
- Skew JS/native (`TurboModuleRegistry.getEnforcing(...) could not be found`): na Androidzie
  rzucany w JS, więc powinien trafić do logcat (`ReactNativeJS` lub `ReactNative`) i na redbox.
  Dokładny tag i to, czy proces przeżywa, do sprawdzenia. [WNIOSEK]

### 4.7 Wiek binarki i "nowsze buildy już na dysku"

- iOS: mtime pliku wykonywalnego w `.app` = czas buildu, `simctl install` go zachowuje.
- Android: `dumpsys package <pkg>` daje `lastUpdateTime`, czyli czas INSTALACJI, nie buildu
  [ZGŁ]. Czas buildu można wziąć z mtime lokalnego APK, jeśli wiadomo, który został
  zainstalowany. Porównanie "ten APK = zainstalowany" po skrócie pliku `base.apk` z urządzenia i
  lokalnego APK jest pewne, ale kosztuje `adb pull` [WNIOSEK].
- Natywne zależności drzewa to na Androidzie nie `ios/Podfile.lock`, tylko `package.json`,
  `android/build.gradle`, `android/app/build.gradle`, `android/settings.gradle`,
  `android/gradle.properties` (i `gradle/libs.versions.toml`, jeśli projekt go ma). [WNIOSEK]
- Nowsze buildy na dysku: `android/app/build/outputs/apk/<wariant>/*.apk`; `applicationId`
  odczytuje `aapt2 dump badging <apk>`. Instalacja nad starą wersją: `adb install -r` (dane
  zostają). Uwaga: podpis musi się zgadzać, inaczej `INSTALL_FAILED_UPDATE_INCOMPATIBLE` i
  pokusa odinstalowania, które kasuje dane i sesję logowania. [WNIOSEK]

### 4.8 Wybór drivera UI

| opcja | jak działa | za | przeciw |
|---|---|---|---|
| A. gołe `adb` | `uiautomator dump` (XML) + `input tap/text/keyevent` + `screencap` | zero instalacji na urządzeniu; każde `adb` je ma | każdy zrzut czeka na 1 s bez zdarzeń dostępności (`waitForIdle(1000, 10000)`), więc minimum ~1 s plus start `app_process`; przy ciągłej animacji 10 s i "could not get idle state" [KOD, AOSP]; nie ma wyszukiwania po id (zawsze cały zrzut); `input text` bez unicode; kolizja z innym klientem UiAutomation |
| B. serwer UiAutomator2 (Appium) samodzielnie | 2 APK (`io.appium.uiautomator2.server` i `.test`), start `am instrument -w ...`, HTTP W3C na porcie 6790 urządzenia, `adb forward` | najbliższy odpowiednik WDA; `/source`, szukanie po `id` / xpath, `click`, `value` (`setText`, unicode), ustawienia `waitForIdleTimeout`, `allowInvisibleElements`, `enableMultiWindows`; logika `wda_el.py` przenosi się prawie 1:1 | trzeba przypiąć wersję APK (npm `appium-uiautomator2-server`) i pilnować instalacji, jak dziś WDA; jedna sesja UiAutomation na urządzenie; brak zmierzonych liczb |
| C. Maestro | gRPC na urządzeniu (port 7001), JVM na Macu | dojrzałe, testID jako `id:` | JVM i start na każde wywołanie, model "flow" zamiast komend jednego strzału; w analizie iOS odrzucone |
| D. `agent-device` (Callstack, v0.21.41 z 2026-11-19, 5.4k gwiazdek) | adb + własny "snapshot helper" na Androidzie, sesje, iOS i Android jednym CLI | aktywny rozwój; obsługa równoległych worktree; komponent RN; ten sam autor ekosystemu RN | obcy model komend i "refów"; skill musiałby oddać mu kontrolę nad pętlą; nie mierzone |
| E. `mobilecli` / mobile-mcp (mobile-next, 1.0.24) | iOS i Android | jedno narzędzie dla obu platform | w analizie iOS wypadło gorzej od WDA; na Androidzie mechanizm niezweryfikowany |

Rekomendacja: **B jako główny driver, A jako zapas** (odpowiednik obecnego "observe-only
fallback", tylko lepszy, bo daje też drzewo i tapnięcia), **D do porównania pomiarem w fazie 2**
zanim zapadnie decyzja. Uzasadnienie B: skill już ma dojrzały kod wokół serwera W3C na
urządzeniu (sesja na proces, `wda_post` z odmową = exit 1, odzyskiwanie po utracie sesji, poll po
id, read-back pola). Zmienia się transport, nie architektura.

Pułapki B, które trzeba zaprojektować od początku:

- **Jeden klient UiAutomation na urządzenie.** Drugi dostaje `UiAutomationService ... already
  registered` [ZGŁ]. Czyli `uiautomator dump` nie zadziała, gdy serwer UiA2 stoi, a Maestro lub
  agent-device na tym samym emulatorze wyrzucą serwer. Reguła "jeden driver naraz" jest na
  Androidzie twardsza niż na iOS.
- **`am instrument --no-window-animation` zeruje skale animacji** na czas instrumentacji
  [WNIOSEK z pamięci kodu AOSP `Am`, do sprawdzenia]. To zahacza o pułapkę z 4.12.
- `waitForIdleTimeout` domyślnie 10 s. Na iOS skill świadomie zostawił domyślne czekanie na
  bezczynność (szybki `waitid` bez niego łapał klatkę animacji). Na Androidzie trzeba to samo
  zmierzyć, a nie skopiować w ciemno.

### 4.9 Typowanie

- `adb shell input text`: tylko ASCII, spacja jako `%s`, metaznaki powłoki trzeba cytować.
  Polskie znaki (`zażółć`, które skill testuje na iOS) nie przejdą. [ZGŁ, Maestro docs]
- UiA2 `element/:id/value` woła `setText`, czyli zastępuje zawartość pola jednym ruchem (bez
  klawiatury). Czy to odpala `onChangeText` w kontrolowanym `TextInput` RN - nie sprawdzone; z
  kodu Androida `TextView.setText` odpala `TextWatcher`, z którego RN korzysta [WNIOSEK]. Pola z
  maską (telefon) formatują w `onChangeText`, więc read-back z `--expect` zostaje obowiązkowy.
- Zgłoszony wyścig w RN: kontrolowany input gubi znaki, gdy zdarzenia przychodzą szybciej niż JS
  odpowiada (`eventCount`). [ZGŁ] To ta sama klasa błędu, co "yo"/"yog" na iOS. `typeid` z
  odczytem z powrotem jest tu tak samo potrzebny.
- ADBKeyBoard (IME instalowane na urządzeniu, tekst przez broadcast) to droga do unicode bez
  UiA2. Zmienia domyślną klawiaturę, czyli wygląd ekranu przy screenshotach. [ZGŁ]
- Klawiatura ekranowa: lokalny AVD ma `hw.keyboard=no`, więc klawiatura ekranowa się pokazuje
  (tak jak na telefonie). AVD z klawiaturą sprzętową ukrywa ją i zmienia układ ekranu przy
  polu tekstowym; `settings put secure show_ime_with_hard_keyboard 1` wymusza ją z powrotem.
  [DOC / ZGŁ]

### 4.10 Współrzędne i jednostki

- Android natywnie: `bounds="[x1,y1][x2,y2]"` z UIAutomator, `input tap` i `screencap` są w
  pikselach fizycznych. [DOC]
- RN i `rn-devtools.mjs tree`: `measureInWindow` i `Dimensions` zwracają dp. [KOD, Argent
  `component-tree.ts`]
- Lokalny AVD: 420 dpi -> 2.625 px/dp. Obecny kod zakłada całkowitą skalę: `device_points` robi
  `cut -d. -f1` i `int(scale)`, `screenshot` dzieli przez 3 w zapasie, `measure-*.py` mają
  domyślne 3. Na Androidzie to musi być liczba z częścią ułamkową.
- Propozycja: **driver Androida przyjmuje i zwraca dp**, a w środku mnoży przez gęstość i
  zaokrągla. Powody: `screenshot` domyślnie przeskalowany do szerokości w dp daje "1 px obrazu =
  1 dp", tak jak dziś "1 px = 1 pt"; wynik `tree` (dp) od razu nadaje się do `tap`; trasy w
  `config.md` są te same na telefonach o różnej gęstości. Błąd zaokrąglenia przy 2.625 to
  najwyżej ~1.3 px, bez znaczenia dla tapnięcia. Alternatywa (px wszędzie) jest prostsza w
  kodzie, ale rozjeżdża się z `tree` i ze screenshotem. To decyzja projektowa do potwierdzenia.
- Do sprawdzenia: czy `measureInWindow` na Androidzie liczy od górnej krawędzi ekranu, czy od
  dołu paska statusu (zgłaszane w starszych RN; przy edge-to-edge z targetSdk 35+ okno zaczyna
  się od 0). Od tego zależy, czy `(tap X,Y)` z `tree` trafia. [ZGŁ / WNIOSEK]

### 4.11 Przycisk Wstecz i predictive back

- Android 16 + targetSdk 36: `onBackPressed` nie jest wołane, a `KEYCODE_BACK` nie jest już
  dostarczany do aplikacji; obsługa idzie przez `OnBackInvokedCallback` /
  `OnBackPressedCallback`. Wyłączenie: `android:enableOnBackInvokedCallback="false"`. [DOC]
- RN 0.81 dodał obsługę predictive back; aplikacje na starszym RN z targetSdk 36 według zgłoszeń
  zamykają się na Wstecz; jest też zgłoszenie z RN 0.83.1 o gubionym Wstecz po powrocie z tła.
  [ZGŁ]
- Na iOS ta klasa zachowań nie istnieje, więc skill nie ma dla niej żadnej reguły. Na Androidzie
  `button BACK` musi być komendą, a "Wstecz robi to, co powinien" częścią asercji zachowania dla
  ekranów z modalem, arkuszem i formularzem.

### 4.12 Animacje i "reduce motion"

- `AccessibilityInfo.isReduceMotionEnabled` w RN i Reanimated (`ReduceMotion.System`, domyślne)
  traktują `Settings.Global.transition_animation_scale == 0` jako "ogranicz ruch". Reanimated
  wtedy przeskakuje `withTiming` / `withSpring` od razu do wartości końcowej. [KOD, RN main i
  Reanimated]
- Wniosek: popularna rada "wyłącz animacje na emulatorze do testów" ZMIENIA zachowanie aplikacji
  RN. Driver nie może tego robić po cichu. Jeśli kiedyś to zrobi, ma to być jawna flaga, a raport
  musi to podać.
- To samo dotyczy startu serwera UiA2 z `--no-window-animation` (4.8).

### 4.13 Okna systemowe i uprawnienia

- Na Androidzie nie ma API "alertów" jak w WDA. Dialog uprawnień należy do pakietu kontrolera
  uprawnień i jest w drzewie jak inne elementy, jeśli driver patrzy na właściwe okno (w UiA2
  `enableMultiWindows`). Komendę `alert` trzeba zbudować jako "znajdź okno dialogu i jego
  przyciski", a nie przenosić. [WNIOSEK]
- Zapobiegawczo: `pm grant <pkg> <permission>` przed testem (np.
  `android.permission.POST_NOTIFICATIONS` od API 33, bo inaczej aplikacja może pokazać dialog w
  środku trasy). `pm revoke` i `pm set-permission-flags` symulują stany. [DOC]
- `pm clear <pkg>` kasuje dane aplikacji, w tym zalogowaną sesję i preferencję `debug_http_host`.
  Nie używać jako "resetu" bez świadomej decyzji (odpowiednik usunięcia kontenera danych na iOS).
- Niezbadane: okna "System UI isn't responding" / "... keeps stopping" na emulatorze i czy da się
  je zamknąć z powłoki.

### 4.14 Deep linki

- `am start -W -a android.intent.action.VIEW -d '<url>' <pkg>`: pakiet na końcu kieruje intent do
  tej aplikacji i omija okno wyboru, gdy dwie aplikacje mają ten sam schemat (na iOS skill
  odradza `openurl` przy dwóch buildach z tym samym schematem; na Androidzie jest na to
  narzędzie). [DOC / WNIOSEK]
- Na iOS pierwszy link wywołuje systemowe "Open in App?". Odpowiednika na Androidzie dla
  własnego schematu z podanym pakietem nie znalazłem [WNIOSEK]. Nieweryfikowane linki http(s)
  od Androida 12 idą do przeglądarki. [WNIOSEK]
- Zasada "udowodnij jeden link do końca" zostaje bez zmian.

### 4.15 Sonda HTTP (`probe-collector.py`)

- Z emulatora `localhost` to emulator. Sonda w aplikacji musi wołać `http://10.0.2.2:8099`
  albo po `adb reverse tcp:8099 tcp:8099` zostać przy `localhost`. [WNIOSEK]
- Ruch HTTP bez TLS: buildy debug RN zwykle go dopuszczają (inaczej nie działałoby Metro), ale
  sprawdzić w manifeście projektu. [WNIOSEK]

### 4.16 Czego emulator nie udowodni

- Schowek: `cmd clipboard` nie ma implementacji powłoki na API 35-36 [ZGŁ]. Wstawienie treści
  wymaga aplikacji pomocniczej. Synchronizacja schowka Maca z emulatorem: niesprawdzone.
- Wybór zdjęć: plik wrzucony `adb push` trzeba zarejestrować w MediaStore (`content call --uri
  content://media --method scan_file --arg <ścieżka>` albo przestarzały broadcast
  `MEDIA_SCANNER_SCAN_FILE`, który według zgłoszeń nadal działa na Androidzie 16) [ZGŁ].
- Reguła ze `gotchas.md` "dane z innej aplikacji = wynik z symulatora plus otwarta kontrola na
  urządzeniu" przenosi się bez zmian.

### 4.17 Telefon z Androidem na kablu

- Host domyślny to `localhost:<port>`, więc wymagany `adb reverse tcp:<port> tcp:<port>` (RN sam
  to podpowiada w logu). `adb reverse tcp:8081 tcp:<inny>` przekierowuje aplikację na inne Metro
  bez rebuildu i bez trwałego stanu w aplikacji, ale reguła znika po odłączeniu telefonu. To
  jedyne miejsce, gdzie istnieje odpowiednik jednorazowego `-RCT_jsLocation`. [KOD / WNIOSEK]
- Xiaomi: wstrzykiwanie wejścia wymaga "USB debugging (Security settings)" z kontem Mi. [ZGŁ]
- Brak `adb root` na urządzeniach seryjnych.
- Priorytet niższy niż emulator; architektura (serial w zmiennej, ten sam driver) od razu go
  obejmuje.

### 4.18 Wspólny serwer adb i równoległe sesje

- Jeden serwer adb (port 5037) obsługuje wszystkie urządzenia i wszystkie narzędzia. `adb
  kill-server` albo start innej wersji adb rozłącza wszystkich, w tym inne sesje Claude i Android
  Studio. Driver nie może tego robić sam. [DOC / WNIOSEK]
- Porty `adb forward` dla UiA2 trzeba przypisywać per serial i sprawdzać właściciela tak, jak
  dziś `assert_wda_owner` sprawdza właściciela portu WDA (`adb forward --list` pokazuje serial i
  port). [WNIOSEK]
- Emulator: porty konsoli parzyste od 5554, adb = konsola + 1, serial `emulator-<port konsoli>`;
  nie wyliczać seriala z portu, brać z `adb devices`. [DOC]
- `avdmanager` i `emulator` są oznaczone jako przestarzałe na rzecz nowego CLI `android emulator
  create|start|stop|list|remove` (start blokuje do pełnego bootu). [DOC]

## 5. Rozważone struktury i rekomendacja

1. **Osobny skill `emulator-verify`** - odrzucone. SKILL.md w 90% to pętla, która nie zależy od
   platformy; dwa skille rozjadą się w zasadach, a skille wołające musiałyby wybierać.
2. **Jeden `sim-ui.sh` z gałęziami dla Androida w każdej komendzie** - odrzucone. Skrypt ma 1016
   linii w bash 3.2, a każda zmiana iOS jest pilnowana przez `regress.sh` (69 przypadków).
   Mieszanie platform w jednym pliku podnosi ryzyko regresji iOS przy każdej zmianie Androida.
3. **Rekomendowane: jeden skill, osobne skrypty Androida o identycznej powierzchni.**
   - `droid-ui.sh` (nazwa robocza): te same komendy co `sim-ui.sh` (`do`, `waitid`, `tapid`,
     `el`, `typeid`, `elements [--all|--settled|--grep|--names]`, `waitfor`, `tap`, `swipe`,
     `longpress`, `type`, `button`, `screenshot`, `launch`, `relaunch`, `terminate`, `openurl`,
     `foreground`, `devices`, `wait`), te same kody wyjścia (0, 1, 2 = pytanie / użycie, 3 =
     ekran w ruchu), ten sam format `--names`, ta sama zasada "odmowa = exit 1" i podsumowanie
     ekranu po nieudanym kroku `do`. Nowe: `button BACK`, `grant PERM`.
   - Później cienki dispatcher (np. `sim-ui.sh` przekazuje do `droid-ui.sh`, gdy cel ma kształt
     seriala adb), żeby SKILL.md mógł mówić o jednym `$S`. Najpierw osobne skrypty, dispatcher
     dopiero po fazie 2.
   - `rig-check.sh`: albo gałąź Androida w tym samym pliku (część wspólna: repo, config, marker,
     restore, nasłuch Metro, WEDGED, werdykty), albo `rig-check-android.sh` z wydzieloną wspólną
     biblioteką. Skłaniam się do wydzielenia wspólnej części do pliku źródłowego (`lib/`) i dwóch
     cienkich skryptów, bo werdykty mają brzmieć identycznie.
   - `read-rn-logs-cdp.py` / `devtools/targets.mjs`: rozszerzyć wybór celu o `--logical-device`
     (albo `--device-id`) i o platformę z metadanych, zamiast dokładać specjalny przypadek jak
     "iPhone".
4. Nazwa skilla zostaje (`simulator-verify`); zmienić opis we frontmatter i w README ("iOS only -
   there is no Android path").

## 6. Driver Androida - powierzchnia i zachowania do zachowania

Zachowania z `sim-ui.sh`, które mają odpowiednik i muszą przejść do `droid-ui.sh`, bo każde
powstało z realnego fałszywego wyniku:

- odmowa wyboru celu przy kilku urządzeniach bez `ANDROID_SERIAL` (exit 2 z listą);
- weryfikacja, że port forward serwera UiA2 prowadzi do tego seriala (odpowiednik
  `assert_wda_owner`);
- diagnostyka "serwer nie zainstalowany" vs "zainstalowany, ale nie wstał" vs "nie dało się
  sprawdzić" (odpowiednik `wda_install_diagnostics`), z gotową komendą naprawy;
- jedna sesja na proces, `do` w jednym procesie, podsumowanie ekranu po błędzie kroku;
- sprawdzanie zakresu współrzędnych z uwzględnieniem orientacji;
- `typeid`: zastąp, odczytaj, porównaj, `--append`, `--expect`, Return dopiero po zgodnym
  odczycie, odmowa dla elementu, który nie jest polem tekstowym (na Androidzie: klasa
  `android.widget.EditText` lub `editable=true` [WNIOSEK]);
- `tapid`: tylko gdy widoczne trafienia to jeden cel; klik przez element, nie środek prostokąta;
- `waitid --exists`, komunikat "id istniało, ale nie było widoczne";
- `elements --settled`: dwa odczyty i diff; zegar paska statusu jest w oknie SystemUI, więc przy
  drzewie tylko aktywnego okna może go w ogóle nie być [WNIOSEK];
- komunikat przy `wait` > 2 s; `need_num`; brak `2>/dev/null` w poradach.

Różnice do opisania w `references/android.md`:

- filtr "elementów z etykietą": zamiast typów XCUI (`StaticText`, `Button`, ...) klasy Androida
  (`android.widget.TextView`, `android.widget.EditText`, `android.widget.Button`,
  `android.widget.ImageView`, `android.view.ViewGroup` z `clickable=true`) i pola `text`,
  `content-desc`, `resource-id`. RN renderuje `Pressable` jako `ViewGroup`, więc odpowiednik
  iOS-owego "pressable to często `Other`" to "pressable to `ViewGroup`, widoczny tylko w
  `--all`" [WNIOSEK];
- `content-desc` nie zawsze równa się `accessibilityLabel`: RN dokleja stany (busy, mixed) i
  `accessibilityValue.text`, a przy roli bez etykiety składa opis z tekstów dzieci [KOD, RN main];
- dopasowanie testID dokładne, bez dopasowania po etykiecie (4.1);
- `visible-to-user` (Android) liczy się tanio w aplikacji, ale ignoruje przezroczystość i
  zasłonięcie przez inne widoki [ZGŁ / WNIOSEK]; reguła "drzewo nie dowodzi, że ekran nie był
  zamontowany" też obowiązuje, tylko z innego powodu.

## 7. Rig-check na Androidzie - projekt werdyktów

| werdykt iOS | jak to wykryć na Androidzie |
|---|---|
| brak urządzenia | `adb devices` bez `device` w stanie online; z kilkoma bez `--serial` exit 2 jak dziś |
| aplikacja nie zainstalowana | `adb shell pm path <pkg>` puste |
| wbudowany bundle | `assets/index.android.bundle` w zainstalowanym APK (4.5); nazwać jako przyczynę dopiero, gdy marker nie przyszedł |
| aplikacja nie jest debuggable | brak `DEBUGGABLE` w `dumpsys package`; bez tego `run-as` nie działa, więc przekierowanie też nie |
| Metro dla tego drzewa / WEDGED / brak Metro | bez zmian (to część Maca: `lsof` + cwd + `/status`) |
| przekierowanie na właściwe Metro | port z APK (`aapt2`) == port Metro drzewa i brak `debug_http_host` -> nic; inaczej zapis `debug_http_host=10.0.2.2:<PORT>` po `force-stop`, z notatką "zapisano trwale"; Expo dev client -> deep link z URL-em |
| trigger | `am force-stop` + `am start -W` (zimny start) albo `curl /reload`; `RELOAD_APP_ACTION` jako trigger tylko dla tej aplikacji |
| odczyt markera | `adb logcat -d -T <czas startu> -s ReactNativeJS:V` w pętli; CDP jako drugi kanał |
| aplikacja padła | `pidof` puste po tym, jak było niepuste; przyczyna z `dumpsys activity exit-info <pkg>` i `logcat -b crash` |
| JS rzucił przy ładowaniu | wpisy `ReactNativeJS` / `ReactNative` od czasu startu z "Invariant Violation", "could not be found", "Unable to load script" |
| skew JS/native | jak wyżej + daty: `lastUpdateTime` z `dumpsys package`, mtime lokalnych APK, ostatnia zmiana plików Gradle / `package.json` w historii; lista nowszych APK z `adb install -r` |
| kilka emulatorów, który jest nasz | połączenie TCP do Metro z procesu emulatora z nazwą AVD (4.3), inaczej exit 2 z listą |
| ostrzeżenie na zielonym werdykcie "natywne zmiany po dacie X ich nie ma" | data instalacji / data lokalnego APK; jawnie napisać, która z nich |

Uwagi:

- Po przeczytaniu markera dziś rig-check robi `curl /reload`, żeby aplikacja wróciła na kod bez
  markera. Na telefonie iOS zrobiono drugi czysty start, bo reload ścigał się ze startem.
  Android: do sprawdzenia, który wariant jest bezpieczny.
- `--launch-arg` traci sens dla RN core. Dla Expo jego odpowiednikiem jest URL dev clienta.
  Przyda się za to `--activity` (gdy aplikacja ma inną aktywność startową niż wynik
  `resolve-activity`).

## 8. Konfiguracja i integracje

Nowa sekcja w `config-template.md`:

- `applicationId` wariantu dev (to `<pkg>`), aktywność startowa, wariant Gradle (`debug` /
  własny) i czy jest w `debuggableVariants`;
- AVD (nazwa, API, obraz `google_apis` czy `playstore`, gęstość), serial nie jako stała, tylko
  "jak go znaleźć";
- port Metro wpisany w APK (`reactNativeDevServerPort`) i metoda przekierowania (preferencja /
  URL dev clienta / `adb reverse` na telefonie), z informacją, że preferencja jest trwała;
- komenda zimnego startu (`npx react-native run-android --port ...` / `npx expo run:android`),
  ścieżka APK, `adb install -r`;
- uprawnienia do nadania przed testem (`pm grant`);
- targetSdk i zachowanie Wstecz;
- telefon: model, `adb reverse`, ograniczenia producenta.

Zmienne środowiskowe: proponuję `ANDROID_SERIAL` (standard adb, rozumieją go też inne narzędzia)
i `U2_PORT` (lokalny port forward serwera UiA2) obok `SIM_UDID` / `WDA_PORT`. Skille `solo`,
`batch-finish`, `epic-prep` i kontrakt slotu executora pm przekazują dziś `SIM_UDID` i
`WDA_PORT`; żeby Android działał w tych przepływach, kontrakt slotu musi znać nowe zmienne. To
zmiana poza tym repo (pm-cli), więc odnotowuję ją tylko jako zależność.

## 9. Faza 2 - plan weryfikacji na emulatorze

Wytyczne ogólne:

- Na emulatorze, który należy do tej sesji. Nie ruszać emulatorów, Metro ani serwera adb innych
  sesji. Nigdy `adb kill-server`.
- Każdy pomiar do `references/benchmarks.md` z datą, sprzętem, wersją obrazu, emulatora, adb, RN
  i serwera UiA2. Bez nazw projektów, pakietów i urządzeń (publiczne repo; `scripts/check-leaks.sh`).
- Aplikacja testowa: najlepiej świeży projekt RN (np. 0.81 i 0.83, bo różnią się w obsłudze
  `debug_http_host` i `debuggableVariants`) plus jedna prawdziwa aplikacja RN z dużym ekranem do
  pomiarów czasu. Osobno jedna aplikacja Expo dev client.
- Nie zmieniać skal animacji, chyba że eksperyment tego dotyczy (4.12).

Eksperymenty, w kolejności (każdy: pytanie -> jak -> kryterium -> na jaką decyzję wpływa):

**Rig (najpierw, bo bez niego żaden odczyt nie jest ważny)**

1. E1 Host i port Metro. Zbudować debug z portem X, Metro na Y. Sprawdzić: (a) połączenie idzie
   na `10.0.2.2:X`; (b) zapis `debug_http_host=10.0.2.2:Y` przez `run-as` po `force-stop`
   przekierowuje na Y w RN 0.81 i 0.83; (c) `adb reverse` nic nie zmienia na emulatorze;
   (d) czy `setprop metro.host` działa bez roota i z rootem. Kryterium: Metro Y dostaje żądanie
   bundla `platform=android&app=<pkg>`. Decyzja: mechanizm przekierowania w rig-checku.
2. E2 Logcat dla markera. `console.log` w pierwszej linii entry -> czy jest w `ReactNativeJS`,
   po ilu sekundach od `am start`, także przy podłączonym CDP. Decyzja: kanał markera.
3. E3 Rozpoznanie emulatora po TCP. Dwa emulatory z jednego obrazu na dwóch Metro: czy `lsof` na
   porcie Metro wskazuje proces emulatora i czy jego linia poleceń zawiera nazwę AVD. Plus
   `/json/list`: `deviceName`, `logicalDeviceId`, `vm`, `description`. Decyzja: wybór celu w
   rig-checku i w `targets.mjs`.
4. E4 Wbudowany bundle. Wariant ze zbundlowanym JS, Metro wyłączone: czy aplikacja startuje po
   cichu na starym JS; czy logcat zostawia ślad odróżniający to od ładowania z Metro. Plus czas
   `pm path` + `pull` + `unzip -l`. Decyzja: kiedy i jak tanio sprawdzać APK.
5. E5 Crash i skew. Natywny crash (testowy) i brak modułu natywnego: co pokazuje `exit-info`,
   `logcat -b crash`, tagi JS; czy proces przeżywa skew. Decyzja: teksty werdyktów.
6. E6 Reload po markerze: `curl /reload` vs `RELOAD_APP_ACTION` vs drugi zimny start - który nie
   zostawia redboxa. Plus Expo: czy dev server Expo odpowiada na `/reload` i `/status`.

**Driver**

7. E7 testID w drzewie. Ekran z `View`, `Text`, `TextInput`, `Pressable`, `Image`, `ScrollView`,
   `Modal`, `FlatList` z testID: czy każdy ma `resource-id` w `uiautomator dump` i w UiA2
   `/source`; jak wygląda zagnieżdżony `Text` z testID; czy widok z samym testID przeżywa zrzut
   skompresowany; czy elementy listy poza ekranem są w drzewie z `visible-to-user=false`, czy ich
   nie ma. Decyzja: filtr `elements` i semantyka `waitid`.
8. E8 Czas odczytu. Ten sam ekran (lekki i ~250 węzłów): `uiautomator dump` vs UiA2 `/source`
   vs UiA2 find by id + `displayed` vs agent-device snapshot. Po 5 powtórzeń. Plus ekran z
   nieskończoną animacją (ActivityIndicator, Lottie, pętla Reanimated): czy `dump` kończy się
   "could not get idle state", ile trwa UiA2 przy `waitForIdleTimeout` 10 s i 0. Decyzja: driver
   główny i ustawienia.
9. E9 Typowanie. `typeid` przez UiA2 `value` na kontrolowanym i niekontrolowanym `TextInput`:
   czy `onChangeText` odpala (sprawdzić przez `rn-devtools eval` albo stan ekranu), 25 powtórzeń
   słowa, polskie znaki, apostrof i cudzysłów, pole z maską. `input text` dla porównania. Decyzja:
   implementacja `typeid` / `type`.
10. E10 Tap po elemencie vs po współrzędnych, element częściowo zasłonięty (pasek kart, klawiatura).
11. E11 Jednostki. Ten sam testID: prostokąt z UiA2 (px) / 2.625 vs prostokąt z `rn-devtools tree`
    (dp): czy się zgadzają, czy różnią o wysokość paska statusu. Decyzja: jednostka drivera i
    poprawka w `tree`.
12. E12 Kolizje UiAutomation: `uiautomator dump` przy działającym serwerze UiA2; agent-device przy
    działającym serwerze. Czy `am instrument --no-window-animation` zmienia
    `transition_animation_scale` (a więc reduce motion w RN). Decyzja: reguła "jeden driver" i
    flagi startu serwera.
13. E13 Okna systemowe: dialog `POST_NOTIFICATIONS` i uprawnienie do zdjęć - czy widać je w
    `/source` z `enableMultiWindows`, jakie mają id przycisków; `pm grant` przed startem.
14. E14 Wstecz: `input keyevent 4` na ekranie z modalem i z BackHandler, targetSdk 35 i 36, RN
    0.81 i starszy. Decyzja: opis `button BACK` i pułapka w gotchas.
15. E15 Zrzut ekranu: czas `exec-out screencap -p`, rozmiar PNG, czas skalowania do szerokości w
    dp przez `sips`. Porównanie z `simctl io`.
16. E16 Pierwsza aktywność i foreground: `resolve-activity`, `am start -W` (TotalTime), który
    wpis `dumpsys` wskazuje aplikację z przodu na API 34 / 35 / 36.
17. E17 Deep link: `am start -d ... <pkg>` z dwoma buildami o tym samym schemacie; czy coś pyta o
    potwierdzenie; Expo dev client URL.

**Środowisko**

18. E18 Koszt: zimny start i start ze snapshotu, RAM Maca dla 1 i 2 emulatorów; `-read-only` dla
    dwóch instancji jednego AVD; etykieta instancji `-prop qemu.<tag>=...` i `getprop`;
    `adb emu avd name`.

Minimalny zestaw do decyzji o architekturze: E1, E2, E3, E7, E8, E9, E11. Reszta zasila
dokumentację i gotchas.

## 10. Kolejność implementacji (po fazie 2) i szacunek

Szacunki są zgrubne, z rozmiaru obecnego kodu iOS, nie z pomiaru.

1. **Rig-check Androida** (wspólna biblioteka + gałąź / skrypt Androida, logcat, `exit-info`,
   APK, przekierowanie) - duże (~400-600 linii). Bez tego nic innego nie ma sensu (Rig gate).
2. **Cykl życia i obserwacja bez drivera UI**: `devices`, `launch`, `relaunch`, `terminate`,
   `openurl`, `screenshot`, `foreground`, `button` przez `adb` - małe.
3. **Serwer UiA2: instalacja, start, dowód** (odpowiednik `wda-sim.sh ensure`), przypięta
   wersja - średnie.
4. **Driver UI**: `elements`, `waitfor`, `waitid`, `el`, `tapid`, `typeid`, `tap`, `swipe`,
   `longpress`, `type`, `do`, podsumowanie po błędzie - duże (największa część; logika z
   `wda_el.py` / `wda_tree.py` do przeniesienia).
5. **`targets.mjs` / `read-rn-logs-cdp.py`**: wybór po `logicalDeviceId` i platformie - małe, z
   testami w istniejącym `targets.test.mjs`.
6. **Dokumentacja**: `references/android.md`, sekcja w `gotchas.md`, `config-template.md`,
   SKILL.md (opis, wybór platformy), README - średnie.
7. **`regress.sh` / `simbench.sh` dla Androida** - średnie; dopiero gdy driver się ustabilizuje.
8. Telefon z Androidem - małe ponad emulator, jeśli punkt 4 od początku bierze serial z
   `ANDROID_SERIAL`.

## 11. Źródła

Kod źródłowy przeczytany lokalnie (RN 0.81.1, `node_modules` lokalnego projektu; RN 0.80.2 tylko
wersja):

- `ReactAndroid/.../uimanager/BaseViewManager.java` (`setTestId`)
- `ReactAndroid/.../uimanager/ReactAccessibilityDelegate.java` (`setDelegate`, `setViewIdResourceName`)
- `ReactAndroid/.../views/scroll/ReactScrollView.java`, `ReactHorizontalScrollView.java`,
  `views/modal/ReactModalHostView.kt`, `views/progressbar/ProgressBarContainerView.kt`
- `ReactAndroid/.../packagerconnection/PackagerConnectionSettings.kt`
- `ReactAndroid/.../modules/systeminfo/AndroidInfoHelpers.kt`
- `ReactAndroid/.../devsupport/DevServerHelper.kt`
- `ReactAndroid/src/main/jni/react/jni/JSLogging.cpp`, `jni/react/runtime/jni/JReactInstance.cpp`
- `ReactCommon/react/runtime/platform/ios/ReactCommon/RCTInstance.mm`
- `@react-native/js-polyfills/console.js`
- `@react-native/dev-middleware/dist/inspector-proxy/InspectorProxy.js`
- `@react-native/gradle-plugin/.../ReactExtension.kt`, `TaskConfiguration.kt`, `utils/AgpConfiguratorUtils.kt`

GitHub i dokumentacja (2026-11-20):

- https://github.com/facebook/react-native/blob/v0.83.0/packages/react-native/ReactAndroid/src/main/java/com/facebook/react/packagerconnection/PackagerConnectionSettings.kt
- https://github.com/facebook/react-native/blob/v0.76.0/packages/react-native/ReactAndroid/src/main/java/com/facebook/react/packagerconnection/PackagerConnectionSettings.kt
- https://github.com/facebook/react-native/commits/main/packages/react-native/ReactAndroid/src/main/java/com/facebook/react/packagerconnection/PackagerConnectionSettings.kt (PR #49848, #54139, #54687, #54852, #57425)
- https://github.com/facebook/react-native/blob/v0.83.0/packages/react-native/ReactAndroid/src/main/java/com/facebook/react/runtime/ReactHostImpl.kt
- https://github.com/facebook/react-native/blob/v0.83.0/packages/react-native/ReactAndroid/src/main/jni/react/jni/JSLoader.cpp
- https://github.com/facebook/react-native/blob/v0.83.0/packages/react-native/ReactAndroid/src/main/jni/react/runtime/jni/JReactHostInspectorTarget.cpp
- https://github.com/facebook/react-native/blob/v0.83.0/packages/react-native/ReactAndroid/src/main/java/com/facebook/react/devsupport/DevSupportManagerBase.kt
- https://github.com/facebook/react-native/blob/v0.83.0/packages/gradle-plugin/react-native-gradle-plugin/src/main/kotlin/com/facebook/react/ReactExtension.kt
- https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/react/renderer/components/view/ViewShadowNode.cpp
- https://github.com/facebook/react-native/pull/29610
- https://github.com/facebook/react-native/blob/main/packages/react-native/ReactAndroid/src/main/java/com/facebook/react/modules/accessibilityinfo/AccessibilityInfoModule.kt
- https://docs.swmansion.com/react-native-reanimated/docs/guides/accessibility
- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/cmds/uiautomator/cmds/uiautomator/src/com/android/commands/uiautomator/DumpCommand.java
- https://github.com/appium/appium-uiautomator2-server (README, `ServerConfig.java`, `ElementLocationHelpers.java`, `SendKeysToElement.java`)
- https://github.com/appium/appium-uiautomator2-driver (`lib/uiautomator2-server/core.ts`, `packages.ts`, `docs/reference/settings.md`, `locator-strategies.md`)
- https://github.com/expo/expo/blob/main/packages/expo-dev-launcher/android/src/debug/java/expo/modules/devlauncher/DevLauncherController.kt
- https://github.com/expo/expo/blob/main/packages/expo-dev-launcher/android/src/debug/java/expo/modules/devlauncher/launcher/DevLauncherRecentlyOpenedAppsRegistry.kt
- https://github.com/expo/expo/tree/main/packages/@expo/cli/src/start/platforms/android (`adbReverse.ts`, `AndroidPlatformManager.ts`)
- https://github.com/callstack/agent-device (README, v0.21.41), https://github.com/callstack/agent-device/pull/1645 (schowek)
- https://github.com/mobile-next/mobilecli (1.0.24)
- https://docs.maestro.dev/platform-support/react-native, https://docs.maestro.dev/troubleshooting
- https://developer.android.com/tools/adb, https://developer.android.com/tools/logcat
- https://developer.android.com/studio/run/emulator-commandline, https://developer.android.com/studio/run/emulator-console, https://developer.android.com/tools/avdmanager, https://developer.android.com/tools/agents/android-cli/commands/emulator_start
- https://developer.android.com/about/versions/16/behavior-changes-16, https://developer.android.com/guide/navigation/custom-back/predictive-back-gesture
- https://developer.android.com/develop/ui/views/notifications/notification-permission
- https://developer.android.com/reference/android/app/ApplicationExitInfo
- https://developer.android.com/studio/run/managing-avds, https://developer.android.com/studio/run/emulator-acceleration
- https://github.com/software-mansion/react-native-screens/discussions/2540 (Wstecz, RN 0.81 / 0.83.1)
- https://github.com/openatx/uiautomator2/issues/952 (foreground na Androidzie 14)
- https://github.com/appium/appium/issues/7745 (drugi klient UiAutomation)
- https://github.com/Genymobile/scrcpy/pull/6852 (skanowanie mediów, Android 16)
- https://hackernoon.com/your-users-type-faster-than-your-javascript-react-native-drops-the-difference (wyścig w kontrolowanym TextInput)
