# Physical iPhone over USB

Read when the target is a phone on the cable. Everything in SKILL.md applies unchanged; this file is what differs. WebDriverAgent on the phone (`wda-device.sh`, the pinned version, the keyboard patch) is in `wda.md`.

## The same loop on a phone (verified 2026-09-25, iPhone 12 / iOS 27)

Everything above and below applies to a phone on the USB cable, with the same scripts and the same commands. The scripts tell a phone from a simulator by **the shape of the udid** (`0000XXXX-<16 hex>` from `xcrun devicectl list devices`, against a simulator's 8-4-4-4-12), never by a flag somebody has to remember, and switch the plumbing underneath:

| | simulator | physical iPhone |
|---|---|---|
| identity | `SIM_UDID=<sim udid>` | `SIM_UDID=<phone udid>` (same variable; with no simulator booted and one phone plugged in it is picked by itself) |
| lifecycle (`launch`/`relaunch`/`terminate`/`openurl`) | `xcrun simctl` | `xcrun devicectl` (`process launch --terminate-existing <bundle> -- <args>`, the `--` keeps devicectl from eating `-RCT_jsLocation`; `process openURL <url>`; terminate by pid) |
| WebDriverAgent | xctrunner on the sim, auto-started, port owner = the sim's process path | `xcodebuild test` on the phone + an `iproxy <port> 8100 -u <udid>` tunnel, brought up by **`scripts/wda-device.sh <udid> --team <id>`** (never auto-started - it is a minutes-long test run); `WDA_PORT` derives itself from the tunnel that names the udid; a sim's port is refused with the tunnel's port named |
| geometry / bounds check | `simctl getenv` | WDA `/wda/screen` |
| `screenshot` | `simctl io` | `devicectl device capture screenshot` (WDA's own `/screenshot` returned a stale frame on a device) |
| `type` | one request per string | **one character per request, 0.35 s apart** - a burst drops characters (`5125550199` arrived as `(519) 9`); `SIMUI_TYPE_DELAY` forces this on a sim too |
| `rig-check.sh` | marker read from the simulator log | marker read over Metro's CDP inspector (`read-rn-logs-cdp.py --device iPhone`); the launch carries `-RCT_jsLocation <mac-usb-address>:<port>` because the phone cannot reach `localhost` |
| JS console | `read-rn-logs-cdp.py` | the same, with `--device iPhone` - a phone registers on Metro as plain `iPhone`, and the reader prefers that exact name over the "iPhone 17" substring matches |

`rig-check.sh --udid <phone udid>` is the same gate as on a simulator and passes in ~12 s. What it cannot see on a phone it says instead of guessing: whether the binary embeds a `main.jsbundle`, and when it was built. The Mac's address on the USB link (`169.254.x.x`) is derived from the phone's existing connection to Metro, else from the only link-local interface; `--host` overrides.

Two device-only traps, both silent:
- **A fresh install waits on the iOS "Local Network" prompt.** The first launch after every uninstall + install sits on the launch screen with zero requests to Metro and zero errors anywhere until Allow is tapped; an install OVER the existing app keeps the permission. With WDA up no human is needed: `$S do '?alert wait 20' '?alert accept'` presses **Allow** (verified 2026-09-29 on the iPhone 12, iOS 27: rig-check RIG OK right after). The fresh install is also logged out. `rig-check.sh` names the prompt when the phone holds no connection to Metro.
- **System modals on the phone, who clears them.** An iOS alert the app raises (Local Network, and by the same WDA call other permission prompts) goes through `$S alert` / `alert accept` / `alert dismiss`; read its text first, because `accept` presses whichever button WDA treats as the accepting one - only the Local Network case is verified, so for a prompt with three buttons (location, photos) confirm the pressed one with a screenshot or tap the button by its label from `$S elements`. The one modal WDA cannot clear is *Enter iPhone Passcode for "XCTest" - Enable UI Automation*: it appears before automation exists, so a human types the passcode.
- **`-RCT_jsLocation` loses to `ip.txt` only when that file lists MORE than one candidate.** A device build carries `ip.txt` with the Mac's address(es); the measured app's custom `AppDelegate.bundleURL()` probes the candidates only when there are several, and with a single line (the usual case) the launch flag wins - measured: the phone loaded from the USB link address (`169.254.x.x:8081`) with `ip.txt` naming the WiFi one (`192.168.x.x`).

The per-repo `config.md` records the phone's udid, the Apple team whose Xcode-managed profile lists it, the runner bundle id, the tunnel port and the build recipe (a device build needs a provisioning profile, so the bundle id and configuration may differ from the simulator's).

## -RCT_jsLocation and ip.txt on a device

- **On a physical device the same flag works, with one documented exception.** A device build carries an `ip.txt` inside its bundle holding the Mac's address (`react-native-xcode.sh` writes it only when `PLATFORM_NAME` is not a simulator - which is why a simulator build never has one). Stock `RCTBundleURLProvider` prefers `jsLocation` over that file but drops it whenever its own packager-reachability probe fails; an app with a custom `bundleURL()` in its AppDelegate may read `ip.txt` FIRST and overwrite `jsLocation` - the app this was measured on does so only when `ip.txt` lists MORE than one candidate. With a single line the flag wins (measured 2026-09-25: loaded from the USB address with `ip.txt` naming the WiFi one). `rig-check.sh` passes the flag on a phone by itself, with the Mac's USB address; before relying on it in another app, read that app's `bundleURL()`.

## Logs from a phone

**An HTTP probe, when the log channel is not usable** (technique 3 in `measurement.md`). `console.log` is only worth instrumenting if you can read it back. On a **physical device** `idevicesyslog` never relays it (New Architecture + Hermes send JS logs to the DevTools inspector only), but the CDP tap (`read-rn-logs-cdp.py`, see `measurement.md`) reads them as long as the phone loads its JS from this Metro (`read-rn-logs-cdp.py --device iPhone`, verified 2026-09-25); a phone running an embedded bundle has no inspector target at all. The other case for a probe is a large payload on any target - a whole element tree or a serialized object gets truncated and line-wrapped into something you cannot parse.

**Native logs from a physical device**, when the question is about the OS rather than about JS (audio session state, permissions, CoreAudio):
```sh
xcrun devicectl device process launch --console --terminate-existing --device <udid> <bundle-id>
```
`xcrun devicectl device console` does not exist - it fails with `Error: Unknown option '--device'`. `idevicesyslog -u <udid>` is the other channel and picks up native `NSLog` from libraries, but not RN's `console.log`.
