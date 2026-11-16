import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, symlinkSync, mkdirSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { execFile, spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import {
  parseLaunchctl, pickApp, attachName, checkDevice, runningUserApps, analyze, summarize, formatSummary,
  reportDir, record, exportFiles, IosProfileError, TIME_PROFILER, SUMMARY_FILE,
} from './ios-profile.mjs';
import { cpuXml, hangsXml, noHangsXml, leaksXml } from './testing/ios-export-fixture.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
export const UDID = '11111111-2222-3333-4444-555555555555';

/** A temp dir with fake xcrun/xctrace first in PATH, the scenario file, a fake app bundle and export fixtures. */
export function rig(over = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'rn-profile-ios-'));
  const bin = join(dir, 'bin');
  mkdirSync(bin);
  for (const name of ['xcrun', 'xctrace']) symlinkSync(join(HERE, 'testing', 'fake-xcrun.mjs'), join(bin, name));
  const app = join(dir, 'dev/data/Containers/Bundle/Application/A/SampleApp.app');
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, 'Info.plist'), '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>SampleApp</string><key>CFBundleDisplayName</key><string>Sample App</string></dict></plist>');
  const fx = join(dir, 'fx');
  mkdirSync(fx);
  writeFileSync(join(fx, 'cpu.xml'), cpuXml());
  writeFileSync(join(fx, 'hangs.xml'), hangsXml());
  writeFileSync(join(fx, 'leaks.xml'), leaksXml());
  const scenario = {
    devices: { devices: { 'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [{ udid: UDID, name: 'Test Phone', state: 'Booted' }, { udid: 'OFF', name: 'Off', state: 'Shutdown' }] } },
    launchctl: `4242\t0\tUIKitApplication:com.example.sample[ab12][rb-legacy]\n-\t0\tUIKitApplication:com.example.idle[cd34]\n300\t0\tUIKitApplication:com.apple.mobilecal[0517]\n301\t0\tUIKitApplication:com.example.Runner.xctrunner[05d9]\n`,
    containers: { 'com.example.sample': app, 'com.apple.mobilecal': '/Runtime/Applications/MobileCal.app' },
    record: { rc: 0, delayMs: 50 },
    exports: { 'time-profile': join(fx, 'cpu.xml'), 'potential-hangs': join(fx, 'hangs.xml') },
    ...over,
  };
  const scenarioFile = join(dir, 'scenario.json');
  writeFileSync(scenarioFile, JSON.stringify(scenario));
  const out = join(dir, 'out');
  mkdirSync(out);
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, FAKE_XCRUN_SCENARIO: scenarioFile };
  const calls = () => (existsSync(`${scenarioFile}.log`) ? readFileSync(`${scenarioFile}.log`, 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : []);
  return { dir, out, fx, env, calls, done: () => rmSync(dir, { recursive: true, force: true }) };
}

/** Runs fn with the rig's PATH and scenario in this process's env. */
async function withEnv(r, fn) {
  const saved = { PATH: process.env.PATH, FAKE_XCRUN_SCENARIO: process.env.FAKE_XCRUN_SCENARIO };
  Object.assign(process.env, { PATH: r.env.PATH, FAKE_XCRUN_SCENARIO: r.env.FAKE_XCRUN_SCENARIO });
  try { return await fn(); } finally {
    process.env.PATH = saved.PATH;
    if (saved.FAKE_XCRUN_SCENARIO === undefined) delete process.env.FAKE_XCRUN_SCENARIO; else process.env.FAKE_XCRUN_SCENARIO = saved.FAKE_XCRUN_SCENARIO;
  }
}

test('xctraceThread rewrites Name (0x..) to the Name 0x.. form Argent groups by', async () => {
  const { xctraceThread } = await import('./ios-profile.mjs');
  assert.equal(xctraceThread('com.example.js (0xbee0deb) (Sample App, pid: 4242)'), 'com.example.js 0xbee0deb (Sample App, pid: 4242)');
  assert.equal(xctraceThread('Main Thread (0x1) (Sample App, pid: 4242)'), 'Main Thread 0x1 (Sample App, pid: 4242)');
});

test('a function spread thin over several unnamed threads is still one hotspot', async () => {
  const r = rig();
  try {
    // 96 samples of main() on the main thread, 4 x 2 samples of work() on 4 unnamed threads (8% in total, 2% each).
    const rows = [];
    for (let i = 0; i < 104; i++) {
      const tid = i < 96 ? 1 : 10 + ((i - 96) % 4);
      const fn = i < 96 ? 'mainWork()' : 'workerDecode()';
      const name = i < 96 ? 'Main Thread (0x1) (Sample App, pid: 4242)' : `Sample App (0x10${tid}) (Sample App, pid: 4242)`;
      rows.push(`<row><sample-time id="t${i}" fmt="x">${1_000_000 + i * 10_000_000}</sample-time><thread id="th${i}" fmt="${name}"></thread><weight id="w${i}" fmt="1 ms">1000000</weight><tagged-backtrace id="b${i}"><frame id="f${i}" name="${fn}" addr="0x1"><binary id="bin${i}" name="SampleApp" path="/Users/dev/SampleApp.app/SampleApp"/></frame></tagged-backtrace></row>`);
    }
    writeFileSync(join(r.fx, 'spread.xml'), `<?xml version="1.0"?>\n<trace-query-result><node><schema name="time-profile"></schema>${rows.join('\n')}</node></trace-query-result>`);
    const sum = summarize(await analyze({ cpu: join(r.fx, 'spread.xml'), hangs: null, leaks: null }), { leaksRecorded: false });
    assert.deepEqual(sum.cpu.hotspots.map((h) => [h.function, h.samples, h.thread]), [['mainWork()', 96, 'Main Thread'], ['workerDecode()', 8, 'Sample App']]);
    assert.deepEqual(sum.cpu.threads.map((t) => [t.thread, t.samples]), [['Main Thread', 96], ['Sample App', 8]]);
  } finally { r.done(); }
});

test('parseLaunchctl keeps running apps only', () => {
  const m = parseLaunchctl('PID\tStatus\tLabel\n4242\t0\tUIKitApplication:com.example.a[ab][rb-legacy]\n-\t0\tUIKitApplication:com.example.b[cd]\n12\t0\tcom.apple.thing\n');
  assert.deepEqual([...m], [['com.example.a', 4242]]);
});

test('pickApp: by bundle id, executable or display name; one app needs no flag; none / several are errors', () => {
  const a = { bundleId: 'com.example.a', executable: 'A', displayName: 'App A', pid: 1 };
  const b = { bundleId: 'com.example.b', executable: 'B', displayName: null, pid: 2 };
  assert.equal(pickApp([a, b], 'App A'), a);
  assert.equal(pickApp([a, b], 'B'), b);
  assert.equal(pickApp([a, b], 'com.example.b'), b);
  assert.equal(pickApp([a], undefined), a);
  assert.equal(attachName(a), 'App A');
  assert.equal(attachName(b), 'B');
  const err = (fn, code, re) => assert.throws(fn, (e) => e instanceof IosProfileError && e.exitCode === code && re.test(e.message));
  err(() => pickApp([a, b], undefined), 2, /several user apps are running; pick one with --app:\n {2}com\.example\.a \(App A, pid 1\)/);
  err(() => pickApp([a], 'Nope'), 1, /Nope is not running on the simulator; running: com\.example\.a/);
  err(() => pickApp([], undefined), 1, /no user app is running/);
  err(() => pickApp([a, { ...a, bundleId: 'com.example.a2' }], 'App A'), 2, /several running apps match App A/);
});

test('checkDevice and runningUserApps read simctl: booted check, user apps only, names from Info.plist', async () => {
  const r = rig();
  try {
    await withEnv(r, async () => {
      assert.deepEqual(await checkDevice(UDID), { udid: UDID, name: 'Test Phone', runtime: 'iOS-27-0' });
      await assert.rejects(checkDevice('OFF'), /is Shutdown, not booted/);
      await assert.rejects(checkDevice('NOPE'), (e) => e.exitCode === 1 && /no simulator with udid NOPE/.test(e.message));
      const apps = await runningUserApps(UDID);
      assert.deepEqual(apps.map((x) => [x.bundleId, x.pid, x.executable, x.displayName]), [['com.example.sample', 4242, 'SampleApp', 'Sample App']]);
    });
  } finally { r.done(); }
});

test('analyze + summarize on the synthetic export: samples, threads, hotspots, the hang, leaks not recorded', async () => {
  const r = rig();
  try {
    const result = await analyze({ cpu: join(r.fx, 'cpu.xml'), hangs: join(r.fx, 'hangs.xml'), leaks: null });
    const sum = summarize(result, { leaksRecorded: false });
    assert.deepEqual([sum.cpu.samples, sum.cpu.sampledMs], [100, 100]);
    assert.deepEqual(sum.cpu.threads.map((t) => [t.thread, t.samples]), [['Main Thread', 70], ['com.example.decoder', 30]]);
    const fns = sum.cpu.hotspots.map((h) => [h.function, h.samples, h.thread]);
    assert.deepEqual(fns.slice(0, 2), [['layoutRows()', 60, 'Main Thread'], ['decodeImage(Data)', 30, 'com.example.decoder']]);
    assert.equal(sum.cpu.hotspots[0].duringHang, true);
    assert.deepEqual(sum.hangs.map((h) => [h.type, h.ms]), [['Microhang', 300]]);
    assert.ok(sum.hangs[0].suspected.includes('layoutRows()'));
    assert.deepEqual(sum.leaks, { recorded: false });
    const text = formatSummary(sum);
    assert.match(text, /^CPU: 100 samples, 100 ms sampled \(Main Thread 70 ms, com\.example\.decoder 30 ms\)/);
    assert.match(text, /60\.0 ms {2}60\.0% {2}Main Thread \[during a hang\] {2}layoutRows\(\)/);
    assert.match(text, /UI hangs: 1\n {2}Microhang 300 ms at 00:01\.000 {2}suspected: layoutRows\(\)/);
    assert.match(text, /leaks: not recorded \(the Time Profiler template has no Leaks instrument; --leaks records them\)/);
  } finally { r.done(); }
});

test('summarize with the leaks template: counts, bytes, the unattributed one marked', async () => {
  const r = rig();
  try {
    writeFileSync(join(r.fx, 'none.xml'), noHangsXml());
    const result = await analyze({ cpu: join(r.fx, 'cpu.xml'), hangs: join(r.fx, 'none.xml'), leaks: join(r.fx, 'leaks.xml') });
    const sum = summarize(result, { leaksRecorded: true, top: 1 });
    assert.deepEqual([sum.leaks.count, sum.leaks.bytes, sum.cpu.hotspots.length], [3, 272, 1]);
    const text = formatSummary(sum);
    assert.match(text, /UI hangs: none/);
    assert.match(text, /leaks: 3 \(272 bytes\)\n {2}2 x SampleCache 256 bytes {2}makeCache\(\) \(SampleApp\.debug\.dylib\)$/m);
  } finally { r.done(); }
});

test('record: xctrace with the udid, the display name, the time limit and Time Profiler; exports kept, trace deleted', async () => {
  const r = rig();
  try {
    const sum = await withEnv(r, () => record({ udid: UDID, seconds: 5, outDir: r.out }));
    const rec = r.calls().find((c) => c[1] === 'record');
    assert.deepEqual(rec, ['xctrace', 'record', '--template', TIME_PROFILER, '--device', UDID, '--attach', 'Sample App', '--time-limit', '5s', '--output', join(r.out, 'native.trace'), '--no-prompt']);
    assert.deepEqual([sum.app.bundleId, sum.seconds, sum.cpu.samples, sum.hangs.length, sum.leaks.recorded], ['com.example.sample', 5, 100, 1, false]);
    assert.equal(existsSync(join(r.out, 'native.trace')), false);
    assert.deepEqual(readdirSync(r.out).sort(), ['native_raw_cpu.xml', 'native_raw_hangs.xml', SUMMARY_FILE].sort());
    assert.match(formatSummary(sum), /^Sample App \(com\.example\.sample, pid 4242\) on Test Phone, 5 s with Time Profiler\n/);
    const again = await reportDir(r.out);
    assert.deepEqual([again.cpu.samples, again.app.bundleId, again.leaks.recorded], [100, 'com.example.sample', false]);
  } finally { r.done(); }
});

test('record --leaks uses the vendored template; --keep-trace keeps the bundle', async () => {
  const r = rig({ exports: undefined });
  try {
    writeFileSync(r.env.FAKE_XCRUN_SCENARIO, JSON.stringify({ ...JSON.parse(readFileSync(r.env.FAKE_XCRUN_SCENARIO, 'utf8')),
      exports: { 'time-profile': join(r.fx, 'cpu.xml'), 'potential-hangs': join(r.fx, 'hangs.xml'), Leaks: join(r.fx, 'leaks.xml') } }));
    const sum = await withEnv(r, () => record({ udid: UDID, app: 'com.example.sample', seconds: 3, leaks: true, keepTrace: true, outDir: r.out }));
    const rec = r.calls().find((c) => c[1] === 'record');
    assert.match(rec[3], /vendor\/argent\/packages\/tool-server\/src\/utils\/ios-profiler\/Argent\.tracetemplate$/);
    assert.equal(existsSync(rec[3]), true);
    assert.deepEqual([sum.leaks.recorded, sum.leaks.count, sum.trace], [true, 3, join(r.out, 'native.trace')]);
    assert.equal(existsSync(join(r.out, 'native.trace')), true);
  } finally { r.done(); }
});

test('record: xctrace failure exits 1 with its message; a timeout and an ignored SIGINT still end xctrace (exit 3)', async () => {
  const r = rig({ record: { rc: 19, stderr: 'Cannot find process matching name: Sample App\n' } });
  try {
    await withEnv(r, () => assert.rejects(record({ udid: UDID, seconds: 1, outDir: r.out }),
      (e) => e.exitCode === 1 && /xctrace record failed \(exit 19\): .*Cannot find process matching name: Sample App/.test(e.message)));
  } finally { r.done(); }
  const t = rig({ record: { rc: 0, delayMs: 60_000 } });
  try {
    const started = Date.now();
    await withEnv(t, () => assert.rejects(record({ udid: UDID, seconds: 1, outDir: t.out, timeoutMs: 300 }),
      (e) => e.exitCode === 3 && /no result within --timeout \(0 s\): xctrace was stopped and nothing was exported/.test(e.message)));
    assert.ok(Date.now() - started < 10_000);
    assert.deepEqual(readdirSync(t.out), []);
  } finally { t.done(); }
});

test('record: a missing or unbooted device and a non-running app fail before xctrace starts', async () => {
  const r = rig();
  try {
    await withEnv(r, async () => {
      await assert.rejects(record({ udid: 'NOPE', outDir: r.out }), (e) => e.exitCode === 1 && /no simulator with udid NOPE/.test(e.message));
      await assert.rejects(record({ udid: UDID, app: 'Other', outDir: r.out }), (e) => e.exitCode === 1 && /Other is not running/.test(e.message));
    });
    assert.equal(r.calls().some((c) => c[1] === 'record'), false);
  } finally { r.done(); }
});

test('reportDir: a directory without exports, or no directory, exits 1', async () => {
  const r = rig();
  try {
    await assert.rejects(reportDir(r.out), (e) => e.exitCode === 1 && /holds no xctrace exports/.test(e.message));
    await assert.rejects(reportDir(join(r.dir, 'nope')), (e) => e.exitCode === 1 && /is not a directory/.test(e.message));
    assert.deepEqual(exportFiles(r.fx), { cpu: null, hangs: null, leaks: null });
  } finally { r.done(); }
});

const CLI = join(HERE, 'rn-profile.mjs');
function cli(r, args) {
  return new Promise((resolve) => {
    execFile(process.execPath, [CLI, ...args], { env: r.env, timeout: 30_000 }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout, stderr });
    });
  });
}
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

test('cli ios record prints the summary and where the exports are; ios report re-reads them', async () => {
  const r = rig();
  try {
    const out = join(r.out, 'run1');
    const a = await cli(r, ['ios', 'record', '--udid', UDID, '--seconds', '2', '--out', out, '--top', '2']);
    assert.equal(a.code, 0, a.stderr);
    assert.match(a.stdout, /^Sample App \(com\.example\.sample, pid 4242\) on Test Phone, 2 s with Time Profiler\nCPU: 100 samples/);
    assert.match(a.stdout, /hotspots \(functions with >= 3% of the samples, 2 of 3\)/);
    assert.match(a.stdout, new RegExp(`exports and summary\\.json in ${out}\n$`));
    const j = JSON.parse((await cli(r, ['ios', 'report', out, '--json'])).stdout);
    assert.deepEqual([j.cpu.samples, j.hangs.length], [100, 1]);
    const again = await cli(r, ['ios', 'record', '--udid', UDID, '--out', out]);
    assert.equal(again.code, 64);
    assert.match(again.stderr, /already holds a recording/);
    const dflt = await cli(r, ['ios', 'record', '--udid', UDID, '--seconds', '1', '--json']);
    const dir = JSON.parse(dflt.stdout).dir;
    assert.match(dir, /rn-profile-ios-/);
    rmSync(dir, { recursive: true, force: true });
  } finally { r.done(); }
});

test('cli ios: usage errors exit 64, a missing device 1, several apps 2', async () => {
  const r = rig({ launchctl: '1\t0\tUIKitApplication:com.example.sample[a]\n2\t0\tUIKitApplication:com.example.other[b]\n' });
  try {
    const sc = JSON.parse(readFileSync(r.env.FAKE_XCRUN_SCENARIO, 'utf8'));
    sc.containers['com.example.other'] = sc.containers['com.example.sample'].replace('/A/', '/B/');
    mkdirSync(sc.containers['com.example.other'], { recursive: true });
    writeFileSync(r.env.FAKE_XCRUN_SCENARIO, JSON.stringify(sc));
    for (const args of [['ios', 'record'], ['ios', 'record', '--udid', UDID, '--seconds', '0'], ['ios', 'record', '--udid', UDID, '--seconds', '601'],
      ['ios', 'record', '--udid', UDID, '--port', '8081'], ['ios', 'report'], ['ios', 'nope'], ['ios', 'record', '--udid', UDID, 'extra']]) {
      assert.equal((await cli(r, args)).code, 64, args.join(' '));
    }
    const missing = await cli(r, ['ios', 'record', '--udid', 'NOPE', '--out', join(r.out, 'x')]);
    assert.deepEqual([missing.code, /no simulator with udid NOPE/.test(missing.stderr)], [1, true]);
    assert.equal(existsSync(join(r.out, 'x')), false);
    const several = await cli(r, ['ios', 'record', '--udid', UDID, '--out', join(r.out, 'y')]);
    assert.equal(several.code, 2);
    assert.match(several.stderr, /several user apps are running; pick one with --app/);
    assert.equal((await cli(r, ['ios', 'report', join(r.out, 'none')])).code, 1);
  } finally { r.done(); }
});

test('cli ios record: Ctrl-C stops xctrace, leaves no process and exits 130', async () => {
  const r = rig({ record: { rc: 0, delayMs: 60_000 } });
  try {
    const child = spawn(process.execPath, [CLI, 'ios', 'record', '--udid', UDID, '--seconds', '60', '--out', r.out], { env: r.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', (b) => { stderr += b; });
    const pidFile = `${r.env.FAKE_XCRUN_SCENARIO}.pid`;
    for (let i = 0; i < 100 && !existsSync(pidFile); i++) await sleep(50);
    const xpid = Number(readFileSync(pidFile, 'utf8'));
    assert.equal(alive(xpid), true);
    child.kill('SIGINT');
    const code = await new Promise((res) => child.on('close', res));
    assert.equal(code, 130, stderr);
    assert.match(stderr, /interrupted: xctrace was stopped and nothing was exported/);
    assert.equal(alive(xpid), false);
    assert.deepEqual(readdirSync(r.out), []);
  } finally { r.done(); }
});

test('recordTrace: an xctrace that ignores SIGINT gets SIGTERM after the save grace', async () => {
  const r = rig({ record: { rc: 0, delayMs: 60_000, ignoreSigint: true } });
  try {
    const { recordTrace } = await import('./ios-profile.mjs');
    const res = await withEnv(r, () => recordTrace({ udid: UDID, name: 'Sample App', seconds: 60, template: TIME_PROFILER, tracePath: join(r.out, 't.trace'), timeoutMs: 100, saveGraceMs: 200 }));
    assert.deepEqual([res.ended, res.code], ['timeout', 143]);
    assert.ok(r.calls().some((c) => c[1] === 'record'));
    assert.equal(alive(Number(readFileSync(`${r.env.FAKE_XCRUN_SCENARIO}.pid`, 'utf8'))), false);
  } finally { r.done(); }
});

test('cli ios record: Ctrl-C or --timeout during the export kills the export, leaves no process, exports nothing', async () => {
  for (const [how, expect] of [['sigint', 130], ['timeout', 3]]) {
    const r = rig({ record: { rc: 0, delayMs: 50 }, exportDelayMs: 60_000 });
    try {
      const extra = how === 'timeout' ? ['--timeout', '2'] : [];
      const child = spawn(process.execPath, [CLI, 'ios', 'record', '--udid', UDID, '--seconds', '1', '--out', r.out, ...extra], { env: r.env, stdio: ['ignore', 'pipe', 'pipe'] });
      let stderr = '';
      child.stderr.on('data', (b) => { stderr += b; });
      const pidFile = `${r.env.FAKE_XCRUN_SCENARIO}.export.pid`;
      for (let i = 0; i < 200 && !existsSync(pidFile); i++) await sleep(50);
      const xpid = Number(readFileSync(pidFile, 'utf8'));
      if (how === 'sigint') child.kill('SIGINT');
      const code = await new Promise((res) => child.on('close', res));
      assert.equal(code, expect, `${how}: ${stderr}`);
      assert.match(stderr, /the export was stopped and nothing was exported/);
      await sleep(300);
      assert.equal(alive(xpid), false, how);
      assert.deepEqual(readdirSync(r.out), [], how);
    } finally { r.done(); }
  }
});

test('record: when every export fails, the reason is printed and the trace is kept', async () => {
  const r = rig({ exports: {} });
  try {
    await withEnv(r, () => assert.rejects(record({ udid: UDID, seconds: 1, outDir: r.out }), (e) => e.exitCode === 1
      && /export produced neither CPU samples nor hangs/.test(e.message)
      && /hangs: Export failed: no data for \/trace-toc/.test(e.message)
      && !/Command failed/.test(e.message)
      && e.message.includes(`the trace is kept at ${join(r.out, 'native.trace')}`)));
    assert.equal(existsSync(join(r.out, 'native.trace')), true);
  } finally { r.done(); }
});
