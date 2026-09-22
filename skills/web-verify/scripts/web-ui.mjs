#!/usr/bin/env node
// web-ui.mjs - observe and drive a web page with headless Chromium (Playwright).
// The web counterpart of simulator-verify's sim-ui.sh: one command = one
// browser session that navigates, runs the optional steps, and prints what it
// saw. No MCP server, no schemas in the model's context.
//
// Usage:
//   web-ui.mjs <command> <url|path> [options]
//
// Commands (what is printed at the end of the session):
//   snapshot     accessibility tree (aria snapshot, YAML) of --selector or the page
//   text         innerText of --selector or the page
//   html         outerHTML of --selector (or the whole document)
//   screenshot   PNG to --out (default .web-verify/evidence/<stamp>.png under cwd)
//   measure      bounding box of every element matching --selector (CSS px)
//   console      console messages, page errors and failed requests, in full
//   flow         run --steps only, then print the aria snapshot (alias of snapshot)
//
// Options:
//   --base URL         prefix for a path argument (default http://127.0.0.1:$WEB_PORT, port 3000 if unset)
//   --steps STEP...    actions run after navigation, in order (repeatable, see below)
//   --selector SEL     Playwright selector scoping snapshot/text/html/screenshot/measure
//   --out PATH         screenshot file
//   --full             full-page screenshot
//   --viewport WxH     default 1280x800
//   --mobile           iPhone 13 emulation (390x844, dpr 3, touch, mobile UA)
//   --wait ms|SEL      after navigation and after the steps: sleep ms, or wait for SEL to be visible
//   --settle           take the reading twice 2 s apart and exit 3 with the diff when they differ
//   --timeout ms       per-action timeout (default 30000)
//   --headed           show the browser window (debugging by a human)
//   --json             machine-readable output for measure/console
//
// Steps (`--steps 'click=text=Continue' 'fill=#email=a@b.c'`):
//   click=SEL        fill=SEL=TEXT     press=KEY (Enter, Tab, ...)    type=TEXT
//   check=SEL        select=SEL=VALUE  hover=SEL    scroll=SEL         goto=PATH
//   wait=ms|SEL      eval=JS (page.evaluate, result printed)
//
// Selectors are Playwright's: CSS, `text=Sign in`, `role=button[name="Save"]`,
// `#id`, `[data-testid=x]`. A selector matching several elements acts on the
// first (Playwright's strict mode is OFF here on purpose - narrow it yourself).
//
// Every session also collects console errors/warnings, uncaught page errors and
// failed requests (network failure or HTTP >= 400) and prints a one-line
// `console:` summary at the end - read it; a silent page with a red console is
// not a passing page.
//
// Browser: Playwright's own Chromium (`npx playwright install chromium` once, in
// the skill dir); when it is missing, the installed Google Chrome is used
// (channel "chrome"). WEB_VERIFY_BROWSER=chrome|chromium forces one.
//
// Exit: 0 ok, 1 navigation/step/selector failure, 2 usage, 3 settle mismatch.

import { chromium, devices } from "playwright";
import { mkdirSync } from "node:fs";
import path from "node:path";

const COMMANDS = ["snapshot", "text", "html", "screenshot", "measure", "console", "flow"];

function usage(msg) {
  if (msg) console.error(`web-ui: ${msg}`);
  console.error(`usage: web-ui.mjs <${COMMANDS.join("|")}> <url|path> [--steps S...] [--selector SEL] [--out PATH] [--full] [--viewport WxH] [--mobile] [--wait ms|SEL] [--settle] [--timeout ms] [--headed] [--json]`);
  process.exit(2);
}

function parseArgs(argv) {
  const o = { steps: [], viewport: { width: 1280, height: 800 }, timeout: 30000, base: `http://127.0.0.1:${process.env.WEB_PORT || "3000"}` };
  const [command, target, ...rest] = argv;
  if (!command || !COMMANDS.includes(command)) usage(command ? `unknown command: ${command}` : "missing command");
  if (!target) usage("missing url or path");
  o.command = command === "flow" ? "snapshot" : command;
  o.target = target;
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    const next = () => { if (i + 1 >= rest.length) usage(`${a} needs a value`); return rest[++i]; };
    switch (a) {
      case "--base": o.base = next(); break;
      case "--steps":
        while (i + 1 < rest.length && !rest[i + 1].startsWith("--")) o.steps.push(rest[++i]);
        break;
      case "--selector": o.selector = next(); break;
      case "--out": o.out = next(); break;
      case "--full": o.full = true; break;
      case "--viewport": {
        const m = /^(\d+)x(\d+)$/.exec(next());
        if (!m) usage("--viewport WxH");
        o.viewport = { width: Number(m[1]), height: Number(m[2]) };
        break;
      }
      case "--mobile": o.mobile = true; break;
      case "--wait": o.wait = next(); break;
      case "--settle": o.settle = true; break;
      case "--timeout": o.timeout = Number(next()); break;
      case "--headed": o.headed = true; break;
      case "--json": o.json = true; break;
      case "-h": case "--help": usage(); break;
      default: usage(`unknown option: ${a}`);
    }
  }
  o.url = /^https?:\/\//.test(o.target) ? o.target : o.base.replace(/\/$/, "") + (o.target.startsWith("/") ? o.target : "/" + o.target);
  return o;
}

async function launch(headed) {
  const forced = process.env.WEB_VERIFY_BROWSER;
  const tryLaunch = (opts) => chromium.launch({ headless: !headed, ...opts });
  if (forced === "chrome") return tryLaunch({ channel: "chrome" });
  if (forced === "chromium") return tryLaunch({});
  try {
    return await tryLaunch({});
  } catch (e) {
    if (!/Executable doesn't exist|install/.test(String(e.message))) throw e;
    console.error("web-ui: Playwright Chromium not installed, using Google Chrome (channel chrome)");
    return tryLaunch({ channel: "chrome" });
  }
}

function attachCollectors(page, log) {
  page.on("console", (m) => {
    const t = m.type();
    if (t === "error" || t === "warning") log.push({ kind: `console.${t}`, text: m.text(), at: m.location()?.url });
  });
  page.on("pageerror", (e) => log.push({ kind: "pageerror", text: String(e.message || e) }));
  page.on("requestfailed", (r) => log.push({ kind: "requestfailed", text: `${r.method()} ${r.url()} - ${r.failure()?.errorText}` }));
  page.on("response", (r) => { if (r.status() >= 400) log.push({ kind: `http.${r.status()}`, text: `${r.request().method()} ${r.url()}` }); });
}

async function doWait(page, spec, timeout) {
  if (spec == null) return;
  if (/^\d+$/.test(spec)) { await page.waitForTimeout(Number(spec)); return; }
  await page.locator(spec).first().waitFor({ state: "visible", timeout });
}

async function runStep(page, step, o) {
  const eq = step.indexOf("=");
  if (eq < 0) throw new Error(`step without '=': ${step}`);
  const op = step.slice(0, eq);
  const arg = step.slice(eq + 1);
  const split2 = () => {
    // SEL=VALUE where SEL may itself contain '=' (text=..., role=...[name="x"]):
    // the LAST '=' that is not inside quotes/brackets splits it.
    let depth = 0, inQ = null;
    for (let i = arg.length - 1; i >= 0; i--) {
      const c = arg[i];
      if (inQ) { if (c === inQ) inQ = null; continue; }
      if (c === '"' || c === "'") { inQ = c; continue; }
      if (c === "]" || c === ")") depth++;
      else if (c === "[" || c === "(") depth--;
      else if (c === "=" && depth === 0) return [arg.slice(0, i), arg.slice(i + 1)];
    }
    throw new Error(`step ${op} needs SEL=VALUE: ${step}`);
  };
  const loc = (sel) => page.locator(sel).first();
  switch (op) {
    case "click": await loc(arg).click({ timeout: o.timeout }); break;
    case "fill": { const [sel, v] = split2(); await loc(sel).fill(v, { timeout: o.timeout }); break; }
    case "select": { const [sel, v] = split2(); await loc(sel).selectOption(v, { timeout: o.timeout }); break; }
    case "check": await loc(arg).check({ timeout: o.timeout }); break;
    case "hover": await loc(arg).hover({ timeout: o.timeout }); break;
    case "scroll": await loc(arg).scrollIntoViewIfNeeded({ timeout: o.timeout }); break;
    case "press": await page.keyboard.press(arg); break;
    case "type": await page.keyboard.type(arg, { delay: 30 }); break;
    case "goto": await page.goto(/^https?:/.test(arg) ? arg : o.base.replace(/\/$/, "") + (arg.startsWith("/") ? arg : "/" + arg), { waitUntil: "load", timeout: o.timeout }); break;
    case "wait": await doWait(page, arg, o.timeout); break;
    case "eval": { const r = await page.evaluate(arg); console.log(`eval: ${JSON.stringify(r)}`); break; }
    default: throw new Error(`unknown step: ${op}`);
  }
}

async function reading(page, o) {
  const scope = o.selector ? page.locator(o.selector).first() : page.locator("body");
  switch (o.command) {
    case "snapshot": return await scope.ariaSnapshot();
    case "text": return (await scope.innerText()).trim();
    case "html": return o.selector ? await scope.evaluate((el) => el.outerHTML) : await page.content();
    case "measure": {
      const els = o.selector ? page.locator(o.selector) : usage("measure needs --selector");
      const n = await els.count();
      const rows = [];
      for (let i = 0; i < n; i++) {
        const box = await els.nth(i).boundingBox();
        const text = (await els.nth(i).innerText().catch(() => "")).replace(/\s+/g, " ").trim().slice(0, 60);
        rows.push({ i, box: box ? { x: Math.round(box.x * 10) / 10, y: Math.round(box.y * 10) / 10, w: Math.round(box.width * 10) / 10, h: Math.round(box.height * 10) / 10 } : null, text });
      }
      return o.json ? JSON.stringify(rows, null, 2) : (n ? rows.map((r) => `${r.i}: ${r.box ? `x=${r.box.x} y=${r.box.y} w=${r.box.w} h=${r.box.h}` : "not rendered (no box)"}${r.text ? `  "${r.text}"` : ""}`).join("\n") : `0 elements match ${o.selector}`);
    }
    case "screenshot": {
      const out = o.out || path.join(process.cwd(), ".web-verify", "evidence", `${new Date().toISOString().replace(/[:.]/g, "-")}.png`);
      mkdirSync(path.dirname(out), { recursive: true });
      if (o.selector) await scope.screenshot({ path: out });
      else await page.screenshot({ path: out, fullPage: !!o.full });
      return `screenshot: ${out} (${o.mobile ? "mobile" : `${o.viewport.width}x${o.viewport.height}`}${o.full ? ", full page" : ""})`;
    }
    case "console": return null; // printed from the log below
    default: usage(`unknown command ${o.command}`);
  }
}

const o = parseArgs(process.argv.slice(2));
const log = [];
const browser = await launch(o.headed);
let exit = 0;
try {
  const ctx = await browser.newContext(o.mobile ? { ...devices["iPhone 13"] } : { viewport: o.viewport });
  ctx.setDefaultTimeout(o.timeout);
  const page = await ctx.newPage();
  attachCollectors(page, log);
  const t0 = Date.now();
  const resp = await page.goto(o.url, { waitUntil: "load", timeout: Math.max(o.timeout, 60000) });
  console.error(`web-ui: GET ${o.url} -> ${resp ? resp.status() : "no response"} in ${Date.now() - t0}ms, title "${await page.title()}"`);
  await doWait(page, o.wait, o.timeout);
  for (const step of o.steps) {
    await runStep(page, step, o);
  }
  if (o.steps.length) await doWait(page, o.wait, o.timeout);
  // let a Next/React page finish its first client render + any pending fetches
  await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => {});

  const first = await reading(page, o);
  if (o.settle && o.command !== "screenshot") {
    await page.waitForTimeout(2000);
    const second = await reading(page, o);
    if (first !== second) {
      console.log(first);
      console.log("\n--- 2 s later (settle mismatch) ---\n");
      console.log(second);
      exit = 3;
    } else {
      console.log(first);
      console.error("web-ui: settled (two readings 2 s apart agree)");
    }
  } else if (first != null) {
    console.log(first);
  }

  if (o.command === "console") {
    if (o.json) console.log(JSON.stringify(log, null, 2));
    else console.log(log.length ? log.map((e) => `${e.kind}: ${e.text}${e.at ? `  (${e.at})` : ""}`).join("\n") : "console: clean (no errors, warnings, page errors or failed requests)");
  } else {
    const errors = log.filter((e) => e.kind !== "console.warning");
    const warns = log.length - errors.length;
    console.error(`console: ${errors.length} error${errors.length === 1 ? "" : "s"}, ${warns} warning${warns === 1 ? "" : "s"}${errors.length ? " - first: " + errors[0].kind + ": " + errors[0].text.slice(0, 160) : ""}${log.length ? " (run the console command for the full list)" : ""}`);
  }
} catch (e) {
  console.error(`web-ui: ${e.message.split("\n")[0]}`);
  exit = exit || 1;
} finally {
  await browser.close();
}
process.exit(exit);
