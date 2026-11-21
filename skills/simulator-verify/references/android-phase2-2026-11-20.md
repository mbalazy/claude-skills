# Android, faza 2: weryfikacja praktyczna (emulator, symulator iOS, telefon)

Data: 2026-11-20 / 2026-11-21. Wejście: `skills/simulator-verify/references/android-analysis-2026-11-20.md` (faza 1, analiza bez urządzeń).
Ten dokument jest samowystarczalny dla fazy 3 (implementacja w nowej sesji): każda decyzja ma tu liczbę lub dowód, każdy przepis ma dokładną komendę.

Zakres fazy 2: testy, pomiary, analiza. Zero zmian w skryptach skilla. Kod napisany w fazie 2 to wyłącznie harness pomiarowy poza repo.

Oznaczenia wyników: PASS / FAIL (zachowanie zgodne / niezgodne z oczekiwanym), CONFIRMED / REFUTED (twierdzenie fazy 1 potwierdzone / obalone), PARTIAL, N-A, BLOCKED (z przyczyną). Identyfikatory dowodów (`D2`, `B4` ...) odpowiadają plikom `evidence/<ID>-*` w katalogu roboczym poza repo (patrz sekcja 9).

Publiczne stałe, które `scripts/check-leaks.sh` zgłaszałby jako fałszywe trafienia (od 2026-11-21 wpisane do `.leak-allow`): adresy aliasu hosta w emulatorze (`10.0.2.2`, Genymotion `10.0.3.2`), nazwy pakietów serwera Appium UiAutomator2 (`io.appium.uiautomator2.server`, `.test`), komponentów systemu Android (`com.android.permissioncontroller`, `com.google.android.permissioncontroller`, `com.android.vending`, `com.android.commands.am.Am`) i narzędzi open source (`dev.mobile.maestro`, `com.callstack.agentdevice.*`, `com.mobilenext.mobilecli.DeviceServer`). To nie są dane pracy.

## 0. Wnioski i decyzje dla fazy 3

Każda decyzja poniżej opiera się na pomiarach z sekcji 3 (w tym 3.GAP: pomiary dodane po teście zimnego czytelnika). Faza 1 była w większości trafna (sekcja 2, 30 twierdzeń: 21 CONFIRMED, 6 REFUTED, 2 PARTIAL, 1 niezaobserwowane). Najważniejsze obalone twierdzenia (V5, V9, V10) dotyczą wyboru hosta Metro i identyfikacji urządzenia, czyli dokładnie tego, na czym stoi rig-check; pozostałe (V27, V29) to szczegóły formatu i MediaStore.

| obszar | decyzja | dlaczego (liczby) |
|---|---|---|
| driver | **serwer UiAutomator2 11.2.4 uruchamiany samodzielnie** (`am instrument` + `adb forward` + HTTP), bez Appium | find 0,06 s, drzewo 5-20 ms jako HTTP (~100 ms dla 250 węzłów; 0,08-0,10 s jako nowy proces Pythona), klik 0,13 s, tekst unicode 0/25 strat w 30 ms (D3-D6, GAP3). Alternatywy: `uiautomator dump` 2 s i pada na animacji; agent-device podmienia klawiaturę; mobilecli gubi tekst po cichu; Maestro 3,5 s na odczyt (E) |
| ustawienia drivera | `disableIdLocatorAutocompletion=true` i `waitForIdleTimeout=0` w każdej sesji (nowa sesja wraca do 10000/false); nigdy `--no-window-animation`. Czytanie klatek przejść przy 0 obsłużyć sprawdzeniem prostokąta w granicach ekranu + pakietu węzła, a `--settled` jak na iOS: dwa odczyty 2 s od siebie | przy 10000 każde wywołanie na ekranie z nieskończoną animacją trwa 10 s (find + click 40 s), przy 1000 - 1,1 s (D4). Przy 0 element wjeżdżającego Modala jest `displayed=true` poniżej ekranu przez ~0,3 s; prostokąt przesuwanego widoku zmienia się przez całe 1,5 s. Czekanie na bezczynność NIE jest ogólnym lekiem: dla Modala find przy 1000 czeka 0,75 s, ale dla przesuwu z native driverem wraca po 0,01 s z pozycją startową (GAP2). Odstęp 2 s łapie oba zmierzone przypadki; krótsze okno niesprawdzone |
| zdrowie drivera | test realnym `/source` z krótkim limitem, nie `/status` | po restarcie adbd `/status` = ready, a `/source` czeka 10 s i pada (D1c) |
| jednostka | **dp** w całym publicznym interfejsie (jak pt na iOS); px tylko wewnątrz | `rn-devtools tree`, `measureInWindow` i `onLayout` mówią w dp; px UiA2 / skala = dp co do 0,1 (G). Skalę czytać z `wm density` (emulator 2,625, telefon 3,0). Okno = ekran zmierzone tylko dla szablonu edge-to-edge; aplikacja bez edge-to-edge (przesunięcie o pasek statusu?) niesprawdzona (sekcja 8) |
| przekierowanie Metro | **klucz `debug_http_host` wpisany przez `run-as` po `force-stop`, scalony z istniejącym plikiem prefów (odczyt w całości, potem zapis)**; w Expo dev-client URL `exp+<slug>://expo-development-client/?url=...`; na telefonie `adb reverse` + host `localhost:<p>` | pref przeżywa restart i `install -r`, działa przed pierwszym startem (B1); zapis w potoku odczyt-zapis gubi pozostałe klucze (GAP5); `metro.host` wymaga roota; 0.88 zapisuje pref (faza 1 sądziła, że tylko pamięć - V5). `localhost` + `adb reverse` sprawdzone na emulatorze (B1), na telefonie NIE (sekcja 7) |
| kanał markera i wyzwalacz | **logcat `ReactNativeJS`** z filtrem `-T <czas urządzenia>`. Wyzwalacz rig-checka: **zimny start**; po zobaczeniu markera rig-check cofa marker i robi **drugi zimny start** (odpowiednik `/reload` po markerze z iOS). Reload (broadcast `<pkg>.RELOAD_APP_ACTION -p <pkg>` albo `/reload` Metro) tylko na aplikacji gotowej, nigdy w trakcie startu | marker po zimnym starcie 1,18-1,74 s (B2, n=8) i 1,82-2,11 s (GAP1, n=3); broadcast 0,46-0,48 s (B2, n=8) i 0,78-0,92 s (GAP1, n=3). Zimny start 10/10 czysto, na gotowej aplikacji broadcast i `/reload` 10/10 czysto; broadcast 0,3 s po starcie: trwały redbox w 9/12 (Reanimated/Worklets), 1,5 s po starcie: 2/10 - czyli tuż po markerze reload jest niebezpieczny (GAP1) |
| identyfikacja urządzenia | serial z `adb devices` + nazwa AVD z `emu avd name`; **jedno Metro (port) na emulator**, ustawione prefem; cel CDP wybierany po porcie Metro | `lsof` pokazuje wspólny `netsimd`; dwa emulatory z jednego obrazu mają identyczny `deviceName`; `logicalDeviceId` nie do policzenia z adb (B3, V8-V10). Sprawdzone: dwa takie emulatory na :8121 i :8122 -> każdy port ma 1 cel, `console.log` wysłany przez CDP na port trafia do logcat właściwego emulatora (GAP8) |
| rig-check | osobny przepis Androida (4.3) z nowymi werdyktami: wbudowany bundle (obecność: `unzip -l` na urządzeniu w 0,03 s; to, że jest UŻYWANY zamiast Metro: tylko logcat), JS rzuca przy ładowaniu (proces żyje, redbox w drzewie), aplikacja nie-debuggable (brak `run-as`), Expo dev-client na ekranie launchera | B4, B6, B8, B9 |
| struktura skryptów | osobny driver Androida z tym samym słownikiem komend co `sim-ui.sh` (sekcja 5) + osobny rig-check Androida; skrypty CDP, sondy i pomiarów współdzielone bez zmian | `rn-devtools.mjs`, `read-rn-logs-cdp.py`, `probe-collector.py`, `measure-*.py` działają na Androidzie bez zmian (K, J, G) |
| współistnienie | driver sprawdza przed startem, czy UiAutomation trzyma inny klient, i zwalnia własny serwer po pracy | pierwszy klient wygrywa, przegrani padają po cichu albo po 10-19 s (D8) |
| telefon | **nieprzetestowany** poza dodaniem i usunięciem `adb reverse`; faza 3 musi go zmierzyć osobno, z człowiekiem przy pierwszej instalacji i odblokowaniu | Play Protect zablokował `adb install` na zablokowanym telefonie (sekcja 7) |

**Decyzje uzgodnione z użytkownikiem (2026-11-21, po fazie 2; wiążą fazę 3 i rozstrzygają listę "decyzje otwarte" niżej):**
1. Jeden skill: Android wchodzi do `simulator-verify`. Wspólna pętla, bramka rig-checka, config i narzędzia CDP. Różnice Androida w nowym `references/android.md`. Nazwa skilla zostaje, z opisu znika "iOS only".
2. Osobne skrypty z tym samym zestawem komend co `sim-ui.sh`: `scripts/android-ui.sh` (driver) i `scripts/android-rig-check.sh`. Przedrostek "android-", bo ten sam skrypt obsłuży telefon.
3. Język: bash z helperami w Pythonie (`u2_tree.py`, `u2_el.py`), układ jak `wda_tree.py` / `wda_el.py`.
4. Zakres fazy 3: emulator, RN CLI i Expo dev-client. Telefon to ostatni blok, w osobnej sesji z użytkownikiem (Play Protect, PIN).
5. Macierz wsparcia w references jako "sprawdzone": API 34/35/36 google_apis arm64, RN 0.88.1 (CLI, Expo SDK 58), RN 0.81.1. Innych wersji nie blokować.
6. APK serwera UiA2 11.2.4: cache na hoście `~/.cache/uia2-server/11.2.4/`, pobierany z npm `appium-uiautomator2-server@11.2.4`, sprawdzany przypiętym sha256, katalog nadpisywalny zmienną (wzorzec `WDA_DEVICE_HOME`). Żadnych binarek w repo.
7. Sesja UiA2: użyć istniejącej z `GET /sessions` (nowa, gdy brak) i przy każdej komendzie ponowić `waitForIdleTimeout=0` + `disableIdLocatorAutocompletion=true`.
8. Domyślny filtr `elements`: reguła po treści - węzeł zostaje, gdy ma `resource-id`, `text` lub `content-desc`, albo jest klikalnym `Button` / `EditText` / `Switch` / `CheckBox`. Przed zamrożeniem sprawdzić na dużym ekranie fixture'a i na aplikacji R (liczba węzłów przed i po filtrze).
9. Zmienne: urządzenie `ANDROID_SERIAL`, port `U2_PORT`. Bez `U2_PORT`: istniejący forward tego seriala na `tcp:6790` z `adb forward --list`, inaczej pierwszy wolny port z 8210-8229 (poza 8080-8199: Metro, WDA, sonda). `adb forward --list` służy też do sprawdzenia właściciela portu (odpowiednik `assert_wda_owner`).
10. `debug_http_host` zostaje po rig-checku; rig-check wypisuje "było X, jest Y".
11. Kolejność pomiarów w fazie 3: najpierw pytania #14, #17, #5, #13 z sekcji 8 (zmieniają kod); przy telefonie #10 i #16; #7 i #8 zamyka implementacja i jej test na aplikacji R; #1, #2, #3, #4, #6, #9, #11, #12 opisane w references jako niesprawdzone.
12. Wiek binarki: sha zainstalowanego APK vs najnowszy APK w `android/app/build/outputs/apk/` testowanego repo; bez lokalnego buildu pominąć z komunikatem.
13. Publiczne stałe Androida i narzędzi open source są w `.leak-allow` (nagłówek raportu); raporty fazy 1 i 2 zacommitowane przed fazą 3.
14. Do repo trafia tylko źródło ekranu testowego (`App.tsx`, `rigswitch.ts`); resztę aplikacji fixture'a generuje się od nowa.
15. Faza 3 idzie jako kolejka `/solo` przygotowana przez `/solo-prep`; telefon w osobnej sesji z użytkownikiem.

**Decyzje otwarte po fazie 2 (stan przed uzgodnieniem; rozstrzygnięte w punktach 6-10 wyżej):**
- Gdzie skill trzyma przypięte APK serwera UiA2 (cache na hoście jak `~/.cache/wda-device` dla WDA, czy pliki w repo).
- Model sesji przy driverze "proces na komendę": każda nowa sesja unieważnia poprzednią i wraca do domyślnych ustawień (GAP3), więc albo ponowne użycie sesji z `GET /sessions` (0,04 s), albo nowa sesja + ustawienia przy każdej komendzie (~0,05 s + ustawienia).
- Domyślny filtr `elements` bez `--all` (iOS: lista typów w `wda_tree.py`). Klasy z ekranu Components: `TextView`, `android.view.View` (Text z `accessibilityRole="header"`), `Button`, `ImageView`, `EditText`, `Switch`, `ViewGroup` (Pressable, View), `HorizontalScrollView` (3.F). Lista oparta tylko na klasach zgubi nagłówki (`android.view.View`) albo przepuści każdy `ViewGroup`; regułę trzeba ustalić na tej liście.
- Nazwy zmiennych i domyślny port: faza 1 proponowała `U2_PORT` obok `SIM_UDID`/`WDA_PORT`; adb sam honoruje `ANDROID_SERIAL`. W fazie 2 używano portu 8210 bez reguły przydziału.
- Czy rig-check zostawia `debug_http_host` po sobie, czy przywraca poprzednią wartość. Fakty: pref przeżywa restart aplikacji i `install -r` (restartu emulatora nie sprawdzano); kasuje go `pm clear` lub usunięcie klucza. Na iOS `-RCT_jsLocation` żyje tylko jedno uruchomienie.

Największe ryzyka dla fazy 3:
1. Wbudowany bundle w wariantach z flavorem. Potwierdzony na prawdziwej aplikacji; to, że aplikacja go używa zamiast Metro, widać tylko w logcat.
2. Reload w trakcie startu: trwały redbox w aplikacjach z Reanimated.
3. Nierozróżnialne emulatory z jednego obrazu na jednym Metro.
4. Skutki uboczne narzędzi na stanie urządzenia: skale animacji, klawiatura, UiAutomation.

## 1. Środowisko i wersje

| element | wartość |
|---|---|
| host | Mac, Apple M5 Pro, 64 GB RAM, macOS 27.0.1 |
| Xcode | 27.2 (27B52), runtime iOS 27.0 |
| Android SDK | platform-tools / adb 37.0.1, emulator 37.2.13, build-tools 35/36, cmdline-tools (avdmanager, sdkmanager); brak nowego CLI `android` |
| JDK / Node | OpenJDK 17.0.21, Node 25.8.1 |
| obrazy systemu | `android-34`, `android-35`, `android-36` `google_apis` arm64-v8a |
| AVD | `svp2-api34`, `svp2-api35`, `svp2-api36`: profil `pixel_9`, 1080x2424, 420 dpi, RAM 4 GB, `hw.gpu.mode=host`, `hw.keyboard=no` |
| fixture'y | F-EXPO: Expo SDK 58, RN 0.88.1, expo-dev-client 58.0.x, Reanimated 4.7.1, worklets 0.13.0. F-CLI: `@react-native-community/cli init` RN 0.88.1, ten sam `App.tsx`, flavory opcjonalne (`-PsvFlavors`) |
| prawdziwa aplikacja | duża aplikacja RN 0.81.1 klienta (anonimizowana: "aplikacja R"), gotowy debug APK wariantu z flavorem, ~440 MB |
| telefon | Android 16 (API 36), build `user`, nakładka producenta |
| UiAutomator2 server | 11.2.4 (versionCode 315, targetSdk 34, minSdk 26) |
| agent-device | 0.21.41 |
| mobilecli | 1.0.24 |
| Maestro | 2.12.1 |

## 2. Weryfikacja twierdzeń fazy 1

Kolumna "faza 1" wskazuje sekcję raportu fazy 1. Dowód = plik w `evidence/` katalogu roboczego.

| # | twierdzenie fazy 1 | faza 1 | wynik | co pokazał pomiar | dowód |
|---|---|---|---|---|---|
| V1 | testID trafia do `resource-id` jako goła wartość (bez prefiksu pakietu) | 4.1 | CONFIRMED | View, Text, Image, Pressable, Switch, ScrollView, HorizontalScrollView, TextInput, Modal: `resource-id="Comp-switch"`. Elementy systemowe mają prefiks (`com.android.permissioncontroller:id/...`) | F, A1 |
| V2 | zagnieżdżony `<Text testID>` nie ma własnego węzła | 4.1 | CONFIRMED | `Comp-text-inner` nie istnieje w żadnym drzewie (UiA2, `uiautomator dump`, agent-device); tekst sklejony w rodzicu "Outer inner tail". `rn-devtools tree` go widzi (bez prostokąta) | F, D3, K |
| V3 | Fabric nie spłaszcza widoku z testID | 4.1 | CONFIRMED (kod 0.88) + praktyka | `Comp-view` (pusty View z testID) obecny. Wyjątek: View z `opacity:0` nie występuje w drzewie dostępności w ogóle (także z `allowInvisibleElements=true`) | F, A2 |
| V4 | kolejność hosta: pref `debug_http_host` > `metro.host` > 10.0.2.2 > localhost; port z resValue | 4.2 | CONFIRMED | pref zapisany przez `run-as` po `force-stop` przekierowuje i przeżywa restart; bez prefu emulator idzie na `10.0.2.2:<port z buildu>`; `metro.host` działa tylko z `adb root`, sam host | B1 |
| V5 | RN 0.83+ trzyma host tylko w pamięci | 4.2 | REFUTED dla 0.88 | 0.88 zapisuje pref ORAZ cache w pamięci procesu (companion object). Pref zmieniony przy żywym procesie nie działa do restartu procesu; po `force-stop` działa | A3, B1 |
| V6 | brak odpowiednika `-RCT_jsLocation` | 4.2 | PARTIAL | goły RN: brak (zostaje pref przez `run-as`). Expo dev-client: TAK - URL `exp+<slug>://expo-development-client/?url=<enc>` wybiera serwer przy każdym starcie i sam zapisuje `debug_http_host` | B1, B8 |
| V7 | `adb reverse` nie wpływa na domyślny host emulatora | 4.2 | CONFIRMED | domyślnie ruch idzie przez 10.0.2.2 (proces hosta `netsimd`); `localhost:<p>` w prefie działa tylko z `adb reverse`, wtedy właścicielem połączenia na hoście jest `adb` | B1 |
| V8 | inspector `deviceName` = "MODEL - RELEASE - API N", identyczny dla dwóch emulatorów z jednego obrazu | 4.3 | CONFIRMED | dwa AVD z obrazu API 36: oba "sdk_gphone64_arm64 - 16 - API 36", `title` też identyczny; `rn-devtools` odmawia (rc=2), a `--page 1` nie rozróżnia (oba mają page 1) | B3 |
| V9 | `logicalDeviceId` z ANDROID_ID da się policzyć z adb | 4.3 | REFUTED | ANDROID_ID jest per klucz podpisu aplikacji; `settings get secure android_id` z powłoki daje inną wartość, z `run-as` - SecurityException. Hash nie do odtworzenia z zewnątrz | B3 |
| V10 | identyfikacja emulatora z `lsof` na porcie Metro | 4.3 (pomysł) | REFUTED | połączenia wszystkich emulatorów idą przez JEDEN wspólny proces `netsimd` (dziecko pierwszego emulatora) | B3 |
| V11 | `console.*` trafia do logcat tag `ReactNativeJS` także przy podłączonym CDP | 4.4 | CONFIRMED | marker i logi `[FIXTURE]` w logcat przy aktywnym `read-rn-logs-cdp.py` | B2, K |
| V12 | debug build po cichu wraca do bundla z assets, gdy Metro nie odpowiada; wariant z flavorem (`devDebug`) jest bundlowany | 4.5 | CONFIRMED | `devDebug` zawiera `assets/index.android.bundle` (1,9 MB); z martwym Metro UI renderuje się, marker nie przychodzi; jedyny ślad: logcat `isMetroRunning(): Async result = false` + "The packager does not seem to be running". Domyślne `debuggableVariants` w 0.88 = `debug`, `debugOptimized` | B4, A7 |
| V13 | crash widać w `dumpsys activity exit-info` | 4.6 | CONFIRMED | reason=4 (JAVA), reason=5 status=11 (SIGSEGV), reason=10/sub 21 (force-stop); `logcat -b crash` ma pełny ślad; `/data/tombstones` czytelny z powłoki na obrazie userdebug | B5 |
| V14 | wiek binarki z `dumpsys package` | 4.7 | CONFIRMED | `lastUpdateTime`, `firstInstallTime`, `pkgFlags=[ DEBUGGABLE ...]`; `install -r` zachowuje prefy i podbija `lastUpdateTime`; lepszy sygnał: `sha256sum` base.apk na urządzeniu (0,06 s) == sha lokalnego APK | B9 |
| V15 | UiA2 server jako główny driver | 4.8 | CONFIRMED z warunkami | najszybszy odczyt drzewa (5-20 ms), unicode, kliknięcia po elemencie; warunki: `waitForIdleTimeout=0`, `disableIdLocatorAutocompletion=true`, zdrowie sprawdzane realnym zapytaniem, nie `/status` | D1-D9 |
| V16 | strategia `id` UiA2 dokleja `pkg:id/` | 4.8 | CONFIRMED | `id=Comp-switch` -> "no such element"; po `disableIdLocatorAutocompletion=true` działa (60 ms) | D3 |
| V17 | `input text` tylko ASCII | 4.9 | CONFIRMED | `zażółć` -> wyjątek Java, rc=255; `%s` = spacja; `&` wymaga cytowania; ASCII bez strat 25/25 | C2 |
| V18 | gęstość 420 dpi = 2,625 px/dp, obecny kod zakłada całkowitą skalę | 4.10 | CONFIRMED | `wm density` 420 na API 34/35/36; prostokąty UiA2 / 2,625 = `measureInWindow` co do 0,1 dp | G |
| V19 | `transition_animation_scale=0` włącza reduce motion RN/Reanimated | 4.12 | CONFIRMED | tylko ta skala; `window_` i `animator_duration_scale` = 0 nie zmieniają wskaźników | H4 |
| V20 | `am instrument --no-window-animation` może zmieniać skale | 4.12 | CONFIRMED (gorzej niż sądzono) | ustawia WSZYSTKIE trzy skale na 0 na czas pracy serwera -> aplikacja widzi reduce motion; po zatrzymaniu wpisuje 1.0 (także tam, gdzie było `null`) | H4 |
| V21 | `uiautomator dump` czeka na bezczynność i pada "could not get idle state" | 4.8 | CONFIRMED (gorzej) | na ekranie z nieskończoną animacją ZAWSZE pada po 11 s, z kodem wyjścia 0 | C1 |
| V22 | tylko jeden klient UiAutomation naraz | 4.18 | CONFIRMED | `uiautomator dump` przy żywym UiA2: rc=137, pusty stdout/stderr, przyczyna tylko w logcat; między narzędziami wygrywa pierwszy właściciel | D8 |
| V23 | `cmd clipboard` nie działa na API 35-36 | 4.13 | CONFIRMED | "No shell command implementation" na 35 i 36; zastępczo UiA2 `set_clipboard` + `KEYCODE_PASTE` | H6 |
| V24 | wstecz: `OnBackPressedCallback` przy targetSdk 36 na API 36, inaczej legacy | 4.11 | CONFIRMED (kod) / PASS (praktyka) | `keyevent 4` i UiA2 `/back` docierają do `BackHandler` na API 34, 35, 36; Modal zamyka się przez `onRequestClose` bez `BackHandler`; na ekranie głównym aplikacja idzie w tło, proces żyje | H1, A11 |
| V25 | Expo dev-client pamięta ostatni URL | 4.5 (pytanie) | REFUTED | po `force-stop` zwykły start pokazuje ekran launchera (DevLauncherActivity) | B8 |
| V26 | `avdmanager`/`emulator` wycofywane na rzecz CLI `android` | 4.16 | NIE ZAOBSERWOWANO | w SDK (cmdline-tools latest) nie ma `android`; `avdmanager` i `emulator` działają bez ostrzeżeń | I3 |
| V27 | serwer UiA2 mówi "HTTP W3C" | 4.8, tabela B | REFUTED (dla samego serwera) | serwer odrzuca W3C `{"using","value"}` ("mandatory field 'selector'"); przyjmuje `{"strategy","selector"}`. Tłumaczenie W3C robi sterownik Appium, którego nie używamy | D |
| V28 | tombstone w `/data/tombstones` wymaga roota | 4.6 | PARTIAL | na obrazie emulatora `google_apis` (userdebug) czytelny z powłoki bez roota; na buildzie `user` (telefon) niesprawdzony | B5 |
| V29 | plik z `adb push` trzeba zarejestrować w MediaStore (`scan_file`) | 4.16 | REFUTED dla API 36 | `adb push` do `/sdcard/Pictures` widoczny w `content query` od razu, bez skanu | H6 |
| V30 | przy `waitForIdleTimeout=0` odczyt łapie klatkę animacji (jak na iOS) | 4.8 | CONFIRMED | przy 0: prostokąt przesuwanego widoku zmienia się co odczyt; element wjeżdżającego Modala `displayed=true` poniżej ekranu przez ~0,3 s. Przy 1000 i 10000 pierwszy odczyt czeka na koniec przejścia | GAP2 |

## 3. Wyniki bloków

### A. Kod RN 0.88.1 vs 0.81.1 (czytany w `node_modules` fixture'a)

| element | 0.88 vs 0.81 | szczegół ważny dla fazy 3 |
|---|---|---|
| testID -> `viewIdResourceName` (`BaseViewManager`, `ReactAccessibilityDelegate`) | bez zmian (przepisane na Kotlin) | TextInput (`ReactEditText`) zawsze ma delegata, więc zawsze ma resource-id |
| `ViewShadowNode` (spłaszczanie) | +1 warunek | `pointerEvents="box-only"` też tworzy kontekst; testID nadal wymusza widok |
| `PackagerConnectionSettings` | ZMIENIONE | setter zapisuje pref i cache w companion object; getter: cache -> pref -> `getServerHost` (wynik też cache'owany) |
| `AndroidInfoHelpers` | bez zmian / `getInspectorHostMetadata.deviceName` = "MANUFACTURER MODEL" (metadane hosta inspektora; to NIE jest pole `deviceName` z `/json/list`, które ma postać "MODEL - RELEASE - API N", V8; `targets.mjs` i `read-rn-logs-cdp.py` dopasowują `--device` do pola z `/json/list`) | wykrycie emulatora: FINGERPRINT zawiera `generic` lub zaczyna się `google/sdk_gphone` |
| `DevServerHelper` | schemat https gdy host kończy się `:443` | `device=sha256("android-<pkg>-<ANDROID_ID>-fusebox")` |
| `RELOAD_APP_ACTION` | bez zmian | akcja `<pkg>.RELOAD_APP_ACTION`, rejestrowana tylko z włączonym dev support, `RECEIVER_EXPORTED` na API 34+ |
| logowanie (`JSLogging.cpp`, `JReactInstance.cpp`) | bez zmian | tag `ReactNativeJS`, priorytet = poziom + DEBUG; brak flagi wyłączającej |
| `ReactHostImpl` ładowanie bundla | +gałąź `bundleFilePath` | martwy Metro -> loader delegata (assets) po cichu |
| `debuggableVariants` | ZMIENIONE: `["debug","debugOptimized"]` | porównanie z `variant.name` bez wielkości liter, więc `devDebug` jest bundlowany |
| resValues | +`react_native_dev_server_ip` (IP hosta BUILDU) | używany tylko do podpowiedzi w dialogu "Change Bundle Location" |
| `isReduceMotionEnabled` | bez zmian | `Settings.Global.TRANSITION_ANIMATION_SCALE == 0` |
| inspector `/json/list` | bez zmian | pola: id, title, description, appId, type, devtoolsFrontendUrl, webSocketDebuggerUrl, vm, deviceName, reactNative{logicalDeviceId, capabilities}; BRAK `platform` |
| wstecz | event `hardwareBackPress` niesie `timeStamp`; callback ponownie włączany | brak `OnBackInvokedCallback` w RN; Expo zawsze wpisuje `android:enableOnBackInvokedCallback` (domyślnie `false`) |

### B. Rig

**B1 host:port.** Tabela zachowań (fixture RN CLI, Metro na hoście `:8121`, drugi Metro `:8122`):

| konfiguracja | efekt | czas do JS |
|---|---|---|
| brak prefu | `10.0.2.2:8121` (port z resValue `react_native_dev_server_port`) | 1,4-2,5 s |
| pref `10.0.2.2:8122` zapisany po `force-stop` | aplikacja na `:8122`; przeżywa kolejny `force-stop` + start | 1,9-2,5 s |
| pref `localhost:8122` bez `adb reverse` | "Unable to load script"; logcat: "Failed to connect to localhost/127.0.0.1:8122" | - |
| pref `localhost:8122` + `adb reverse tcp:8122 tcp:8122` | działa; na hoście połączenie należy do procesu `adb` | 2,0 s |
| `setprop metro.host` jako shell | "Failed to set property" rc=1 | - |
| `adb root` + `setprop metro.host localhost` + reverse | działa, sam host; port nadal z resValue; czyszczenie `setprop metro.host ""` | 1,3 s |

`aapt2 dump resources <apk>` czyta port z APK w 0,05 s. Katalog `shared_prefs` nie istnieje przed pierwszym uruchomieniem, ale `run-as <pkg> mkdir -p shared_prefs` + zapis pliku `<pkg>_preferences.xml` działa przed pierwszym startem. Pułapka cytowania: `adb shell run-as <pkg> sh -c "cat > F"` wykonuje przekierowanie w powłoce `shell`, nie aplikacji - trzeba `adb shell "run-as <pkg> sh -c 'cat > F'"`.

**B2 marker** (pierwsza linia `index.js`, odczyt `adb logcat -d -T <czas urządzenia> -s ReactNativeJS:V`, n=8):

| wyzwolenie | mediana | zakres |
|---|---|---|
| `am force-stop` + `am start` (zimny) | 1,59 s | 1,18-1,74 s |
| `am broadcast -a <pkg>.RELOAD_APP_ACTION -p <pkg>` | 0,47 s | 0,46-0,48 s |
| `curl -X POST :<port>/reload` | 0,47 s | 0,46-0,74 s |

Uwaga: `/reload` Metro przeładował tylko aplikację na pierwszym planie (druga, w tle, podłączona do tego samego Metro, nie przeładowała się); broadcast trafia dokładnie w wskazany pakiet. `read-rn-logs-cdp.py` (bez zmian) czyta te same logi z historią sprzed podłączenia.

**B3 kto jest czyj.** Szczegóły w V8-V10. Dodatkowo: aplikacja w stanie redbox (`runtime not ready`) nie ma strony w `/json/list` wcale. `title` strony = "<appId> (<MANUFACTURER> <MODEL>)".

**B4 wbudowany bundle.** Szczegóły w V12. `unzip -l <base.apk>` NA URZĄDZENIU (toybox ma `unzip`) wykrywa bundle w 0,03 s - bez `adb pull`.

**B5 śmierć procesu.** Szczegóły w V13. Systemowe okno "keeps stopping" nie pojawiło się po pojedynczych crashach (fokus wrócił do launchera).

**B6 JS rzuca przy ładowaniu.** Dla `throw` i dla `TurboModuleRegistry.getEnforcing('NoSuchModule')`: proces ŻYJE, logcat `E ReactNativeJS: [runtime not ready]: <komunikat>` + `E unknown:ReactNative: ... JavascriptException`, a w drzewie dostępności redbox: teksty `RELOAD (R, R)`, `DISMISS (ESC)` i pełny komunikat. Komunikat skew ma ten sam tekst co na iOS ("could not be found. Verify that a module by this name is registered in the native binary").

**B7 reload.** Patrz B2. Expo dev server też obsługuje `/reload` (HTTP 200).

**B8 Expo dev-client (SDK 58).** Zimny start bez URL-a -> `expo.modules.devlauncher.launcher.DevLauncherActivity` (ekran "DEVELOPMENT SERVERS"). `am start -a android.intent.action.VIEW -d 'exp+<slug>://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A<port>' <pkg>` -> aplikacja w ~2 s; launcher sam zapisuje `debug_http_host=10.0.2.2:<port>` i `expo.modules.devlauncher.recentyopenedapps.xml`. `force-stop` + zwykły start -> znów launcher. Deep link schematu aplikacji przy zimnym starcie -> launcher, nie aplikacja. Po załadowaniu z serwera deep linki działają.

**B9 binarka.** Szczegóły w V14. Inny klucz podpisu: `INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package <pkg> signatures do not match newer version` rc=1.

### C. Gołe adb

| operacja | wynik |
|---|---|
| `uiautomator dump` (ekran lekki / Components) | 2,0 s, 16 KB; `--compressed` 1,97 s 12 KB; zawiera elementy częściowo poza ekranem (szerokość ujemna) |
| `uiautomator dump` na ekranie z `Animated.loop` | "ERROR: could not get idle state." po 11,0 s, rc=0, także `--compressed` i `/dev/tty` |
| `uiautomator dump` przy żywym UiA2 | rc=137, pusty stdout i stderr; logcat: `IllegalStateException: UiAutomationService ... already registered!` |
| `uiautomator dump --windows` | działa na API 34/35/36 (`<displays><display><window ...>`) |
| `input text` | ASCII per klawisz (0/25 strat, także pole z maską), ~0,45 s na wywołanie; unicode -> wyjątek rc=255 |
| `input swipe x y x y 800` | long press 0,85 s; `input swipe` przewija listę |
| `exec-out screencap -p` | 1,4-2,4 s, 1,38 MB (1080x2424); surowy `screencap` 1,2-2,2 s (koszt to przechwycenie, nie PNG) |
| `adb emu screenrecord screenshot <dir>` | 0,18-0,26 s, 1,85 MB; plik nazwany od sekundy - dwa w jednej sekundzie nadpisują się; tylko emulator |
| foreground | `dumpsys activity activities` -> `topResumedActivity=` (0,05 s); `dumpsys window` -> `mCurrentFocus=` (0,09 s); te same pola na API 34/35/36; wygaszony ekran -> `mCurrentFocus=null` |

### D. Serwer UiAutomator2 11.2.4 (uruchamiany bez Appium)

- **D1 start:** `adb install -r -g` obu APK (~0,1 s, instalacja przyrostowa dzięki `.idsig`), `adb forward tcp:<P> tcp:6790`, `adb shell am instrument -w -e disableAnalytics true io.appium.uiautomator2.server.test/androidx.test.runner.AndroidJUnitRunner` w tle -> `GET /status` "ready" po 0,5-1,8 s.
- **D1b/c zdrowie:** restart adbd (`adb root`/`unroot`) zrywa forward i proces `am instrument` po stronie hosta; proces serwera na urządzeniu żyje i `/status` mówi `ready:true`, ale `/source` czeka 10,1 s i zwraca "Timed out ... waiting for the root AccessibilityNodeInfo". To samo "ready" przy UiAutomation zajętym przez inne narzędzie (`POST /session` -> "UiAutomation not connected"). Wniosek: `/status` NIE jest dowodem zdrowia.
- **D2 sesje:** drugi `POST /session` po cichu unieważnia pierwszą ("invalid session id" dla starej).
- **Format:** serwer przyjmuje `{"strategy":"id","selector":"..."}`, NIE W3C `{"using","value"}` (to tłumaczy sterownik Appium); błąd "no such element" przychodzi z HTTP 404.
- **D3 wyszukiwanie (n=10):** `id` (po wyłączeniu autouzupełniania) 0,054-0,066 s; xpath `//*[@resource-id="X"]` 0,079-0,102 s; `-android uiautomator` 0,066 s; brak elementu: błąd natychmiast (0,07 s), bez czekania - serwer nie ma niejawnego oczekiwania dla `id`.
- **D4 `/source`** (`waitForIdleTimeout`): lekkie ekrany 5-17 ms, ekran 250 węzłów 98 ms (w drzewie tylko 52 widoczne). Z nieskończoną animacją (`Animated.loop` native driver lub pętla Reanimated): 10,04 s przy 10000 (domyślnie), 1,1 s przy 1000, 7 ms przy 0 - wynik poprawny we wszystkich przypadkach. `ActivityIndicator` nie blokuje. `find` + `click` przy 10000 i animacji: 40 s.
- **D5 click:** po elemencie 0,13 s; tap w środek zasłoniętego elementu "udaje się" (trafia w zasłonę, brak błędu - jak na iOS).
- **D6 `value`:** pole kontrolowane, niekontrolowane, z maską: unicode, emoji, `O'Brien "x" & <tag> $HOME` - wszystko dokładnie; 0/25 strat; ~30 ms. Ustawia cały tekst naraz: `onChangeText` wywołuje się raz na `value`, nie per znak (inaczej niż `input text` i mobilecli). Return: `POST /appium/device/press_keycode {"keycode":66}` -> `onSubmitEditing`.
- **D7:** `enableMultiWindows=true` przy otwartej klawiaturze: 34 -> 323 węzły (systemui + IME). Okno uprawnień jest aktywnym oknem, więc domyślny `/source` pokazuje TYLKO je.
- **D8 kolizje:** patrz V22. agent-device pierwszy -> sesja UiA2 nie powstaje; UiA2 pierwszy -> agent-device `snapshot` pada po 10,5 s. mobilecli trzyma UiAutomation przez proces `DeviceServer` z bezczynnością 30 min.
- **D9:** `adb forward --list` pokazuje `<serial> tcp:<P> tcp:6790` - wiąże port hosta z serialem.
- brak endpointów `is_keyboard_shown` / `hide_keyboard` (unknown command) - to robi sterownik Appium przez `dumpsys input_method`.

### F. Semantyka drzewa (UiA2 `/source`, ekran Components)

| element RN | class | text | content-desc | uwagi |
|---|---|---|---|---|
| `Text testID` | TextView | tekst | - | |
| `Text accessibilityRole="header"` | android.view.View | tekst | - | klasa View, nie TextView |
| zagnieżdżony `Text testID` | - | - | - | brak węzła (V2) |
| `View testID` (pusty) | ViewGroup | - | - | |
| `View opacity:0` | - | - | - | brak węzła |
| `Image testID` | ImageView | - | - | |
| `Pressable` bez etykiety | ViewGroup | - | - | clickable+focusable |
| `Pressable` z dzieckiem Text | ViewGroup | - | tekst dziecka | dziecko TextView też jest w drzewie |
| `Pressable accessibilityLabel` | ViewGroup | - | etykieta | widoczny tekst dziecka osobno |
| `Switch` | Switch | - | - | checkable, `checked` |
| `accessibilityState busy` | ViewGroup | - | "Loading data, busy" | |
| `accessibilityValue text` | ViewGroup | - | "Volume, 50 percent" | |
| `accessible role=button` z dziećmi | Button | - | "Child A, Child B" | |
| element zasłonięty | - | - | - | `displayed=true` - brak wykrywania przesłonięcia |
| ScrollView poziomy | HorizontalScrollView | - | - | dzieci poza widokiem nie istnieją w drzewie (UiA2), dump pokazuje jedno częściowo |
| FlatList 100 wierszy | - | - | - | w drzewie tylko widoczne (0..14); `rn-devtools tree --all` widzi 100 zamontowanych |

`uiautomator dump` daje te same atrybuty (bez `displayed`). Atrybuty elementu z UiA2 (`text`, `rect`, `attribute/displayed|resource-id|content-desc|class|bounds`) ~65 ms każdy.

### G. Jednostki i geometria

`wm size` 1080x2424, `wm density` 420 na wszystkich AVD (API 34/35/36). `rn-devtools tree` drukuje "Screen: 411x923 pt" - to dp. Tap w `(x,y)` z `tree` przemnożone przez 2,625 trafia (`input tap`). Prostokąty UiA2 w px / 2,625 = `measureInWindow` (np. pill `[383,363]` px -> 145,9/138,3 dp, app: 145,9/138,3). Okno = ekran (szablon RN 0.88 ma edge-to-edge). Gęstość niecałkowita daje dociąganie do pikseli: anchor 60 dp ma 59,81 dp (157 px), odstęp zaprojektowany 6 dp mierzy 6,48 dp (`measure-boxes.py ... 2.625`). `measure-element.py --scale 2.625` znajduje kontener poprawnie (120x40), ale nie oddzielił białego tekstu od ciemnej pigułki (PARTIAL). Obrót: zrzut ma 2424x1080; test układu w poziomie nierozstrzygnięty (fixture liczy wymiary raz).

### H. System

- **H1 wstecz:** V24.
- **H2 uprawnienia:** okno `GrantPermissionsActivity` w drzewie z id `com.android.permissioncontroller:id/permission_allow_button` / `permission_deny_button` (tekst "Don’t allow" z typograficznym apostrofem). `pm grant` przed zapytaniem -> brak okna. `pm revoke` ZABIJA proces aplikacji. `pm clear` kasuje `shared_prefs` (czyli `debug_http_host`!) i uprawnienia runtime.
- **H3 deep linki:** `am start -W -a VIEW -d <url>` bez pakietu przy dwóch aplikacjach z tym schematem -> systemowe okno wyboru (`ResolverActivity`: "Open with", "Just once", "Always"), a `am start` zgłasza `Status: ok`. Z pakietem jako ostatnim argumentem -> prosto do aplikacji. Nieznany schemat: "Error: Activity not started, unable to resolve Intent", rc=0. Pułapka (1 wystąpienie, API 34): deep link wysłany zaraz po zimnym starcie, gdy JS jeszcze się ładował, zginął.
- **H4 animacje:** V19, V20.
- **H5:** wygaszony ekran (`keyevent 26`): `find` -> HTTP 500, `mCurrentFocus=null`; `KEYCODE_WAKEUP` + `wm dismiss-keyguard` przywraca (emulator bez PIN). Klawiatura: `dumpsys input_method` -> `mInputShown=true|false`; chowanie `keyevent 111`.
- **H6 schowek i zdjęcia:** V23; UiA2 `POST /appium/device/set_clipboard {"content":<base64>,"contentType":"plaintext"}` + `keyevent 279` (PASTE) wkleja unicode; `get_clipboard` zwraca pusty (ograniczenie tła). `adb push` do `/sdcard/Pictures` na API 36 od razu widoczny w MediaStore (`content query --uri content://media/external/images/media`).
- **H7:** brak systemowych okien po crashach.

### I. Emulator

| AVD | pierwszy rozruch `-no-window` do `sys.boot_completed=1` |
|---|---|
| svp2-api36 | 23,3 s |
| svp2-api36b (drugi AVD z obrazu API 36, tylko do testu B3) | 19,3 s |
| svp2-api35 | 14,2 s |
| svp2-api34 | 16,8 s |

`adb emu avd name` -> nazwa AVD; `getprop ro.boot.qemu.avd_name` -> nazwa AVD (tak samo, z wnętrza). Proces hosta: `qemu-system-aarch64-headless -avd <nazwa> -port <N>` (serial `emulator-<N>`). `netsimd` jest jeden dla wszystkich emulatorów. Obraz `google_apis` jest userdebug: `adb root` działa.

### J. Sieć

Sonda `probe-collector.py --port 8199` (bez zmian): fetch z aplikacji na `http://10.0.2.2:8199` dochodzi; `http://localhost:8199` -> "Network request failed" bez `adb reverse`, działa z `adb reverse tcp:8199 tcp:8199`. Cleartext HTTP w debug działa (szablon RN i Expo).

### K. Istniejące narzędzia CDP na Androidzie (bez zmian w kodzie)

`rn-devtools.mjs targets|eval|tree|net` i `read-rn-logs-cdp.py` działają na emulatorze bez zmian: `tree --ids` 0,11 s, `eval` ok (`require` nie istnieje w globalnym zakresie - jak na iOS), `net start/read` widzi fetch do 10.0.2.2 i do localhost (także nieudany). Jedyny problem: dwa emulatory z jednego obrazu na jednym Metro (V8).

**I, ciąg dalszy.** Start ze snapshotu `default_boot` (quickboot, domyślny, gdy AVD nie startuje z `-no-snapshot`): 1,7-1,8 s do `sys.boot_completed=1` (log: "Successfully loaded snapshot 'default_boot' using 762 ms"); `adb -s <serial> emu kill` zamyka w 4 s i zapisuje snapshot. Pamięć: jeden emulator po długiej pracy 4,6 GB RSS; dwa świeże 1,8 + 2,3 GB, wolna pamięć hosta 44% -> 34%. Dwie instancje JEDNEGO AVD: bez `-read-only` druga pada ("FATAL | Running multiple emulators with the same AVD is an experimental feature. Please use -read-only flag"); z `-read-only`, gdy pierwsza działa bez niego: "ERROR | Another emulator instance is running. Please close it or run all emulators with -read-only flag". Równoległość = osobne AVD albo WSZYSTKIE instancje `-read-only` (bez zapisu snapshotu). Nie sprawdzono etykiety `-prop qemu.<tag>=...` (patrz sekcja 8).

### E. Narzędzia alternatywne (fixture RN CLI, te same ekrany)

| | agent-device 0.21.41 | mobilecli 1.0.24 | Maestro 2.12.1 |
|---|---|---|---|
| adresowanie urządzenia | `--serial emulator-<N>` | NAZWA AVD (`emulator-<N>` -> "device not found") | `--device emulator-<N>` |
| odczyt drzewa | `snapshot -i` 0,10-0,2 s (pierwszy 0,38 s) | `dump ui` 0,18 s (pierwszy 1,38 s), JSON, `identifier` = resource-id, prostokąt w px | `hierarchy` 3,2-3,9 s na wywołanie (JVM + driver za każdym razem), 85 KB JSON |
| pod nieskończoną animacją | 0,1-0,2 s (nie czeka na bezczynność) | 2,26 s, poprawny wynik | 3,85 s, poprawny wynik |
| tap po testID | `press id=<testID>` 0,15 s | brak tapu po id (współrzędne z dump) | `tapOn: {id: ...}` |
| pisanie unicode | `fill` OK | `io text`: z fokusem OK (dopisuje, 0/10 strat); BEZ fokusu rc=0 "Sent" i nic nie wpisane | `inputText` OK |
| zagnieżdżony Text z testID | nie znajduje (jak każde narzędzie a11y) | nie ma | nie ma |
| ślad na urządzeniu | instaluje `...imehelper` i `...snapshothelper`; NA CZAS SESJI PRZEŁĄCZA DOMYŚLNĄ KLAWIATURĘ na swoją (`close` przywraca) | wrzuca `.dex` + `.so` do `/data/local/tmp`, uruchamia `app_process ... DeviceServer --idle-timeout-ms=1800000` (30 min trzyma UiAutomation) | instaluje `dev.mobile.maestro` + `.test` na czas przebiegu; po udanym usuwa, po NIEUDANYM zostawia |
| ślad na hoście | `~/.agent-device` (sesje, logi, daemon); "telemetria" = lokalny JSON gestów | `~/.mobilecli/daemon.log`, demon hosta, `adb forward localabstract:mobilecli-server` | `~/.maestro` (analytics.json, deps, tests z artefaktami); analityka wyłączana `MAESTRO_CLI_NO_ANALYTICS=1` |
| przy żywym UiA2 (D8) | `open` 11 s, `snapshot` pada po 10,5 s ("snapshot helper output could not be parsed") | jego DeviceServer zajmuje UiAutomation, wtedy UiA2 nie tworzy sesji | "Maestro Android driver did not start up in time (driver port 7001)", rc=1 po 19 s |
| inne | `--settle` zwraca diff 0,9 s | | `openLink` bez pakietu -> okno wyboru przy dwóch aplikacjach z tym schematem; przepływ 10 kroków (unicode, tapy pod `Animated.loop`) PASS w 24,3 s |

### L. Parytet iOS (własny symulator "iPhone 17 - svp2", WDA :8196, skill bez zmian, fixture RN CLI zbudowany na iOS: pody 74 s, build 32 s)

- `rig-check.sh --repo <fixture> --udid <udid> --port 8121` bez `--bundle-id` odmawia ("no bundle id ... pass --bundle-id") - fixture nie ma `.simulator-verify/config.md`. Z `--bundle-id`: RIG OK, marker po 4 s, całość 8,9 s. Ostrzeżenie "no Metro serves this repo" mimo działającego Metro tego repo na :8121 - rig-check skanuje tylko porty 8080-8110 (obserwacja dla iOS, nie naprawiana w fazie 2).
- `do 'waitid ...' 'tapid ...' 'waitid ...'` 1,29 s; `el` 0,41 s; `elements --names` 0,44-0,50 s; `elements --all --names` 0,62 s (48 linii).
- `typeid Input-controlled 'hello world'` na iOS ZGUBIŁ znaki ("heworld"), wykrył to read-back (exit 1); `zażółć gęślą` OK. Na Androidzie UiA2 `value` 0/25 strat w tym samym polu.

Różnice semantyki na tym samym ekranie Components:

| element | iOS (WDA) | Android (UiA2) |
|---|---|---|
| zasłonięty tekst | `displayed:false` (WDA liczy przesłonięcie) | `displayed=true` |
| element poziomej listy poza ekranem | istnieje, `displayed:false` | nie istnieje w drzewie |
| `accessibilityState busy` / `accessibilityValue` | `label='Loading data' value='busy'`, `label='Volume' value='50 percent'` | jeden `content-desc` "Loading data, busy", "Volume, 50 percent" |
| Switch | `value='0'/'1'` | `checked=false/true`, brak value |
| `Text` | `StaticText` + duplikat bez id (2 węzły) | jeden `TextView` |
| zagnieżdżony `Text testID`, `opacity:0` | brak | brak |
| Pressable z dzieckiem Text | `label` = tekst dziecka | `content-desc` = tekst dziecka |

### N. Prawdziwa aplikacja ("aplikacja R": RN 0.81.1, debug APK wariantu z flavorem, 443 MB, tylko emulator API 36)

- **Zabezpieczenie zadziałało:** przed pierwszym startem zapisano `debug_http_host=10.0.2.2:<martwy port>` (pref przez `run-as`); w trakcie 0 połączeń emulatora z portami Metro i sondy innych sesji (`lsof ... | grep netsimd`).
- **B4 na prawdziwej aplikacji:** `assets/index.android.bundle` 18,9 MB w APK; przy martwym hoście aplikacja po cichu uruchomiła wbudowany JS; jedyny ślad to te same linie logcat co w fixture'ze. Port z `aapt2 dump resources`: wartość domyślna 8081.
- Pierwszy start: najpierw systemowe okno uprawnienia powiadomień (przed UI aplikacji). Odrzucone przez id `com.android.permissioncontroller:id/permission_deny_button`.
- Ekran powitalny z tłem wideo: UiA2 `/source` 98 węzłów / 39 KB, 11 resource-id z testID, mediana 21 ms TAKŻE przy `waitForIdleTimeout=10000` (wideo nie blokuje bezczynności, w przeciwieństwie do animacji RN); `uiautomator dump` 2,0 s OK; agent-device `snapshot` 0,11 s (7 widocznych z 15).
- Kod aplikacji ma ~10 tys. wystąpień `testID` w ~940 plikach. Na ekranach bez logowania widać ich kilkanaście.
- Przycisk logowania otwiera ZEWNĘTRZNĄ przeglądarkę (Chrome, ekran pierwszego uruchomienia). Przeglądarkę i aplikację zatrzymano od razu i nie sprawdzano dalszych ekranów (reguła: zero akcji wychodzących). Wniosek dla fazy 3: przepływ, który wychodzi do przeglądarki, zmienia aplikację na pierwszym planie - `foreground` musi to pokazać.
- Aplikację odinstalowano.

### GAP. Pomiary dodane po testach zimnego czytelnika (2026-11-21, emulator API 36, fixture RN CLI z Reanimated)

Test zimnego czytelnika to subagent, który dostał tylko ten raport i miał wskazać, czego brakuje do startu fazy 3. Pomiary poniżej zamykają luki, które wskazał. Do fixture'a dodano dwa jednorazowe przejścia: widok przesuwany `Animated.timing` 1,5 s (native driver) i Modal z `animationType="slide"`.

**GAP1. Wyzwalacz rig-checka i wyścig ze startem** (10 prób na wariant; stan po 5 s: ekran główny / redbox / pusty):

| wariant | wynik |
|---|---|
| broadcast `RELOAD_APP_ACTION` na gotowej aplikacji | 10/10 ekran główny |
| `/reload` Metro na gotowej aplikacji | 10/10 ekran główny |
| zimny start | 10/10 ekran główny |
| zimny start, broadcast po 1,5 s | 8/10 ekran główny, 2/10 redbox |
| zimny start, broadcast po 0,3 s | 9/12 redbox (trwały, nadal po +10 s), reszta pusty ekran do ~10 s |

Czas markera w tej serii: zimny start 2,11 / 1,82 / 1,96 s, broadcast 0,90 / 0,92 / 0,78 s, `/reload` Metro 0,63 / 0,77 / 0,78 s (n=3 każdy; wolniej niż w B2, fixture ma już Reanimated i więcej ekranów).

Treść redboxa: `[runtime not ready]: Error: Exception in HostFunction: Assertion failed` ze stosem `installTurboModule` / `NativeReanimatedModule` albo `[Worklets] JavaScript context is not available yet.` Na Androidzie to ten sam rodzaj wyścigu, co `/reload` po starcie na iPhonie z fazy 1.

Oś czasu pokazuje dwa zjawiska. Po markerze drzewo ma jeszcze 0,5-1,3 s tylko 14 węzłów bez tekstu (pusty korzeń), dopiero potem ekran główny (58 węzłów). Przez ~0,5 s po `force-stop` + `am start` UiA2 pokazuje drzewo aplikacji, która była POD spodem (tu menu deweloperskie innej aplikacji). Dlatego `waitid` po starcie musi sprawdzać pakiet węzła.

**GAP2. `waitForIdleTimeout` a klatki przejść:**

| przypadek | przy 0 | przy 1000 | przy 10000 |
|---|---|---|---|
| widok przesuwany 1,5 s, odczyt `rect` co 0,1 s po kliknięciu | x rośnie w każdym odczycie (53 -> 566 px): czytamy klatki | ponowny find przy 1000 wraca po 0,01 s, a `rect` zaraz po nim daje pozycję STARTOWĄ (3/3) - bezczynność nie widzi animacji native drivera | jeden z odczytów po kliknięciu czekał ~2 s i zwrócił pozycję końcową; pierwszy odczyt (0,04 s) dał startową |
| Modal `slide`, przycisk Close | znaleziony po 0,12-0,14 s, `displayed=true`, y=2526-2569 px (ekran ma 2424) przez ~0,3 s, potem y=145 | pierwszy find trwa 0,74-0,77 s i zwraca y=145 (3/3) | to samo co 1000 (0,74 s) |

Prostokąt Modala w trakcie wjazdu stoi w miejscu (kolejne odczyty co ~70 ms mają to samo y przez ~0,3 s), więc dwa zgodne odczyty BLISKO siebie nie wystarczą. `--settled` z iOS porównuje odczyty 2 s od siebie - to złapałoby oba przypadki (sprawdzone tylko na tych dwóch). Granice ekranu łapią Modal, ale nie przesuw w obrębie ekranu. Tekst Modala w strefie paska statusu (y 52-113 px) nie występuje w drzewie (z `allowInvisibleElements` ma `displayed=false`). Na zrzucie też go nie widać, więc drzewo jest zgodne z ekranem.

**GAP3. Drobne fakty o UiA2:**
- `POST /session/<sid>/elements` (liczba mnoga) zwraca listę: tekst "Duplicate" -> 2 elementy w 0,06 s; `id` istniejący -> 1; brak -> pusta lista w 0,05 s (bez błędu); xpath -> 1 w 0,10 s.
- `POST /session` zwraca id sesji w `value.sessionId` (0,04-0,05 s). KAŻDA nowa sesja wraca do ustawień domyślnych (`waitForIdleTimeout` 10000, `disableIdLocatorAutocompletion` false - odczyt `GET /session/<sid>/appium/settings`, 3/3) i unieważnia poprzednią. `GET /sessions` 0,04 s.
- Atrybut `package` jest na każdym węźle `/source`: okno uprawnień -> 14 węzłów `com.google.android.permissioncontroller`, ekran aplikacji -> 17 węzłów `com.example.svcli`. Atrybutu `package` pojedynczego elementu (`/element/<id>/attribute/package`) nie sprawdzano.
- Pusty TextInput: `text` zwraca **placeholder** ("Controlled"), `attribute/hint` też; odróżnia to tylko `attribute/showing-hint` = `true`. Po wpisaniu `showing-hint=false`. Klasa pola: `android.widget.EditText`.
- Pełny koszt odczytu drzewa z nowego procesu Pythona (start + `GET /sessions` + `/source`): 0,08-0,10 s (n=5). Liczby 5-20 ms z D4 to samo HTTP w jednym procesie; agent-device 0,1-0,2 s to pełne wywołanie CLI. Porównywalne są 0,08-0,10 s z 0,1-0,2 s.
- Po restarcie adbd (`adb root`/`unroot`): forward znika, proces serwera na urządzeniu żyje. Samo `adb forward` przywraca `/status` i listę sesji, ale `/source` pada po 10,1 s. Naprawia dopiero `force-stop` obu pakietów UiA2 + ponowne `am instrument` + nowa sesja (`/source` 0,05 s).
- W `ps -A -o PID,NAME,ARGS` serwer UiA2 to dwa procesy: `app_process ... com.android.commands.am.Am instrument -w ... io.appium.uiautomator2.server.test/...` oraz `io.appium.uiautomator2.server`.

**GAP4. Blokada ekranu (emulator bez PIN-u):** `input keyevent KEYCODE_SLEEP` usypia (`dumpsys power`: `mWakefulness=Asleep`), a drugie wywołanie nadal daje Asleep, więc działa idempotentnie, w przeciwieństwie do przełącznika `KEYCODE_POWER` (26). `KEYCODE_WAKEUP` + `wm dismiss-keyguard` -> `mWakefulness=Awake`, `isKeyguardShowing=false`. Emulator bez PIN-u nie pokazuje keyguarda po uśpieniu (`isKeyguardShowing` nie pojawił się), a telefon pokazał `isKeyguardShowing=true` (sekcja 7).

**GAP5. Scalanie prefu `debug_http_host`:**
- Potok `run-as cat F | merge | run-as sh -c 'cat > F'` ZGUBIŁ pozostałe klucze. Zapis obcina plik, zanim odczyt go przeczyta (oba polecenia adb startują razem).
- Odczyt w całości do zmiennej na hoście, scalenie, potem zapis: pozostałe klucze zostają, aplikacja ładuje się z nowego hosta, a plik po uruchomieniu aplikacji jest bez zmian (0,1 s).
- Brak pliku: `run-as cat` zwraca pusty tekst, scalenie tworzy nowy `<map>`.

**GAP6. Expo dev-client:**
- `dumpsys package <pkg>` wypisuje schemat `exp+<slug>` (tu `exp+svp2expo`, zgodny z `slug` w `app.json`). Rozpoznanie dev-clienta i slug dają się wziąć z jednego polecenia.
- Intencja `exp+...` rozwiązuje się do `MainActivity` aplikacji.
- Plik wejścia fixture'a Expo to `index.ts` (`main` w `package.json`), nie `index.js`.

**GAP7. Pliki i formaty:**
- `adb emu screenrecord screenshot <dir>` zapisuje `Screenshot_<sekundy epoki>.png`. Drugie wywołanie w tej samej sekundzie nadpisuje plik.
- `sha256sum` na urządzeniu i `shasum -a 256` na hoście dają ten sam pierwszy token (dalej różne ścieżki).
- `pm path` fixture'a = 1 linia (APK bez splitów); APK dzielone (splits) nie były testowane.
- `aapt2` jest w `build-tools/35.0.0`, `36.0.0` i `37.0.0`. Wartość portu jest w linii po nazwie zasobu: `() 8081`.

**GAP8. Dwa emulatory z jednego obrazu, każdy na własnym Metro:** `svp2-api36` z prefem `10.0.2.2:8121`, `svp2-api36b` z `10.0.2.2:8122`. `/json/list` każdego Metro ma 1 cel (oba z identycznym `deviceName`). `rn-devtools.mjs targets --port 8121` / `--port 8122` -> po 1 celu. `eval "console.log('WHO_<port>')"` przez każdy port trafia do logcat właściwego emulatora (5560 -> WHO_8121, 5570 -> WHO_8122). Wybór po porcie Metro działa bez zmian w skryptach CDP.

### M. Telefon - wyniki w sekcji 7.

## 4. Książka przepisów dla fazy 3

Wszystkie komendy sprawdzone w fazie 2 na emulatorze `google_apis` arm64 (API 34/35/36), adb 37.0.1, UiA2 server 11.2.4. `ADB=$ANDROID_HOME/platform-tools/adb`, `S=<serial>` (np. `emulator-5560`), `PKG=<application id>`, `P=<port hosta dla UiA2>`. Każda komenda adb z `-s $S` - na maszynie zwykle wisi więcej niż jedno urządzenie.

### 4.1 Urządzenie i emulator

| cel | komenda | czas / uwagi |
|---|---|---|
| lista | `$ADB devices -l` | serial `emulator-<port konsoli>` |
| nazwa AVD z seriala | `$ADB -s $S emu avd name` (pierwsza linia) albo `$ADB -s $S shell getprop ro.boot.qemu.avd_name` | jedyne pewne powiązanie serial <-> AVD |
| start | `$ANDROID_HOME/emulator/emulator -avd <AVD> -port <N> -no-boot-anim [-no-window]` w tle, potem pętla `$ADB -s emulator-<N> shell getprop sys.boot_completed` == 1 co 0,5 s. Port konsoli `N` parzysty z zakresu 5554-5682, wolny, gdy `adb devices` nie zna `emulator-<N>` i nic nie słucha na `N` ani `N+1` (reguła z dokumentacji emulatora, w fazie 2 nie mierzona) | zimny 14-23 s, ze snapshotu 1,7 s |
| druga instancja tego samego AVD | wszystkie instancje z `-read-only` | inaczej FATAL / ERROR (sekcja 3 I) |
| zamknięcie | `$ADB -s $S emu kill` | 4 s, zapisuje snapshot |
| szybki zrzut (tylko emulator) | `D=$(mktemp -d); $ADB -s $S emu screenrecord screenshot $D`, wynik = jedyny plik w `$D` (`Screenshot_<sekundy epoki>.png`) | 0,2 s; świeży katalog na każdy zrzut, bo dwa zrzuty w tej samej sekundzie mają tę samą nazwę (GAP7) |
| rozmiar i gęstość | `$ADB -s $S shell wm size`, `wm density` | skala = density/160 (420 -> 2,625; telefon 480 -> 3,0) |
| wybudzenie | `$ADB -s $S shell input keyevent KEYCODE_WAKEUP; $ADB -s $S shell wm dismiss-keyguard` | tylko bez PIN-u |
| aplikacja na pierwszym planie | `$ADB -s $S shell dumpsys activity activities \| grep topResumedActivity=` | 0,05 s, te same pola na API 34-36; `mCurrentFocus` z `dumpsys window` pokazuje też okna systemowe (okno uprawnień, okno wyboru); `null` = wygaszony ekran |
| klawiatura widoczna | `$ADB -s $S shell dumpsys input_method \| grep mInputShown` | ukrycie: `input keyevent 111` |

### 4.2 Aplikacja

| cel | komenda | uwagi |
|---|---|---|
| instalacja | `$ADB -s $S install -r <apk>` | zachowuje prefy; inny klucz -> `INSTALL_FAILED_UPDATE_INCOMPATIBLE` rc=1 |
| wiek / identyczność binarki | `$ADB -s $S shell dumpsys package $PKG \| grep -E 'lastUpdateTime\|pkgFlags'`; lepiej porównać pierwszy token `$ADB -s $S shell sha256sum <ścieżka z pm path>` z pierwszym tokenem `shasum -a 256 <lokalny apk>` (`cut -d' ' -f1`) | 0,06 s. `pm path` zwraca jedną linię `package:<ścieżka>` na APK; aplikacje z APK dzielonymi (splits) dadzą kilka linii - nie testowane. Skąd wziąć lokalny APK do porównania (odpowiednik DerivedData na iOS: `android/app/build/outputs/apk/<wariant>/`) - decyzja fazy 3 |
| bundle wbudowany? | `$ADB -s $S shell unzip -l <ścieżka z pm path> \| grep index.android.bundle` | 0,03 s, bez `adb pull`. Mówi tylko, że bundle JEST w APK; że aplikacja go UŻYWA zamiast Metro, mówi logcat (4.3) |
| port Metro wbity w APK | `$ANDROID_HOME/build-tools/<najnowsza>/aapt2 dump resources <apk> \| grep -A1 'integer/react_native_dev_server_port'`; wartość w drugiej linii, postać `() 8081` | 0,05 s; `aapt2` jest w każdej wersji build-tools (35/36/37) |
| aktywność startowa | `$ADB -s $S shell cmd package resolve-activity --brief $PKG \| tail -1` | |
| zimny start | `$ADB -s $S shell am force-stop $PKG; $ADB -s $S shell am start -W -n <aktywność>` | `-W` daje `TotalTime` |
| start na pierwszy plan bez restartu | `$ADB -s $S shell am start -n <aktywność>` (bez force-stop) | |
| zakończenie | `$ADB -s $S shell am force-stop $PKG` | exit-info reason=10 sub=21 |
| PID | `$ADB -s $S shell pidof $PKG` | pusty = nie żyje |
| jak umarł | `$ADB -s $S shell dumpsys activity exit-info $PKG \| grep -m3 reason=` + `$ADB -s $S logcat -d -b crash` | reason=4 Java, 5 natywny, 10 force-stop |
| deep link | `$ADB -s $S shell am start -W -a android.intent.action.VIEW -d '<url>' $PKG` | ZAWSZE z pakietem (bez: okno wyboru przy 2 aplikacjach, a `Status: ok`). Sprawdzać stdout na "Error:" - rc=0 także przy błędzie. Wysyłać dopiero po gotowości JS (deep link w trakcie ładowania zginął) |
| uprawnienie przed startem | `$ADB -s $S shell pm grant $PKG android.permission.<X>` | `pm revoke` zabija proces; `pm clear` kasuje też `debug_http_host` |

### 4.3 Rig: Metro, marker, reload

| cel | komenda | uwagi |
|---|---|---|
| skierowanie aplikacji na Metro `:<p>` (goły RN) | 1) `$ADB -s $S shell am force-stop $PKG`; 2) `$ADB -s $S shell run-as $PKG mkdir -p shared_prefs`; 3) `CUR=$($ADB -s $S shell "run-as $PKG cat shared_prefs/${PKG}_preferences.xml 2>/dev/null")` - odczyt W CAŁOŚCI do zmiennej; 4) scalenie na hoście: usunąć element `<string name="debug_http_host">`, dodać nowy z `10.0.2.2:<p>`, zachować resztę (pusty `CUR` = nowy `<map>`); 5) zapis: `$ADB -s $S shell "run-as $PKG sh -c 'cat > shared_prefs/${PKG}_preferences.xml'" < nowy.xml` | 0,1 s. NIE robić tego jednym potokiem odczyt -> zapis: zapis obcina plik przed odczytem i gubi pozostałe klucze (GAP5). Działa przed pierwszym startem, przeżywa restart i `install -r`; wymaga `debuggable`; nie zmieniać przy żywym procesie (cache w pamięci) |
| to samo w Expo dev-client | `$ADB -s $S shell am start -a android.intent.action.VIEW -d 'exp+<slug>://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A<p>' $PKG` | ~2 s do JS; zapisuje `debug_http_host` sam; zwykły start bez URL-a = ekran launchera |
| usunięcie | jak wyżej, ale scalenie tylko usuwa element `debug_http_host` | `rm -f` całego pliku skasowałby też prefy aplikacji |
| telefon na kablu | `$ADB -s $S reverse tcp:<p> tcp:<p>` + host `localhost:<p>` w prefie | właścicielem połączenia na hoście jest `adb`; usuwać `reverse --remove tcp:<p>` (nie `--remove-all` - inne sesje mogą mieć swoje) |
| marker | pierwsza linia pliku wejścia (`index.js` w RN CLI; w Expo plik z `main` w `package.json`, w fixture'ze `index.ts`): `console.log('<MARKER>')`; czas startu z urządzenia `T=$($ADB -s $S shell date +%s.%N \| cut -c1-14)` PRZED wyzwoleniem, potem pętla `$ADB -s $S logcat -d -T "$T" -s ReactNativeJS:V \| grep <MARKER>` co 0,1 s | zimny 1,2-2,1 s, broadcast 0,46-0,92 s (B2, GAP1). Marker przychodzi PRZED renderem: ekran jest pusty jeszcze 0,5-1,3 s, więc po markerze czekać na testID (GAP1) |
| wybór wyzwalacza | domyślnie zimny start (`force-stop` + `am start -W`); po markerze cofnąć marker w pliku i zrobić drugi zimny start (to samo, co iOS robi `/reload`); broadcast albo `/reload` tylko na aplikacji GOTOWEJ | broadcast 0,3 s po starcie: trwały redbox w 9/12 (Reanimated), po 1,5 s w 2/10; zimny start 10/10 czysto; na gotowej aplikacji broadcast i `/reload` 10/10 czysto (GAP1). Rig-check nie zna testID ekranu, więc "gotowa" bez testID = drugi zimny start |
| reload bez restartu | `$ADB -s $S shell am broadcast -a $PKG.RELOAD_APP_ACTION -p $PKG` | trafia dokładnie w pakiet; 0,47 s |
| reload przez Metro | `curl -X POST http://127.0.0.1:<p>/reload` | przeładowuje tylko aplikację na pierwszym planie |
| Expo dev-client: rozpoznanie i slug | `$ADB -s $S shell dumpsys package $PKG \| grep -oE 'exp\+[a-z0-9-]+' \| sort -u` -> `exp+<slug>`; pusto = nie dev-client | zwykły `relaunch` dev-clienta kończy się na ekranie launchera (B8) - trzeba startować URL-em `exp+<slug>://expo-development-client/?url=...` (GAP6) |
| JS rzuca przy ładowaniu | `$ADB -s $S logcat -d -T "$T" -s ReactNativeJS:E \| grep 'runtime not ready'` | proces żyje; redbox w drzewie (`DISMISS`, `RELOAD`). Bez `-T` łapie stare linie z poprzednich uruchomień |
| Metro nie odpowiada / wbudowany bundle w użyciu | `$ADB -s $S logcat -d -T "$T" \| grep -E 'isMetroRunning\(\): Async result = false\|packager does not seem to be running'` | jedyny sygnał, że aplikacja jedzie na wbudowanym JS; UI wygląda normalnie. Tagi: `unknown:BridgelessReact` (W) i `unknown:ReactNative` (W) |
| logi JS | `logcat -s ReactNativeJS:V` albo istniejący `read-rn-logs-cdp.py` bez zmian | |

### 4.4 Serwer UiAutomator2 (bez Appium)

Instalacja (raz na urządzenie): `npm pack appium-uiautomator2-server@<wersja>` (w fazie 2: 11.2.4, versionCode 315), rozpakować; potrzebne dwa pliki z `package/apks/`: `appium-uiautomator2-server-v<wersja>.apk` (pakiet `io.appium.uiautomator2.server`) i `appium-uiautomator2-server-debug-androidTest.apk` (pakiet `...server.test`). Instalacja: `$ADB -s $S install -r -g` każdego z nich (~0,1 s). Gdzie skill trzyma przypiętą wersję (cache jak `~/.cache/wda-device` dla WDA, czy plik w repo) - decyzja fazy 3.

| cel | komenda | uwagi |
|---|---|---|
| start | `$ADB -s $S forward tcp:$P tcp:6790`; w tle `$ADB -s $S shell am instrument -w -e disableAnalytics true io.appium.uiautomator2.server.test/androidx.test.runner.AndroidJUnitRunner`; czekać na `"ready":true` z `GET /status` | 0,5-1,8 s. NIE używać `--no-window-animation` (włącza aplikacji reduce motion i po zatrzymaniu wpisuje 1.0) |
| sesja | `POST /session` z `{"capabilities":{"alwaysMatch":{"platformName":"Android"}}}`; id w `value.sessionId`; istniejąca: `GET /sessions` -> `value[0].id` | 0,04-0,05 s. Druga sesja po cichu unieważnia pierwszą, a nowa sesja ma ustawienia domyślne - po każdym `POST /session` ustawienia od nowa (GAP3) |
| ustawienia | `POST /session/<sid>/appium/settings` `{"settings":{"waitForIdleTimeout":0,"disableIdLocatorAutocompletion":true}}`; `enableMultiWindows` i `allowInvisibleElements` to też ustawienia (nie capabilities), zmiana ~3 ms; odczyt `GET .../appium/settings` | bez `disableIdLocatorAutocompletion` `id` nie znajduje gołych testID. `waitForIdleTimeout`: przy 10000 każde wywołanie na ekranie z nieskończoną animacją trwa 10 s, przy 1000 - 1,1 s; przy 0 odczyt łapie klatki przejść, a czekanie na bezczynność nie chroni przed animacją native drivera (GAP2) |
| zdrowie | `GET /session/<sid>/source` z limitem 3 s | `/status` mówi ready także przy martwym UiAutomation. Naprawa (np. po restarcie adbd): `force-stop` obu pakietów, `adb forward` od nowa, `am instrument` od nowa, nowa sesja i ustawienia; samo `adb forward` nie wystarcza (`/source` pada po 10,1 s) (GAP3) |
| znajdź po testID | `POST /session/<sid>/element` `{"strategy":"id","selector":"<testID>"}` -> `value.ELEMENT` | 0,06 s; brak = HTTP 404 "no such element" od razu (polling po stronie klienta) |
| wszystkie trafienia | `POST /session/<sid>/elements` (ta sama treść) -> lista `[{"ELEMENT":...}]` | 0,05-0,06 s; brak = pusta lista, bez błędu (GAP3); potrzebne dla `el` i `tapid` ("dokładnie jeden widoczny") |
| inne strategie | `{"strategy":"xpath","selector":"//*[@resource-id=\"X\"]"}` 0,08-0,10 s; `{"strategy":"-android uiautomator","selector":"new UiSelector().text(\"X\")"}` | format `strategy`/`selector`, NIE W3C `using`/`value` |
| atrybuty | `GET .../element/<id>/text`, `.../rect`, `.../attribute/<displayed\|resource-id\|content-desc\|class\|bounds\|checked>` | ~0,065 s każdy |
| klik | `POST .../element/<id>/click` | 0,13 s; nie wykrywa zasłonięcia |
| tekst | `POST .../element/<id>/value` `{"text":"..."}`; czyszczenie `POST .../element/<id>/clear` | unicode OK, ~30 ms, jedno `onChangeText` |
| drzewo | `GET /session/<sid>/source`; odpowiedź to JSON, XML jest napisem w `value` (w Pythonie `json.loads(..., strict=False)`, bo XML ma znaki sterujące, np. `&#10;`) | 5-20 ms HTTP, ~0,08-0,10 s z nowego procesu Pythona; duży ekran ~100 ms; tylko aktywne okno; okna systemowe z `enableMultiWindows:true` |
| klawisz | `POST /session/<sid>/appium/device/press_keycode` `{"keycode":66}` | 66 ENTER, 4 BACK, 279 PASTE |
| wstecz | `POST /session/<sid>/back` | |
| schowek | `POST /session/<sid>/appium/device/set_clipboard` `{"content":"<base64>","contentType":"plaintext"}` | `get_clipboard` zwraca pusty |
| zrzut | `GET /session/<sid>/screenshot` (base64 PNG) | 1,4-4,2 s; szybciej `adb emu screenrecord screenshot <dir>` 0,2 s (tylko emulator, nazwa pliku per sekunda) |
| stop | `$ADB -s $S shell am force-stop io.appium.uiautomator2.server.test`; `... io.appium.uiautomator2.server`; `$ADB -s $S forward --remove tcp:$P` | zwalnia UiAutomation dla innych narzędzi |
| właściciel portu | `$ADB forward --list` -> `<serial> tcp:$P tcp:6790` | odpowiednik `assert_wda_owner` |
| inni klienci UiAutomation | `$ADB -s $S shell ps -A -o PID,NAME,ARGS \| grep -E 'uiautomator\|DeviceServer\|dev\.mobile\.maestro\|agentdevice'` | wzorzec UiA2 sprawdzony (GAP3); dla mobilecli (`app_process ... com.mobilenext.mobilecli.DeviceServer`) z obserwacji w E; dla Maestro i agent-device to nazwy pakietów (`dev.mobile.maestro`, `com.callstack.agentdevice.snapshothelper`), nazwy procesów niesprawdzone. Wzorzec łapie też własny serwer (odróżniać po `io.appium.uiautomator2`). Pewny sygnał po fakcie: logcat `UiAutomationService ... already registered` |

### 4.5 Gołe adb (zapas, gdy UiA2 nie działa)

| cel | komenda | uwagi |
|---|---|---|
| drzewo | `$ADB -s $S exec-out uiautomator dump /dev/tty` | 2 s; przy animacji "ERROR: could not get idle state." po 11 s z rc=0; przy żywym UiA2 rc=137 bez komunikatu |
| tap | `$ADB -s $S shell input tap <px> <py>` | px = dp x skala |
| swipe / long press | `input swipe x1 y1 x2 y2 <ms>`; long press = ten sam punkt, 800 ms | |
| tekst ASCII | `input text 'a%sb'` | `%s` = spacja, unicode niemożliwy, metaznaki cytować |
| klawisz | `input keyevent <kod>` | |
| zrzut | `$ADB -s $S exec-out screencap -p > out.png` | 1,4-2,4 s |

## 5. Semantyka komend `sim-ui.sh`: iOS vs Android

"Odpowiednik" = sprawdzony mechanizm z sekcji 4. Jednostka publiczna po obu stronach: punkty logiczne (pt na iOS, dp na Androidzie, rekomendacja w sekcji 0).

| komenda | iOS dziś | odpowiednik Android | różnica, którą faza 3 musi obsłużyć |
|---|---|---|---|
| `elements [--all] [--grep] [--names]` | WDA `/source` JSON, filtr typów (`ACCEPTED` w `wda_tree.py`) | UiA2 `/source` XML -> te same kolumny (id = resource-id, typ = class, label = text lub content-desc, rect px/skala) | domyślny filtr do ustalenia (sekcja 0, decyzje otwarte; klasy w 3.F); brak duplikatów `StaticText`; elementy poza ekranem NIE istnieją (iOS: `displayed:false`); busy/value sklejone w content-desc; tylko aktywne okno (okno uprawnień przesłania aplikację, poznać po atrybucie `package` węzłów) |
| `elements --settled` | dwa odczyty `SIMUI_SETTLE_SECONDS` (2 s) od siebie, exit 3 gdy różne | dwa odczyty `/source` przy `waitForIdleTimeout=0`, 2 s od siebie | odczyty blisko siebie nie wystarczą (Modal stoi ~0,3 s poniżej ekranu); 2 s łapie oba zmierzone przypadki (GAP2) |
| `waitid ID [--timeout] [--exists]` | polling WDA find | polling `POST /element` id co ~0,1 s przy `waitForIdleTimeout=0`; trafienie = `displayed` + prostokąt w granicach ekranu + pakiet okna = `$PKG` (z `/source` albo `mCurrentFocus`) | `displayed` nie uwzględnia zasłonięcia i bywa `true` poza ekranem w trakcie przejścia (GAP2); przez ~0,5 s po starcie drzewo należy do aplikacji spod spodu (GAP1); elementu poza listą nie ma wcale (`--exists` nie odróżni "przewinięty" od "nie istnieje") |
| `tapid ID` | WDA tap w punkt trafialny | `POST /elements` -> dokładnie jeden spełniający warunki trafienia z `waitid` -> `POST .../click` | brak wykrywania zasłonięcia po obu stronach; Android nie ma "hittable"; przesuw z native driverem w obrębie ekranu nie jest wykrywalny jednym odczytem |
| `el ID` | typ/label/value/rect/displayed | `POST /elements`, dla każdego `text`, `rect`, `attribute/content-desc\|class\|checked\|displayed\|showing-hint` | Switch: `checked` zamiast `value`; pusty TextInput zwraca w `text` placeholder - prawdziwa wartość jest pusta, gdy `showing-hint=true` (GAP3) |
| `typeid ID TEXT [--append] [--expect]` | WDA type + read-back | pole = klasa `android.widget.EditText`; `.../value` (zastępuje), `--append`: odczyt + `value` całości; read-back przez `text` z uwzględnieniem `showing-hint` | Android ustawia tekst naraz (jedno `onChangeText`), iOS pisze per znak; read-back pustego pola zwraca placeholder (GAP3); maska działa inaczej - read-back obowiązkowy jak na iOS |
| `tap X Y`, `doubletap`, `longpress`, `swipe`, `drag` | WDA w pt | `input tap/swipe` w px (x skala) | long press = `swipe` w miejscu; doubletap i drag nie sprawdzone (sekcja 8) |
| `type TEXT` | WDA keys do fokusu | UiA2 `value` na elemencie z fokusem (find `focused(true)`, niesprawdzone) albo `input text` dla ASCII | `input text` nie zna unicode; mobilecli bez fokusu po cichu nic nie wpisuje |
| `button HOME\|ENTER\|VOLUME_*` | WDA | `keyevent 3 / 66 / 24 / 25`; dodatkowo BACK (4) - komenda, której iOS nie ma | wstecz trzeba dodać jako nową komendę |
| `lock \| unlock \| locked` | WDA | lock: `input keyevent KEYCODE_SLEEP` (idempotentny); unlock: `KEYCODE_WAKEUP` + `wm dismiss-keyguard`; locked: `mWakefulness` z `dumpsys power` różne od `Awake` LUB `isKeyguardShowing=true` z `dumpsys window` | `KEYCODE_POWER` (26) to przełącznik - nie używać; z PIN-em (telefon) odblokowanie niemożliwe (GAP4) |
| `activate BUNDLE` | WDA activate | `am start -n <aktywność>` bez force-stop | |
| `foreground` | WDA activeAppInfo | `topResumedActivity` (0,05 s); `mCurrentFocus` dla okien systemowych | przeglądarka zewnętrzna, okno wyboru i okno uprawnień przejmują pierwszy plan |
| `orientation` | WDA | rozmiar zrzutu (2424x1080 w poziomie, sprawdzone); `dumpsys input` niesprawdzone | nie mierzone dokładnie (rotacja PARTIAL) |
| `alert ...` | WDA alerty | okna systemowe w drzewie z prefiksowanymi id (`com.android.permissioncontroller:id/permission_allow_button`); rozpoznanie: `mCurrentFocus` / `mFocusedApp` z `dumpsys window` (zaobserwowane: uprawnienia `com.google.android.permissioncontroller/...GrantPermissionsActivity` (N), okno wyboru `ResolverActivity` (H3), Play Protect `com.android.vending/...PlayProtectDialogsActivity` (sekcja 7)); atrybut `package` węzłów drzewa różny od `$PKG` to drugi kandydat, niesprawdzony | brak pojęcia "alert" - trzeba rozpoznawać okno uprawnień, okno wyboru, ANR po pakiecie okna |
| `screenshot [--width]` | simctl io, przeskalowanie do pt | `exec-out screencap -p` (lub `emu screenrecord screenshot`), przeskalowanie do szerokości w dp jak na iOS: `sips --resampleWidth <szerokość px / skala>` | skala niecałkowita: dociąganie do pikseli |
| `launch / relaunch / terminate BUNDLE [ARG]` | simctl | `am start` / `force-stop` + `am start -W` / `force-stop`; dla Expo dev-client (`exp+<slug>` w `dumpsys package`) `relaunch` = `force-stop` + start URL-em `exp+<slug>://expo-development-client/?url=...` | argumenty uruchomienia nie istnieją; `-RCT_jsLocation` zastępuje pref `debug_http_host`; zwykły start dev-clienta = ekran launchera (B8, GAP6) |
| `openurl URL` | simctl openurl | `am start -W -a VIEW -d URL <pkg>` | zawsze z pakietem; rc=0 przy błędzie |
| `devices` | booted simulators | `adb devices` + `emu avd name` | |
| `waitfor REGEX [--all]` | polling drzewa | polling `/source` | |
| `wait`, `do` | | bez zmian | |

## 6. Werdykty narzędzi

| narzędzie | werdykt | liczby, na których stoi |
|---|---|---|
| serwer UiAutomator2 (samodzielnie, HTTP) | **driver główny** | find 0,06 s, `/source` 5-20 ms jako HTTP w jednym procesie (0,08-0,10 s jako nowy proces Pythona), click 0,13 s, `value` unicode 0/25 strat w 30 ms; z `waitForIdleTimeout=0` nie czeka na nieskończone animacje (ale czyta klatki przejść - GAP2); brak śladu poza dwoma APK; jeden proces na urządzenie |
| `uiautomator dump` + `input` | **zapas** tylko dla odczytu drzewa i tapów, gdy UiA2 nie wstaje | 2 s na odczyt, pada po 11 s na każdej nieskończonej animacji z rc=0, rc=137 przy żywym UiA2, `input text` bez unicode |
| agent-device | **nie jako driver**; ewentualnie do porównań ręcznych | odczyt 0,1-0,2 s jako pełne wywołanie CLI (porównywalne z 0,08-0,10 s UiA2 z nowego procesu), ale na czas sesji podmienia klawiaturę systemową i instaluje dwa APK - zmienia testowane środowisko; kolizja z UiA2 |
| mobilecli | **nie używać** | po cichu nie wpisuje tekstu bez fokusu (rc=0), trzyma UiAutomation 30 min po ostatnim użyciu (blokuje UiA2), adresuje po nazwie AVD |
| Maestro | **nie jako driver** (ewentualnie gotowe przepływy E2E, poza zakresem skilla) | 3,2-3,9 s na każdy odczyt drzewa (start JVM + drivera), po nieudanym przebiegu zostawia APK na urządzeniu, `openLink` bez pakietu |
| CDP: `rn-devtools.mjs`, `read-rn-logs-cdp.py` | **bez zmian, działa** | `tree --ids` 0,11 s, `eval`, `net` OK; jedyny problem: wybór celu przy dwóch emulatorach z tego samego obrazu |
| `measure-boxes.py`, `probe-collector.py` | **bez zmian, działa**; `measure-boxes.py` bierze skalę jako drugi argument pozycyjny (`measure-boxes.py <png> 2.625`) | dwa pomiary odstępstw przez dociąganie do pikseli: 0,19 dp i 0,48 dp (G) - za mało na regułę tolerancji, faza 3 musi zmierzyć więcej |
| `measure-element.py` | **PARTIAL** (`--scale 2.625`) | kontener znaleziony poprawnie (120x40 dp), ale białego tekstu w ciemnej pigułce nie oddzielił od tła (G) |

Reguła współistnienia: tylko jeden klient UiAutomation na urządzenie i wygrywa pierwszy. Każdy przegrany pada inaczej (rc=137 bez komunikatu, "UiAutomation not connected" przy `/status` ready, timeout 10-19 s). Driver fazy 3 musi przed startem sprawdzić, czy UiAutomation trzyma ktoś inny (`ps -A -o PID,NAME,ARGS`, wzorzec w 4.4, "inni klienci UiAutomation"; `pidof` nie wystarczy, bo nie widzi argumentów `app_process`). Musi też umieć zwolnić własny serwer. Pakiety helperów agent-device: `com.callstack.agentdevice.imehelper`, `com.callstack.agentdevice.snapshothelper`.

## 7. Telefon z Androidem (Android 16 / API 36, build `user`, nakładka producenta)

| sprawdzenie | wynik |
|---|---|
| podłączenie | `adb devices` OK, `ro.debuggable=0`, ekran zablokowany (`isKeyguardShowing=true`, `deviceLocked=1`, stan Dozing) |
| geometria | 1080x2400, density 480 -> skala 3,0 (całkowita, w przeciwieństwie do emulatora 2,625) |
| `adb install` fixture'a | **BLOCKED.** Instalacja wisiała 60 s: Play Protect pokazał okno zgody (`PlayProtectDialogsActivity`) na zablokowanym ekranie. `verifier_verify_adb_installs=1`, `package_verifier_user_consent=1`. Sesja instalacji jest zatwierdzona. `pm install-abandon <id>` odpowiada "Success", ale sesja zostaje. Ustawień weryfikacji (bezpieczeństwo prywatnego telefonu) NIE zmieniano |
| `adb reverse` | PASS: dodanie i usunięcie pojedynczej reguły bez instalacji; reguły innych sesji nietknięte |
| UiA2, marker, `/json/list`, typowanie, uprawnienia | BLOCKED (wymagają zainstalowanej aplikacji i odblokowanego ekranu) |

Wnioski dla fazy 3:
- Telefon wymaga człowieka przy pierwszej instalacji przez adb (Play Protect) i przy odblokowaniu.
- Rig-check telefonu musi rozpoznawać "instalacja czeka na zgodę na urządzeniu" (`mFocusedApp` = aktywność Play Protect, sesja w `dumpsys package` "Active install sessions").
- Skala 3,0 vs 2,625 potwierdza, że skalę trzeba czytać z urządzenia, nie zakładać.

## 8. Otwarte pytania, BLOCKED, decyzje bez użytkownika

**Niesprawdzone albo częściowe (do dokończenia w fazie 3 przed oparciem na nich kodu):**
1. "Change Bundle Location" z menu deweloperskiego RN 0.88 - czy zapisuje trwale (kod mówi, że tak, przez ten sam setter; praktyka niesprawdzona).
2. Expo `<scheme>://?__expo_url=...` - sprawdzono tylko `exp+<slug>://expo-development-client/?url=`.
3. Wstecz przy `targetSdk` 35 na API 36 (sprawdzono targetSdk 36 na API 34/35/36).
4. Rotacja: PARTIAL (zrzut ma wymiary poziome, fixture liczył wymiary raz). `orientation` bez sprawdzonego źródła.
5. `doubletap`, `drag`, `type` do fokusu przez `focused(true)` - niesprawdzone.
6. Etykieta emulatora `-prop qemu.<tag>=...` + `getprop` - niesprawdzona (nazwa AVD przez `emu avd name` działa i wystarcza).
7. Złożony "ręczny rig-check" (B10) nie został uruchomiony jako jeden skrypt. Każdy krok i każdy werdykt sprawdzono osobno (B1-B9), przepis jest w 4.3.
8. Plik prefów domyślnych prawdziwej aplikacji nie był czytany (zapis na martwy port w N nadpisał cały plik przed pierwszym startem, więc nic nie zginęło). Przepis scalający jeden klucz (4.3) sprawdzony na fixture'ze z dodatkowymi kluczami (GAP5).
9. Wybór zdjęcia w pickerze: N-A (fixture nie ma pickera); sprawdzono tylko indeksowanie w MediaStore.
10. Telefon: wszystko poza dodaniem i usunięciem `adb reverse` BLOCKED (sekcja 7). Ładowanie JS przez `adb reverse` sprawdzono tylko na emulatorze.
11. Tolerancja pomiarów pikselowych przy skali 2,625: tylko dwa pomiary (G).
12. Nazwy procesów Maestro i agent-device w `ps` (wzorzec w 4.4 opiera się na nazwach pakietów).
13. APK dzielone (splits) w `pm path` / `sha256sum` / `unzip -l`.
14. Aplikacja BEZ edge-to-edge: czy prostokąty UiA2 i `measureInWindow` dalej się zgadzają (przesunięcie o pasek statusu) - zmierzono tylko szablon edge-to-edge.
15. Lokalizacja lokalnego APK do porównania sha (odpowiednik "newer builds" z DerivedData) i lista plików natywnych zależności Androida z fazy 1 (sekcja 4.7 fazy 1) - ani potwierdzona, ani odrzucona.
16. Expo dev-client na telefonie (URL z `localhost` + `adb reverse`) - niesprawdzone.
17. Strategia przeciw klatkom przejść poza dwoma zmierzonymi przypadkami (Modal `slide`, przesuw native driverem 1,5 s): inne nawigatory (np. react-navigation), przejścia dłuższe niż 2 s.

**Decyzje podjęte bez użytkownika:**
- Po dwóch testach zimnego czytelnika (subagent z samym raportem) dołożono pomiary GAP1-GAP8 zamiast zostawiać luki jako pytania.
- Prawdziwa aplikacja = gotowy debug APK aplikacji klienta (kopia w katalogu roboczym, repo klienta tylko odczyt), w raporcie "aplikacja R".
- Okno uprawnienia powiadomień w aplikacji R odrzucone. Po tym, jak logowanie otworzyło zewnętrzną przeglądarkę, przeglądarkę i aplikację zatrzymano i zakończono test aplikacji R (reguła "zero akcji wychodzących").
- Telefon: ustawień Play Protect nie zmieniano. Blok M oznaczony BLOCKED zamiast obchodzenia zabezpieczeń.
- Rig-check iOS ostrzegł o Metro poza zakresem portów 8080-8110. Zapisane jako obserwacja, bez poprawki (zakaz zmian w fazie 2).
- Fixture'y, AVD `svp2-*`, własny symulator iOS i narzędzia zostają na fazę 3 (sekcja 10).
- Do fixture'a dodano dwa jednorazowe przejścia na potrzeby GAP2 (sekcja 3.GAP). Kopia `App.tsx` sprzed zmiany leży obok (`fixtures/shared/App.tsx.pre-gap`).

## 9. Przekazanie do fazy 3

**Kolejność implementacji** (od tego, bez czego nic nie działa):
1. Wybór urządzenia: serial, nazwa AVD, odmowa przy kilku urządzeniach bez wskazania (odpowiednik `SIM_UDID`, np. `ANDROID_SERIAL`, które adb i tak honoruje).
2. Cykl życia serwera UiA2: instalacja z wersji przypiętej, start, ustawienia, zdrowie przez `/source`, stop. Wykrycie obcego klienta UiAutomation.
3. Odczyt: `elements`, `el`, `waitid`, `waitfor`, `foreground` (dp, filtr kolumn jak na iOS).
4. Akcje: `tapid`, `typeid` z read-backiem, `tap/swipe/longpress` w dp, `button` + nowe BACK, `launch/relaunch/terminate/openurl`.
5. Rig-check Androida (4.3): app zainstalowany i debuggable -> sha APK -> bundle wbudowany? -> pref hosta na Metro tego repo (scalenie jednego klucza) -> zimny start -> marker w logcat -> cofnięcie markera -> drugi zimny start. Werdykty: odpowiedniki z iOS plus "instalacja czeka na zgodę", "JS rzuca przy ładowaniu", "wbudowany bundle".
6. `screenshot` w dp, `alert` dla okien systemowych.
7. Telefon (reverse zamiast 10.0.2.2, skala z urządzenia, Play Protect, PIN).

**Kontrakty do zachowania z iOS:** te same nazwy komend i flag, te same kody wyjścia co dzisiejszy `sim-ui.sh` (0 = OK, 1 = porażka kroku, 2 = złe użycie albo niejednoznaczne urządzenie, 3 = `elements --settled` widzi różnicę), błędy po stronie stderr z nazwą przyczyny. Nowe przyczyny: "UiAutomation zajęte przez <narzędzie>", "okno systemowe przesłania aplikację (<pakiet>)", "aplikacja nie jest debuggable - pref hosta niemożliwy".

**Przypadki do `regress.sh` Androida** (każdy wystąpił w fazie 2):
- testID na każdym typie komponentu (V1). Zagnieżdżony Text i `opacity:0` NIE są znajdowane (V2, V3).
- Ekran z `Animated.loop` i z pętlą Reanimated: `/source` jako HTTP < 100 ms (D4: 7 ms), całe polecenie < 0,5 s - nie 10 s.
- Reload w trakcie startu nie może się zdarzyć (redbox Reanimated, GAP1); po markerze drugi zimny start.
- Modal `slide` i przesuw native driverem: `waitid`/`tapid` nie raportują trafienia poza ekranem, `--settled` zwraca 3 w trakcie przejścia (GAP2).
- Pusty TextInput: read-back nie myli placeholdera z wartością (GAP3).
- Prefy aplikacji z innymi kluczami przeżywają przekierowanie Metro (GAP5).
- `typeid` unicode, emoji, metaznaki w polu kontrolowanym i z maską.
- Okno uprawnień przesłania aplikację: `elements` musi to powiedzieć.
- Dwie aplikacje z tym samym schematem: `openurl` bez okna wyboru.
- Martwe Metro + wbudowany bundle: rig-check = DEAD, nie OK.
- JS rzuca przy ładowaniu: proces żyje, rig-check musi to nazwać.
- UiAutomation trzymane przez inne narzędzie: czytelny błąd zamiast timeoutu.
- Restart adbd: serwer "ready", ale martwy -> wykryć i zrestartować.
- `--no-window-animation` nigdy nie użyte (skale animacji po przebiegu bez zmian).
- Wstecz zamyka Modal, a na ekranie głównym wysyła aplikację w tło (proces żyje).

**Pułapki (zebrane):** `am start` i `uiautomator dump` zwracają rc=0 przy błędzie. `/status` UiA2 kłamie. `pm revoke` zabija aplikację, a `pm clear` kasuje pref hosta. `/reload` Metro trafia tylko w aplikację na pierwszym planie. Deep link podczas ładowania JS ginie. Dwa emulatory z jednego obrazu są nierozróżnialne w `/json/list`. `netsimd` jest wspólny, więc `lsof` nie wskaże emulatora. Skala 2,625 jest niecałkowita. Expo dev-client po zwykłym starcie pokazuje launcher; port do URL-a `relaunch` brać z `debug_http_host` w prefach (launcher zapisuje go sam, B8) albo z konfiguracji repo. Nowa sesja UiA2 kasuje ustawienia. Przeglądarka zewnętrzna przejmuje pierwszy plan.

**Gdzie co leży (poza repo, na maszynie użytkownika; katalog roboczy `~/notes/android-phase2/`):**
- `journal.md`: chronologiczny dziennik wszystkich pomiarów (ma prawdziwe nazwy, nie kopiować do repo).
- `evidence/`: surowe wyjścia; identyfikatory jak w tym raporcie.
- `harness/`: skrypty pomiarowe fazy 2 (`u2.sh`, `u2.py`, `u2time.py`, `sethost.sh`, `rigmark.sh`, `boot.sh`, `apimatrix.sh`, `xmlids.py`, `mcnode.py`). To harness, nie driver - wzorzec wywołań, nie kod do skopiowania.
- `fixtures/shared/App.tsx`: wspólny ekran testowy (ekrany components, inputs, list, anim, back, perm, big, badge, network; przełączniki w `shared/rigswitch.ts`).
- `fixtures/f-cli/`: RN CLI 0.88.1, `com.example.svcli`, schemat `svp2cli`, Metro :8121, flavory opcjonalne `-PsvFlavors` (wariant `devDebug` z bundlem).
- `fixtures/f-expo/`: Expo SDK 58 z dev-client, `com.example.svp2expo`, schemat `svp2expo`, Metro :8120.
- `fixtures/apks/`: zbudowane APK (`cli-debug.apk`, `cli-devdebug.apk`, `expo-debug.apk`); iOS F-CLI zbudowany w `fixtures/f-cli/ios/build`.
- `tools/`: UiA2 server 11.2.4 (`tools/uia2`), agent-device i mobilecli (`tools/alt`), Maestro (`tools/maestro`).

**Odbudowa środowiska:**
- AVD `svp2-api34`, `svp2-api35`, `svp2-api36` oraz `svp2-api36b` (drugi AVD z obrazu API 36, do testów dwóch emulatorów) istnieją (profil Pixel 9, `google_apis` arm64). Zostały na nich fixture'y (`svp2-api36`: `com.example.svcli` i `com.example.svp2expo`; `svp2-api34`/`35`/`36b`: `com.example.svcli`), bez UiA2 i helperów; klawiatura systemowa, skale animacji 1.0/1.0/null (sprawdzone przy sprzątaniu na wszystkich czterech). `com.example.svcli` na `svp2-api36` nie ma pliku prefów (usunięty w GAP5), więc łączy się z `10.0.2.2:8121` z resValue.
- Start: `emulator -avd svp2-api36 -port 5560 -no-window -no-boot-anim`.
- Metro fixture'a: `npx react-native start --port 8121 --no-interactive` w `fixtures/f-cli`, `npx expo start --port 8120 --dev-client` w `fixtures/f-expo`.
- Sonda: `probe-collector.py --port 8199`.
- Własny symulator iOS "iPhone 17 - svp2" (udid: `xcrun simctl list devices | grep svp2`), WDA przez `wda-sim.sh ensure <udid> --port 8196`.

## 10. Dziennik sprzątania (2026-11-21)

| co | stan |
|---|---|
| serwer UiA2 i helpery agent-device na emulatorach | odinstalowane z `svp2-api34/35/36` (36b ich nie miał); domyślna klawiatura = systemowa na wszystkich (sprawdzone) |
| pakiety Maestro | odinstalowane (zostały po nieudanym przebiegu D8) |
| aplikacja R | odinstalowana z emulatora; kopia APK w `fixtures/real/` (poza repo) |
| Metro :8120/:8121/:8122, sonda :8199 | zatrzymane, także Metro :8121 uruchomione ponownie dla GAP (przed zabiciem sprawdzono katalog procesu) |
| forwardy adb, emulatory | usunięte, wszystkie emulatory wyłączone |
| własny symulator iOS | wyłączony (WDA :8196 zwolniony), zostaje na fazę 3 |
| `~/.maestro`, `~/.agent-device`, `~/.mobilecli` | usunięte (powstały w trakcie fazy 2) |
| skale animacji emulatora | 1.0 / 1.0 / null, jak przed startem; `accelerometer_rotation` = 1 |
| telefon | pakiety identyczne z listą sprzed startu; reguła `reverse` innej sesji nietknięta; **wisząca sesja instalacji fixture'a czeka na zgodę Play Protect** (sekcja 7) |
| pomiary GAP (po testach zimnego czytelnika) | emulatory `svp2-api36` i `svp2-api36b` uruchamiane ponownie z Metro :8121/:8122; potem UiA2 odinstalowany, Metro zatrzymane, emulatory wyłączone, brak forwardów (sprawdzone 00:55) |
| rzeczy innych sesji | porty 8081/8088/8093/8099/8110/8195 i ich symulatory jak przed startem (nowe od tamtej pory: port 8131 i zmiany w symulatorach pip - nie z tej sesji) |
| zostaje celowo na fazę 3 | AVD `svp2-*` (usunięcie: `avdmanager delete avd -n svp2-api34` itd.), obrazy systemu API 34/35 (`sdkmanager --uninstall "system-images;android-34;google_apis;arm64-v8a"`), katalog roboczy fazy 2, własny symulator iOS (`xcrun simctl delete <udid>`) |
