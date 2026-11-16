import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { startFakeInspector, fakeTarget, fakeRuntime, vmRuntime } from './devtools/testing/fake-inspector.mjs';
import { makeAppContext } from './devtools/testing/fake-app.mjs';

const CLI = fileURLToPath(new URL('./rn-devtools.mjs', import.meta.url));

function run(args, env = {}) {
  return new Promise((resolve) => {
    execFile(process.execPath, [CLI, ...args], { env: { ...process.env, METRO_PORT: '', ...env }, timeout: 20_000 }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout, stderr });
    });
  });
}

const handler = fakeRuntime({
  '1+1': { value: 2 },
  '"a"+"b"': { value: 'ab' },
  'void 0': { value: undefined },
  '({a: 1})': { value: { a: 1 } },
  'nope.x': { throws: "ReferenceError: Property 'nope' doesn't exist" },
  'hang': { hang: true },
  'later()': { resolve: { ok: true } },
  'forever()': { pending: true },
  '0/0': { unserializable: 'NaN' },
});

async function withMetro(targets, fn) {
  const fake = await startFakeInspector({ targets, handler });
  try { await fn(String(fake.port)); } finally { await fake.close(); }
}

const oneApp = (port) => [fakeTarget(port, { page: 1 }), fakeTarget(port, { page: 2 })];

test('eval prints the value as JSON and exits 0', () => withMetro(oneApp, async (port) => {
  const r = await run(['eval', '1+1', '--port', port]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, '2\n');
  assert.equal((await run(['eval', '"a"+"b"', '--port', port])).stdout, '"ab"\n');
  assert.equal((await run(['eval', 'void 0', '--port', port])).stdout, 'undefined\n');
  assert.equal((await run(['eval', '({a: 1})', '--port', port])).stdout, '{"a":1}\n');
}));

test('eval awaits a Promise; --no-await prints the Promise object; a never-settling one exits 3', () => withMetro(oneApp, async (port) => {
  assert.equal((await run(['eval', 'later()', '--port', port])).stdout, '{"ok":true}\n');
  assert.equal((await run(['eval', 'later()', '--port', port, '--no-await'])).stdout, '{"_h":0,"_i":0}\n');
  const r = await run(['eval', 'forever()', '--port', port, '--timeout', '0.3']);
  assert.equal(r.code, 3);
  assert.match(r.stderr, /did not settle within 300 ms/);
}));

test('a result JSON cannot carry exits 1 naming it', () => withMetro(oneApp, async (port) => {
  const r = await run(['eval', '0/0', '--port', port]);
  assert.equal(r.code, 1);
  assert.equal(r.stdout, '');
  assert.match(r.stderr, /The result is NaN, which JSON cannot carry/);
}));

test('the port comes from METRO_PORT when --port is absent', () => withMetro(oneApp, async (port) => {
  const r = await run(['eval', '1+1'], { METRO_PORT: port });
  assert.equal(r.code, 0, r.stderr);
}));

test('a JS exception exits 1 with the exception text on stderr', () => withMetro(oneApp, async (port) => {
  const r = await run(['eval', 'nope.x', '--port', port]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /ReferenceError: Property 'nope' doesn't exist/);
  assert.equal(r.stdout, '');
}));

test('no answer within --timeout exits 3 naming the timeout', () => withMetro(oneApp, async (port) => {
  const r = await run(['eval', 'hang', '--port', port, '--timeout', '0.3']);
  assert.equal(r.code, 3);
  assert.match(r.stderr, /within 300 ms/);
}));

test('two devices exit 2 listing them; --device then picks one', () => withMetro(
  (port) => [fakeTarget(port, { page: 1, device: 'iPhone A' }), fakeTarget(port, { page: 3, device: 'iPhone B', fusebox: true })],
  async (port) => {
    const r = await run(['eval', '1+1', '--port', port]);
    assert.equal(r.code, 2);
    assert.match(r.stderr, /refusing to guess[\s\S]*iPhone A[\s\S]*iPhone B/);
    assert.equal((await run(['eval', '1+1', '--port', port, '--device', 'iPhone B'])).code, 0);
  }));

test('a device that matches nothing exits 1 listing the existing targets', () => withMetro(oneApp, async (port) => {
  const r = await run(['eval', '1', '--port', port, '--device', 'no-such-device']);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /no-such-device[\s\S]*iPhone 17 Test/);
}));

test('Metro not listening exits 1 naming the port', async () => {
  const fake = await startFakeInspector();
  const port = String(fake.port);
  await fake.close();
  const r = await run(['eval', '1', '--port', port]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, new RegExp(`not answering on port ${port}`));
});

test('targets lists every page and marks the one commands use', () => withMetro(oneApp, async (port) => {
  const r = await run(['targets', '--port', port]);
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /^\* 1 \| com\.example\.app \| iPhone 17 Test \| React Native Bridgeless/m);
  assert.match(r.stdout, /^ {2}2 \| .*UI \[C\+\+ connection\]/m);
  const j = JSON.parse((await run(['targets', '--port', port, '--json'])).stdout);
  assert.equal(j.selected, '1');
  assert.equal(j.targets.length, 2);
}));

test('usage errors exit 64', async () => {
  assert.equal((await run(['bogus'])).code, 64);
  assert.equal((await run(['eval'])).code, 64);
  assert.equal((await run(['eval', '1', '--timeout', 'x'])).code, 64);
  assert.equal((await run(['eval', '1', '--bogus-flag'])).code, 64);
  assert.equal((await run(['eval', '1', '--port', 'abc'])).code, 64);
});

test('net: start, a second start, read with bodies, grep, redacted headers, JSON, stop, read after stop', async () => {
  const ctx = makeAppContext();
  const app = (code) => vm.runInContext(code, ctx);
  const fake = await startFakeInspector({ targets: oneApp, handler: vmRuntime(ctx) });
  const port = String(fake.port);
  try {
    const before = await run(['net', 'read', '--port', port]);
    assert.equal(before.code, 1);
    assert.match(before.stderr, /not running in the app[\s\S]*net start/);

    const s1 = await run(['net', 'start', '--port', port]);
    assert.equal(s1.code, 0, s1.stderr);
    assert.match(s1.stdout, /network log started/);
    const open = app('XMLHttpRequest.prototype.open');
    const s2 = await run(['net', 'start', '--port', port]);
    assert.match(s2.stdout, /already running in the app, 0 request\(s\) captured - nothing changed/);
    assert.equal(app('XMLHttpRequest.prototype.open'), open);

    await app('request("POST", "https://api.example.test/v1/search?query=yoga", JSON.stringify({ q: "yoga" }), { Authorization: "Bearer secret-token" })');
    await app('request("GET", "https://api.example.test/v1/other")');
    const r = await run(['net', 'read', '--port', port, '--grep', 'query=yoga', '--headers']);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /^1 request\(s\) shown, 1 matched, 2 captured/);
    assert.match(r.stdout, /POST 200 OK \d+ ms https:\/\/api\.example\.test\/v1\/search\?query=yoga/);
    assert.match(r.stdout, /> body \(12 chars\) \{"q":"yoga"\}/);
    assert.match(r.stdout, /< body \(\d+ chars, application\/json\)/);
    assert.doesNotMatch(r.stdout, /secret-token/);
    assert.match(r.stdout, /<redacted, 19 chars>/);
    const j = JSON.parse((await run(['net', 'read', '--port', port, '--json'])).stdout);
    assert.deepEqual(j.entries.map((e) => e.method), ['POST', 'GET']);
    assert.equal(j.entries[0].requestHeaders.authorization ?? j.entries[0].requestHeaders.Authorization, '<redacted, 19 chars>');

    const stop = await run(['net', 'stop', '--port', port]);
    assert.equal(stop.code, 0, stop.stderr);
    assert.match(stop.stdout, /fetch\/XHR put back \(5 function\(s\)\), 2 captured request\(s\) deleted/);
    assert.notEqual(app('XMLHttpRequest.prototype.open'), open);
    await app('request("GET", "https://api.example.test/v1/after-stop")');
    assert.equal((await run(['net', 'read', '--port', port])).code, 1);
    assert.match((await run(['net', 'stop', '--port', port])).stdout, /was not running/);
  } finally { await fake.close(); }
});

test('net: usage errors exit 64', async () => {
  assert.equal((await run(['net'])).code, 64);
  assert.equal((await run(['net', 'pause'])).code, 64);
  assert.equal((await run(['net', 'read', '--since', 'soon'])).code, 64);
  assert.equal((await run(['net', 'read', '--limit', '0'])).code, 64);
  assert.equal((await run(['net', 'read', '--grep', '('])).code, 64);
  assert.equal((await run(['net', 'start', '--full'])).code, 64);
});
