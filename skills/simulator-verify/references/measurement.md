# Measurement and instrumentation

Read when the eye is not enough: alignment off by a point or two, an overlap or a collapse, a popover next to its trigger, or numbers you need out of the running app. Every bit of instrumentation here is throwaway and comes out before the commit (`git status` clean).

### 3b. Measure (pixel-perfect bugs) - numbers, not eyeballing

When the bug is about alignment/centering/spacing of a **small** element (a label "not centered", a badge "off by a bit"), the eye is unreliable and the JPEG compounds it - a 1-2pt offset is real but invisible at a glance. Do not report "looks ok" or "looks off"; produce a **number**.

1. Full-res screenshot: `xcrun simctl io booted screenshot shot.png` (device px, e.g. iPhone @3x = 3px/pt).
2. Find the element's px region. Use the element tree coordinates (a11y coords are in pt -> x3), or crop-and-zoom (`sips -c H W --cropOffset Y X ...`) to read it off.
3. Measure with the bundled script:
   ```
   python3 <skill-dir>/scripts/measure-element.py shot.png \
       --region X,Y,W,H --container dark --inset 20 --scale 3
   ```
   It returns container vs inner-content center delta in px **and pt**, plus inner top/bottom padding. Negative vertical = content rides HIGH; positive = LOW.
4. **Verdict from the number**: `|delta| < ~0.5pt` = centered (PASS). `|delta| >= ~1pt` = real defect; report the exact value and the asymmetric padding (e.g. "text 1.5pt high: 2pt top vs 5pt bottom").
5. Confirm stability: re-run at 2-3 `--inset` values; a real geometric offset is constant, a measurement artifact wobbles.

After a fix, re-measure the same region and show the before/after delta (e.g. `-1.5pt -> 0.0pt`) as proof.

For elements that resist pixel detection (low contrast, anti-aliasing), prefer **layout instrumentation** (see 3c below). Remove all instrumentation before committing.

### 3c. Instrument (overlap / collapse / "invisible box" bugs) - ground truth, not guesses

When a layout bug is about **where boxes actually are** (an element overlapping another, a view collapsing, something rendering "under" something else), STOP theorizing. Two throwaway techniques give you exact ground truth - both were what cracked ACME-1164 (a search input silently collapsing to 0 height, so its glass painted over the chips below it - looked like z-order, was actually a height collapse):

**1. Colored background overlays (you read these yourself from a screenshot).** Temporarily give each suspect box a translucent bg via inline `style` and screenshot it. Distinct colors = instantly see each box's real frame and any overlap:
```tsx
style={{ backgroundColor: 'rgba(255,0,0,0.35)' }}   // box A (e.g. red = input)
style={{ backgroundColor: 'rgba(0,0,255,0.35)' }}   // box B (e.g. blue = cards)
style={{ backgroundColor: 'rgba(0,255,0,0.2)' }}    // box C (e.g. green = container)
```
Crop+zoom the screenshot (`python3` + PIL, or `sips`) to compare the bands. No copy-paste from anyone needed - you see it.

**2. `onLayout` logging that you read yourself (no Metro copy-paste).** Add a throwaway logger and read the numbers straight off the simulator's system log:
```tsx
const logLayout = (tag: string) => (e: LayoutChangeEvent) => {
  const { x, y, width, height } = e.nativeEvent.layout;
  console.log(`[LAYOUT] ${tag} ${JSON.stringify({ x, y, width, height })}`);
};
// ...on each suspect box:
<Flex onLayout={logLayout('SEARCH_INPUT')} ...>
```
RN routes `console.*` to Apple os_log (`subsystem com.facebook.react.log`, `category javascript`). Read it without the user pasting anything:
```
# record time, trigger the action (reload / navigate), then read only-new logs:
set TS (date '+%Y-%m-%d %H:%M:%S'); curl -s localhost:$PORT/reload >/dev/null; sleep 6   # $PORT = Metro port from config.md
<skill-dir>/scripts/read-rn-logs.sh --since "$TS" --grep '[LAYOUT]'
# or just grab the last N seconds:
<skill-dir>/scripts/read-rn-logs.sh 8
```
The `--since "$TS"` (timestamp captured before the action) is the "which logs are new" mechanism - everything older is filtered out. `--info --debug` is baked in (JS logs are INFO level; plain `log show` drops them). Gotcha: multi-arg `console.log(a, b)` prints comma-separated quoted args - prefer one template string for clean grepping. Script: `scripts/read-rn-logs.sh` (`--all` also includes native-bridge logs, `--grep` filters).

**Device selection is not the same variable as `sim-ui.sh`'s.** `read-rn-logs.sh` takes `--udid`, `$SIMCTL_DEVICE` or `$SIM_UDID`; with several simulators booted and none of them set it refuses instead of reading an arbitrary device. An empty result now prints the device and the time window it searched - read that before concluding the instrumentation never fired, because "no logs" from the wrong simulator looks identical to "the code never ran".

**RN >= 0.77 (New Architecture + Hermes): os_log is DEAD for JS logs.** Fusebox routes `console.*` exclusively to React Native DevTools over CDP - nothing reaches `com.facebook.react.log` and Metro's terminal no longer prints client logs either, so `read-rn-logs.sh` comes back empty however correct the query is (verified on RN 0.83: LogBox showed a live warning while os_log had zero lines). Use the CDP tap instead:
```
# stream console.* straight from Metro's inspector proxy (stdlib only, no deps):
scripts/read-rn-logs-cdp.py --port 8090 --seconds 10 --grep '[LAYOUT]'
```

Metro closes the inspector socket on every app restart (relaunch, crash, a reload that replaces the runtime) - that is normal. The tap **follows**: it waits for the same bundle id on the same device to reappear and reconnects, and `Runtime.enable` on the new runtime replays what was logged while nobody was attached, so a relaunch inside the window loses nothing (`# reconnected to ...` on stderr marks it). Start the tap once, before the flow, with `--seconds` covering the whole flow (or `0` = until Ctrl-C); `--no-follow` restores exit-on-close. Before 2026-08-29 the tap died silently on the first close and whole flows ran unlogged.
It auto-picks the app's MAIN JS runtime (`prefersFuseboxFrontend: true`; worklet runtimes like Reanimated's UI need `--all-runtimes`), refuses to guess between devices (`--device <name-substring>`), and `Runtime.enable` makes Hermes replay its buffered console history with original timestamps - so logs from just BEFORE the tap connected still show up. One debugger per page: if React Native DevTools is attached to the same app, close it first.

Reading the numbers beats reading the pixels: in ACME-1164 the logs showed `SEARCH_INPUT height=64` on one step and `height=16` on the buggy step - that single number ended ~3 sessions of guessing. When a layout bug survives one round of eyeballing, instrument immediately; don't iterate on hunches.



Sidestep the log entirely: have the app POST its data to a collector on the Mac, where the payload arrives whole and machine-readable.
```sh
scripts/probe-collector.py            # :8099 -> /tmp/probe.log, one JSON line per request
```
It prints the URL to use from the simulator (`localhost`) and from a physical device (the Mac's LAN address, which it looks up for you). Then, in the component under test:
```tsx
fetch('http://localhost:8099', { method: 'POST', body: JSON.stringify({ tag: 'SEARCH_INPUT', ...layout }) });
// a GET works too, so the shortest probe is: fetch('http://localhost:8099/?tag=mounted')
```
Read `/tmp/probe.log` yourself. It carries any size of payload, survives a device with no readable JS log, and needs no copy-paste from the user. Remove the `fetch` before committing, exactly like the other instrumentation.

Native logs from a physical device: `device.md`.

### 3e. Anchored overlays (popover / menu / picker) - three channels, never the eye

A popover placed next to a trigger has TWO independent failure modes, and a screenshot cannot separate them: the **anchor** it was handed can be wrong, and the **offset math** applied to that anchor can be wrong. A tall popover makes a badly-anchored one still look "roughly next to" the trigger - ACME-1368's time picker sat 358pt off its row and read as fine at a glance. Do not report an anchored overlay as correct from a screenshot.

Run all three channels; they must agree on the same number:

**1. Anchor-truth protocol** (catches a wrong anchor). The a11y tree is ground truth for the trigger's real screen rect:
```
$S elements --all   # BEFORE tapping: record the trigger's rect [x,y,w,h]
```
then tap it and log the anchor the overlay actually received. `delta = trigger.y - anchor.y`. **0 = correctly anchored; anything else is the bug**, and the delta itself names the cause (a delta equal to a sheet's top edge = a missing sheet-to-screen coordinate translation - inside an RN-Screens form sheet `measureInWindow` returns SHEET-relative coordinates, while an RN `Modal` positions in full-screen space).

**2. Colored boxes drawn in the overlay's own coordinate space** (makes the gap literal). Inside the overlay component, draw the anchor rect it believes in, and outline the frame it actually rendered. The outline must NOT disturb layout - use an absolutely-positioned child, never `borderWidth` on the measured view (that changes its height and corrupts channel 3):
```tsx
{/* red = the anchor as the overlay sees it */}
<View pointerEvents="none" style={{ position:'absolute', left:a.x, top:a.y, width:a.width, height:a.height,
  backgroundColor:'rgba(255,0,0,0.4)', borderWidth:1, borderColor:'red', zIndex:9998 }} />
{/* lime = the rendered frame, drawn as a fill-parent overlay so geometry is untouched */}
<View pointerEvents="none" style={{ position:'absolute', top:0,left:0,right:0,bottom:0,
  borderWidth:2, borderColor:'lime', zIndex:9999 }} />
```
Then measure the boxes instead of squinting at them (`scripts/measure-boxes.py`, full-res shot via `xcrun simctl io <udid> screenshot`): it reports each box's top/bottom/height in pt and the gap between them.

**3. `onLayout` on the popover frame** (catches an estimated-height lie). Log `renderedH` next to the `estimatedHeight` the caller passed, plus the computed `top`:
```
[FLOAT-RENDER] renderedH=303 estH=360 top=486 anchorY=866 gapAbove=77
```
A flip-above popover positioned from an over-estimated height gets a gap of `estH + offsetAbove - renderedH` - that arithmetic is where "it appears too high" complaints come from, and the number tells you the whole story.

**A/B a refactor in ONE build.** When the change is "same math, moved/parameterised", do not switch branches to compare: compute the OLD formula inline next to the new one and log `SAME_AS_LEGACY` / `DIFFERS_FROM_LEGACY`. Every real interaction then becomes a live equivalence test on real anchors, and a `DIFFERS` line on a caller you did not intend to change is the regression, caught immediately. Pair it with an exhaustive sweep unit test (sweep anchor y over the full screen × several anchor heights × each caller's config) - the sweep proves the whole domain, the logs prove the domain the device actually visits.

Remove every bit of this before committing (`git status` clean); instrument in a scratch worktree with its own Metro port so the main checkout stays untouched.
