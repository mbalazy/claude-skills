# Driver reference - sim-ui.sh and rn-devtools.mjs

Read before your first batch in a session, and whenever a command does something you did not expect. `$S` is `<skill-dir>/scripts/sim-ui.sh`; run it with no arguments for the full command list with signatures. The measured numbers quoted here are collected, with date and hardware, in `benchmarks.md`.

- **`scripts/sim-ui.sh`** - the driver for everything: observation and interaction via WebDriverAgent's HTTP API (localhost:8100), lifecycle via `xcrun simctl`. No MCP server needed. Run it with no args for the command list. It auto-starts WDA (`com.facebook.WebDriverAgentRunner.xctrunner` must be installed on the sim). **A physical iPhone on the cable is the same driver**: put the phone's udid in `SIM_UDID` and every command works unchanged - see `device.md`.

- **Android emulator**: `scripts/android-ui.sh` is the counterpart of `sim-ui.sh` (same commands, flags and exit codes); what differs per command is in `android.md`.

- **`scripts/rn-devtools.mjs`** - asks the app's JS runtime over Metro's CDP inspector (runtime pages, evaluate JS, a log of the app's JS requests); see 2b. Its shared code is `scripts/devtools/`, Argent-derived files under `scripts/devtools/vendor/argent/` (Apache 2.0, see its NOTICE).

- **In a throwaway `git worktree`, none of this exists locally.** Both the skill directory and `.simulator-verify/` are typically git-ignored, so a fresh worktree of the same repo has neither - and no amount of re-running will create them. Call the scripts by their absolute path from wherever the skill is installed and point them at the tree under test: `<skill-dir>/scripts/rig-check.sh --repo <worktree>`. `rig-check.sh` then reads the project config from the repo's MAIN worktree by itself, so `--bundle-id` is only needed when even that has no config. For `sim-ui.sh` in a hand session, export `SIM_UDID` and `WDA_PORT` - it derives nothing.

- **A simulator is named after what it serves.** With two or three booted, a model name ("iPhone 17 Pro") identifies nothing - and picking the wrong sim produces confident, false readings. The device name is the one thing visible at a glance (Simulator window title, `simctl list`, the candidate list `rig-check.sh` prints when it refuses to guess), so make it carry the answer: `xcrun simctl rename <udid> "<model> - <worktree basename>"`, run the moment a sim is built for a worktree. Treat it as a label, not as evidence - confirm by connection when a wrong answer would be expensive.

## Rules for the loop - why one command per step is the bug

So the rule for this loop:

- **Batch every step whose coordinates you already know into one `do` call.** Only break
  out of the batch when the next coordinate genuinely depends on reading the last result.
- **Never a bare `sleep` after a relaunch or a tap.** `waitid ID` (or `waitfor 'REGEX'`
  when there is no testID to wait for) returns the moment the thing is there, and it FAILS
  LOUDLY when it is not - a fixed `sleep 5` that happens to be long enough today silently
  becomes a flake tomorrow. In ten days of transcripts fixed pauses outnumbered waits 663
  to 101 and were at least 78 of 197 minutes of tool time. A pause that IS the test (stay
  locked for 15 s) is a `wait N` and stays one. `wait` longer than 2 s prints a one-line
  NOTE saying so - if you were waiting for the app, that line is your cue to use `waitid`.
- **When the app has testIDs, wait and tap by testID.** `waitid ID` costs ~0.2s a poll
  against 1.7-4.2s for a tree read, and `tapid ID` needs no coordinate at all - nothing to
  re-derive per device, nothing in `config.md` to go stale, no layout shift under a
  keyboard to miss. Measured on the same route (two taps, two waits, one batch): 7.7s with
  `tap X Y` + `waitfor`, 3.7-4.1s with `tapid` + `waitid`. What the lookup matches, and
  where it differs from a tree read, is under "2. Observe" below - read it once.
- **A tap is not a checkpoint.** Follow it with `waitid` / `waitfor` on something only the
  new screen has, inside the same batch - that is what makes a batch safe to run unattended.
- **Never silence the driver.** No `2>/dev/null` and no `>/dev/null` on `sim-ui.sh`: its
  stderr is where a refused tap, an off-screen coordinate and a timed-out wait are
  reported, and 47% of calls in those transcripts had thrown it away. Filter the OUTPUT
  with `elements --grep` / `--names` instead of a pipe, and check the exit code of every
  step you did not put inside a `do` batch (a batch stops at the first failure by itself,
  and exits non-zero - including on a step with a missing argument, which until 2026-11-14
  ended the batch with exit 0).
  A wrapper that printed "tapped ..." after a tap that had errored, and a raw `curl` whose
  "unknown command" went to `/dev/null`, each produced a run that tested nothing.
- **No raw `curl` to WebDriverAgent when the driver has the command.** Landscape taps,
  `lock` / `unlock` / `locked`, `activate`, `foreground`, `orientation`, `drag`,
  `alert buttons` are all `sim-ui.sh` commands now; a hand-rolled request brings its own
  stale session id and its own unchecked error.
- **Do not follow a failed batch with "what is on screen?".** When a step of a `do` batch
  fails, the batch prints the front app and the visible labelled elements right after the
  error (the same lines as `elements --names`, at most 40 - it says how many more there
  are) - read that instead of spending a call on `elements` or a screenshot. It costs one
  tree read (~1.7 s on a light screen) on the failure only; `SIMUI_FAIL_SUMMARY=0` turns
  it off. A tolerated `?step` and a usage error (exit 2) print nothing extra.
- **Prefer text to a screenshot** whenever text can answer: ~750 bytes against an 870KB
  image, and every screenshot was followed by ~8 s of looking at it (148 of them in 11
  sessions, 2026-11-05..13). Pick the cheapest command that answers the question:

  | question | command |
  |---|---|
  | is X on screen now / did the tap get there | `waitid X` (in the same batch as the tap) |
  | what does X say, what is in the field | `el X` (an empty field shows its placeholder as `value`) |
  | what is on this screen, which ids | `elements --names` (`--all` for unlabelled containers) |
  | did the screen stop moving | `elements --settled` |
  | which app is in front | `foreground` |
  | which React component renders testID X, what it shows | `rn-devtools.mjs tree --id X` (2b below) |
  | which testIDs React rendered here, also ones iOS does not expose | `rn-devtools.mjs tree --ids` (2b below) |
  | what a store, global or flag holds in the running app | `rn-devtools.mjs eval EXPR` (2b below) |
  | how does it LOOK - layout, spacing, colour, clipping, glass | `screenshot`, and only then |
- **After a code change, reach for `rig-check.sh --reload` first.** It keeps the app's
  navigation state, so the whole re-navigation - the expensive part - does not happen at
  all. The default terminate+launch trigger throws the screen away and makes you drive
  back to it.

The benchmark that produced those numbers is `scripts/simbench.sh` (see its header). Re-run
it before and after touching this loop instead of guessing; `scripts/regress.sh` captures
the 69 stdout/stderr/rc cases that prove the driver still behaves identically.

### 1. Reach
All commands below are `S=<skill-dir>/scripts/sim-ui.sh` (`<skill-dir>` = the directory holding this SKILL.md, user-wide or in the project's `.claude/skills/`). **Set `SIM_UDID`** - with more than one simulator booted the script refuses to run rather than pick one, and it checks that the WebDriverAgent answering on `WDA_PORT` really drives that device (a stranger's WDA on the port used to return the other simulator's screen without a word).
- Resolve the device: `$S devices` -> pick the booted simulator.
- Launch the app: `$S launch <bundle-id>` (the bundle id from `config.md`; foregrounds if already running). Use `$S relaunch <id>` when you changed code - it terminates first, so the sim fetches a fresh JS bundle from Metro. A cold start measured 8-9s on this app, so do not guess it: `$S waitfor '<something on the first screen>' --timeout 30` returns as soon as it is up and tells you if it never is.
- Navigate to the target screen with `$S tapid ID` where the control has a testID (`$S elements --all --names` lists the ids on screen), else by tapping element rects from the tree: `$S tap X Y` (tap the rect center: `x + w/2`, `y + h/2`). Prefer deep links via `$S openurl` only if the config confirms a registered scheme - and only if a probe shows the URL actually reaches JS, which is a separate question from the scheme being registered (see `gotchas.md`).
- **Run the whole known route in one call.** Steps are this script's own subcommands; a
  step whose own arguments contain spaces needs inner quotes, a `?` prefix lets a step
  fail without aborting the batch, and `#` starts a comment:

  ```sh
  # by testID - the default when the app has them. `typeid` types into the field and
  # reads it back, and STOPS the batch when the field holds anything else - so the search
  # never runs for a cut word (see "2. Observe" below).
  $S do "relaunch $BUNDLE -RCT_jsLocation localhost:$PORT" \
        'waitid Home-menu-button --timeout 60' \
        'tapid NavBar-tab-search' 'waitid Search-input' \
        'typeid Search-input yoga' 'button ENTER' \
        'waitid Search-result-card-42 --timeout 30'

  # by coordinate and text - when there is no testID to address:
  $S do "relaunch $BUNDLE -RCT_jsLocation localhost:$PORT" \
        'waitfor "Search items" --timeout 30' \
        'tap 220 904' 'waitfor "StaticText Schedule"' \
        'tap 220 317' 'waitfor "Button Back"'
  ```

  `waitfor` matches its regex, case-insensitively, against each element's
  `type label name value` joined with spaces - which is why `'StaticText Schedule'` finds
  a screen title without also matching the tab button of the same name. It prints the
  elements it matched, so a batch leaves a readable trail of what each step reached.
  Two traps come with that, both silent:
  - **Without `--all` it only sees the filtered tree** (TextField, Button, Switch, Icon,
    SearchField, StaticText, Image, and only when labeled). A React Native pressable is
    very often `type: "Other"`: `waitfor Settings-back-button` timed out with the screen
    plainly up, and `--all` (or `waitid`) found it at once.
  - **A short pattern matches things you did not mean**, because the fields are joined and
    case is ignored: `Sign` matched the status bar's `"No signal"` and the batch walked on
    from the launch screen. Anchor it, or wait by testID - an id is matched exactly.
  In a shell variable, keep X and Y separate: Claude's Bash is zsh, which does not split
  `R="195 625"; $S tap $R` into two words, so the tap errors out and a chain that ignores
  the exit code carries on to the screenshot.
- Once a route is known, write it into `config.md` next to the screen map. Re-deriving tab
  coordinates from `elements --all` is a round trip you only need to pay once per device.

### 2. Observe
- `$S elements` -> the accessibility tree as compact JSON (`rect` is `[x,y,w,h]` in pt). This is the primary signal: assert on real elements, not pixels.
- **`$S elements --all`** -> the FULL visible tree including unlabeled `Other`/container nodes. Use it whenever an element you can see isn't in the filtered tree - RN rows, glass buttons, and icon-only controls usually live there as `type:"Other"` with an exact rect (e.g. list rows, the search-field clear button). Reach for `--all` BEFORE falling back to screenshot-and-guess coordinates.
- **`$S elements [--all] --grep REGEX`** keeps the elements where ONE field (type, label, name or value) matches, and **`--names`** prints one line per element (`testID  type  [rect]  'text'`) instead of JSON. Use them instead of piping the tree into a throwaway parser - sessions re-typed that parser on most reads, each time a slightly different one. With `--settled` the two reads are still compared whole; the filter only changes what is printed.
- **One element by testID** - `$S el ID` (type, label, value, rect, `displayed` of every element carrying that id), `$S waitid ID [--timeout S] [--exists]`, `$S tapid ID`, `$S typeid ID "text"` (below, under typing). `displayed` is the same visibility function the tree's filter uses, asked for one element: it agreed with the tree on every identifier of three screens (81, 85 and 117 ids), list rows and covered elements included. Know what the lookup is before leaning on it:
  - WebDriverAgent's "accessibility id" means `identifier == X`, **or** `label == X` for an element that has NO identifier. So `waitid "Popular now"` finds a bare text, and `waitid Menu` finds nothing when "Menu" is the label of a button that has a testID. Each match says `by: "id"` or `by: "id-or-label"` (the label equals the query: most likely a text match).
  - It returns every match, displayed or not. `waitid` succeeds when ANY is displayed; `tapid` taps only when the displayed matches are ONE target (React Native often exposes a view twice with the identical frame - that counts as one) and otherwise refuses and lists them.
  - `tapid` presses through `element/click`, where WebDriverAgent picks a hittable point - not the centre of the rect. For a partly covered element the centre is the wrong place: a title whose centre sat under the tab bar switched tabs when tapped by coordinate. Do not "fix" a `tapid` by tapping the rect's centre yourself.
  - **`<Screen>-screen-root` is a poor thing to wait for.** A root container often reports `displayed: false` while its screen is plainly up (Home and Settings do, Explore does not - the tree says the same). Wait for a real control of the screen, or pass `--exists` when presence is all you need; a timed-out `waitid` tells you when the id existed but was not displayed.
  - Find, `displayed` and `rect` are separate requests, not one snapshot. On a screen that is still loading a rect can move between them, and an element whose visibility flickers (one calendar cell did, in the tree as well) can read `false` once. A wait absorbs that; a single `el` read does not - for an assertion about several elements at once use `elements --settled`.
  - **`tapid` can take ~21 s instead of ~1 s** when the app never goes idle: `element/click` waits for idleness before and after the tap, up to `waitForIdleTimeout` (10 s) each. Measured 2026-11-14: Safari with a focused address field 20.5 s, and one React Native app in one state for 12 taps in a row until a relaunch. (With the timeout set to 3 s inside ONE WebDriverAgent session the click took 6.5 s, but WDA resets the setting to 10 for every new session and the driver opens one per command, so this is not a knob you can turn from outside.) The tap still lands, and the driver prints a NOTE with the time. A coordinate `tap` in the same state took 2.5 s - it is faster but presses the rect's centre, so use it only where the centre is plainly the element.
  - **One driver command per WebDriverAgent at a time.** WDA holds ONE session; every command opens its own, which voids the session of a command still running. `waitid` / `tapid` / `el` re-attach and carry on: `waitid` until its timeout, `tapid` / `el` up to 6 restarts from the lookup (one other command replaces the session twice - it opens one and deletes it on exit). A background `waitid` used to fail with "invalid session id" while the element was on screen. The other commands fail loudly with WDA's error. Two sessions of Claude on one simulator therefore take turns, they do not overlap.
  - A fast wait no longer hides the 2-4 s a tree read used to add. With WebDriverAgent's default settings the screen was already still when the wait passed (same screenshot 1.5 s later); with `waitForIdleTimeout` set to 0 it was mid-transition. Leave that setting alone.
- `$S screenshot [out.png] [--width N]` then Read the file -> visual confirmation of layout, spacing, glass surfaces, anything the tree can't express. By default the image is resampled to the device's point width (px ÷ SIMULATOR_MAINSCREEN_SCALE), so **1px == 1pt on any simulator** and coordinates read straight off the image. `--width 0` = full res (for 3b measurement).
- After any tap that should change the screen, re-run `$S elements` and confirm the content actually changed (e.g. header label flipped) - a registered click is not proof of navigation.
- Interactions: `$S tap|doubletap|longpress|swipe|drag|type|button` (see script header for signatures). Coordinates are POINTS; a coordinate measured on a full-res screenshot must be divided by the scale first. Out-of-range coordinates are rejected rather than silently doing nothing - and **against the rotated frame when the app in front is in landscape** (a video player is 874x402 on an iPhone 17, and `tap 600 200` is legal there; `$S orientation` says what WebDriverAgent sees). A gesture or keystroke WebDriverAgent refuses ends the command with exit 1 and its error - it is never reported as done. What WDA ACCEPTS without effect is still reported: `type` with no focused field prints "typed" and changes nothing, so read the field back. `drag` from a list scrolls further than the finger moved (546 pt for a 400 pt drag on Explore: iOS adds momentum) - assert on where things ended up, not on the distance. `button VOLUME_UP` / `VOLUME_DOWN` work only on a physical iPhone.
- **Type into a field with `$S typeid <field-id> "text"`, not `type`.** `type` sends keys to whatever has focus and never looks at the result: in one app's search screen `type yoga` + `button ENTER` left "yo" or "yog" in 3 of 5 runs (2026-11-14) and in 10 of 10 one morning (2026-11-15), while printing "typed: yoga" - and the search ran for the cut word. The same afternoon it typed full words 25 of 25: whether it cuts depends on a state you cannot see, so its "typed" proves nothing. `typeid` goes through the field itself (XCTest focuses it and types with its own synchronisation), then reads the field back: 25 of 25 exact in the same field (including `zażółć` and `O'Brien "x"`), also after the field had lost focus, 1.2-1.6 s for the whole command and ~2.4 s when it replaces a submitted search (2026-11-15) - about what `tapid` + `type` cost. It REPLACES the field's text (`--append` keeps it, `''` empties the field), treats a value equal to the placeholder as empty, and exits 1 when the field holds anything else - pass `--expect VALUE` for a field that formats what you type (a phone mask). A trailing `\n` (`typeid Search-input $'yoga\n'`) is sent as Return only after the read-back matched. It refuses, untouched, an element that is not a text field (TextField, SecureTextField, SearchField, TextView): typing focuses by tapping, and a button would be pressed. A field-typed element that is really a button still gets that tap - a SearchField opening the search screen (a search bar that only navigates), a TextField opening an editor (Safari's collapsed address bar, `TabBarItemTitle`) - and `typeid` exits 1 saying the element may have been tapped; `tapid` it first and type into the field that appears. A secure field reads as bullets, so there it says it could not check. Keep `type` for a field without a testID (then `SIMUI_TYPE_DELAY=0.2` and an `el` read before ENTER) and for a segmented OTP input (see `gotchas.md`).
- App and device state without `curl`: `$S activate BUNDLE` (foreground without a restart and without launch arguments), `$S foreground` (bundle id + pid of the app in front - the cheap way to learn that a tap threw you out to Safari or the home screen), `$S lock` / `$S unlock` / `$S locked`, `$S alert buttons`. `unlock` cannot get past a passcode or Face ID on a physical iPhone - that one needs the human.
- **Alerts queue and arrive late.** One read a few seconds after a tap that says "no alert" is not evidence the tap did nothing. Use `$S alert wait [seconds]` to wait for one, and `$S alert accept --all` afterwards - if it drains more alerts than you ever saw, every tap landed.
- **One read right after a tap is a frame of an animation, not the state.** A dismissing keyboard, a sheet mid-transition or a launch screen reads as "gone" and is back in the next frame (a tap-to-dismiss was CONFIRMED off one read; 4 s later the keyboard was there). Assert transitions with **`$S elements --settled`**: two reads 2 s apart (`SIMUI_SETTLE_SECONDS`), exit 3 with the diff when they differ. Only two reads that agree are evidence.
- `$S elements` is not a passive read: answering it makes `UITabBarController` instantiate every child controller, so it can mount the very screen you are testing for. Never use it to prove a screen was NOT mounted.

### 2b. Ask the app's JS runtime (`scripts/rn-devtools.mjs`)
The accessibility tree shows what iOS exposes; the app's JS runtime knows the rest (state, globals, what React rendered). `scripts/rn-devtools.mjs` talks to it over Metro's CDP inspector, the channel `read-rn-logs-cdp.py` reads logs from. Node built-ins only (tested on Node 25.8; the global `WebSocket` needs Node >= 22.4), one-shot: every command connects, does its job, closes.
```
RD=<skill-dir>/scripts/rn-devtools.mjs
node $RD targets --port 8090                     # the runtime pages; * marks the one commands use
node $RD eval '1+1' --port 8090                  # -> 2 (JSON on stdout)
node $RD eval 'typeof globalThis.nativeFabricUIManager' --device "iPhone 17"
node $RD tree --port 8090                        # React component tree of the screen in front
node $RD tree --id Some-testID                   # that component and its ancestors
node $RD tree --grep 'checkout|total' --json     # matches on name/text/label/testID, as JSON
node $RD tree --ids                              # testIDs React rendered on screen, one per line
```
- **Target selection is `read-rn-logs-cdp.py`'s**: `--port` (default `$METRO_PORT`, else 8081), `--device` (substring; an exact name wins), `--app <bundle id>`, `--page <n>` (an explicit page, the only way to a worklet runtime such as Reanimated's `UI`). The main runtime is the page that prefers the Fusebox frontend. Several devices, or several app runtimes on one device: exit 2 with the list, never a guess.
- **Exit codes**: 0 done; 1 nothing to talk to (Metro not on the port, no matching target), the expression threw (its text on stderr) or its result is something JSON cannot carry (NaN, a BigInt, a cycle - wrap it in `String(...)`); 2 ambiguous target; 3 no answer within `--timeout` (seconds, default 10) or the page went away mid-command; 64 usage.
- `eval` runs in the app's global scope and awaits a Promise (`--no-await` to skip). React Native's `Promise` is a polyfill that CDP's own `awaitPromise` does not recognise (it returns `{"_h":0,...}`), so the wait happens inside the app; a rejection exits 1 with its text, a Promise that never settles exits 3. Hermes has `globalThis`, not Node's `global`.
- **`tree`** prints one component per line, two spaces per level: `Name "text" [testID=X] (tap X,Y)`, where the text is the visible text or else the accessibility label and `(tap X,Y)` is the centre of the part of its rect that is on screen, in points - what `$S tap X Y` takes on a portrait simulator (no orientation correction: a landscape UI is reported in the window's axes). Layout-only wrappers, components fully off screen (`--all` keeps them) and text an ancestor already shows are pruned with the rules of Argent's component tree, so a wrapper missing from the output proves nothing. Every testID React renders on screen stays, partly visible components included; React usually has more of them than `$S elements --all --names`, because iOS merges many views into one accessible element. `--grep REGEX` (case-insensitive) and `--id X` keep the matches plus their ancestors (with `--ids`, only the matches' testIDs); a filter that matches nothing prints `(nothing matches the filter)` and exits 0. `--max-nodes N` collapses wrapper chains. Its `--timeout` default is 15 s.
- **Network log (`net start | read | stop`)** - which HTTP requests the app's JavaScript made and what came back, when the screen alone cannot say (a request never sent, a 4xx behind an empty state, the query a search really sent):
  ```
  node $RD net start --port 8090        # install the log in the app; a second start changes nothing
  # ... drive the screen (tap, type, navigate) ...
  node $RD net read --port 8090 --grep 'search' --since 2m
  node $RD net stop --port 8090         # fetch/XHR put back, records deleted
  ```
  `read` prints the requests oldest first: time (UTC), method, status (or `pending` / `failed (<reason>)`), duration, URL, then request and response body cut at 500 chars with a `...[N more chars; --full prints all]` marker. `--grep REGEX` filters on the URL, `--since 30s|5m|2h|HH:MM[:SS]|<ISO time>` on the start time (a time without a zone is UTC, as `read` prints), `--limit N` keeps the last N (default 50), `--json` gives the same fields as JSON. `--headers` adds headers with the values of Authorization, Proxy-Authorization, Cookie and Set-Cookie replaced by `<redacted, N chars>`; `--show-secrets` prints them, so never paste that output anywhere. Requests to Metro itself are left out.
  - **JavaScript requests only.** It patches what JS sends through: XMLHttpRequest (React Native's `fetch` and axios run on it), Expo's native fetch, and React Native's network module. Requests native code makes itself (native SDKs, `<Image>` loads, analytics libraries with their own HTTP stack) never pass through JS and never appear: an empty log is not proof that nothing was sent. Requests to Metro itself (any URL on the `--port` Metro) are recorded but `read` hides them - so a smoke test needs a URL on another host, never `localhost:<metro port>`.
  - **It lives in the app's JS.** The records stay between commands until `stop` or a JS reload; after a reload (or before any `start`) `read` exits 1 "not running". Start it BEFORE the action: a request already sent is not recorded.
  - **A screen that shows results may have sent nothing**: apps cache query results, so repeating a search or reopening a screen often makes no request. Use a fresh query, or reload, when you need the request itself.
  - Responses over 1 MiB are cut by the interceptor itself (marked in `read`), binary bodies are not recorded.
- **Metro lets ONE debugger hold an app.** Connecting here closes React Native DevTools or a running `read-rn-logs-cdp.py` on that app. A log tap in follow mode (the default) reconnects at once and closes this command in turn: it exits 3 with "another debugger took the page". Run the log tap with `--no-follow`, or stop it, while you use `rn-devtools.mjs`.

## Lifecycle details

- After a CC restart the app is often backgrounded to the iOS home screen - always `$S launch` to bring the app forward; don't assume it's foregrounded.
- Springboard icon taps are fragile (coordinates land between icons). Launch by bundle id, not by tapping the home-screen icon.
- Element rects are `[x, y, width, height]` (top-left + size). Tap the center: `x + width/2`, `y + height/2`.
- `$S launch` on a running app just foregrounds it - it does NOT fetch a fresh JS bundle. After code changes use `$S relaunch` (or `curl -s localhost:PORT/reload`).
