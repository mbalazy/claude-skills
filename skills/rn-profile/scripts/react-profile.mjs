// react-profile.mjs - record React commits in the running app over Metro's
// CDP inspector, with Argent's profiler scripts (vendored unmodified under
// skills/simulator-verify/scripts/devtools/vendor/argent/) and the shared CDP
// client of simulator-verify.
//
// Every command is one-shot. A recording lives in the app between commands:
// the React DevTools backend keeps the commits, Hermes's sampler keeps the
// CPU profile, and globalThis.__rn_profile_session (ours) keeps the session:
// id, start, time limit and how it ended. The time limit is a timer in the
// app that stops the React side; stop then still returns what was recorded,
// with the CPU profile cut at the limit. A JS reload loses the recording.
//
// Sequence (Argent's start/stop tools and session blueprint, as the spike
// probed it): setup -> read state -> bootstrap the DevTools backend when no
// renderer interface exists -> root tracker -> Profiler.stop (Hermes's
// sampler is process-wide and survives a reload) -> Profiler.enable (this
// Hermes answers "Unsupported method"; ignored) -> Profiler.start ->
// startProfiling on every renderer. stop = Profiler.stop (CPU profile) ->
// stop and read the React data -> fiber metadata.

import { randomUUID } from 'node:crypto';
import { vendorPath } from '../../simulator-verify/scripts/devtools/vendor-loader.mjs';

const SCRIPTS = 'packages/tool-server/src/utils/react-profiler/scripts.ts';
const BOOTSTRAP = 'packages/tool-server/src/utils/react-profiler/devtools-bootstrap.ts';
const scripts = () => import(vendorPath(SCRIPTS));

export const FORMAT = 'rn-profile-react/1';
export const DEFAULT_MAX_SECONDS = 60;
export const MAX_SECONDS_CAP = 600;
export const DEFAULT_INTERVAL_US = 1000;
// Reading a long recording's data can outlast the usual 10 s.
const COLLECT_TIMEOUT_MS = 60_000;

export class ProfileError extends Error {
  constructor(message, exitCode = 1) { super(message); this.exitCode = exitCode; }
}

const ev = async (client, expr, timeoutMs) => client.evaluate(expr, { awaitPromise: false, timeoutMs });
const evJson = async (client, expr, timeoutMs) => {
  const raw = await ev(client, expr, timeoutMs);
  return typeof raw === 'string' ? JSON.parse(raw) : raw;
};

const READ_SESSION = `JSON.stringify(globalThis.__rn_profile_session || null)`;

/**
 * Runs after React's profiler started (buildStartScript installed the owner):
 * installs our session record and the time-limit timer. When the timer fires
 * for this session and it is still running, it stops every renderer (the
 * React data stays readable until the next start) and records why.
 */
export function sessionScript(session) {
  return `(function() {
  var s = ${JSON.stringify(session)};
  var o = globalThis.__ARGENT_PROFILER_OWNER__;
  s.startedAtEpochMs = o && typeof o.startedAtEpochMs === 'number' ? o.startedAtEpochMs : Date.now();
  s.endedBy = null;
  s.endedAtEpochMs = null;
  // Each renderer's start, as READ_STATE_SCRIPT lists them: a later start by another tool changes them.
  s.rendererStarts = [];
  var hk = globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__;
  if (hk && hk.rendererInterfaces) hk.rendererInterfaces.forEach(function(ri) {
    if (ri && typeof ri.__argent_startedAtEpochMs__ === 'number') s.rendererStarts.push(ri.__argent_startedAtEpochMs__);
  });
  globalThis.__rn_profile_session = s;
  setTimeout(function() {
    var cur = globalThis.__rn_profile_session;
    if (!cur || cur.sessionId !== s.sessionId || cur.endedBy) return;
    // Another tool stopped or took over the profiler since: its recording is not ours to end.
    var owner = globalThis.__ARGENT_PROFILER_OWNER__;
    if (!owner || owner.sessionId !== s.sessionId) { cur.endedBy = 'stopped-elsewhere'; return; }
    var h = globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (h && h.rendererInterfaces) h.rendererInterfaces.forEach(function(ri) { try { ri.stopProfiling(); } catch (e) {} });
    cur.endedBy = 'time-limit';
    cur.endedAtEpochMs = Date.now();
  }, s.maxMs);
  return JSON.stringify(s);
})()`;
}

/**
 * Starts a recording. Resolves with { started, session, discarded } or { already, session }.
 * discarded: an earlier recording that was never stopped (e.g. ended by its time limit) is dropped.
 */
export async function startRecording(client, { maxSeconds = DEFAULT_MAX_SECONDS, intervalUs = DEFAULT_INTERVAL_US, takeover = false, timeoutMs } = {}) {
  const S = await scripts();
  await ev(client, S.REACT_NATIVE_PROFILER_SETUP_SCRIPT, timeoutMs);
  let state = await evJson(client, S.READ_STATE_SCRIPT, timeoutMs);
  if (!state.hookExists) {
    throw new ProfileError('The app has no React DevTools hook: it is not a development build, or React has not started yet.');
  }
  if (!state.rendererInterfaceFound) {
    const boot = await evJson(client, S.BOOTSTRAP_DEVTOOLS_BACKEND_SCRIPT, timeoutMs);
    if (!boot.ok) {
      const { bootstrapFailureMessage } = await import(vendorPath(BOOTSTRAP));
      throw new ProfileError(`Cannot reach React's renderer (${boot.reason}): ${bootstrapFailureMessage(boot)}`);
    }
    await ev(client, S.REACT_NATIVE_PROFILER_SETUP_SCRIPT, timeoutMs);
    state = await evJson(client, S.READ_STATE_SCRIPT, timeoutMs);
  }
  if (state.isRunning) {
    const mine = await evJson(client, READ_SESSION, timeoutMs);
    if (mine && !mine.endedBy && state.owner?.sessionId === mine.sessionId) return { already: true, session: mine, nowEpochMs: state.nowEpochMs };
    if (!takeover) {
      const who = state.owner?.tool ? `${state.owner.tool}` : 'another tool (React DevTools or another profiler)';
      throw new ProfileError(`React is already being profiled by ${who}. Stop it there, or pass --takeover to end that recording and start this one.`);
    }
    await ev(client, S.STOP_FOR_TAKEOVER_SCRIPT, timeoutMs);
  }
  const previous = await evJson(client, READ_SESSION, timeoutMs);
  await ev(client, S.FIBER_ROOT_TRACKER_SCRIPT, timeoutMs);
  // A sampler left running (an earlier session, a reload) would carry its samples into this one.
  await client.send('Profiler.stop', {}, { timeoutMs }).catch(() => {});
  await client.send('Profiler.enable', {}, { timeoutMs }).catch(() => {});
  await client.send('Profiler.start', { interval: intervalUs }, { timeoutMs });
  const sessionId = randomUUID();
  // React's start, our session record and its timer in ONE evaluate: a recording never runs without its limit.
  const startAndSession = `(function() {
    var r = JSON.parse(${S.buildStartScript(JSON.stringify({ tool: 'rn-profile', sessionId }))});
    if (r.ok) r.session = JSON.parse(${sessionScript({ sessionId, tool: 'rn-profile', maxMs: Math.round(maxSeconds * 1000), intervalUs })});
    return JSON.stringify(r);
  })()`;
  let started;
  try {
    started = await evJson(client, startAndSession, timeoutMs);
  } catch (err) {
    await rollBack(client, S, sessionId, timeoutMs);
    throw err;
  }
  if (!started.ok) {
    await client.send('Profiler.stop', {}, { timeoutMs }).catch(() => {});
    throw new ProfileError(`React's profiler did not start (${started.reason}${started.message ? `: ${started.message}` : ''}).`);
  }
  const session = started.session;
  // A previous session still "running" here was stopped by another tool (ours running returned `already`).
  return { started: true, session, discarded: previous ? previous.endedBy ?? 'stopped-elsewhere' : null };
}

/** After a start that failed midway: stop what may have started, best effort. */
async function rollBack(client, S, sessionId, timeoutMs) {
  await ev(client, `(function() {
    var o = globalThis.__ARGENT_PROFILER_OWNER__;
    if (o && o.sessionId === ${JSON.stringify(sessionId)}) (${S.STOP_FOR_TAKEOVER_SCRIPT});
    var s = globalThis.__rn_profile_session;
    if (s && s.sessionId === ${JSON.stringify(sessionId)}) delete globalThis.__rn_profile_session;
  })()`, timeoutMs).catch(() => {});
  await client.send('Profiler.stop', {}, { timeoutMs }).catch(() => {});
}

/** { recording, session, nowEpochMs, otherOwner }. */
export async function recordingStatus(client, { timeoutMs } = {}) {
  const S = await scripts();
  const state = await evJson(client, S.READ_STATE_SCRIPT, timeoutMs);
  const session = await evJson(client, READ_SESSION, timeoutMs);
  const ours = session && state.owner?.sessionId === session.sessionId;
  return {
    recording: Boolean(state.isRunning && ours),
    session,
    nowEpochMs: state.nowEpochMs ?? null,
    otherOwner: state.isRunning && !ours ? (state.owner?.tool ?? 'unknown') : null,
  };
}

/** Marks how our session ended, in the app, before anything is consumed: a retried stop reads the same. */
const MARK_ENDED = `(function() {
  var s = globalThis.__rn_profile_session;
  if (s && !s.endedBy) {
    var o = globalThis.__ARGENT_PROFILER_OWNER__;
    var running = false, h = globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (h && h.rendererInterfaces) h.rendererInterfaces.forEach(function(ri) { if (ri && ri.__argent_isProfiling__ === true) running = true; });
    if (running && o && o.sessionId === s.sessionId) { s.endedBy = 'stop'; s.endedAtEpochMs = Date.now(); }
    else s.endedBy = 'stopped-elsewhere';
  }
  return JSON.stringify(s || null);
})()`;

/**
 * Ends the recording and returns the profile (the object written to --out).
 * Hermes's sampler is stopped when the recording is ours or there is none;
 * a recording another tool took over is left to it.
 */
export async function stopRecording(client, { timeoutMs } = {}) {
  const S = await scripts();
  const collectMs = Math.max(COLLECT_TIMEOUT_MS, timeoutMs ?? 0);
  const found = await evJson(client, READ_SESSION, timeoutMs);
  if (!found) {
    await client.send('Profiler.stop', {}, { timeoutMs: collectMs }).catch(() => {});
    throw new ProfileError('No recording in the app: never started, or the JS reloaded since (a reload loses it). Run `react start` again.');
  }
  const state = await evJson(client, S.READ_STATE_SCRIPT, timeoutMs);
  const sameStarts = JSON.stringify(state.rendererStartedAtEpochMs ?? []) === JSON.stringify(found.rendererStarts ?? []);
  const otherRunning = state.isRunning && state.owner?.sessionId !== found.sessionId;
  if (!sameStarts || otherRunning) {
    await ev(client, 'delete globalThis.__rn_profile_session', timeoutMs);
    throw new ProfileError('Another tool took over React\'s profiler during this recording, so what React holds now is not this recording. Nothing was read; run `react start` again.');
  }
  const session = await evJson(client, MARK_ENDED, timeoutMs);
  let cpuProfile = null;
  try {
    cpuProfile = (await client.send('Profiler.stop', {}, { timeoutMs: collectMs }))?.profile ?? null;
  } catch { /* the sampler was already stopped (an earlier stop that failed later) */ }
  const read = await evJson(client, S.STOP_AND_READ_SCRIPT, collectMs);
  const commits = (read.live?.dataForRoots ?? []).reduce((n, r) => n + (r.commitData?.length ?? 0), 0);
  let fiberMeta = {};
  if (commits > 0) {
    try { fiberMeta = await evJson(client, S.RESOLVE_FIBER_META_SCRIPT, 15_000); } catch { /* names stay, metadata is optional */ }
  }
  await ev(client, 'delete globalThis.__rn_profile_session', timeoutMs);
  // Another tool stopped it at a moment nobody recorded: the length is unknown.
  const durationMs = session.endedAtEpochMs ? Math.max(0, session.endedAtEpochMs - session.startedAtEpochMs) : null;
  if (cpuProfile) cpuProfile = dropStaleLeadingGap(cpuProfile);
  if (cpuProfile && session.endedBy === 'time-limit') cpuProfile = trimCpuProfile(cpuProfile, durationMs);
  return {
    format: FORMAT,
    startedAt: new Date(session.startedAtEpochMs).toISOString(),
    durationMs,
    endedBy: session.endedBy,
    maxMs: session.maxMs,
    intervalUs: session.intervalUs,
    react: { dataForRoots: read.live?.dataForRoots ?? [], displayNameById: read.displayNameById ?? {} },
    fiberMeta,
    cpuProfile,
  };
}

/**
 * Ported from Argent's dropStaleLeadingGap (utils/react-profiler/pipeline/00-cpu-correlate.ts),
 * returning a copy: Hermes stamps samples taken while the VM was already suspended at start
 * with a stale time, so the first positive delta can be a jump (seen: 27,954 s for an 11 s
 * recording). Such a delta (>= 1 s and longer than everything after it) becomes 0 and moves
 * startTime; a normal profile comes back as it is.
 */
export function dropStaleLeadingGap(profile) {
  const deltas = profile?.timeDeltas;
  if (!Array.isArray(deltas)) return profile;
  const first = deltas.findIndex((d, i) => i > 0 && d > 0);
  if (first < 0) return profile;
  const gap = deltas[first];
  if (gap < 1_000_000 || gap <= profile.endTime - profile.startTime - gap) return profile;
  const timeDeltas = deltas.slice();
  timeDeltas[first] = 0;
  return { ...profile, timeDeltas, startTime: profile.startTime + gap };
}

/** A Hermes CPU profile cut to its first keepMs (the samples after the time limit dropped). */
export function trimCpuProfile(profile, keepMs) {
  if (!Array.isArray(profile?.samples) || !Array.isArray(profile.timeDeltas)) return profile;
  const limitUs = keepMs * 1000;
  let t = 0;
  let n = 0;
  while (n < profile.timeDeltas.length && t + profile.timeDeltas[n] <= limitUs) {
    t += profile.timeDeltas[n];
    n++;
  }
  return { ...profile, samples: profile.samples.slice(0, n), timeDeltas: profile.timeDeltas.slice(0, n), endTime: profile.startTime + t };
}

// ---- summary --------------------------------------------------------------

/**
 * One row per (commit, named fiber), as Argent's flattenProfilingData builds
 * them, plus the per-commit timings and the fibers no name was found for.
 */
export function flattenCommits(react) {
  const rows = [];
  const timings = [];
  let unattributedFibers = 0;
  let unattributedMs = 0;
  const unattributedCommits = new Set();
  let index = 0;
  for (const root of react?.dataForRoots ?? []) {
    for (const c of root.commitData ?? []) {
      const self = new Map((c.fiberSelfDurations ?? []).filter((p) => Array.isArray(p) && p.length >= 2));
      const duration = typeof c.duration === 'number' ? c.duration : 0;
      for (const pair of c.fiberActualDurations ?? []) {
        if (!Array.isArray(pair) || pair.length < 2) continue;
        const [id, actual] = pair;
        const name = react.displayNameById?.[String(id)] ?? null;
        const selfMs = self.get(id) ?? 0;
        if (!name) {
          unattributedFibers++;
          unattributedMs += selfMs;
          unattributedCommits.add(index);
          continue;
        }
        rows.push({ commitIndex: index, name, actualMs: actual, selfMs, didRender: actual > 0 });
      }
      timings.push({ index, timestamp: c.timestamp, durationMs: duration });
      index++;
    }
  }
  return { rows, timings, unattributed: { fibers: unattributedFibers, commits: unattributedCommits.size, ms: round(unattributedMs) } };
}

const round = (n) => Math.round(n * 100) / 100;

/** The numbers stop prints. */
export function summarize(profile, { top = 10 } = {}) {
  const { rows, timings, unattributed } = flattenCommits(profile.react);
  const totalCommitMs = round(timings.reduce((a, t) => a + t.durationMs, 0));
  const slowest = timings.reduce((best, t) => (!best || t.durationMs > best.durationMs ? t : best), null);
  const byName = new Map();
  for (const r of rows) {
    if (!r.didRender) continue;
    const e = byName.get(r.name) ?? { name: r.name, renders: 0, selfMs: 0 };
    e.renders++;
    e.selfMs += r.selfMs;
    byName.set(r.name, e);
  }
  const all = [...byName.values()].map((e) => ({ ...e, selfMs: round(e.selfMs) }));
  const cpu = profile.cpuProfile;
  return {
    durationMs: profile.durationMs,
    endedBy: profile.endedBy,
    maxMs: profile.maxMs,
    commits: timings.length,
    totalCommitMs,
    slowestCommit: slowest ? { index: slowest.index, durationMs: round(slowest.durationMs), atMs: slowest.timestamp } : null,
    byRenders: [...all].sort((a, b) => b.renders - a.renders || b.selfMs - a.selfMs || a.name.localeCompare(b.name)).slice(0, top),
    bySelfTime: [...all].sort((a, b) => b.selfMs - a.selfMs || b.renders - a.renders || a.name.localeCompare(b.name)).slice(0, top),
    components: all.length,
    unattributed,
    cpuSamples: Array.isArray(cpu?.samples) ? cpu.samples.length : null,
  };
}

const secs = (ms) => `${(ms / 1000).toFixed(1)} s`;

export function formatSummary(sum) {
  const ended = sum.endedBy === 'time-limit' ? `ended by its ${secs(sum.maxMs)} time limit`
    : sum.endedBy === 'stopped-elsewhere' ? 'stopped by another tool before this stop'
      : 'ended by stop';
  const lines = [sum.durationMs === null ? `recorded until another tool stopped it (when is unknown)` : `recorded ${secs(sum.durationMs)} (${ended})`];
  const slow = sum.slowestCommit ? `, slowest ${sum.slowestCommit.durationMs} ms (commit #${sum.slowestCommit.index} at +${secs(sum.slowestCommit.atMs)})` : '';
  lines.push(`React commits: ${sum.commits}, total commit time ${sum.totalCommitMs} ms${slow}`);
  if (sum.cpuSamples !== null) lines.push(`CPU samples: ${sum.cpuSamples}`);
  if (sum.commits === 0) {
    lines.push('No commits: nothing re-rendered while recording.');
    return lines.join('\n');
  }
  lines.push('', `Top components by renders (${sum.components} rendered):`);
  for (const e of sum.byRenders) lines.push(`  ${String(e.renders).padStart(5)}  ${e.name}  (self ${e.selfMs} ms)`);
  lines.push('', 'Top components by self time:');
  for (const e of sum.bySelfTime) lines.push(`  ${String(e.selfMs).padStart(8)} ms  ${e.name}  (${e.renders} renders)`);
  if (sum.unattributed.fibers) {
    lines.push('', `Unattributed: ${sum.unattributed.fibers} fiber renders in ${sum.unattributed.commits} commits (${sum.unattributed.ms} ms self) had no name - components that unmounted before stop.`);
  }
  return lines.join('\n');
}
