import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  loadProfile, toFiberCommits, recordingMs, componentRenders, slowestCommits, whyRendered,
  formatRenders, formatCommits, formatWhy, AnalysisError,
} from './react-analysis.mjs';
import { PROFILE } from './testing/react-profile-fixture.mjs';

test('toFiberCommits: one row per named fiber, flat commit index, unnamed fibers counted apart', () => {
  const f = toFiberCommits(PROFILE);
  assert.equal(f.totalCommits, 3);
  assert.equal(f.commits.length, 8);
  assert.deepEqual(f.unattributedByCommit, [[1, 1, 2]]);
  assert.deepEqual(f.commitTimings.map((t) => [t.timestamp, t.durationMs, t.selfMs]), [[0, 5, 5], [500, 30, 30], [1500, 2, 1.5]]);
  const list2 = f.commits.find((c) => c.commitIndex === 2 && c.componentName === 'List');
  assert.equal(list2.didRender, false);
  assert.deepEqual(f.commits.find((c) => c.componentName === 'Screen').hookTypes, ['State', 'Effect']);
});

test('recordingMs: as recorded, else the CPU span, else the last commit end', () => {
  assert.equal(recordingMs(PROFILE, []), 2000);
  assert.equal(recordingMs({ cpuProfile: { startTime: 0, endTime: 3_000_000 } }, []), 3000);
  assert.equal(recordingMs({}, [{ timestamp: 100, durationMs: 5 }, { timestamp: 40, durationMs: 1 }]), 105);
});

test('renders: count, mounts, total and max self time, reason; sorted by time or renders; grep', async () => {
  const r = await componentRenders(PROFILE);
  assert.deepEqual(r.rows.map((e) => [e.name, e.renders, e.mounts, e.selfMs, e.maxSelfMs, e.reason]), [
    ['List', 2, 1, 16, 14, 'parent'],
    ['Screen', 2, 1, 10, 8, 'state'],
    ['Row', 3, 1, 8.5, 6, 'parent'],
  ]);
  assert.deepEqual([r.commits, r.components, r.unattributed], [3, 3, { fibers: 1, ms: 2 }]);
  assert.deepEqual((await componentRenders(PROFILE, { sort: 'renders' })).rows.map((e) => e.name), ['Row', 'List', 'Screen']);
  const g = await componentRenders(PROFILE, { grep: '^r', top: 5 });
  assert.deepEqual([g.matched, g.rows.map((e) => e.name)], [1, ['Row']]);
  const text = formatRenders(r);
  assert.match(text, /^3 commits over 2\.0 s; 3 components rendered \(by self time, top 3\)/);
  assert.match(text, /\n {7}2 {7}1 {6}16\.00 {4}14\.00 {2}parent {12}List/);
  assert.match(text, /1 fiber renders, 2 ms self, had no name/);
});

test('commits: the slowest first, with the components that rendered, their reasons and the root cause', async () => {
  const r = await slowestCommits(PROFILE, { top: 2 });
  assert.deepEqual(r.rows.map((s) => [s.commitIndex, s.totalRenderMs]), [[1, 30], [0, 5]]);
  const hot = r.rows[0];
  assert.deepEqual(hot.components.map((c) => [c.name, c.selfDurationMs]), [['List', 14], ['Screen', 8], ['Row', 6]]);
  assert.equal(hot.rootCauseComponent, 'Screen');
  assert.equal(hot.unattributedFiberCount, 1);
  const text = formatCommits(r);
  assert.match(text, /^3 commits; the 2 slowest:\n\n#1 at \+0\.5 s {2}30\.00 ms {2}root cause: Screen \(state/);
  assert.match(text, /14\.00 ms self {2}x1 {2}List/);
  assert.match(text, /1 fibers without a name, 2 ms self/);
  const floor = await slowestCommits(PROFILE, { minMs: 10 });
  assert.deepEqual([floor.matched, floor.rows.length], [1, 1]);
});

test('commits: a commit whose rendered fibers all lost their names is still listed', async () => {
  const p = structuredClone(PROFILE);
  p.react.dataForRoots[0].commitData.push({ timestamp: 1800, duration: 99, fiberActualDurations: [[42, 99]], fiberSelfDurations: [[42, 99]], changeDescriptions: [] });
  const r = await slowestCommits(p, { top: 1 });
  assert.deepEqual([r.rows[0].commitIndex, r.rows[0].totalRenderMs, r.rows[0].components, r.rows[0].unattributedFiberCount], [3, 99, [], 1]);
  assert.match(formatCommits(r), /#3 at \+1\.8 s {2}99\.00 ms\n {2}1 fibers without a name, 99 ms self/);
});

test('commits: CPU samples inside a commit name the busiest JS functions', async () => {
  const p = structuredClone(PROFILE);
  p.cpuProfile = {
    startTime: 0, endTime: 1_000_000,
    nodes: [{ id: 1, callFrame: { functionName: '(root)' }, children: [2] }, { id: 2, callFrame: { functionName: 'layoutList', url: 'app.js', lineNumber: 10 } }],
    samples: Array(40).fill(2), timeDeltas: [0, ...Array(39).fill(15_000)],
  };
  const r = await slowestCommits(p, { top: 1 });
  assert.equal(r.rows[0].cpuHotspots?.[0]?.name, 'layoutList');
  assert.match(formatCommits(r), /JS busiest: layoutList \d+\.\d ms/);
});

test('why: every render of one component with its reason, changed props/hooks and the parent that caused it', async () => {
  const r = await whyRendered(PROFILE, 'Row');
  assert.deepEqual([r.renders, r.selfMs, r.maxSelfMs, r.reasons], [3, 8.5, 6, { mount: 1, parent: 1, props: 1 }]);
  assert.deepEqual(r.shown[1].causedBy, { component: 'Screen', reason: 'state', props: [], chain: ['List', 'Screen'] });
  assert.deepEqual(r.shown[2].changedProps, ['item']);
  const text = formatWhy(r);
  assert.match(text, /^Row: 3 renders, 8\.5 ms self in total, 6 ms at most; /);
  assert.match(text, /#1 at \+0\.5 s {2}6\.00 ms self {2}parent {2}caused by Screen \(state\) via List/);
  assert.match(text, /#2 at \+1\.5 s {2}1\.50 ms self {2}props {2}props item/);
  const screen = await whyRendered(PROFILE, 'Screen');
  assert.deepEqual(screen.shown[1].changedHooks, [{ index: 0, type: 'State' }]);
  assert.match(formatWhy(screen), /state {2}hooks #0 State/);
  assert.equal((await whyRendered(PROFILE, 'Row', { top: 1 })).shown.length, 1);
  assert.match(formatWhy(await whyRendered(PROFILE, 'Row', { top: 1 })), /\.\.\. and 2 more renders/);
});

test('why: a component that never rendered says so and names similar ones', async () => {
  const r = await whyRendered(PROFILE, 'ro');
  assert.deepEqual([r.renders, r.similar], [0, ['Row']]);
  assert.equal(formatWhy(r), 'ro did not render in this profile. Names containing it: Row');
});

test('loadProfile: a missing, cut, foreign or empty file exits 1 with what is wrong', () => {
  const dir = mkdtempSync(join(tmpdir(), 'rn-profile-analysis-'));
  try {
    const at = (name, text) => { const p = join(dir, name); writeFileSync(p, text); return p; };
    const full = JSON.stringify(PROFILE);
    assert.equal(loadProfile(at('ok.json', full)).durationMs, 2000);
    const cases = [
      [join(dir, 'nope.json'), /no such file/],
      [at('cut.json', full.slice(0, full.length / 2)), /not valid JSON \(cut short/],
      [at('other.json', '{"format":"chrome-trace"}'), /not a React profile written by `rn-profile\.mjs react stop` \(format: chrome-trace\)/],
      [at('empty.json', ''), /not valid JSON/],
      [at('broken.json', JSON.stringify({ format: 'rn-profile-react/1', react: { dataForRoots: [{}] } })), /no readable React commit data/],
      [at('null-commit.json', JSON.stringify({ format: 'rn-profile-react/1', react: { dataForRoots: [{ commitData: [null] }] } })), /damaged commit \(root 0, commit 0\)/],
      [at('no-time.json', JSON.stringify({ format: 'rn-profile-react/1', react: { dataForRoots: [{ commitData: [{ duration: 1 }] }] } })), /damaged commit/],
      [at('bad-pairs.json', JSON.stringify({ format: 'rn-profile-react/1', react: { dataForRoots: [{ commitData: [{ timestamp: 0, duration: 1, fiberActualDurations: { a: 1 } }] }] } })), /damaged commit/],
    ];
    for (const [path, re] of cases) assert.throws(() => loadProfile(path), (err) => err instanceof AnalysisError && err.exitCode === 1 && re.test(err.message), path);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
