import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startFakeInspector, fakeTarget, fakeRuntime, withTreeScript } from './devtools/testing/fake-inspector.mjs';

const CLI = fileURLToPath(new URL('./rn-devtools.mjs', import.meta.url));

function run(args, env = {}, nodeFlags = []) {
  return new Promise((resolve) => {
    execFile(process.execPath, [...nodeFlags, CLI, ...args], { env: { ...process.env, METRO_PORT: '', ...env }, timeout: 20_000 }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout, stderr });
    });
  });
}

const runtime = fakeRuntime({
  '1+1': { value: 2 },
  '"a"+"b"': { value: 'ab' },
  'void 0': { value: undefined },
  '({a: 1})': { value: { a: 1 } },
  'nope.x': { throws: "ReferenceError: Property 'nope' doesn't exist" },
  'hang': { hang: true },
  'later()': { resolve: { ok: true } },
  'forever()': { pending: true },
  '0/0': { unserializable: 'NaN' },
  'throw new Error("x")': { throws: 'Error: x\n    at global (:1:7)' },
});

// A synthetic screen for the tree command.
const SCREEN = { screenW: 400, screenH: 800, components: [
  { id: 0, name: 'Screen', rect: { x: 0, y: 0, w: 400, h: 800 }, parentIdx: -1, testID: 'Main-root' },
  { id: 1, name: 'Header', rect: { x: 0, y: 0, w: 400, h: 100 }, parentIdx: 0, testID: 'Main-header' },
  { id: 2, name: 'Text', rect: { x: 10, y: 10, w: 200, h: 40 }, parentIdx: 1, text: 'Hello there' },
  { id: 3, name: 'Button', rect: { x: 20, y: 600, w: 100, h: 40 }, parentIdx: 0, testID: 'Main-go', accLabel: 'Go' },
] };
let treeAnswer = SCREEN;
const handler = (msg, session) => withTreeScript(treeAnswer, runtime)(msg, session);

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

test('eval of a thrown error exits 1 with its message', () => withMetro(oneApp, async (port) => {
  const r = await run(['eval', 'throw new Error("x")', '--port', port]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /^Error: x/);
}));

test('tree prints the component tree with testIDs, text and tap points', () => withMetro(oneApp, async (port) => {
  const r = await run(['tree', '--port', port]);
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /^Screen: 400x800 pt/);
  assert.match(r.stdout, /\nScreen \[testID=Main-root\] \(tap 200,400\)\n {2}Header \[testID=Main-header\]/);
  assert.match(r.stdout, /\n {4}Text "Hello there" \(tap 110,30\)/);
  assert.match(r.stdout, /\n {2}Button "Go" \[testID=Main-go\] \(tap 70,620\)/);
}));

test('tree filters: --grep with ancestors, --id exact, --ids a plain list, --json machine-readable', () => withMetro(oneApp, async (port) => {
  const g = await run(['tree', '--port', port, '--grep', 'hello']);
  assert.equal(g.code, 0, g.stderr);
  assert.doesNotMatch(g.stdout, /Main-go/);
  assert.match(g.stdout, /Main-root[\s\S]*Main-header[\s\S]*Hello there/);
  const id = await run(['tree', '--port', port, '--id', 'Main-go']);
  assert.doesNotMatch(id.stdout, /Main-header/);
  assert.match(id.stdout, /Main-go/);
  assert.equal((await run(['tree', '--port', port, '--ids'])).stdout, 'Main-go\nMain-header\nMain-root\n');
  assert.equal((await run(['tree', '--port', port, '--ids', '--id', 'nope'])).stdout, '');
  assert.equal((await run(['tree', '--port', port, '--ids', '--id', 'Main-go'])).stdout, 'Main-go\n');
  assert.equal((await run(['tree', '--port', port, '--ids', '--grep', '^Main-(go|header)$'])).stdout, 'Main-go\nMain-header\n');
  const j = JSON.parse((await run(['tree', '--port', port, '--json', '--id', 'Main-go'])).stdout);
  assert.deepEqual(j.nodes.map((n) => n.testID), ['Main-root', 'Main-go']);
  assert.match((await run(['tree', '--port', port, '--id', 'nope'])).stdout, /nothing matches the filter/);
}));

test('tree: a script error exits 1, no answer exits 3, bad options exit 64', async () => {
  treeAnswer = { error: 'No DevTools hook' };
  try {
    await withMetro(oneApp, async (port) => {
      const r = await run(['tree', '--port', port]);
      assert.equal(r.code, 1);
      assert.match(r.stderr, /No DevTools hook/);
    });
    treeAnswer = null;
    await withMetro(oneApp, async (port) => {
      const r = await run(['tree', '--port', port, '--timeout', '0.3']);
      assert.equal(r.code, 3);
      assert.match(r.stderr, /within 300 ms/);
    });
  } finally { treeAnswer = SCREEN; }
  assert.equal((await run(['tree', '--max-nodes', '0'])).code, 64);
  assert.equal((await run(['tree', '--grep', '('])).code, 64);
  assert.equal((await run(['tree', '--ids', '--json'])).code, 64);
  assert.equal((await run(['tree', 'extra'])).code, 64);
});

test('targets and eval work on a Node without TypeScript support; only tree needs it', () => withMetro(oneApp, async (port) => {
  const off = ['--no-experimental-strip-types'];
  const e = await run(['eval', '1+1', '--port', port], {}, off);
  assert.equal(e.code, 0, e.stderr);
  assert.equal(e.stdout, '2\n');
  assert.equal((await run(['targets', '--port', port], {}, off)).code, 0);
  const t = await run(['tree', '--port', port], {}, off);
  assert.equal(t.code, 1);
  assert.match(t.stderr, /cannot run TypeScript/);
}));
