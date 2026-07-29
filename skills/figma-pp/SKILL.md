---
name: figma-pp
description: Implements Figma designs as pixel-perfect React Native code, verified live on a simulator/device. Use when user says "/figma-pp", provides a Figma node URL to implement in an Expo/RN app, asks to make a screen match a design, or wants visual verification of RN UI against Figma. Generic across RN projects; reads per-repo config from .figma-pp/.
---

# Figma → Pixel-Perfect React Native

Turn a Figma node into RN code that visually matches the design, verified on a running simulator/device - not "looks about right" from reading the code.

**Core insight from real sessions:** the value is in two places - (1) `get_design_context` gives exact values so you never guess, and (2) `save_screenshot` → `Read` is the only real "does it look right". Everything else removes friction between those two.

**Invocation:**
- Single screen: `/figma-pp <figma-node-url-or-id> [deep-link-or-route]`
  - With 2nd arg → reach the screen deterministically (deep link, or force-open fallback).
  - Without it → reach the screen by manual navigation via `list_elements_on_screen` (tap testIDs, never inline-screenshot coords).
- Batch (multiple screens): `/figma-pp <node1> <node2> <node3> ...` → see **Batch mode** below.

## Batch mode

When given multiple nodes, don't just loop the whole skill N times - structure it so the shared work happens once and the `ds-mapping.md` cache warms up across the set:

1. **Phase 1 + 2 for ALL nodes first.** Pull `get_design_context` for each, build the combined spec, then do DS mapping for the whole batch in one pass. This is where shared tokens surface and cross-screen inconsistencies show up (e.g. two screens using slightly different spacing for the "same" element). Enrich `.figma-pp/ds-mapping.md` once for the set.
2. **Phase 3-5 per screen, sequentially.** Assets → reach screen → compare loop, one screen at a time (the simulator shows one screen anyway; parallel gives nothing). Finish a screen before moving to the next so each gets real visual sign-off.
3. **One combined montage at the end.** Stack each screen's side-by-side into a single image for the user to sign off the whole batch (run `compare.sh` per screen, then `magick montage`/`-append` the results).

If a route/deep-link is needed per screen, take it from `.figma-pp/deep-links.md` (or discover + record it there as you go). Track progress across the batch so a long run can resume cleanly.

## Setup gate (first thing, every run)

Look for `<repo-root>/.figma-pp/config.md`. This holds everything project-specific (Figma MCP server name, URL scheme, assets path, design-system package, font names). The skill itself is generic - it knows nothing about any one app.

**Figma MCP server name:** read the **Figma MCP server** field from `config.md` (default `figma` if absent) - this is the `mcpServers` key in `.claude.json` for this repo's Figma account. Every Figma tool below is written as `mcp__<figma-server>__*`; substitute the configured name (e.g. `figma` → `mcp__figma__get_design_context`). Different repos use different accounts, so this is per-repo, never hardcoded.

- **Missing?** Copy `references/config-template.md` to `<repo-root>/.figma-pp/config.md` and `references/deep-links-template.md` to `<repo-root>/.figma-pp/deep-links.md`, fill what you can infer from the repo (scheme from `app.config.js`, assets dir, DS package), then ask the user to confirm the URL scheme + assets path before continuing. Also ensure `.figma-pp/` is gitignored (add it if not).
- **Present?** Read it. Also read `.figma-pp/ds-mapping.md` and `.figma-pp/deep-links.md` if they exist.

`.figma-pp/` (per-repo, gitignored) holds: `config.md`, `ds-mapping.md` (typography/color → component/token), `deep-links.md` (screen → route map, self-maintained - see Phase 4).

## The loop (5 phases)

### Phase 1 — GROUND TRUTH
For each target node:
- `mcp__<figma-server>__get_design_context` → the spec. Returns Tailwind/React with literal values: hex colors, gradient stops, font family+weight+size+lineHeight+letterSpacing, padding, border-radius, gaps, PLUS asset URLs and addressable sub-node IDs.
- `mcp__<figma-server>__get_screenshot` → visual reference (URL, not inline - saves context).

Extract a **spec sheet**: colors, fonts, spacing, radius, gradient stops, structure. Note sub-node IDs in the `I<inst>;<comp>` format - the part after `;` is independently addressable for asset export.

⚠️ `get_design_context` dumps the WHOLE frame (everything behind a modal too) = token noise. Prefer a tight node-id. `get_metadata` does NOT descend into instances (flattened top node only) - get sub-node IDs from `get_design_context`, not metadata.

### Phase 2 — DS MAPPING (mandatory gate)
**Before writing any code**, map every spec value onto something that already exists in the repo. This is the single biggest source of drift - past sessions painted from scratch and picked the wrong type (e.g. `Header3` where the design was `Display3`).

- Typography → existing DS component (grep the DS package). Match family+weight+size+lineHeight to a real component, don't eyeball the name.
- Color → existing token. Spacing/radius → token if one exists.
- Check fonts are registered, check needed deps exist (e.g. `expo-linear-gradient` for gradients).
- Use/extend `.figma-pp/ds-mapping.md` as the cache so you don't re-derive every run. Add new mappings you discover.
- **No matching component? That's a deliberate decision to surface**, not a silent "build from zero". Flag it.

This turns "paint from scratch" into "use existing = consistent by construction".

### Phase 3 — ASSETS
For visual parts you can't reproduce in code (illustrations, textured backgrounds, cover rows):
- Export sub-nodes with `scripts/asset.sh` (download at scale 3 → floodfill parent bg → trim → cwebp). See `references/gotchas.md` for WHY floodfill (exports bake in the parent background, no alpha).
- Backgrounds are usually **per-instance** (differ per step/state) - export each. Illustrations are usually transparent - one export.
- Always WebP (per project asset rule). Output into the assets dir from `config.md`.

⚠️ Changing an asset's bytes under the same path needs a FULL reload - Metro caches by hash, Fast Refresh won't pick it up.

### Phase 4 — REPRO (reach the screen)
Getting to the screen is the biggest time-sink. In priority order:

1. **Deep link** (if route arg given or in `deep-links.md`): `scripts/open-screen.sh <scheme> <route>` (uses `xcrun simctl openurl`). Note: mobile MCP blocks custom URL schemes directly - go through simctl or `MOBILEMCP_ALLOW_UNSAFE_URLS=1`.
2. **Force-open fallback** (screen has no route): a dev-only flag in the component that bypasses gating. Document where it lives in `deep-links.md`.
3. **Manual nav** (no 2nd arg): drive via `mobile_list_elements_on_screen` → tap by testID/coords-from-elements. NEVER tap from inline-screenshot coordinates (it's 3x scaled).

**Maintain `deep-links.md` as you go.** When you reach a screen not listed, append a row: `screen | route-or-deep-link | source (file:line where the route/flag is defined)`. If a deep link fails, mark it `⚠ unverified` rather than deleting it. The file header carries these instructions so the map self-maintains across sessions.

⚠️ Fast Refresh can reset navigation (kicks you to Home/modal) - re-run the deep link to restore.

### Phase 5 — COMPARE LOOP (the core)
Iterate: edit → Fast Refresh → verify → fix.

- `mcp__mobile__mobile_save_screenshot` to a file → `Read` it inline (full res - the inline mobile screenshot is too small for detail).
- `mobile_list_elements_on_screen` → verify copy 1:1 (real strings, no OCR) AND measure positions/spacing in points to compare proportions against Figma.
- Compare by **values first** (the Phase-1 spec), eyeball second. Do NOT trust a naive full-screen pixel-diff: the Figma frame (e.g. 360×780) ≠ device (393pt + safe area + status bar), so text wrapping and positions legitimately differ with identical code.
- Animations: `mobile_start_screen_recording` → gesture → `stop` → ffmpeg frames → montage (see gotchas for swipe tuning).

**Montage only at the end / on request.** During iteration, compare yourself. When you believe it's done (or the user asks "show montage"), build a side-by-side with `scripts/compare.sh` and send it to the user for sign-off.

**Gate:** `tsc` clean + biome + jest. But NEVER call it "done" from tests alone - pixel-perfect requires the visual sign-off above.

## When stuck
Read `references/gotchas.md` - the full list of simulator + Figma frictions (frozen status bar, swipe bounce, a11y-tree gaps, asset cache, coordinate scaling, cold-relaunch trap). Don't rediscover them.
