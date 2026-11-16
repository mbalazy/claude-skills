import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startFakeInspector, fakeTarget, fakeRuntime } from './devtools/testing/fake-inspector.mjs';

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
  (port) => [fakeTarget(port, { page: 1, device: 'iPhone A' }), fakeTarget(port, { page: 3, device: 'iPhone B' })],
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
