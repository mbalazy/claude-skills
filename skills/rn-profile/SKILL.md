---
name: rn-profile
description: Profile a running React Native app (development build, iOS simulator) from the command line - record which React components re-render and how long each commit takes, with Hermes's CPU sampler alongside, and print the commits and the heaviest components; then, from the saved file without the app, renders per component, the slowest commits and why a component rendered. Use when a question is about performance - "what re-renders when I tap X", "why is this screen slow", "which component costs the most", "does this change cut renders" - instead of answering it by reading code. Triggers - "/rn-profile", "sprofiluj", "profiler react", "co się re-renderuje", "dlaczego ten ekran muli", "zmierz rendery". Talks to the app over Metro's CDP inspector through simulator-verify's devtools code; Node built-ins only.
---

# rn-profile

Measures the running app instead of guessing from the code. One-shot commands: each connects to the app's JS runtime over Metro's inspector, does its job and exits. The recording itself lives in the app between commands, so the steps that make the app work (taps through `simulator-verify`'s `sim-ui.sh`, or a person) happen in between.

Requirements: a **development build** (React DevTools hook present), Metro running, Node with TypeScript type stripping on by default (>= 23.6; tested on 25.8). The scripts import `../../simulator-verify/scripts/devtools/`, so both skills must come from the same checkout (`install.sh` links them that way). The profiler scripts injected into the app are Software Mansion's Argent (Apache 2.0), vendored unmodified under `simulator-verify/scripts/devtools/vendor/argent/` (see its NOTICE).

## React profiler

```
RP=<skill-dir>/scripts/rn-profile.mjs
node $RP react start --port 8090 [--max 60]       # begin recording
# ... drive the app: the interaction you want to measure ...
node $RP react status --port 8090                 # recording for N s (limit M s)
node $RP react stop --port 8090 --out /tmp/p.json # end, write the profile, print the summary
```

- **start** turns on React's profiler on every renderer and Hermes's CPU sampler (`--interval-us`, default 1000). The recording **ends by itself after `--max` seconds** (default 60, at most 600): a timer in the app stops the React side, and `stop` still returns what was recorded up to then, with the CPU samples cut at the limit. The limit bounds React only: Hermes's CPU sampler cannot be stopped from inside the app, so it keeps sampling until `stop` - stop soon after the limit, or the CPU profile `stop` collects (it waits up to 60 s, or `--timeout` when longer) only grows. A second `start` while recording changes nothing. If React is already being profiled by another tool (React DevTools' Profiler tab, Argent), start exits 1 naming it; `--takeover` ends that recording and starts this one. Starting over a recording nobody stopped drops it, and says so.
- **status**: `recording for N s`, `ended by its time limit and waits for react stop`, `being profiled by <other tool>`, or `not recording` (`--json` for the raw state).
- **stop** needs `--out FILE` and checks it can write there BEFORE it ends the recording (the app hands the data over once); a stop that fails leaves an existing file as it was. If another tool took over React's profiler during the recording, stop reads nothing, leaves that tool's recording alone and exits 1; if another tool only stopped it, stop returns the data with its length unknown. It prints:
  - how long it recorded and how it ended (stop, or the time limit);
  - React commits: count, total commit time, the slowest commit and when it happened (`+N s` from the start);
  - CPU sample count;
  - the top components (`--top N`, default 10) by render count and by self time (time spent in the component itself, children excluded);
  - unattributed renders: fibers whose name could not be read because the component unmounted before stop (modals, transient views) - their time is missing from the per-component lists, the commit durations stay right.
  `--json` prints the same summary as JSON. The file holds the raw data (`format: rn-profile-react/1`: React's commit data per root, fiber id -> name, per-component hook metadata, the Hermes CPU profile) for the analysis commands below.

**Analysing a saved profile** - no app, no Metro; they read the file `stop` wrote:

```
node $RP react renders /tmp/p.json [--sort time|renders] [--grep REGEX] [--top 20]
node $RP react commits /tmp/p.json [--top 10] [--min-ms 16]
node $RP react why /tmp/p.json <Component> [--top 20]
```

- **renders**: per component, its renders, how many of them were first mounts, total and max self time, and the dominant reason it re-rendered (`props`, `state`, `hooks`, `context`, `parent`) with the props / hooks that changed most. Sorted by total self time, or by render count with `--sort renders`; `--grep` keeps the names matching a case-insensitive regex.
- **commits**: the slowest commits, longest first: when (`+N s`), how long, whether it was mostly first mounts, the root cause of a cascade (the nearest ancestor with a real change), the components that rendered in it by self time (`xN` = N instances, e.g. list rows) with their reason, the fibers that lost their names, and the JS functions busiest in that window from the CPU samples. `--min-ms` drops commits below a duration (16 ms = one frame at 60 Hz).
- **why**: every render of one component, by its exact display name: the reason, the changed props or hooks (index and type), or for a `parent` render the ancestor whose change set it off and the chain to it. A name that never rendered exits 1 and lists the names that contain it.
- `--json` on each prints the full result. A missing file, a file cut short or one that is not a `react stop` profile exits 1 saying which.
- Reasons come from React DevTools' change data: `hooks` vs `state` needs the hook types of a development build; a context provider has no change data: `-` in `renders`, `unknown` in `why`. A component with only first mounts also shows `-`. A re-render with no change of its own is `parent`.

**Reading the numbers**

- Compare against a baseline of the same length with no input: an idle screen commits too (animations, timers, polling), and the difference is what the interaction costs.
- Generic host components (`View`, `Text`, styling wrappers) lead the render counts on any screen; the useful names are usually in the self-time list and below the first few rows.
- Durations come from the development build on a simulator under whatever else the Mac is doing: compare runs with each other, never with a production budget.

**Limits**

- A JS reload loses the recording: `stop` then exits 1 "No recording in the app".
- Hermes's sampler is process-wide and survives a JS reload. `start` stops a leftover one before it starts its own, and `stop` stops it; a recording that is never stopped leaves it running until the next `start`/`stop` or an app relaunch.
- Connecting takes the app from React Native DevTools and from a following `read-rn-logs-cdp.py` (Metro lets one debugger hold an app; see simulator-verify's section 2b). Run the log tap with `--no-follow` while profiling.

## Target options and exit codes

Target selection is the same as `simulator-verify/scripts/rn-devtools.mjs`: `--port` (default `$METRO_PORT`, else 8081), `--device` (substring; an exact name wins), `--app <bundle id>`, `--page <n>`, `--timeout S` (default 10). Several devices or app runtimes: exit 2 with the list, never a guess.

| Exit | Meaning |
|---|---|
| 0 | done |
| 1 | nothing to talk to (Metro not on the port, no matching app), no React DevTools hook (release build), nothing recording, or another tool holds the profiler |
| 2 | ambiguous target |
| 3 | no answer within `--timeout` |
| 64 | usage |
