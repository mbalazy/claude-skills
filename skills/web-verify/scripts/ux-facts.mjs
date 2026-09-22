#!/usr/bin/env node
// ux-facts.mjs - the DETERMINISTIC layer of a UX audit: one browser session,
// one page state, a JSON file of measured facts. No judgment in here - the
// numbers are for the auditor (human or model) to read against a standard.
//
// Usage:
//   ux-facts.mjs <url|path> [options]
//
// State (how to reach what is measured):
//   --base URL          prefix for a path (default http://127.0.0.1:$WEB_PORT, 3000 if unset)
//   --steps STEP...     web-ui.mjs steps run after navigation (click=, fill=, press=, goto=, wait=, eval=)
//   --wait ms|SEL       after navigation and after the steps
//   --viewport WxH      default 1280x800
//   --mobile            iPhone 13 emulation (390x844, touch)
//   --dark              emulate prefers-color-scheme: dark
//   --reduced-motion    emulate prefers-reduced-motion: reduce
//   --locale TAG        browser locale + Accept-Language (e.g. ko-KR)
//   --timeout ms        per action (default 30000)
//
// Checks (all run unless disabled with --no-<check>):
//   axe          axe-core, tags wcag2a wcag2aa wcag21aa wcag22aa best-practice -> violations with selectors
//   keys         Tab walk (--tabs N, default 40): focus order, visible focus ring, in viewport, obscured,
//                traps/cycles, tabindex>0; then every key in --shortcuts pressed once, with what changed
//   targets      every visible interactive element's box; below --min-target (24) = fail, below
//                --warn-target (44 with --mobile, else 24) = warn (WCAG 2.2 2.5.8 floor / touch guidance)
//   overflow     horizontal page overflow, elements wider than the viewport, clipped text (scrollWidth >
//                clientWidth on text elements - the i18n / long-label check)
//   structure    headings outline (h1 count, level skips), landmarks, title, lang, viewport meta
//   motion       running animations after settle (with --reduced-motion: anything still running is a finding)
//   timing       navigation load / networkidle times; time from the last step to networkidle;
//                whether a busy indicator ([aria-busy], role=progressbar/status, "loading" text) was seen
//   console      errors, warnings, page errors, failed requests (same collectors as web-ui.mjs)
//
// Output:
//   --out PATH          JSON file (default .ux-audit/runs/<stamp>/facts-<slug>.json under cwd)
//   --screenshot PATH   also save a PNG of the final state (same session, no extra cost)
//   --quiet             no human summary on stderr
//
// Exit: 0 written, 1 navigation/step failure, 2 usage.

import { chromium, devices } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

const CHECKS = ["axe", "keys", "targets", "overflow", "structure", "motion", "timing", "console"];

function usage(msg) {
  if (msg) console.error(`ux-facts: ${msg}`);
  console.error("usage: ux-facts.mjs <url|path> [--steps S...] [--wait ms|SEL] [--viewport WxH] [--mobile] [--dark] [--reduced-motion] [--locale TAG] [--tabs N] [--shortcuts k1,k2] [--min-target N] [--warn-target N] [--no-<check>] [--out PATH] [--screenshot PATH] [--quiet]");
  process.exit(2);
}

function parseArgs(argv) {
  const o = { steps: [], viewport: { width: 1280, height: 800 }, timeout: 30000, tabs: 40, shortcuts: [], minTarget: 24, checks: new Set(CHECKS), base: `http://127.0.0.1:${process.env.WEB_PORT || "3000"}` };
  const [target, ...rest] = argv;
  if (!target || target.startsWith("--")) usage("missing url or path");
  o.target = target;
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    const next = () => { if (i + 1 >= rest.length) usage(`${a} needs a value`); return rest[++i]; };
    if (a.startsWith("--no-")) { const c = a.slice(5); if (!CHECKS.includes(c)) usage(`unknown check ${c}`); o.checks.delete(c); continue; }
    switch (a) {
      case "--base": o.base = next(); break;
      case "--steps": while (i + 1 < rest.length && !rest[i + 1].startsWith("--")) o.steps.push(rest[++i]); break;
      case "--wait": o.wait = next(); break;
      case "--viewport": { const m = /^(\d+)x(\d+)$/.exec(next()); if (!m) usage("--viewport WxH"); o.viewport = { width: +m[1], height: +m[2] }; break; }
      case "--mobile": o.mobile = true; break;
      case "--dark": o.dark = true; break;
      case "--reduced-motion": o.reducedMotion = true; break;
      case "--locale": o.locale = next(); break;
      case "--timeout": o.timeout = +next(); break;
      case "--tabs": o.tabs = +next(); break;
      case "--shortcuts": o.shortcuts = next().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--min-target": o.minTarget = +next(); break;
      case "--warn-target": o.warnTarget = +next(); break;
      case "--out": o.out = next(); break;
      case "--screenshot": o.screenshot = next(); break;
      case "--quiet": o.quiet = true; break;
      case "-h": case "--help": usage(); break;
      default: usage(`unknown option: ${a}`);
    }
  }
  if (o.warnTarget == null) o.warnTarget = o.mobile ? 44 : 24;
  o.url = /^https?:\/\//.test(o.target) ? o.target : o.base.replace(/\/$/, "") + (o.target.startsWith("/") ? o.target : "/" + o.target);
  return o;
}

async function launch() {
  const forced = process.env.WEB_VERIFY_BROWSER;
  const tryLaunch = (opts) => chromium.launch({ headless: true, ...opts });
  if (forced === "chrome") return tryLaunch({ channel: "chrome" });
  if (forced === "chromium") return tryLaunch({});
  try { return await tryLaunch({}); } catch (e) {
    if (!/Executable doesn't exist|install/.test(String(e.message))) throw e;
    console.error("ux-facts: Playwright Chromium not installed, using Google Chrome (channel chrome)");
    return tryLaunch({ channel: "chrome" });
  }
}

function attachCollectors(page, log) {
  page.on("console", (m) => { const t = m.type(); if (t === "error" || t === "warning") log.push({ kind: `console.${t}`, text: m.text(), at: m.location()?.url }); });
  page.on("pageerror", (e) => log.push({ kind: "pageerror", text: String(e.message || e) }));
  page.on("requestfailed", (r) => log.push({ kind: "requestfailed", text: `${r.method()} ${r.url()} - ${r.failure()?.errorText}` }));
  page.on("response", (r) => { if (r.status() >= 400) log.push({ kind: `http.${r.status()}`, text: `${r.request().method()} ${r.url()}` }); });
}

async function doWait(page, spec, timeout) {
  if (spec == null) return;
  if (/^\d+$/.test(spec)) { await page.waitForTimeout(+spec); return; }
  await page.locator(spec).first().waitFor({ state: "visible", timeout });
}

// same step grammar as web-ui.mjs (kept in step by hand - one file per skill)
async function runStep(page, step, o) {
  const eq = step.indexOf("=");
  if (eq < 0) throw new Error(`step without '=': ${step}`);
  const op = step.slice(0, eq), arg = step.slice(eq + 1);
  const split2 = () => {
    let depth = 0, inQ = null;
    for (let i = arg.length - 1; i >= 0; i--) {
      const c = arg[i];
      if (inQ) { if (c === inQ) inQ = null; continue; }
      if (c === '"' || c === "'") { inQ = c; continue; }
      if (c === "]" || c === ")") depth++; else if (c === "[" || c === "(") depth--;
      else if (c === "=" && depth === 0) return [arg.slice(0, i), arg.slice(i + 1)];
    }
    throw new Error(`step ${op} needs SEL=VALUE: ${step}`);
  };
  const loc = (sel) => page.locator(sel).first();
  switch (op) {
    case "click": await loc(arg).click({ timeout: o.timeout }); break;
    case "fill": { const [s, v] = split2(); await loc(s).fill(v, { timeout: o.timeout }); break; }
    case "select": { const [s, v] = split2(); await loc(s).selectOption(v, { timeout: o.timeout }); break; }
    case "check": await loc(arg).check({ timeout: o.timeout }); break;
    case "hover": await loc(arg).hover({ timeout: o.timeout }); break;
    case "scroll": await loc(arg).scrollIntoViewIfNeeded({ timeout: o.timeout }); break;
    case "press": await page.keyboard.press(arg); break;
    case "type": await page.keyboard.type(arg, { delay: 30 }); break;
    case "goto": await page.goto(/^https?:/.test(arg) ? arg : o.base.replace(/\/$/, "") + (arg.startsWith("/") ? arg : "/" + arg), { waitUntil: "load", timeout: o.timeout }); break;
    case "wait": await doWait(page, arg, o.timeout); break;
    case "eval": await page.evaluate(arg); break;
    default: throw new Error(`unknown step: ${op}`);
  }
}

// ---- in-page helpers (serialised into page.evaluate) ----------------------
const INTERACTIVE = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=switch], [role=option], [role=slider], [tabindex]:not([tabindex="-1"])';

const pageHelpers = `
  window.__ux = {
    describe(el) {
      if (!el || el === document.body || el === document.documentElement) return { tag: 'body' };
      const r = el.getBoundingClientRect();
      const name = (el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].innerText) || el.getAttribute('title') || el.getAttribute('placeholder') || el.innerText || el.value || '').replace(/\\s+/g, ' ').trim().slice(0, 60);
      return {
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') || null,
        name,
        selector: window.__ux.selectorOf(el),
        box: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
      };
    },
    selectorOf(el) {
      if (el.id) return '#' + el.id;
      const tid = el.getAttribute('data-testid'); if (tid) return '[data-testid="' + tid + '"]';
      const parts = [];
      let n = el;
      while (n && n.nodeType === 1 && parts.length < 4 && n !== document.body) {
        let s = n.tagName.toLowerCase();
        const p = n.parentElement;
        if (p) { const sib = Array.from(p.children).filter((c) => c.tagName === n.tagName); if (sib.length > 1) s += ':nth-of-type(' + (sib.indexOf(n) + 1) + ')'; }
        parts.unshift(s); n = p;
      }
      return parts.join(' > ');
    },
    visible(el) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return false;
      const cs = getComputedStyle(el);
      return cs.visibility !== 'hidden' && cs.display !== 'none' && cs.opacity !== '0';
    },
    inViewport(r) { return r.y + r.h > 0 && r.x + r.w > 0 && r.y < innerHeight && r.x < innerWidth; },
    obscured(el) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return null;
      const cx = Math.min(Math.max(r.x + r.width / 2, 0), innerWidth - 1), cy = Math.min(Math.max(r.y + r.height / 2, 0), innerHeight - 1);
      const top = document.elementFromPoint(cx, cy);
      if (!top) return null;
      if (top === el || el.contains(top) || top.contains(el)) return null;
      return window.__ux.selectorOf(top);
    },
    focusRing(el) {
      const cs = getComputedStyle(el);
      const outline = cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0;
      const shadow = cs.boxShadow && cs.boxShadow !== 'none';
      // compare with the unfocused look: a ring that is there whether focused or not is not a focus indicator
      return { outline, shadow, outlineWidth: cs.outlineWidth, outlineColor: cs.outlineColor, boxShadow: shadow ? cs.boxShadow.slice(0, 80) : null };
    },
  };
`;

async function tabWalk(page, o) {
  const stops = [];
  const seen = new Map();
  let trap = null, cycleAt = null;
  await page.evaluate(() => { document.activeElement && document.activeElement.blur && document.activeElement.blur(); });
  for (let i = 0; i < o.tabs; i++) {
    await page.keyboard.press("Tab");
    const d = await page.evaluate(() => {
      const el = document.activeElement;
      const desc = window.__ux.describe(el);
      if (desc.tag === "body") return desc;
      const r = desc.box;
      const focused = window.__ux.focusRing(el);
      const matchesFV = (() => { try { return el.matches(":focus-visible"); } catch { return null; } })();
      return { ...desc, inViewport: window.__ux.inViewport(r), obscuredBy: window.__ux.obscured(el), focusVisible: matchesFV, ring: focused, tabindex: el.getAttribute("tabindex") };
    });
    if (d.tag === "body") { stops.push({ i, tag: "body", note: "focus left the document (wrapped to the browser chrome)" }); if (i > 0) break; continue; }
    const key = d.selector;
    if (seen.has(key)) { cycleAt = { i, firstSeen: seen.get(key), selector: key }; break; }
    seen.set(key, i);
    stops.push({ i, ...d });
  }
  if (stops.length >= o.tabs && !cycleAt) trap = null; // just long
  // a trap = focus stuck on one element for consecutive Tabs (seen-map catches a 1-cycle at i+1)
  if (cycleAt && cycleAt.i - cycleAt.firstSeen === 1) trap = cycleAt;
  const positiveTabindex = await page.evaluate(() => Array.from(document.querySelectorAll('[tabindex]')).filter((e) => +e.getAttribute('tabindex') > 0).map((e) => window.__ux.describe(e)));
  const noRing = stops.filter((s) => s.tag !== "body" && s.focusVisible !== false && !s.ring.outline && !s.ring.shadow);
  const outOfView = stops.filter((s) => s.tag !== "body" && !s.inViewport);
  const obscured = stops.filter((s) => s.tag !== "body" && s.obscuredBy);
  const orderBreaks = [];
  for (let k = 1; k < stops.length; k++) {
    const a = stops[k - 1], b = stops[k];
    if (a.tag === "body" || b.tag === "body") continue;
    // reading order: a later stop should not be clearly ABOVE the previous one (same column) - a rough, honest heuristic
    if (b.box.y + b.box.h < a.box.y - 4 && Math.abs(b.box.x - a.box.x) < 40) orderBreaks.push({ from: a.selector, to: b.selector, fromY: a.box.y, toY: b.box.y });
  }
  return { tabsPressed: Math.min(stops.length + (cycleAt ? 1 : 0), o.tabs), stops, cycleAt, trap, positiveTabindex, summary: { stops: stops.filter((s) => s.tag !== "body").length, noVisibleRing: noRing.length, outOfViewport: outOfView.length, obscured: obscured.length, positiveTabindex: positiveTabindex.length, orderBreaks: orderBreaks.length }, noVisibleRing: noRing.map((s) => ({ selector: s.selector, name: s.name })), outOfViewport: outOfView.map((s) => ({ selector: s.selector, name: s.name, box: s.box })), obscured: obscured.map((s) => ({ selector: s.selector, name: s.name, by: s.obscuredBy })), orderBreaks };
}

async function shortcutProbe(page, o) {
  const results = [];
  for (const key of o.shortcuts) {
    const snap = () => page.evaluate(() => ({ url: location.href, active: window.__ux.describe(document.activeElement).selector || "body", dialogs: document.querySelectorAll("dialog[open], [role=dialog]").length, title: document.title, text: document.body.innerText.length, current: Array.from(document.querySelectorAll("[aria-current]:not([aria-current=false]), [aria-selected=true], [aria-expanded=true], [aria-pressed=true]")).map((e) => window.__ux.describe(e).selector).join("|") }));
    const before = await snap();
    await page.evaluate(() => { const a = document.activeElement; if (a && a !== document.body && /input|textarea|select/i.test(a.tagName)) a.blur(); });
    await page.keyboard.press(key);
    await page.waitForTimeout(250);
    const after = await snap();
    const changed = [];
    if (before.url !== after.url) changed.push(`url ${new URL(before.url).pathname}${new URL(before.url).search} -> ${new URL(after.url).pathname}${new URL(after.url).search}`);
    if (before.active !== after.active) changed.push(`focus ${before.active} -> ${after.active}`);
    if (before.dialogs !== after.dialogs) changed.push(`dialogs ${before.dialogs} -> ${after.dialogs}`);
    if (Math.abs(before.text - after.text) > 20) changed.push(`text length ${before.text} -> ${after.text}`);
    if (before.current !== after.current) {
      const b = new Set(before.current.split("|").filter(Boolean)), a = new Set(after.current.split("|").filter(Boolean));
      const gained = [...a].filter((x) => !b.has(x)), lost = [...b].filter((x) => !a.has(x));
      changed.push(`aria state: ${gained.length ? "now " + gained.join(", ") : ""}${gained.length && lost.length ? "; " : ""}${lost.length ? "no longer " + lost.join(", ") : ""}`);
    }
    results.push({ key, effect: changed.length ? changed : ["no observable change"] });
    if (after.dialogs > before.dialogs) { await page.keyboard.press("Escape"); await page.waitForTimeout(150); }
    if (before.url !== after.url) { await page.goBack({ waitUntil: "load" }).catch(() => {}); await page.waitForTimeout(200); }
  }
  return results;
}

async function targets(page, o) {
  const rows = await page.evaluate((sel) => Array.from(document.querySelectorAll(sel)).filter((e) => window.__ux.visible(e)).map((e) => window.__ux.describe(e)), INTERACTIVE);
  const fail = rows.filter((r) => r.box.w < o.minTarget || r.box.h < o.minTarget);
  const warn = rows.filter((r) => !fail.includes(r) && (r.box.w < o.warnTarget || r.box.h < o.warnTarget));
  return { thresholds: { fail: o.minTarget, warn: o.warnTarget }, total: rows.length, summary: { belowFail: fail.length, belowWarn: warn.length }, belowFail: fail.slice(0, 40), belowWarn: warn.slice(0, 40) };
}

async function overflow(page) {
  return page.evaluate(() => {
    const se = document.scrollingElement || document.documentElement;
    const pageOverflowX = se.scrollWidth - innerWidth;
    const wide = Array.from(document.body.querySelectorAll("*")).filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && (r.right > innerWidth + 1 || r.left < -1) && window.__ux.visible(e); }).slice(0, 20).map((e) => window.__ux.describe(e));
    const clipped = Array.from(document.body.querySelectorAll("*")).filter((e) => {
      if (!e.childNodes.length || !Array.from(e.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim())) return false;
      if (!window.__ux.visible(e)) return false;
      if (e.clientWidth <= 1 || e.clientHeight <= 1) return false; // sr-only pattern, not clipping
      const cs = getComputedStyle(e);
      if (cs.overflowX === "visible" && cs.overflow === "visible") return false;
      return e.scrollWidth > e.clientWidth + 1;
    }).slice(0, 30).map((e) => ({ ...window.__ux.describe(e), scrollWidth: e.scrollWidth, clientWidth: e.clientWidth, ellipsis: getComputedStyle(e).textOverflow === "ellipsis" }));
    return { pageOverflowX: Math.max(0, pageOverflowX), summary: { pageOverflowX: Math.max(0, pageOverflowX), elementsBeyondViewport: wide.length, clippedText: clipped.length }, elementsBeyondViewport: wide, clippedText: clipped };
  });
}

async function structure(page) {
  return page.evaluate(() => {
    const hs = Array.from(document.querySelectorAll("h1,h2,h3,h4,h5,h6")).filter((h) => window.__ux.visible(h)).map((h) => ({ level: +h.tagName[1], text: h.innerText.replace(/\s+/g, " ").trim().slice(0, 60) }));
    const skips = [];
    for (let i = 1; i < hs.length; i++) if (hs[i].level > hs[i - 1].level + 1) skips.push({ from: hs[i - 1], to: hs[i] });
    const landmarks = {};
    for (const [k, sel] of Object.entries({ main: "main,[role=main]", nav: "nav,[role=navigation]", header: "header,[role=banner]", footer: "footer,[role=contentinfo]", search: "[role=search]", dialogOpen: "dialog[open],[role=dialog]" })) landmarks[k] = document.querySelectorAll(sel).length;
    const viewportMeta = document.querySelector('meta[name=viewport]')?.getAttribute("content") || null;
    return { title: document.title, lang: document.documentElement.lang || null, viewportMeta, h1Count: hs.filter((h) => h.level === 1).length, headings: hs.slice(0, 40), levelSkips: skips, landmarks, summary: { h1: hs.filter((h) => h.level === 1).length, headings: hs.length, levelSkips: skips.length, hasMain: landmarks.main > 0, lang: document.documentElement.lang || null } };
  });
}

async function motion(page) {
  await page.waitForTimeout(1200);
  return page.evaluate(() => {
    const anims = document.getAnimations ? document.getAnimations() : [];
    const running = anims.filter((a) => a.playState === "running");
    const infinite = running.filter((a) => { const t = a.effect && a.effect.getTiming ? a.effect.getTiming() : {}; return t.iterations === Infinity; });
    return { summary: { running: running.length, infinite: infinite.length }, running: running.slice(0, 20).map((a) => ({ type: a.constructor.name, name: a.animationName || a.id || null, target: a.effect && a.effect.target ? window.__ux.describe(a.effect.target).selector : null, iterations: a.effect && a.effect.getTiming ? a.effect.getTiming().iterations : null })) };
  });
}

const o = parseArgs(process.argv.slice(2));
const log = [];
const browser = await launch();
let exit = 0;
const facts = { url: o.url, state: { viewport: o.mobile ? "iPhone 13 (390x844)" : `${o.viewport.width}x${o.viewport.height}`, mobile: !!o.mobile, dark: !!o.dark, reducedMotion: !!o.reducedMotion, locale: o.locale || null, steps: o.steps }, at: new Date().toISOString(), checks: {} };
try {
  const ctxOpts = o.mobile ? { ...devices["iPhone 13"] } : { viewport: o.viewport };
  if (o.locale) ctxOpts.locale = o.locale;
  if (o.dark) ctxOpts.colorScheme = "dark";
  if (o.reducedMotion) ctxOpts.reducedMotion = "reduce";
  const ctx = await browser.newContext(ctxOpts);
  ctx.setDefaultTimeout(o.timeout);
  const page = await ctx.newPage();
  attachCollectors(page, log);
  // busy-indicator witness: poll cheaply for aria-busy / progressbar / "loading" text while navigating and stepping
  let busySeen = false;
  const busyPoll = setInterval(() => { page.evaluate(() => !!document.querySelector('[aria-busy="true"],[role=progressbar],[role=status]:not(:empty)') || /\bloading\b|ładowanie/i.test(document.body?.innerText?.slice(0, 4000) || "")).then((b) => { if (b) busySeen = true; }).catch(() => {}); }, 100);
  const t0 = Date.now();
  const resp = await page.goto(o.url, { waitUntil: "load", timeout: Math.max(o.timeout, 60000) });
  const tLoad = Date.now() - t0;
  await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => {});
  const tIdle = Date.now() - t0;
  await doWait(page, o.wait, o.timeout);
  await page.addScriptTag({ content: pageHelpers });
  let tSteps = null;
  if (o.steps.length) {
    const s0 = Date.now();
    for (const step of o.steps) await runStep(page, step, o);
    await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => {});
    tSteps = Date.now() - s0;
    await doWait(page, o.wait, o.timeout);
    await page.evaluate(() => !!window.__ux).then(async (ok) => { if (!ok) await page.addScriptTag({ content: pageHelpers }); });
  }
  clearInterval(busyPoll);
  facts.http = resp ? resp.status() : null;
  facts.title = await page.title();
  if (o.screenshot) { mkdirSync(path.dirname(o.screenshot), { recursive: true }); await page.evaluate(() => window.scrollTo(0, 0)); await page.screenshot({ path: o.screenshot, fullPage: false }); facts.screenshot = o.screenshot; }
  if (o.checks.has("timing")) facts.checks.timing = { loadMs: tLoad, networkIdleMs: tIdle, stepsToIdleMs: tSteps, busyIndicatorSeen: busySeen, limits: { instant: 100, flow: 1000, attention: 10000 } };
  if (o.checks.has("structure")) facts.checks.structure = await structure(page);
  if (o.checks.has("overflow")) facts.checks.overflow = await overflow(page);
  if (o.checks.has("targets")) facts.checks.targets = await targets(page, o);
  if (o.checks.has("motion")) facts.checks.motion = await motion(page);
  if (o.checks.has("axe")) {
    const r = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa", "best-practice"]).analyze();
    const byImpact = {};
    for (const v of r.violations) byImpact[v.impact || "none"] = (byImpact[v.impact || "none"] || 0) + 1;
    facts.checks.axe = { engine: `axe-core ${r.testEngine?.version}`, summary: { violations: r.violations.length, nodes: r.violations.reduce((n, v) => n + v.nodes.length, 0), byImpact, incomplete: r.incomplete.length, passes: r.passes.length }, violations: r.violations.map((v) => ({ id: v.id, impact: v.impact, tags: v.tags.filter((t) => /wcag|best/.test(t)), help: v.help, helpUrl: v.helpUrl, nodes: v.nodes.slice(0, 10).map((n) => ({ target: n.target.join(" "), html: n.html.slice(0, 160), failure: (n.failureSummary || "").replace(/\s+/g, " ").slice(0, 240) })), nodeCount: v.nodes.length })), incomplete: r.incomplete.slice(0, 10).map((v) => ({ id: v.id, help: v.help, nodes: v.nodes.length })) };
  }
  if (o.checks.has("keys")) {
    facts.checks.keys = await tabWalk(page, o);
    if (o.shortcuts.length) facts.checks.keys.shortcuts = await shortcutProbe(page, o);
  }
  if (o.checks.has("console")) {
    const errors = log.filter((e) => e.kind !== "console.warning");
    facts.checks.console = { summary: { errors: errors.length, warnings: log.length - errors.length }, entries: log.slice(0, 60) };
  }
} catch (e) {
  facts.error = e.message.split("\n")[0];
  exit = 1;
} finally {
  await browser.close();
}
const slug = (o.target.replace(/^https?:\/\/[^/]+/, "") || "/").replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "") || "root";
const out = o.out || path.join(process.cwd(), ".ux-audit", "runs", new Date().toISOString().slice(0, 10), `facts-${slug}${o.mobile ? "-mobile" : ""}${o.dark ? "-dark" : ""}${o.locale ? "-" + o.locale : ""}.json`);
mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(facts, null, 2));
if (!o.quiet) {
  const c = facts.checks;
  const line = [];
  if (facts.error) line.push(`ERROR ${facts.error}`);
  if (c.axe) line.push(`axe ${c.axe.summary.violations} violations (${Object.entries(c.axe.summary.byImpact).map(([k, v]) => `${v} ${k}`).join(", ") || "none"})`);
  if (c.keys) line.push(`keys ${c.keys.summary.stops} stops, ${c.keys.summary.noVisibleRing} no ring, ${c.keys.summary.obscured} obscured, ${c.keys.summary.outOfViewport} off-screen${c.keys.trap ? ", TRAP" : ""}${c.keys.summary.positiveTabindex ? `, ${c.keys.summary.positiveTabindex} tabindex>0` : ""}`);
  if (c.targets) line.push(`targets ${c.targets.total}, ${c.targets.summary.belowFail} < ${o.minTarget}px${o.warnTarget > o.minTarget ? `, ${c.targets.summary.belowWarn} < ${o.warnTarget}px` : ""}`);
  if (c.overflow) line.push(`overflow x=${c.overflow.summary.pageOverflowX}px, ${c.overflow.summary.elementsBeyondViewport} beyond viewport, ${c.overflow.summary.clippedText} clipped text`);
  if (c.structure) line.push(`structure h1=${c.structure.summary.h1}, ${c.structure.summary.levelSkips} level skips, main=${c.structure.summary.hasMain}, lang=${c.structure.summary.lang}`);
  if (c.motion) line.push(`motion ${c.motion.summary.running} running (${c.motion.summary.infinite} infinite)`);
  if (c.timing) line.push(`timing load ${c.timing.loadMs}ms, idle ${c.timing.networkIdleMs}ms${c.timing.stepsToIdleMs != null ? `, steps ${c.timing.stepsToIdleMs}ms` : ""}, busy indicator ${c.timing.busyIndicatorSeen ? "seen" : "not seen"}`);
  if (c.console) line.push(`console ${c.console.summary.errors} errors, ${c.console.summary.warnings} warnings`);
  console.error(`ux-facts: ${facts.url} [${facts.state.viewport}${o.dark ? ", dark" : ""}${o.reducedMotion ? ", reduced-motion" : ""}${o.locale ? ", " + o.locale : ""}] -> ${facts.http}\n  ` + line.join("\n  ") + `\n  written ${out}`);
}
process.exit(exit);
