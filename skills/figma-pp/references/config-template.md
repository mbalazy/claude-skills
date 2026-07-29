# .figma-pp config (per-repo, gitignored)

Copy this file to `<repo-root>/.figma-pp/config.md` and fill it in.
The `figma-pixel-perfect` skill reads this on every run. Keep it current.

## Project

- **Figma MCP server:** `figma`      <!-- the mcpServers key in .claude.json for this repo's Figma account; tools are mcp__<this>__get_design_context etc. Default `figma`. -->
- **URL scheme:** `<scheme>`        <!-- from app.config.js `scheme:` — e.g. myapp -->
- **Assets dir:** `<path>`          <!-- where exported WebP assets go — e.g. apps/expo/assets/ -->
- **Design-system package:** `<pkg>` <!-- e.g. @my/ui — grep here for components/tokens -->
- **Fonts registered:** `<list>`    <!-- e.g. Inter (Bold/Regular), Space Grotesk -->
- **Gradient dep:** `<dep or none>` <!-- e.g. expo-linear-gradient -->

## Simulator / device

- **Default target:** `<simulator | device>`
- **udid hint:** `<udid or "use mobile_list_available_devices">`
- **Logical screen size:** `<w x h pt>` <!-- from mobile_get_screen_size — needed for coord scaling -->
- **Reach-screen default:** `<deep-link | manual>`

## Parent backgrounds (for asset floodfill)

When Figma exports bake in a parent background (no alpha), asset.sh floodfills it out.
List the common parent bg colors here so exports come out transparent:

- `<#hexcolor>`  <!-- e.g. #123456 (app navy) -->

## Notes

<!-- Anything project-specific: known DEV force-open flags, env vars, quirks. -->
