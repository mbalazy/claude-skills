# simulator-verify config - <app name>

Everything project-specific that the `simulator-verify` skill reads. Copy this
file to `<repo-root>/.simulator-verify/config.md` and fill it in.

**Keep this directory out of git.** It accumulates real account data (test
users, phone numbers, appointment contents) as you fill in the screen map, and
that must not end up in a commit. Add `.simulator-verify/` to `.gitignore`, or
to `.git/info/exclude` if you would rather not touch the shared ignore file.

Treat it as a living document: every screen you reach, every deep link that
works, every flow that turned out to fire something outward-facing goes back in
here. The skill stays generic; this file is where the project knowledge lives.

## App

- **bundle id**: `<com.example.app.development>` - the dev build's id, what
  `sim-ui.sh launch` takes.
- **scheme**: `<Xcode scheme, e.g. MyApp-Development>`
- **platform**: iOS simulator / physical device. Note here if a physical device
  is in play - JS `console.log` does NOT reach `idevicesyslog` on a device with
  the New Architecture, and UI automation needs a signed WebDriverAgent, so on
  a device the loop degrades to screenshots plus a human tapping.

## Device

- **default**: booted simulator (resolve via `sim-ui.sh devices`)
- **known good**: `<iPhone model + iOS version that has WebDriverAgent installed>`
- **pin a specific device**: export `SIM_UDID=<udid>`, otherwise the first
  booted simulator wins.

## Metro

- **port**: `<8081>` - and verify it before trusting it. With several projects
  or worktrees open, ports get taken in start order. Identify the owner by
  working directory:
  ```sh
  lsof -ti tcp:PORT -s tcp:listen           # -> PID
  lsof -a -p PID -d cwd -Fn                 # -> which repo it serves
  ```
- **Never kill or restart a Metro that belongs to another project or another
  session.** List here any port that is known to belong to something else.
- **Reload the JS bundle from the shell**: `curl -s localhost:PORT/reload`, then
  wait ~5s.
- **Wrong bundle loaded** (a redbox naming another app's module): repoint the
  installed app without rebuilding, then terminate + launch:
  ```sh
  xcrun simctl spawn booted defaults write <bundle-id> RCT_jsLocation "localhost:PORT"
  ```

## Cold start (only when the app is not installed or Metro is down)

Fill in the exact command that produces a working dev build in this repo -
including the node version manager, env file and port flags, because getting
this wrong costs a rebuild:

```sh
<e.g. ENVFILE=.env.development npx react-native run-ios --scheme <Scheme> --port <PORT> --no-packager>
```

Metro in its own terminal: `<e.g. yarn start --port PORT>`

## Screen map

The point of this table is that the next session does not have to rediscover
navigation. Fill a row the first time you reach a screen.

| Screen | How to reach | Key elements (accessibility labels) |
|---|---|---|
| `<Home>` | `<tab "Home">` | `<header "Home", search field, ...>` |
| | | |

Notes worth capturing per row: controls that are NOT in the accessibility tree
(icon-only buttons, glass surfaces) and therefore need tapping by coordinates
from a full-resolution screenshot; and any element whose presence depends on
data state.

## Outward-facing flows - check before driving

List every create/submit flow that touches the real world (sends an SMS or
email, charges a card, notifies a user). Section 3d of the skill explains why:
reaching a visual state by completing one of these is not free.

- `<flow>` -> `<what it fires>` -> `<the instrumentation shortcut to use instead>`

## Network debugging

How to see HTTP traffic in this app. If the project ships a network logger,
describe how to reach it and how to get the dump into the shell (a console dump
read back with `read-rn-logs.sh` beats tapping through an in-app list).

- **Library / mechanism**: `<e.g. react-native-network-logger, enabled in non-production builds>`
- **How to reach the UI**: `<Settings -> Engineering -> Network Logger>`
- **Programmatic dump**: `<the button that dumps to console, and the grep tag it prints>`
- **Dev/staging only?** Note the limits (e.g. captures only since app launch).

## Deep links

- **scheme**: `<myapp://>` - registered? verify before relying on it.
- Known links: `<myapp://debug/dump-network-logs>`
- Open with `sim-ui.sh openurl <url>`. If no scheme is registered, navigate by
  tapping rect centers from `sim-ui.sh elements`.

## Design system (for visual assertions)

Where the tokens live, so a visual check can assert "token-correct" rather than
"looks about right": `<e.g. styled-components, colors via theme.semantic.*,
spacing via theme.spacing.*; token catalog at .claude/design-tokens.md>`

## Test data

State of the dev account, as far as it matters for verification: what exists,
what does not, and therefore which paths cannot be eyeballed without creating
something. **Do not put real customers' names or phone numbers here** - describe
the shape ("one past appointment, no upcoming"), not the people.

## Known red / pre-existing breakage

Anything that is already failing on the base branch, so a verification run does
not blame it on the current change. Re-check the list before leaning on it.
