#!/usr/bin/env node
// dev-server.mjs - the dev server of ONE tree on ONE port: start it detached,
// say who owns the port, stop only what this tree started, and (check) prove
// the port serves the tree under test - the web rig check.
//
// The failure it exists for: a browser will happily read a page served by a
// DIFFERENT tree (the main checkout's server on the port you assumed, another
// session's worktree, a stale build) and every reading is then confident and
// false. So the check does not trust the port number: it resolves the LISTENING
// pid's working directory and requires it to be the tree under test.
//
// Usage:
//   dev-server.mjs check  --repo DIR --port N [--start] [--cmd 'CMD'] [--path /] [--api-path /api/x]... [--timeout S]
//   dev-server.mjs start  --repo DIR --port N [--cmd 'CMD'] [--timeout S]
//   dev-server.mjs status --port N [--repo DIR] [--json]
//   dev-server.mjs stop   --repo DIR --port N
//
//   --repo DIR     the tree that must be served (default: git root of cwd)
//   --port N       the port the server must listen on (default: $WEB_PORT)
//   --cmd CMD      how to start the server, run by `sh -c` in DIR with PORT in
//                  the environment (default: `npm run dev -- -p "$PORT"`, the
//                  Next.js shape; Vite wants `npm run dev -- --port "$PORT" --strictPort`)
//   --path P       the route the check GETs (default: /)
//   --api-path R   check only, repeatable: after the page probe, GET this route
//                  too. ECONNREFUSED, a timeout or a 5xx is RIG DEAD naming the
//                  route; 4xx is fine - the server is alive and answering. A
//                  page renders happily from cache while the API proxy behind it
//                  is dead, and every reading taken then is confident and false
//                  (vega-247, 2026-09-21: RIG OK while every API read was
//                  ECONNREFUSED). With no --api-path nothing changes.
//   --mount SEL    check only: after the HTTP probe, open --path in the skill's
//                  headless Chromium and require SEL (default: h1) to render
//                  NON-EMPTY text - proves the app MOUNTED, not just that the
//                  server answered. `--mount ''` turns the probe off.
//   --timeout S    seconds to wait for the port after a start (default 120)
//   --start        check only: start the server when nothing listens on the port
//                  (never when the port is held by something else - see below)
//
// Ownership rule: a port held by a process whose cwd is NOT the tree is never
// touched - it is another session's server, and killing it is the most
// destructive mistake available here. `stop` refuses it, `check` reports it as
// RIG DEAD with the owner named, `--start` does not start a second server.
//
// Runtime files live under <repo>/.web-verify/run/ (dev-<port>.pid, dev-<port>.log);
// keep `.web-verify/` out of git (see SKILL.md).
//
// Why --api-path (vega-247, 2026-09-21): after a series of hot reloads the dev
// server kept serving the page while every API read answered ECONNREFUSED.
// rig-check still printed RIG OK, because GET / reads no API - and one reading
// was recorded as CHANGED off a page that had no data behind it.
//
// Why the mount probe (pm-cli-130, 2026-09-06): a Vite kept running across
// an `npm ci` answered 200 on `/` and on the API proxy while every
// `/node_modules/.vite/deps/*.js` was a 504 "Outdated Optimize Dep" - a blank
// page behind two green HTTP probes, reported as RIG OK. A server answering is
// not an app mounted; only a browser can tell the two apart.
//
// Exit: 0 = ok / RIG OK, 1 = failed / RIG DEAD, 2 = bad usage.

import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { realpathSync } from "node:fs";

const DEFAULT_CMD = 'npm run dev -- -p "$PORT"';

function usage(msg) {
  if (msg) console.error(`dev-server: ${msg}`);
  console.error("usage: dev-server.mjs check|start|status|stop --repo DIR --port N [--cmd CMD] [--path P] [--api-path R]... [--mount SEL] [--timeout S] [--start] [--json]");
  process.exit(2);
}

function parseArgs(argv) {
  const opts = { cmd: DEFAULT_CMD, path: "/", apiPaths: [], mount: "h1", timeout: 120, start: false, json: false };
  const [command, ...rest] = argv;
  if (!command || !["check", "start", "status", "stop"].includes(command)) usage(command ? `unknown command: ${command}` : "missing command");
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    const next = () => {
      if (i + 1 >= rest.length) usage(`${a} needs a value`);
      return rest[++i];
    };
    switch (a) {
      case "--repo": opts.repo = next(); break;
      case "--port": opts.port = Number(next()); break;
      case "--cmd": opts.cmd = next(); break;
      case "--path": opts.path = next(); break;
      case "--api-path": opts.apiPaths.push(next()); break;
      case "--mount": opts.mount = next(); break;
      case "--timeout": opts.timeout = Number(next()); break;
      case "--start": opts.start = true; break;
      case "--json": opts.json = true; break;
      case "-h": case "--help": usage(); break;
      default: usage(`unknown option: ${a}`);
    }
  }
  if (!opts.port) opts.port = Number(process.env.WEB_PORT || "");
  if (!Number.isInteger(opts.port) || opts.port <= 0) usage("--port N (or $WEB_PORT) is required");
  if (!opts.repo && command !== "status") {
    try {
      opts.repo = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
    } catch {
      usage("--repo DIR is required outside a git tree");
    }
  }
  if (opts.repo) {
    if (!existsSync(opts.repo)) usage(`--repo ${opts.repo} does not exist`);
    opts.repo = realpathSync(opts.repo);
  }
  return { command, opts };
}

// --- who holds the port ------------------------------------------------------

function listeningPids(port) {
  try {
    const out = execFileSync("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    return [...new Set(out.split("\n").map((s) => s.trim()).filter(Boolean).map(Number))];
  } catch {
    return []; // lsof exits 1 when nothing matches
  }
}

function pidCwd(pid) {
  try {
    const out = execFileSync("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    const line = out.split("\n").find((l) => l.startsWith("n"));
    return line ? line.slice(1) : "";
  } catch {
    return "";
  }
}

function pidComm(pid) {
  try {
    return execFileSync("ps", ["-o", "comm=", "-p", String(pid)], { encoding: "utf8" }).trim();
  } catch {
    return "?";
  }
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

// owners: every listening pid with its cwd, and whether that cwd is the tree
// (equal to it, or inside it - a monorepo app started from a package dir).
function portOwners(port, repo) {
  return listeningPids(port).map((pid) => {
    const cwd = pidCwd(pid);
    let real = cwd;
    try { real = cwd ? realpathSync(cwd) : cwd; } catch { /* keep the raw path */ }
    const ours = !!repo && !!real && (real === repo || real.startsWith(repo + path.sep));
    return { pid, comm: pidComm(pid), cwd: real, ours };
  });
}

// --- runtime files --------------------------------------------------------------

function runDir(repo) {
  const dir = path.join(repo, ".web-verify", "run");
  mkdirSync(dir, { recursive: true });
  return dir;
}
const pidFile = (repo, port) => path.join(runDir(repo), `dev-${port}.pid`);
const logFile = (repo, port) => path.join(runDir(repo), `dev-${port}.log`);

function tail(file, lines = 15) {
  try {
    const all = readFileSync(file, "utf8").split("\n");
    return all.slice(Math.max(0, all.length - lines)).join("\n").trim();
  } catch {
    return "";
  }
}

// --- waiting on the port -------------------------------------------------------

function portOpen(port) {
  return new Promise((resolve) => {
    const s = net.connect({ port, host: "127.0.0.1" });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("error", () => resolve(false));
    s.setTimeout(1000, () => { s.destroy(); resolve(false); });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForPort(port, seconds, aliveCheck) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    if (await portOpen(port)) return true;
    if (aliveCheck && !aliveCheck()) return false;
    await sleep(500);
  }
  return false;
}

// --- commands -------------------------------------------------------------------

async function start(opts) {
  const owners = portOwners(opts.port, opts.repo);
  if (owners.length) {
    const o = owners[0];
    if (o.ours) {
      console.log(`dev-server: already up - pid ${o.pid} (${o.comm}) serves ${o.cwd} on :${opts.port}`);
      return 0;
    }
    console.error(`dev-server: port ${opts.port} is held by pid ${o.pid} (${o.comm}) with cwd ${o.cwd || "?"} - not this tree; not touched`);
    return 1;
  }
  const log = logFile(opts.repo, opts.port);
  const fd = openSync(log, "a");
  writeFileSync(fd, `\n=== dev-server start ${new Date().toISOString()} :${opts.port} in ${opts.repo}\n=== ${opts.cmd}\n`);
  // detached = its own session and process group, so the caller's group (pm's
  // rig hook kills its group at the cap; a shell's Ctrl-C signals its group)
  // never takes the server down with it.
  const child = spawn("sh", ["-c", opts.cmd], {
    cwd: opts.repo,
    env: { ...process.env, PORT: String(opts.port), WEB_PORT: String(opts.port), BROWSER: "none" },
    detached: true,
    stdio: ["ignore", fd, fd],
  });
  child.unref();
  writeFileSync(pidFile(opts.repo, opts.port), String(child.pid));
  console.log(`dev-server: started pid ${child.pid} (${opts.cmd}) in ${opts.repo}, log ${log}`);
  const up = await waitForPort(opts.port, opts.timeout, () => pidAlive(child.pid));
  if (!up) {
    // The one silent way this fails: the server came up on `localhost`, which
    // Node resolves to ::1 first, so 127.0.0.1 never answers (Vite's default).
    const v6 = listeningPids(opts.port);
    const hint = v6.length ? ` - BUT pid ${v6[0]} (${pidComm(v6[0])}) does listen on :${opts.port}: it is bound to ::1/localhost only; start it with --host 127.0.0.1` : "";
    console.error(`dev-server: 127.0.0.1:${opts.port} did not open within ${opts.timeout}s (pid ${child.pid} ${pidAlive(child.pid) ? "still running" : "exited"})${hint} - log tail:\n${tail(log)}`);
    return 1;
  }
  const owners2 = portOwners(opts.port, opts.repo);
  const mine = owners2.find((o) => o.ours);
  if (!mine) {
    console.error(`dev-server: :${opts.port} opened but its owner is not this tree: ${JSON.stringify(owners2)}`);
    return 1;
  }
  console.log(`dev-server: up - pid ${mine.pid} (${mine.comm}) serves ${mine.cwd} on :${opts.port}`);
  return 0;
}

function status(opts) {
  const owners = portOwners(opts.port, opts.repo);
  if (opts.json) {
    console.log(JSON.stringify({ port: opts.port, repo: opts.repo || null, owners }, null, 2));
    return owners.length ? 0 : 1;
  }
  if (!owners.length) {
    console.log(`:${opts.port} - nothing listens`);
    return 1;
  }
  for (const o of owners) {
    const tag = opts.repo ? (o.ours ? "THIS TREE" : "OTHER TREE") : "";
    console.log(`:${opts.port} - pid ${o.pid} (${o.comm}) cwd ${o.cwd || "?"} ${tag}`.trim());
  }
  return 0;
}

async function stop(opts) {
  const owners = portOwners(opts.port, opts.repo);
  if (!owners.length) {
    console.log(`dev-server: nothing listens on :${opts.port}`);
    try { unlinkSync(pidFile(opts.repo, opts.port)); } catch { /* none */ }
    return 0;
  }
  const foreign = owners.filter((o) => !o.ours);
  if (foreign.length) {
    console.error(`dev-server: refusing to stop :${opts.port} - held by ${foreign.map((o) => `pid ${o.pid} (${o.comm}) cwd ${o.cwd || "?"}`).join(", ")}, not this tree`);
    return 1;
  }
  // The recorded pid is the `sh -c` leader of a detached session; killing its
  // group takes the npm/next children with it. Fall back to the listener's pid.
  let leader = 0;
  try { leader = Number(readFileSync(pidFile(opts.repo, opts.port), "utf8").trim()); } catch { /* none */ }
  const targets = new Set(owners.map((o) => o.pid));
  if (leader && pidAlive(leader)) targets.add(leader);
  for (const pid of targets) {
    try { process.kill(-pid, "SIGTERM"); } catch { try { process.kill(pid, "SIGTERM"); } catch { /* gone */ } }
  }
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && (await portOpen(opts.port))) await sleep(200);
  if (await portOpen(opts.port)) {
    for (const pid of targets) {
      try { process.kill(-pid, "SIGKILL"); } catch { try { process.kill(pid, "SIGKILL"); } catch { /* gone */ } }
    }
  }
  try { unlinkSync(pidFile(opts.repo, opts.port)); } catch { /* none */ }
  console.log(`dev-server: stopped :${opts.port} (${[...targets].join(", ")})`);
  return 0;
}

function treeLine(repo) {
  try {
    const sha = execFileSync("git", ["-C", repo, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
    let branch = execFileSync("git", ["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8" }).trim();
    if (branch === "HEAD") branch = "detached";
    const dirty = execFileSync("git", ["-C", repo, "status", "--porcelain"], { encoding: "utf8" }).trim() ? " dirty" : "";
    return `${branch}@${sha}${dirty}`;
  } catch {
    return "not a git tree";
  }
}

async function probe(port, route, seconds) {
  const url = `http://127.0.0.1:${port}${route.startsWith("/") ? route : "/" + route}`;
  const t0 = Date.now();
  try {
    const res = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(seconds * 1000) });
    return { url, status: res.status, ms: Date.now() - t0 };
  } catch (e) {
    return { url, status: 0, ms: Date.now() - t0, error: e?.cause?.message || e.message };
  }
}

// mountProbe opens the route in the skill's Chromium and reads the text of
// the selector. Returns { ok, text, why }: ok = rendered non-empty text; why
// names what went wrong (no browser, timeout, empty) in one line. The browser
// is the same one web-ui.mjs uses (Playwright's Chromium, Google Chrome as the
// fallback), so a rig this passes is the rig the readings will be taken on.
async function mountProbe(port, route, selector, seconds) {
  const url = `http://127.0.0.1:${port}${route.startsWith("/") ? route : "/" + route}`;
  let playwright;
  try {
    playwright = await import("playwright");
  } catch (e) {
    return { ok: false, why: `playwright is not installed in the skill dir (${e.message}) - run npm install && npx playwright install chromium in ${path.dirname(new URL(import.meta.url).pathname)}/..` };
  }
  const { chromium } = playwright;
  const forced = process.env.WEB_VERIFY_BROWSER;
  const tryLaunch = (o) => chromium.launch({ headless: true, ...o });
  let browser;
  try {
    if (forced === "chrome") browser = await tryLaunch({ channel: "chrome" });
    else if (forced === "chromium") browser = await tryLaunch({});
    else {
      try { browser = await tryLaunch({}); } catch (e) {
        if (!/Executable doesn't exist|install/.test(String(e.message))) throw e;
        browser = await tryLaunch({ channel: "chrome" });
      }
    }
  } catch (e) {
    return { ok: false, why: `could not launch a browser for the mount probe: ${e.message}` };
  }
  const errors = [];
  try {
    const page = await browser.newPage();
    page.on("pageerror", (e) => errors.push(String(e.message || e)));
    page.on("response", (r) => { if (r.status() >= 400) errors.push(`${r.status()} ${r.url()}`); });
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: seconds * 1000 });
    const loc = page.locator(selector).first();
    try {
      await loc.waitFor({ state: "attached", timeout: seconds * 1000 });
    } catch {
      return { ok: false, why: `served but the app did not mount (${selector} never appeared within ${seconds}s)${errors.length ? ` - page errors: ${errors.slice(0, 3).join("; ")}` : ""}` };
    }
    const deadline = Date.now() + seconds * 1000;
    let text = "";
    while (Date.now() < deadline) {
      text = ((await loc.textContent()) || "").trim();
      if (text) break;
      await sleep(250);
    }
    if (!text) return { ok: false, why: `served but the app did not mount (${selector} empty after ${seconds}s)${errors.length ? ` - page errors: ${errors.slice(0, 3).join("; ")}` : ""}` };
    return { ok: true, text: text.slice(0, 60), why: "" };
  } catch (e) {
    return { ok: false, why: `mount probe of ${url} failed: ${e.message}` };
  } finally {
    await browser.close().catch(() => {});
  }
}

// check = the rig check. RIG OK only when the port's owner IS the tree, a
// GET answers with something below 500 - a dev server that compiles the route
// on first hit needs the long probe timeout, that is normal - AND (unless
// --mount '') the app renders the mount selector with non-empty text in a
// real browser.
async function check(opts) {
  const dead = (why) => { console.log(`RIG DEAD: ${why}`); return 1; };
  let owners = portOwners(opts.port, opts.repo);
  if (!owners.length) {
    if (!opts.start) return dead(`nothing listens on :${opts.port} and --start not given (tree ${opts.repo})`);
    const rc = await start(opts);
    if (rc !== 0) return dead(`dev server did not come up on :${opts.port} (see above; log ${logFile(opts.repo, opts.port)})`);
    owners = portOwners(opts.port, opts.repo);
  }
  const foreign = owners.filter((o) => !o.ours);
  const mine = owners.find((o) => o.ours);
  if (!mine) {
    const f = foreign[0];
    return dead(`:${opts.port} is served by pid ${f.pid} (${f.comm}) with cwd ${f.cwd || "?"} - not ${opts.repo}; not touched (another session's server?)`);
  }
  const p = await probe(opts.port, opts.path, Math.max(60, opts.timeout));
  if (p.status === 0) return dead(`pid ${mine.pid} owns :${opts.port} but GET ${p.url} failed after ${p.ms}ms: ${p.error} - log tail:\n${tail(logFile(opts.repo, opts.port))}`);
  if (p.status >= 500) return dead(`GET ${p.url} -> ${p.status} in ${p.ms}ms (server of ${mine.cwd}) - log tail:\n${tail(logFile(opts.repo, opts.port))}`);
  // The API probes: a page can render from cache while the proxy behind it is
  // gone, so a route the app actually READS is the only thing that proves the
  // API side of the rig. 4xx answers (401, 404) are the server talking - alive.
  const apiSeen = [];
  for (const route of opts.apiPaths) {
    const a = await probe(opts.port, route, Math.max(30, Math.min(opts.timeout, 60)));
    if (a.status === 0) return dead(`api ${route} is not answering on :${opts.port}: ${a.error} after ${a.ms}ms (the page itself served ${p.status} - a live page over a dead API) - log tail:\n${tail(logFile(opts.repo, opts.port))}`);
    if (a.status >= 500) return dead(`api ${route} -> ${a.status} in ${a.ms}ms (server of ${mine.cwd}) - log tail:\n${tail(logFile(opts.repo, opts.port))}`);
    apiSeen.push(`api ${route} -> ${a.status}`);
  }

  let mounted = "";
  if (opts.mount) {
    const t0 = Date.now();
    const m = await mountProbe(opts.port, opts.path, opts.mount, Math.max(30, Math.min(opts.timeout, 60)));
    if (!m.ok) return dead(`${m.why} (server of ${mine.cwd}, GET ${opts.path} -> ${p.status}) - log tail:\n${tail(logFile(opts.repo, opts.port))}`);
    mounted = `, ${opts.mount} mounted ("${m.text}") in ${Date.now() - t0}ms`;
  }
  const api = apiSeen.length ? `, ${apiSeen.join(", ")}` : "";
  console.log(`RIG OK: http://127.0.0.1:${opts.port} serves ${mine.cwd} (${treeLine(opts.repo)}) - pid ${mine.pid} (${mine.comm}), GET ${opts.path} -> ${p.status} in ${p.ms}ms${api}${mounted}`);
  return 0;
}

const { command, opts } = parseArgs(process.argv.slice(2));
const handlers = { check, start, status, stop };
process.exit(await handlers[command](opts));
