import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, readFileSync, rmSync, existsSync, writeFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { startFakeInspector, fakeTarget } from '../../simulator-verify/scripts/devtools/testing/fake-inspector.mjs';
import { fakeReactApp } from './testing/fake-react-app.mjs';

const CLI = fileURLToPath(new URL('./rn-profile.mjs', import.meta.url));

function run(args) {
  return new Promise((resolve) => {
    execFile(process.execPath, [CLI, ...args], { env: { ...process.env, METRO_PORT: '' }, timeout: 20_000 }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout, stderr });
    });
  });
}

// The fake inspector answers Runtime.evaluate from the vm app and Profiler.* from its sampler.
function appHandler(app) {
  return async (msg) => {
    const { method, params = {} } = msg;
    if (method === 'Runtime.evaluate') {
      let v;
      try { v = await app.client.evaluate(params.expression); } catch (err) {
        return { result: { type: 'object' }, exceptionDetails: { text: 'Uncaught', exception: { description: String(err) } } };
      }
      return v === undefined ? { result: { type: 'undefined' } } : { result: { type: typeof v, value: v } };
    }
    if (method.startsWith('Profiler.')) {
      try { return await app.client.send(method, params); } catch (err) { return { error: { code: err.code ?? -32000, message: err.message } }; }
    }
    return {};
  };
}

async function withApp(app, fn) {
  const fake = await startFakeInspector({ targets: (port) => [fakeTarget(port)], handler: appHandler(app) });
  const dir = mkdtempSync(join(tmpdir(), 'rn-profile-test-'));
  try { await fn(String(fake.port), dir); } finally { await fake.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('the whole cycle against one app', async () => {
  const app = fakeReactApp();
  await withApp(app, async (port, dir) => {
    const start = await run(['react', 'start', '--port', port, '--max', '30']);
    assert.equal(start.code, 0, start.stderr);
    assert.match(start.stdout, /recording React commits and CPU samples; it ends by itself after 30\.0 s/);
    const again = await run(['react', 'start', '--port', port]);
    assert.match(again.stdout, /already recording for \d+\.\d s \(limit 30\.0 s\) - nothing changed/);
    assert.match((await run(['react', 'status', '--port', port])).stdout, /^recording for \d+\.\d s \(limit 30\.0 s\)/);
    app.run('commit([[1, 3, 1], [2, 2, 1.5]], 4); commit([[2, 1, 1]], 1)');
    const out = join(dir, 'p.json');
    const stop = await run(['react', 'stop', '--port', port, '--out', out]);
    assert.equal(stop.code, 0, stop.stderr);
    assert.match(stop.stdout, /^recorded \d+\.\d s \(ended by stop\)\nReact commits: 2, total commit time 5 ms, slowest 4 ms/);
    assert.match(stop.stdout, /Top components by renders \(2 rendered\):\n +2 {2}ListScreen/);
    assert.match(stop.stdout, new RegExp(`profile written to ${out.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
    const profile = JSON.parse(readFileSync(out, 'utf8'));
    assert.equal(profile.format, 'rn-profile-react/1');
    assert.equal(profile.react.dataForRoots[0].commitData.length, 2);
    assert.equal(app.sampler.running, false);
    const after = await run(['react', 'stop', '--port', port, '--out', join(dir, 'q.json')]);
    assert.equal(after.code, 1);
    assert.match(after.stderr, /No recording in the app/);
    assert.equal((await run(['react', 'status', '--port', port])).stdout, 'not recording\n');
  });
});

test('a recording ended by its time limit: status says so, stop returns it with --json', async () => {
  const app = fakeReactApp();
  await withApp(app, async (port, dir) => {
    assert.equal((await run(['react', 'start', '--port', port, '--max', '0.2'])).code, 0);
    app.run('commit([[3, 1, 1]], 1)');
    await sleep(400);
    assert.match((await run(['react', 'status', '--port', port])).stdout, /ended by its 0\.2 s time limit and waits for `react stop/);
    const stop = await run(['react', 'stop', '--port', port, '--out', join(dir, 'p.json'), '--json']);
    assert.equal(stop.code, 0, stop.stderr);
    const sum = JSON.parse(stop.stdout);
    assert.deepEqual([sum.endedBy, sum.commits, sum.byRenders[0].name], ['time-limit', 1, 'Row']);
  });
});

test('an --out that cannot be written fails before the recording is consumed', async () => {
  const app = fakeReactApp();
  await withApp(app, async (port, dir) => {
    await run(['react', 'start', '--port', port]);
    const bad = await run(['react', 'stop', '--port', port, '--out', join(dir, 'missing-dir', 'p.json')]);
    assert.equal(bad.code, 64);
    assert.match(bad.stderr, /cannot write --out/);
    assert.match((await run(['react', 'status', '--port', port])).stdout, /^recording for/);
    assert.ok(!existsSync(join(dir, 'missing-dir')));
  });
});

test('a failed stop leaves an existing --out file as it was and creates none', async () => {
  const app = fakeReactApp();
  await withApp(app, async (port, dir) => {
    const old = join(dir, 'old.json');
    writeFileSync(old, '{"kept":true}');
    const res = await run(['react', 'stop', '--port', port, '--out', old]);
    assert.equal(res.code, 1);
    assert.equal(readFileSync(old, 'utf8'), '{"kept":true}');
    assert.equal((await run(['react', 'stop', '--port', port, '--out', join(dir, 'new.json')])).code, 1);
    assert.deepEqual(readdirSync(dir), ['old.json']);
    assert.equal((await run(['react', 'stop', '--port', port, '--out', dir])).code, 64, 'a directory is refused');
  });
});

test('usage errors exit 64; no Metro exits 1', async () => {
  for (const args of [['react'], ['react', 'pause'], ['cpu', 'start'], ['react', 'stop'], ['react', 'start', '--max', '0'],
    ['react', 'start', '--max', '601'], ['react', 'start', '--interval-us', '1.5'], ['react', 'stop', '--out', 'x', '--top', '0'], ['react', 'status', '--bogus']]) {
    assert.equal((await run(args)).code, 64, args.join(' '));
  }
  const none = await run(['react', 'status', '--port', '1']);
  assert.equal(none.code, 1);
});
