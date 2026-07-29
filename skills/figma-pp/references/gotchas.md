# Gotchas reference — simulator + Figma frictions

Distilled from real implementation sessions. Read when something behaves weird; don't rediscover these the hard way.

## Coordinates & a11y tree

- **Never tap from inline-screenshot coordinates.** The inline screenshot from mobile MCP is 3x scaled (file is e.g. 1206×2622, logical screen is 402×874). A logo that looks like y33 is actually y74. Two ways to be right:
  - Take coordinates from `mobile_list_elements_on_screen` — they're in points (= truth).
  - Or scale a saved screenshot down to logical width BEFORE measuring.
- **Header buttons (logo / hamburger) are often NOT in the a11y tree** (bare `TouchableOpacity`). No element to target → you're guessing coords. Prefer deep link / force-open over tapping these.
- **Dev-menu rows may also be missing from a11y tree.** First blind tap often hits the wrong row. Scale-to-logical and measure Y.

## Reaching the screen

- **mobile MCP blocks custom URL schemes directly.** Use `xcrun simctl openurl <udid> "<scheme>:///<route>"` or set `MOBILEMCP_ALLOW_UNSAFE_URLS=1`.
- **Deep link is deterministic; clicking through nav is not.** Clicking logo → DevTools repeatedly failed (a11y + coord scale). Deep link bypasses navigation entirely — biggest single time-saver.
- **Fast Refresh can reset navigation** — kicks you back to Home (sometimes with an onboarding modal). Re-run the deep link to restore the view.
- **Cold relaunch drops to the expo-dev-client launcher** (no auto-reconnect). Avoid full relaunch; prefer Fast Refresh / in-app reload.

## Liveness / verification

- **Simulator status bar is frozen** (stuck clock, e.g. 12:19). Screenshots look "stale" but aren't. Check liveness via a clock/element in `list_elements_on_screen`, not the status bar.
- **Naive full-screen pixel-diff is misleading.** Figma frame (e.g. 360×780) ≠ device (393pt + safe area + status bar). Text wrapping and absolute positions differ even with identical, correct code. Compare VALUES (from `get_design_context`) + eyeball; reserve pixel-diff for a tightly-cropped single component where dimensions actually align.

## Assets

- **Exports bake in the parent background (no alpha).** `download_assets` / `get_screenshot` render the node on its parent fill (e.g. hero illustration on app navy `#123456`). You must floodfill the edges to transparency. Recipe (in `asset.sh`):
  ```bash
  magick in.png -alpha set -bordercolor '#123456' -border 1 -fuzz 14% \
    -fill none -draw 'alpha 0,0 floodfill' -shave 1x1 out.png
  ```
- **Backgrounds are per-instance**, illustrations are usually shared/transparent. A multi-step flow has a different bg per step → export each sub-node separately. Don't reuse one bg across steps.
- **Sub-node addressing:** IDs come as `I<inst>;<comp>` (e.g. `I1001:2002;3003:4004`). The part after `;` (`3003-4004`) is independently screenshot/exportable — isolate an asset/bg without the whole screen.
- **Changing asset bytes under the same path needs a FULL reload.** Metro caches by hash; Fast Refresh won't pick up new bytes at an existing path.
- **Always WebP** (`cwebp -q 85`). Project rule.

## Figma API quirks

- **`get_design_context` dumps the entire frame** (including content behind a modal) = token noise. Target a tight node-id when you can.
- **`get_metadata` does not descend into instances** — returns only the flattened top node. Get addressable sub-node IDs from `get_design_context`, not metadata.

## Animations / gestures

- **`pagingEnabled` swipe sometimes bounces back** (below threshold). Use a stronger swipe (distance ~280) and start higher over the content so you don't grab a scrollable inner box.
- **Verify animation via recording → frames:** `mobile_start_screen_recording` → gesture → `mobile_stop_screen_recording` → `ffmpeg` extract frames → `magick montage` for a filmstrip you can `Read`.
