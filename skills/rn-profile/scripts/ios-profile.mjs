// ios-profile.mjs - records an app running on an iOS simulator with
// `xcrun xctrace` for a fixed time, exports the trace and summarises where
// the app spent native CPU time, the UI hangs and (with the leaks template)
// leaked memory.
//
// Export and analysis are Software Mansion's Argent (Apache 2.0), vendored
// unmodified under skills/simulator-verify/scripts/devtools/vendor/argent/:
// exportIosTraceData (ios-profiler/export.ts) and runIosProfilerPipeline
// (ios-profiler/pipeline/). Finding the app and the record / stop sequence
// follow Argent's tools/profiler/native-profiler/platforms/ios.ts, ported:
//   - the simulator is always named by udid (never "booted");
//   - xctrace attaches by the app's display name: on Xcode 27.2 attaching by
//     pid fails ("Cannot find process for provided pid") and by
//     CFBundleExecutable too ("Cannot find process matching name");
//   - the default template is Time Profiler. Argent's own template adds
//     Allocations + Leaks, which turn malloc stack logging on in the app
//     process and leave it on until the app is relaunched, so every later
//     CPU or hang reading of that process is skewed; it is used only with
//     `leaks: true`.

import { execFile, spawn } from 'node:child_process';
import { existsSync, readdirSync, rmSync, statSync, writeFileSync, readFileSync } from 'node:fs';
import { join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { vendorPath } from '../../simulator-verify/scripts/devtools/vendor-loader.mjs';

const BASE = 'packages/tool-server/src/utils/';
export const TIME_PROFILER = 'Time Profiler';
export const LEAKS_TEMPLATE = fileURLToPath(vendorPath(`${BASE}ios-profiler/Argent.tracetemplate`));
export const DEFAULT_SECONDS = 15;
export const MAX_SECONDS = 600;
const SIMCTL_TIMEOUT_MS = 20_000;
/** After SIGINT xctrace still has to package the trace; then SIGTERM, then SIGKILL. */
const SAVE_GRACE_MS = 60_000;
const TERM_GRACE_MS = 10_000;
const EXPORT_SUFFIXES = { cpu: '_raw_cpu.xml', hangs: '_raw_hangs.xml', leaks: '_raw_leaks.xml' };
export const SUMMARY_FILE = 'summary.json';

export class IosProfileError extends Error {
  constructor(message, exitCode = 1) { super(message); this.exitCode = exitCode; }
}

function run(cmd, args, timeoutMs = SIMCTL_TIMEOUT_MS) {
  return new Promise((resolve) => {
    execFile(cmd, args, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout: stdout ?? '', stderr: stderr ?? '', error: err });
    });
  });
}

const lastLines = (text, n = 4) => text.trim().split('\n').filter(Boolean).slice(-n).join(' | ');

/** The simulator with this udid; exit 1 when it does not exist or is not booted. */
export async function checkDevice(udid) {
  const r = await run('xcrun', ['simctl', 'list', 'devices', '-j']);
  if (r.code !== 0) throw new IosProfileError(`xcrun simctl list failed: ${lastLines(r.stderr || r.stdout) || r.error?.message}`);
  let devices;
  try { devices = JSON.parse(r.stdout).devices; } catch { throw new IosProfileError('xcrun simctl list printed no JSON'); }
  for (const [runtime, list] of Object.entries(devices ?? {})) {
    const d = list.find((x) => x.udid === udid);
    if (!d) continue;
    if (d.state !== 'Booted') throw new IosProfileError(`simulator ${udid} (${d.name}) is ${d.state}, not booted`);
    return { udid, name: d.name, runtime: runtime.replace(/^.*SimRuntime\./, '') };
  }
  throw new IosProfileError(`no simulator with udid ${udid} (\`xcrun simctl list devices\` lists them)`);
}

/** bundle id -> pid of the apps `launchctl list` shows running ("-" = registered, not running). */
export function parseLaunchctl(text) {
  const running = new Map();
  for (const line of text.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+\S+\s+UIKitApplication:([^[\s]+)/);
    if (m) running.set(m[2], Number(m[1]));
  }
  return running;
}

/**
 * The user apps running on the simulator: installed under the device's own
 * data directory (system apps live in the runtime), UI test runners
 * (`*.xctrunner`, e.g. WebDriverAgent) left out.
 */
export async function runningUserApps(udid) {
  const r = await run('xcrun', ['simctl', 'spawn', udid, 'launchctl', 'list']);
  if (r.code !== 0) throw new IosProfileError(`cannot list the simulator's processes: ${lastLines(r.stderr || r.stdout) || r.error?.message}`);
  const apps = [];
  for (const [bundleId, pid] of parseLaunchctl(r.stdout)) {
    if (bundleId.startsWith('com.apple.') || bundleId.endsWith('.xctrunner')) continue;
    const c = await run('xcrun', ['simctl', 'get_app_container', udid, bundleId, 'app']);
    const path = c.stdout.trim();
    if (c.code !== 0 || !path.includes('/data/Containers/Bundle/Application/')) continue;
    const p = await run('plutil', ['-convert', 'json', '-o', '-', join(path, 'Info.plist')]);
    let info = {};
    try { info = JSON.parse(p.stdout); } catch { /* no readable Info.plist: names fall back to the bundle id */ }
    apps.push({
      bundleId, pid, path,
      executable: info.CFBundleExecutable ?? basename(path, '.app'),
      displayName: info.CFBundleDisplayName ?? info.CFBundleName ?? null,
    });
  }
  return apps;
}

/** The app to record: --app matches bundle id, executable or display name; one running app needs none. */
export function pickApp(apps, want) {
  const describe = (a) => `${a.bundleId} (${a.displayName ?? a.executable}, pid ${a.pid})`;
  if (want) {
    const hit = apps.filter((a) => a.bundleId === want || a.executable === want || a.displayName === want);
    if (hit.length === 1) return hit[0];
    if (hit.length > 1) throw new IosProfileError(`several running apps match ${want}:\n${hit.map((a) => `  ${describe(a)}`).join('\n')}\npass the bundle id`, 2);
    throw new IosProfileError(`${want} is not running on the simulator${apps.length ? `; running: ${apps.map(describe).join(', ')}` : ' (no user app is running)'}`);
  }
  if (apps.length === 1) return apps[0];
  if (!apps.length) throw new IosProfileError('no user app is running on the simulator; launch it first');
  throw new IosProfileError(`several user apps are running; pick one with --app:\n${apps.map((a) => `  ${describe(a)}`).join('\n')}`, 2);
}

/** The name xctrace --attach matches on a simulator (see the header). */
export const attachName = (app) => app.displayName ?? app.executable;

/**
 * Runs `xctrace record` for `seconds` and waits for it to save. Ends it
 * (SIGINT, then SIGTERM, then SIGKILL) when `timeoutMs` passes or this process
 * gets SIGINT / SIGTERM, and returns only once xctrace has exited.
 */
export function recordTrace({ udid, name, seconds, template, tracePath, timeoutMs, saveGraceMs = SAVE_GRACE_MS }) {
  const args = ['xctrace', 'record', '--template', template, '--device', udid, '--attach', name,
    '--time-limit', `${seconds}s`, '--output', tracePath, '--no-prompt'];
  return new Promise((resolve, reject) => {
    const child = spawn('xcrun', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    const keep = (b) => { output = (output + b).slice(-20_000); };
    child.stdout.on('data', keep);
    child.stderr.on('data', keep);
    let ended = null;
    const timers = [];
    const stopChild = (why) => {
      if (ended) return;
      ended = why;
      const kill = (sig) => { try { child.kill(sig); } catch { /* gone */ } };
      kill('SIGINT');
      timers.push(setTimeout(() => kill('SIGTERM'), saveGraceMs));
      timers.push(setTimeout(() => kill('SIGKILL'), saveGraceMs + TERM_GRACE_MS));
    };
    const onSignal = () => stopChild('interrupted');
    process.on('SIGINT', onSignal);
    process.on('SIGTERM', onSignal);
    timers.push(setTimeout(() => stopChild('timeout'), timeoutMs));
    const done = () => {
      timers.forEach(clearTimeout);
      process.off('SIGINT', onSignal);
      process.off('SIGTERM', onSignal);
    };
    child.on('error', (err) => { done(); reject(new IosProfileError(`cannot run xcrun xctrace: ${err.message}`)); });
    child.on('close', (code, signal) => { done(); resolve({ code, signal, ended, output, args }); });
  });
}

/** The export files (Argent's names) in a directory, null for the ones that are not there. */
export function exportFiles(dir) {
  const names = existsSync(dir) ? readdirSync(dir) : [];
  const out = {};
  for (const [key, suffix] of Object.entries(EXPORT_SUFFIXES)) {
    const f = names.find((n) => n.endsWith(suffix));
    out[key] = f ? join(dir, f) : null;
  }
  return out;
}

export async function exportTrace(tracePath) {
  const { exportIosTraceData } = await import(vendorPath(`${BASE}ios-profiler/export.ts`));
  return exportIosTraceData(tracePath);
}

export async function analyze(files) {
  const { runIosProfilerPipeline } = await import(vendorPath(`${BASE}ios-profiler/pipeline/index.ts`));
  const { normalizeThreadName } = await import(vendorPath(`${BASE}profiler-shared/thread.ts`));
  const result = await runIosProfilerPipeline(files);
  const threads = new Map();
  for (const s of result.cpuSamples) {
    const t = normalizeThreadName(s.threadFmt);
    const e = threads.get(t) ?? { thread: t, samples: 0, ms: 0 };
    e.samples++;
    e.ms += s.weightNs / 1e6;
    threads.set(t, e);
  }
  return { ...result, threads: [...threads.values()].sort((a, b) => b.ms - a.ms) };
}

const round = (n) => Math.round(n * 100) / 100;

/**
 * What the recording showed. `leaksRecorded` false = the template has no Leaks
 * instrument, said as such rather than as "0 leaks".
 */
export function summarize(result, { meta = {}, leaksRecorded, exportErrors = {}, top = 10 }) {
  const totalMs = result.cpuSamples.reduce((a, s) => a + s.weightNs / 1e6, 0);
  return {
    ...meta,
    cpu: {
      samples: result.cpuSamples.length,
      sampledMs: round(totalMs),
      threads: result.threads.slice(0, 5).map((t) => ({ ...t, ms: round(t.ms) })),
      hotspots: result.cpuHotspots.slice(0, top).map((h) => ({
        function: h.dominantFunction, ms: round(h.totalWeightMs), percent: h.weightPercentage, samples: h.sampleCount,
        thread: h.thread, duringHang: h.duringHang, callChain: h.topCallChain.slice(0, 4),
      })),
      hotspotsTotal: result.cpuHotspots.length,
    },
    hangs: result.uiHangs.map((h) => ({
      type: h.hangType, ms: round(h.durationMs), at: h.startTimeFormatted, suspected: h.suspectedFunctions.slice(0, 3),
    })),
    leaks: leaksRecorded
      ? {
          recorded: true,
          count: result.memoryLeaks.reduce((a, l) => a + l.count, 0),
          bytes: result.memoryLeaks.reduce((a, l) => a + l.totalSizeBytes, 0),
          top: [...result.memoryLeaks].sort((a, b) => b.totalSizeBytes - a.totalSizeBytes).slice(0, top).map((l) => ({
            object: l.objectType, count: l.count, bytes: l.totalSizeBytes, frame: l.responsibleFrame, library: l.responsibleLibrary, attributed: l.attributed,
          })),
        }
      : { recorded: false },
    exportErrors,
  };
}

export function formatSummary(sum) {
  const lines = [];
  if (sum.app) lines.push(`${sum.app.displayName ?? sum.app.executable} (${sum.app.bundleId}, pid ${sum.app.pid}) on ${sum.device?.name ?? sum.device?.udid}, ${sum.seconds} s with ${sum.template === TIME_PROFILER ? 'Time Profiler' : 'the leaks template'}`);
  const c = sum.cpu;
  lines.push(`CPU: ${c.samples} samples, ${c.sampledMs} ms sampled${c.threads.length ? ` (${c.threads.map((t) => `${t.thread} ${t.ms} ms`).join(', ')})` : ''}`);
  if (c.hotspots.length) {
    lines.push(`hotspots (functions with >= 3% of the samples, ${c.hotspots.length} of ${c.hotspotsTotal}):`);
    for (const h of c.hotspots) {
      lines.push(`  ${h.ms.toFixed(1).padStart(8)} ms ${`${h.percent.toFixed(1)}%`.padStart(6)}  ${h.thread}${h.duringHang ? ' [during a hang]' : ''}  ${h.function}`);
    }
  } else if (c.samples) {
    lines.push('hotspots: no function reached 3% of the samples');
  }
  if (sum.hangs.length) {
    lines.push(`UI hangs: ${sum.hangs.length}`);
    for (const h of sum.hangs) lines.push(`  ${h.type} ${h.ms} ms at ${h.at}${h.suspected.length ? `  suspected: ${h.suspected.join(', ')}` : ''}`);
  } else {
    lines.push('UI hangs: none');
  }
  if (!sum.leaks.recorded) {
    lines.push('leaks: not recorded (the Time Profiler template has no Leaks instrument; --leaks records them)');
  } else {
    lines.push(`leaks: ${sum.leaks.count} (${sum.leaks.bytes} bytes)`);
    for (const l of sum.leaks.top) lines.push(`  ${l.count} x ${l.object} ${l.bytes} bytes  ${l.frame}${l.library ? ` (${l.library})` : ''}${l.attributed ? '' : ' [no call stack: likely system noise]'}`);
  }
  for (const [k, msg] of Object.entries(sum.exportErrors ?? {})) {
    if (k === 'leaks' && !sum.leaks.recorded) continue;
    lines.push(`export of ${k} failed: ${msg.split('\n')[0]}`);
  }
  return lines.join('\n');
}

/** Re-reads the exports `record` left in a directory. */
export async function reportDir(dir, { top } = {}) {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) throw new IosProfileError(`${dir} is not a directory`);
  const files = exportFiles(dir);
  if (!files.cpu && !files.hangs) throw new IosProfileError(`${dir} holds no xctrace exports (*${EXPORT_SUFFIXES.cpu}, *${EXPORT_SUFFIXES.hangs})`);
  let saved = {};
  try { saved = JSON.parse(readFileSync(join(dir, SUMMARY_FILE), 'utf8')); } catch { /* exports without a summary: no header */ }
  const meta = { app: saved.app, device: saved.device, seconds: saved.seconds, template: saved.template, dir };
  const leaksRecorded = saved.leaks ? saved.leaks.recorded === true : Boolean(files.leaks);
  return summarize(await analyze(files), { meta, leaksRecorded, exportErrors: saved.exportErrors ?? {}, top });
}

/**
 * The whole recording: device and app checks, xctrace, export, analysis.
 * The .trace bundle is deleted unless keepTrace; the exports and summary.json stay in outDir.
 */
export async function record({ udid, app: want, seconds = DEFAULT_SECONDS, leaks = false, outDir, keepTrace = false, timeoutMs, top = 10 }) {
  const device = await checkDevice(udid);
  const app = pickApp(await runningUserApps(udid), want);
  const template = leaks ? LEAKS_TEMPLATE : TIME_PROFILER;
  const tracePath = join(outDir, 'native.trace');
  if (existsSync(tracePath)) throw new IosProfileError(`${tracePath} already exists; pick another --out`, 64);
  const limitMs = timeoutMs ?? seconds * 1000 + 90_000;
  const rec = await recordTrace({ udid, name: attachName(app), seconds, template, tracePath, timeoutMs: limitMs });
  const dropTrace = () => { if (!keepTrace) rmSync(tracePath, { recursive: true, force: true }); };
  if (rec.ended === 'timeout') {
    dropTrace();
    throw new IosProfileError(`xctrace did not finish within ${Math.round(limitMs / 1000)} s; it was stopped and nothing was exported`, 3);
  }
  if (rec.ended === 'interrupted') {
    dropTrace();
    throw new IosProfileError('interrupted: xctrace was stopped and nothing was exported', 130);
  }
  if (rec.code !== 0 || !existsSync(tracePath)) {
    dropTrace();
    throw new IosProfileError(`xctrace record failed (exit ${rec.code ?? rec.signal}): ${lastLines(rec.output) || 'no output'}`);
  }
  const exported = await exportTrace(tracePath);
  dropTrace();
  const files = exported.files;
  if (!files.cpu && !files.hangs) {
    throw new IosProfileError(`xctrace export produced neither CPU samples nor hangs: ${Object.entries(exported.diagnostics.errors).map(([k, v]) => `${k}: ${v.split('\n')[0]}`).join('; ')}`);
  }
  const meta = { app, device, seconds, template: leaks ? 'leaks' : TIME_PROFILER, dir: outDir, trace: keepTrace ? tracePath : null };
  const sum = summarize(await analyze(files), { meta, leaksRecorded: leaks, exportErrors: exported.diagnostics.errors, top });
  writeFileSync(join(outDir, SUMMARY_FILE), JSON.stringify(sum, null, 1));
  return sum;
}
