// react-analysis.mjs - answers questions about a React profile saved by
// `rn-profile.mjs react stop`, without the app: which components render most
// and longest, which commits were slowest and what rendered in them, and why
// a component rendered.
//
// Argent's analysis stages do the work, vendored unmodified under
// skills/simulator-verify/scripts/devtools/vendor/argent/: summarizeRenders
// (render-summary.ts) for the per-component numbers and the dominant reason,
// preprocess (00-preprocess.ts) for the parent that caused a cascade,
// buildHotCommitSummaries (00-hot-commits.ts) for the components of a commit,
// and the CPU correlation (00-cpu-correlate.ts) for the JS functions busy
// during a commit. toFiberCommits is a port of flattenProfilingData and
// normalizeChangeDescription from Argent's tools/profiler/react/react-profiler-stop.ts.

import { readFileSync } from 'node:fs';
import { vendorPath } from '../../simulator-verify/scripts/devtools/vendor-loader.mjs';
import { FORMAT } from './react-profile.mjs';

const BASE = 'packages/tool-server/src/utils/react-profiler/';
const stage = (file) => import(vendorPath(BASE + file));

export class AnalysisError extends Error {
  constructor(message) { super(message); this.exitCode = 1; }
}

/** Reads and checks a profile file; a missing, cut or foreign file exits 1. */
export function loadProfile(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (err) {
    throw new AnalysisError(`cannot read ${path}: ${err.code === 'ENOENT' ? 'no such file' : err.message}`);
  }
  let profile;
  try {
    profile = JSON.parse(text);
  } catch {
    throw new AnalysisError(`${path} is not valid JSON (cut short, or not a profile)`);
  }
  if (profile?.format !== FORMAT) {
    throw new AnalysisError(`${path} is not a React profile written by \`rn-profile.mjs react stop\` (format: ${profile?.format ?? 'missing'})`);
  }
  if (!Array.isArray(profile.react?.dataForRoots) || !profile.react.dataForRoots.every((r) => Array.isArray(r?.commitData))) {
    throw new AnalysisError(`${path} has no readable React commit data`);
  }
  const pairList = (v) => v === undefined || v === null || (Array.isArray(v) && v.every((p) => Array.isArray(p)));
  profile.react.dataForRoots.forEach((root, r) => root.commitData.forEach((c, i) => {
    const ok = c && typeof c === 'object' && Number.isFinite(c.timestamp) && Number.isFinite(c.duration)
      && pairList(c.fiberActualDurations) && pairList(c.fiberSelfDurations) && pairList(c.changeDescriptions);
    if (!ok) throw new AnalysisError(`${path} has a damaged commit (root ${r}, commit ${i}): it needs a numeric timestamp and duration and [id, value] lists`);
  }));
  return profile;
}

function normalizeChangeDescription(raw) {
  if (!raw || typeof raw !== 'object') return null;
  return {
    props: Array.isArray(raw.props) ? raw.props : null,
    state: typeof raw.state === 'boolean' ? raw.state : null,
    hooks: Array.isArray(raw.hooks) ? raw.hooks : null,
    context: typeof raw.context === 'boolean' ? raw.context : null,
    didHooksChange: raw.didHooksChange === true,
    isFirstMount: raw.isFirstMount === true,
  };
}

/**
 * The profile as Argent's stages take it: one DevToolsFiberCommit per named
 * fiber per commit (commitIndex flat across roots), the timing of every
 * commit, and per commit the fibers whose name was lost ([index, count, ms]).
 */
export function toFiberCommits(profile) {
  const names = profile.react.displayNameById ?? {};
  const meta = profile.fiberMeta ?? {};
  const commits = [];
  const commitTimings = [];
  const unattributedByCommit = [];
  let index = 0;
  for (const root of profile.react.dataForRoots) {
    for (const c of root.commitData) {
      const pairs = (list) => new Map((list ?? []).filter((p) => Array.isArray(p) && p.length >= 2));
      const actual = pairs(c.fiberActualDurations);
      const self = pairs(c.fiberSelfDurations);
      const changes = pairs(c.changeDescriptions);
      const commitDuration = typeof c.duration === 'number' ? c.duration : 0;
      let dropped = 0;
      let droppedMs = 0;
      let selfMs = 0;
      for (const [id, actualDuration] of actual) {
        if (actualDuration > 0) selfMs += self.get(id) ?? 0;
        const name = names[String(id)] ?? null;
        if (!name) {
          dropped++;
          droppedMs += self.get(id) ?? 0;
          continue;
        }
        const m = meta[name];
        commits.push({
          commitIndex: index,
          timestamp: c.timestamp,
          componentName: name,
          actualDuration,
          selfDuration: self.get(id) ?? 0,
          commitDuration,
          didRender: actualDuration > 0,
          changeDescription: normalizeChangeDescription(changes.get(id)),
          hookTypes: m?.hookTypes ?? null,
          parentName: m?.parentName ?? null,
          isCompilerOptimized: m?.isCompilerOptimized === true,
        });
      }
      commitTimings.push({ timestamp: c.timestamp, durationMs: commitDuration, selfMs });
      if (dropped > 0) unattributedByCommit.push([index, dropped, Math.round(droppedMs * 100) / 100]);
      index++;
    }
  }
  return { commits, commitTimings, unattributedByCommit, totalCommits: index };
}

/** The recording's length: as recorded, else the CPU profile's span, else the last commit's end. */
export function recordingMs(profile, timings) {
  if (typeof profile.durationMs === 'number') return profile.durationMs;
  const cpu = profile.cpuProfile;
  if (cpu && typeof cpu.endTime === 'number' && typeof cpu.startTime === 'number') return (cpu.endTime - cpu.startTime) / 1000;
  return timings.reduce((end, t) => Math.max(end, (t.timestamp ?? 0) + (t.durationMs ?? 0)), 0);
}

const round = (n) => Math.round(n * 100) / 100;

function matcher(grep) {
  if (!grep) return () => true;
  const re = new RegExp(grep, 'i');
  return (name) => re.test(name);
}

/**
 * Per component over every render: renders, mounts, total and max self time,
 * with Argent's dominant re-render reason and its most changed props / hooks.
 * sort: 'time' (total self time) or 'renders'.
 */
export async function componentRenders(profile, { grep, sort = 'time', top = 20 } = {}) {
  const { summarizeRenders } = await stage('render-summary.ts');
  const f = toFiberCommits(profile);
  const ms = recordingMs(profile, f.commitTimings);
  const summary = summarizeRenders(f.commits, f.commitTimings, ms);
  const argent = new Map(summary.components.map((c) => [c.name, c]));
  const acc = new Map();
  for (const c of f.commits) {
    if (!c.didRender) continue;
    const e = acc.get(c.componentName) ?? { name: c.componentName, renders: 0, mounts: 0, selfMs: 0, maxSelfMs: 0 };
    e.renders++;
    if (c.changeDescription?.isFirstMount) e.mounts++;
    e.selfMs += c.selfDuration;
    e.maxSelfMs = Math.max(e.maxSelfMs, c.selfDuration);
    acc.set(c.componentName, e);
  }
  const keep = matcher(grep);
  const rows = [...acc.values()].filter((e) => keep(e.name)).map((e) => {
    const a = argent.get(e.name);
    return {
      name: e.name, renders: e.renders, mounts: e.mounts, selfMs: round(e.selfMs), maxSelfMs: round(e.maxSelfMs),
      reason: a?.reason ?? null, topProps: a?.topProps ?? [], topHooks: a?.topHooks ?? [],
    };
  });
  const bySort = sort === 'renders'
    ? (a, b) => b.renders - a.renders || b.selfMs - a.selfMs || a.name.localeCompare(b.name)
    : (a, b) => b.selfMs - a.selfMs || b.renders - a.renders || a.name.localeCompare(b.name);
  rows.sort(bySort);
  return {
    recordingMs: ms,
    commits: f.totalCommits,
    components: acc.size,
    matched: rows.length,
    sort,
    rows: rows.slice(0, top),
    totalRenderMs: summary.totalRenderMs,
    peakSecondRenderMs: summary.peakSecondRenderMs,
    unattributed: f.unattributedByCommit.reduce((a, [, n, m]) => ({ fibers: a.fibers + n, ms: round(a.ms + m) }), { fibers: 0, ms: 0 }),
  };
}

/** The slowest commits (by duration), each with what rendered in it, why, and the busiest JS functions. */
export async function slowestCommits(profile, { top = 10, minMs = 0 } = {}) {
  const { preprocess } = await stage('pipeline/00-preprocess.ts');
  const { buildHotCommitSummaries } = await stage('pipeline/00-hot-commits.ts');
  const { buildCpuSampleIndex, correlateCpuWithCommits, dropStaleLeadingGap } = await stage('pipeline/00-cpu-correlate.ts');
  const f = toFiberCommits(profile);
  const chosen = f.commitTimings
    .map((t, index) => ({ index, ...t }))
    .filter((t) => t.durationMs >= minMs)
    .sort((a, b) => b.durationMs - a.durationMs || a.index - b.index)
    .slice(0, top);
  const wanted = new Set(chosen.map((t) => t.index));
  const pre = preprocess(f.commits).filter((c) => wanted.has(c.commitIndex));
  let summaries = buildHotCommitSummaries(pre, [...wanted], f.unattributedByCommit);
  const cpu = profile.cpuProfile;
  if (cpu && Array.isArray(cpu.samples) && Array.isArray(cpu.timeDeltas) && Array.isArray(cpu.nodes)) {
    const copy = { ...cpu, timeDeltas: cpu.timeDeltas.slice() };
    dropStaleLeadingGap(copy);
    summaries = correlateCpuWithCommits(summaries, buildCpuSampleIndex(copy));
  }
  const byIndex = new Map(summaries.map((s) => [s.commitIndex, s]));
  const unattributed = new Map(f.unattributedByCommit.map(([i, n, ms]) => [i, { n, ms }]));
  return {
    commits: f.totalCommits,
    matched: f.commitTimings.filter((t) => t.durationMs >= minMs).length,
    // A commit whose rendered fibers all lost their names has no summary: it is still listed.
    rows: chosen.map((t) => byIndex.get(t.index) ?? {
      commitIndex: t.index, timestampMs: t.timestamp, totalRenderMs: t.durationMs, components: [], totalComponentCount: 0,
      unattributedFiberCount: unattributed.get(t.index)?.n, unattributedMs: unattributed.get(t.index)?.ms,
    }),
  };
}

/** Every render of one component (exact name) with its reason; null when it never rendered. */
export async function whyRendered(profile, name, { top = 20 } = {}) {
  const { preprocess } = await stage('pipeline/00-preprocess.ts');
  const { deriveReason } = await stage('pipeline/utils.ts');
  const f = toFiberCommits(profile);
  const all = preprocess(f.commits).filter((c) => c.didRender);
  const mine = all.filter((c) => c.componentName === name);
  if (!mine.length) {
    const lower = name.toLowerCase();
    const similar = [...new Set(all.map((c) => c.componentName))].filter((n) => n.toLowerCase().includes(lower)).sort().slice(0, 10);
    return { name, renders: 0, similar };
  }
  const reasons = {};
  const renders = mine.map((c) => {
    const cd = c.changeDescription;
    const reason = cd?.isFirstMount ? 'mount' : deriveReason(cd, c.hookTypes);
    reasons[reason] = (reasons[reason] ?? 0) + 1;
    const hooks = (cd?.hooks ?? []).map((i) => ({ index: i, type: c.hookTypes?.[i] ?? null }));
    return {
      commitIndex: c.commitIndex, timestampMs: c.timestamp, selfMs: round(c.selfDuration), actualMs: round(c.actualDuration), reason,
      changedProps: cd?.props ?? [], changedHooks: hooks, contextChanged: cd?.context === true,
      causedBy: c.rootCauseParent ? { component: c.rootCauseParent, reason: c.rootCauseReason, props: c.rootCauseProps ?? [], chain: c.rootCauseChain ?? [] } : null,
    };
  });
  return {
    name,
    renders: renders.length,
    selfMs: round(mine.reduce((a, c) => a + c.selfDuration, 0)),
    maxSelfMs: round(Math.max(...mine.map((c) => c.selfDuration))),
    reasons,
    hasChangeData: mine.some((c) => c.changeDescription !== null),
    shown: renders.slice(0, top),
  };
}

// ---- text ------------------------------------------------------------------

const secs = (ms) => `+${(ms / 1000).toFixed(1)} s`;

export function formatRenders(r) {
  const lines = [`${r.commits} commits over ${(r.recordingMs / 1000).toFixed(1)} s; ${r.components} components rendered${r.matched !== r.components ? `, ${r.matched} match` : ''} (by ${r.sort === 'renders' ? 'render count' : 'self time'}, top ${r.rows.length})`];
  if (!r.rows.length) return lines.join('\n');
  lines.push(' renders  mounts    self ms   max ms  why (re-renders)  component');
  for (const e of r.rows) {
    const detail = [...e.topProps.map((p) => `.${p}`), ...e.topHooks].slice(0, 3).join(' ');
    const why = e.reason ? `${e.reason}${detail ? ` ${detail}` : ''}` : '-';
    lines.push(`${String(e.renders).padStart(8)}${String(e.mounts).padStart(8)}${e.selfMs.toFixed(2).padStart(11)}${e.maxSelfMs.toFixed(2).padStart(9)}  ${why.padEnd(16)}  ${e.name}`);
  }
  if (r.unattributed.fibers) lines.push(`(${r.unattributed.fibers} fiber renders, ${r.unattributed.ms} ms self, had no name - unmounted before stop - and are not in the rows)`);
  return lines.join('\n');
}

export function formatCommits(r) {
  const lines = [`${r.commits} commits; the ${r.rows.length} slowest${r.matched !== r.commits ? ` of ${r.matched} over the floor` : ''}:`];
  for (const s of r.rows) {
    const changed = [
      s.rootCauseChangedProps?.length ? `props ${s.rootCauseChangedProps.join(', ')}` : '',
      s.rootCauseChangedHookNames?.length ? `hooks ${s.rootCauseChangedHookNames.join(', ')}` : '',
    ].filter(Boolean).join('; ');
    const cause = s.rootCauseComponent ? `  root cause: ${s.rootCauseComponent} (${s.rootCauseReason}${changed ? `: ${changed}` : ''})` : '';
    const kind = s.isInitialRender ? '  mostly first mounts' : '';
    lines.push('', `#${s.commitIndex} at ${secs(s.timestampMs)}  ${s.totalRenderMs.toFixed(2)} ms${kind}${cause}`);
    for (const c of s.components) {
      const why = c.isFirstMount ? 'mount' : c.reason ?? '';
      lines.push(`  ${c.selfDurationMs.toFixed(2).padStart(8)} ms self  x${c.count}  ${c.name}${why ? `  (${why}${c.topChangedProps?.length ? `: ${c.topChangedProps.join(', ')}` : ''})` : ''}`);
    }
    if (s.totalComponentCount > s.components.length) lines.push(`  ... and ${s.totalComponentCount - s.components.length} more components`);
    if (s.unattributedFiberCount) lines.push(`  ${s.unattributedFiberCount} fibers without a name, ${s.unattributedMs} ms self`);
    if (s.cpuHotspots?.length) lines.push(`  JS busiest: ${s.cpuHotspots.map((h) => `${h.name} ${h.selfMs.toFixed(1)} ms`).join(', ')}`);
  }
  return lines.join('\n');
}

const listed = (items, max = 4) => (items.length > max ? `${items.slice(0, max).join(', ')} +${items.length - max} more` : items.join(', '));

export function formatWhy(r) {
  if (!r.renders) {
    return `${r.name} did not render in this profile.${r.similar.length ? ` Names containing it: ${r.similar.join(', ')}` : ''}`;
  }
  const counts = Object.entries(r.reasons).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k} ${n}`).join(', ');
  const lines = [`${r.name}: ${r.renders} renders, ${r.selfMs} ms self in total, ${r.maxSelfMs} ms at most; ${counts}`];
  if (!r.hasChangeData) lines.push('(no change data recorded for it: React DevTools keeps none for some fibers, e.g. context providers)');
  for (const x of r.shown) {
    const what = [
      x.changedProps.length ? `props ${listed(x.changedProps)}` : '',
      x.changedHooks.length ? `hooks ${listed(x.changedHooks.map((h) => `#${h.index}${h.type ? ` ${h.type}` : ''}`))}` : '',
      x.contextChanged ? 'context' : '',
      x.causedBy ? `caused by ${x.causedBy.component} (${x.causedBy.reason}${x.causedBy.props.length ? `: ${x.causedBy.props.join(', ')}` : ''})${x.causedBy.chain.length > 1 ? ` via ${x.causedBy.chain.slice(0, -1).join(' < ')}` : ''}` : '',
    ].filter(Boolean).join('; ');
    lines.push(`  #${x.commitIndex} at ${secs(x.timestampMs)}  ${x.selfMs.toFixed(2)} ms self  ${x.reason}${what ? `  ${what}` : ''}`);
  }
  if (r.renders > r.shown.length) lines.push(`  ... and ${r.renders - r.shown.length} more renders (--top)`);
  return lines.join('\n');
}
