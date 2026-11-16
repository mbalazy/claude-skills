import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';
import { fakeReactApp } from './testing/fake-react-app.mjs';
import {
  startRecording, recordingStatus, stopRecording, ProfileError,
  trimCpuProfile, flattenCommits, summarize, formatSummary, FORMAT,
} from './react-profile.mjs';

test('start, status, commits, stop: the profile carries the commits, names and the CPU profile', async () => {
  const app = fakeReactApp();
  const started = await startRecording(app.client, { maxSeconds: 30 });
  assert.equal(started.started, true);
  assert.equal(started.session.maxMs, 30000);
  assert.equal(started.discarded, null);
  assert.ok(app.client.sent.indexOf('Profiler.stop') < app.client.sent.indexOf('Profiler.start'), 'a stale sampler is stopped before the start');
  assert.equal((await recordingStatus(app.client)).recording, true);
  app.run('commit([[1, 3, 1], [2, 2, 1.5], [3, 0.5, 0.5]], 4)');
  app.run('commit([[3, 0.4, 0.4], [3, 0, 0]], 1)');
  const profile = await stopRecording(app.client);
  assert.equal(profile.format, FORMAT);
  assert.equal(profile.endedBy, 'stop');
  assert.equal(profile.react.dataForRoots[0].commitData.length, 2);
  assert.equal(profile.react.displayNameById['2'], 'ListScreen');
  assert.ok(profile.cpuProfile.samples.length > 0);
  assert.equal(app.sampler.running, false);
  const after = await recordingStatus(app.client);
  assert.deepEqual([after.recording, after.session], [false, null]);
});

test('a second start while recording changes nothing', async () => {
  const app = fakeReactApp();
  const first = await startRecording(app.client);
  const again = await startRecording(app.client);
  assert.equal(again.already, true);
  assert.equal(again.session.sessionId, first.session.sessionId);
  assert.equal(app.sampler.starts, 1);
});

test('stop with nothing recording still stops the sampler and exits 1', async () => {
  const app = fakeReactApp();
  await app.client.send('Profiler.start', {});
  await assert.rejects(stopRecording(app.client), (err) => err instanceof ProfileError && err.exitCode === 1 && /No recording[\s\S]*reload/.test(err.message));
  assert.equal(app.sampler.running, false);
});

test('a JS reload loses the recording: stop in the new runtime exits 1', async () => {
  const app = fakeReactApp();
  await startRecording(app.client);
  app.run('delete globalThis.__rn_profile_session'); // a reload starts with fresh globals
  await assert.rejects(stopRecording(app.client), (err) => err.exitCode === 1 && /No recording/.test(err.message));
});

test('the time limit ends the React side in the app; stop returns what was recorded before it, CPU cut at the limit', async () => {
  const app = fakeReactApp();
  await startRecording(app.client, { maxSeconds: 0.05 });
  app.run('commit([[2, 2, 2]], 2)');
  await sleep(120);
  assert.equal(app.run('commit([[3, 1, 1]], 1)'), false, 'nothing is recorded after the limit');
  const status = await recordingStatus(app.client);
  assert.deepEqual([status.recording, status.session.endedBy], [false, 'time-limit']);
  const profile = await stopRecording(app.client);
  assert.equal(profile.endedBy, 'time-limit');
  assert.equal(profile.react.dataForRoots[0].commitData.length, 1);
  assert.ok(profile.durationMs >= 40 && profile.durationMs < 110, `duration ${profile.durationMs}`);
  assert.ok(profile.cpuProfile.samples.length <= profile.durationMs, 'samples after the limit are dropped');
});

test("the time limit never stops a recording another tool started after ours was stopped", async () => {
  const app = fakeReactApp();
  await startRecording(app.client, { maxSeconds: 0.08 });
  app.run(`(function() {
    var ri = __REACT_DEVTOOLS_GLOBAL_HOOK__.rendererInterfaces.get(1);
    ri.stopProfiling(); ri.startProfiling(); globalThis.__ARGENT_PROFILER_OWNER__ = { tool: 'other-profiler', sessionId: 'x' };
  })()`);
  await sleep(150);
  assert.equal(app.run('__REACT_DEVTOOLS_GLOBAL_HOOK__.rendererInterfaces.get(1).__argent_isProfiling__'), true, "the other tool's recording runs on");
  assert.equal(app.run('globalThis.__rn_profile_session.endedBy'), 'stopped-elsewhere');
});

test('stop after another tool took over: nothing read, its recording and sampler left running, exit 1', async () => {
  const app = fakeReactApp();
  await startRecording(app.client);
  await sleep(5);
  app.run(`(function() {
    var ri = __REACT_DEVTOOLS_GLOBAL_HOOK__.rendererInterfaces.get(1);
    ri.stopProfiling(); ri.startProfiling(); globalThis.__ARGENT_PROFILER_OWNER__ = { tool: 'other-profiler', sessionId: 'x' };
  })()`);
  await assert.rejects(stopRecording(app.client), (err) => err.exitCode === 1 && /took over/.test(err.message));
  assert.equal(app.run('__REACT_DEVTOOLS_GLOBAL_HOOK__.rendererInterfaces.get(1).__argent_isProfiling__'), true);
  assert.equal(app.sampler.running, true);
  assert.equal(app.run('globalThis.__rn_profile_session'), undefined);
});

test('stop after another tool only stopped ours: the data is returned, its length unknown', async () => {
  const app = fakeReactApp();
  await startRecording(app.client);
  app.run('commit([[2, 1, 1]], 1); __REACT_DEVTOOLS_GLOBAL_HOOK__.rendererInterfaces.get(1).stopProfiling()');
  const profile = await stopRecording(app.client);
  assert.deepEqual([profile.endedBy, profile.durationMs, profile.react.dataForRoots[0].commitData.length], ['stopped-elsewhere', null, 1]);
  assert.match(formatSummary(summarize(profile)), /^recorded until another tool stopped it/);
});

test('a stop that failed after taking the CPU profile can be retried and reads the same ending', async () => {
  const app = fakeReactApp();
  await startRecording(app.client);
  app.run('commit([[2, 1, 1]], 1)');
  const evaluate = app.client.evaluate;
  app.client.evaluate = async (expr) => {
    if (expr.includes('__argent_stopAndRead')) throw Object.assign(new Error('no answer'), { exitCode: 3 });
    return evaluate(expr);
  };
  await assert.rejects(stopRecording(app.client), (err) => err.exitCode === 3);
  app.client.evaluate = evaluate;
  const profile = await stopRecording(app.client);
  assert.equal(profile.endedBy, 'stop');
  assert.equal(typeof profile.durationMs, 'number');
  assert.equal(profile.cpuProfile, null, 'the first attempt took the CPU profile');
  assert.equal(profile.react.dataForRoots[0].commitData.length, 1);
});

test('starting over an unread recording says it was dropped', async () => {
  const app = fakeReactApp();
  await startRecording(app.client, { maxSeconds: 0.02 });
  await sleep(60);
  const next = await startRecording(app.client);
  assert.equal(next.discarded, 'time-limit');
});

test('another profiler holds React: start refuses, --takeover ends it and starts', async () => {
  const app = fakeReactApp();
  app.run(`(function() {
    var ri = __REACT_DEVTOOLS_GLOBAL_HOOK__.rendererInterfaces.get(1);
    ri.startProfiling(); ri.__argent_isProfiling__ = true; globalThis.__ARGENT_PROFILER_OWNER__ = { tool: 'other-profiler' };
  })()`);
  await assert.rejects(startRecording(app.client), (err) => err.exitCode === 1 && /already being profiled by other-profiler[\s\S]*--takeover/.test(err.message));
  const res = await startRecording(app.client, { takeover: true });
  assert.equal(res.started, true);
  assert.equal((await recordingStatus(app.client)).recording, true);
});

test('a start that fails after the sampler started rolls back: React stopped, sampler stopped, no session', async () => {
  const app = fakeReactApp();
  const evaluate = app.client.evaluate;
  app.client.evaluate = async (expr) => {
    if (expr.includes('__argent_doStart') && expr.includes('__rn_profile_session = s')) {
      await evaluate(expr); // the app did it, the answer never arrived
      throw Object.assign(new Error('no answer'), { exitCode: 3 });
    }
    return evaluate(expr);
  };
  await assert.rejects(startRecording(app.client), (err) => err.exitCode === 3);
  app.client.evaluate = evaluate;
  assert.equal(app.sampler.running, false);
  assert.equal(app.run('globalThis.__rn_profile_session'), undefined);
  assert.equal(app.run('__REACT_DEVTOOLS_GLOBAL_HOOK__.rendererInterfaces.get(1).__argent_isProfiling__'), false);
  assert.equal((await startRecording(app.client)).started, true, 'a new start works without --takeover');
});

test('an app without the DevTools hook: start exits 1 naming a development build', async () => {
  const app = fakeReactApp({ hook: false });
  await assert.rejects(startRecording(app.client), (err) => err.exitCode === 1 && /development build/.test(err.message));
});

test('trimCpuProfile keeps the samples inside the first keepMs', () => {
  const p = { startTime: 100, endTime: 5100, samples: [1, 2, 3, 4, 5], timeDeltas: [1000, 1000, 1000, 1000, 1000] };
  assert.deepEqual(trimCpuProfile(p, 3), { startTime: 100, endTime: 3100, samples: [1, 2, 3], timeDeltas: [1000, 1000, 1000] });
  assert.equal(trimCpuProfile(p, 10).samples.length, 5);
  assert.equal(trimCpuProfile(null, 1), null);
});

// A synthetic profile: two roots, one fiber without a name (unmounted).
const PROFILE = {
  durationMs: 4200, endedBy: 'stop', maxMs: 60000,
  cpuProfile: { samples: [1, 1, 1] },
  react: {
    displayNameById: { 1: 'Screen', 2: 'Row', 3: 'Header' },
    dataForRoots: [
      { commitData: [
        { timestamp: 100, duration: 12.5, fiberActualDurations: [[1, 12], [2, 3], [3, 0]], fiberSelfDurations: [[1, 6], [2, 3], [3, 0]] },
        { timestamp: 900, duration: 30, fiberActualDurations: [[2, 4], [9, 20]], fiberSelfDurations: [[2, 4], [9, 18]] },
      ] },
      { commitData: [
        { timestamp: 2500, duration: 2, fiberActualDurations: [[2, 1.25], [3, 0.75]], fiberSelfDurations: [[2, 1.25], [3, 0.75]] },
      ] },
    ],
  },
};

test('flattenCommits numbers commits across roots and keeps unnamed fibers apart', () => {
  const f = flattenCommits(PROFILE.react);
  assert.deepEqual(f.timings.map((t) => [t.index, t.durationMs]), [[0, 12.5], [1, 30], [2, 2]]);
  assert.deepEqual(f.unattributed, { fibers: 1, commits: 1, ms: 18 });
  assert.equal(f.rows.filter((r) => r.name === 'Header' && !r.didRender).length, 1);
});

test('summarize: commit count, total and slowest commit, top components by renders and by self time', () => {
  const s = summarize(PROFILE);
  assert.equal(s.commits, 3);
  assert.equal(s.totalCommitMs, 44.5);
  assert.deepEqual(s.slowestCommit, { index: 1, durationMs: 30, atMs: 900 });
  assert.deepEqual(s.byRenders.map((e) => [e.name, e.renders, e.selfMs]), [['Row', 3, 8.25], ['Screen', 1, 6], ['Header', 1, 0.75]]);
  assert.deepEqual(s.bySelfTime.map((e) => e.name), ['Row', 'Screen', 'Header']);
  assert.equal(s.cpuSamples, 3);
  assert.equal(summarize(PROFILE, { top: 1 }).byRenders.length, 1);
});

test('formatSummary: the lines a person reads, the time limit and the unattributed note', () => {
  const text = formatSummary(summarize(PROFILE));
  assert.match(text, /^recorded 4\.2 s \(ended by stop\)\nReact commits: 3, total commit time 44\.5 ms, slowest 30 ms \(commit #1 at \+0\.9 s\)\nCPU samples: 3/);
  assert.match(text, /Top components by renders \(3 rendered\):\n {6}3 {2}Row {2}\(self 8\.25 ms\)/);
  assert.match(text, /Top components by self time:\n {6}8\.25 ms {2}Row {2}\(3 renders\)/);
  assert.match(text, /Unattributed: 1 fiber renders in 1 commits \(18 ms self\)/);
  assert.match(formatSummary(summarize({ ...PROFILE, endedBy: 'time-limit', maxMs: 30000 })), /ended by its 30\.0 s time limit/);
  const empty = formatSummary(summarize({ ...PROFILE, react: { dataForRoots: [], displayNameById: {} }, cpuProfile: null }));
  assert.match(empty, /React commits: 0, total commit time 0 ms\nNo commits/);
});
