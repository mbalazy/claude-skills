import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, cpSync, rmSync, appendFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseNotice, checkDrift } from './vendor-drift.mjs';
import { addVendorRoot } from './vendor-loader.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const DRIFT = join(HERE, 'vendor-drift.mjs');
const REAL_VENDOR = join(HERE, 'vendor', 'argent');

function write(path, text) { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, text); }

/** A fake upstream checkout and a vendor dir holding one unmodified copy of it. */
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'vendor-drift-'));
  const upstream = join(root, 'upstream');
  const vendor = join(root, 'vendor');
  write(join(upstream, 'LICENSE.txt'), 'Apache License 2.0 (test copy)\n');
  write(join(upstream, 'packages/x/src/a.ts'), 'export const a = 1;\n');
  write(join(vendor, 'LICENSE.txt'), 'Apache License 2.0 (test copy)\n');
  write(join(vendor, 'packages/x/src/a.ts'), 'export const a = 1;\n');
  write(join(vendor, 'NOTICE'), 'header\n\nCopied files (path | change):\n- packages/x/src/a.ts | unmodified\n');
  return { root, upstream, vendor, done: () => rmSync(root, { recursive: true, force: true }) };
}

function run(args) {
  return new Promise((resolve) => execFile(process.execPath, [DRIFT, ...args], { env: { ...process.env, ARGENT_UPSTREAM: '' } }, (err, stdout, stderr) =>
    resolve({ code: err ? err.code : 0, stdout, stderr })));
}

test('parseNotice reads the copied-files list', () => {
  assert.deepEqual(parseNotice('x\nCopied files (path | change):\n- a/b.ts | unmodified\n- c.ts | renamed export\n\n'), [
    { path: 'a/b.ts', change: 'unmodified' },
    { path: 'c.ts', change: 'renamed export' },
  ]);
  assert.throws(() => parseNotice('no section'), /Copied files/);
});

test('no drift: exit 0', async (t) => {
  const f = fixture(); t.after(f.done);
  assert.deepEqual(checkDrift(f).problems, []);
  const r = await run(['--upstream', f.upstream, '--vendor', f.vendor]);
  assert.equal(r.code, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /no drift: 1 vendored file/);
});

test('an altered vendored file is drift: exit 1 naming it', async (t) => {
  const f = fixture(); t.after(f.done);
  appendFileSync(join(f.vendor, 'packages/x/src/a.ts'), '// local edit\n');
  const r = await run(['--upstream', f.upstream, '--vendor', f.vendor]);
  assert.equal(r.code, 1);
  assert.match(r.stdout, /differs from upstream: packages\/x\/src\/a\.ts/);
});

test('an unlisted file, a missing listed file and a changed LICENSE are each reported', (t) => {
  const f = fixture(); t.after(f.done);
  write(join(f.vendor, 'packages/x/src/extra.ts'), 'export {};\n');
  appendFileSync(join(f.vendor, 'NOTICE'), '- packages/x/src/gone.ts | unmodified\n');
  appendFileSync(join(f.vendor, 'LICENSE.txt'), 'edited\n');
  const { problems } = checkDrift(f);
  assert.ok(problems.includes('not listed in NOTICE: packages/x/src/extra.ts'), problems.join('\n'));
  assert.ok(problems.includes('listed in NOTICE but missing: packages/x/src/gone.ts'), problems.join('\n'));
  assert.ok(problems.some((p) => p.startsWith('LICENSE.txt differs')), problems.join('\n'));
});

test('a file marked as changed is not compared byte for byte, but must exist', (t) => {
  const f = fixture(); t.after(f.done);
  write(join(f.vendor, 'NOTICE'), 'Copied files (path | change):\n- packages/x/src/a.ts | trimmed to one export\n');
  appendFileSync(join(f.vendor, 'packages/x/src/a.ts'), '// changed on purpose\n');
  assert.deepEqual(checkDrift(f).problems, []);
});

test('run through a symlinked directory (as an installed skill is), it still checks', async (t) => {
  const f = fixture(); t.after(f.done);
  appendFileSync(join(f.vendor, 'packages/x/src/a.ts'), '// local edit\n');
  const link = join(f.root, 'linked-devtools');
  symlinkSync(HERE, link);
  const r = await new Promise((resolve) => execFile(process.execPath, [join(link, 'vendor-drift.mjs'), '--upstream', f.upstream, '--vendor', f.vendor],
    (err, stdout, stderr) => resolve({ code: err ? err.code : 0, stdout, stderr })));
  assert.equal(r.code, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /differs from upstream/);
});

test('without --upstream or ARGENT_UPSTREAM it is a usage error', async () => {
  assert.equal((await run([])).code, 64);
  assert.equal((await run(['--upstream', tmpdir() + '/definitely-not-argent'])).code, 64);
});

test('the real vendor directory carries LICENSE.txt and a NOTICE naming the source and commit', async (t) => {
  const { readFileSync } = await import('node:fs');
  const notice = readFileSync(join(REAL_VENDOR, 'NOTICE'), 'utf8');
  assert.match(notice, /https:\/\/github\.com\/software-mansion\/argent/);
  assert.match(notice, /8cd8fe1e3f344be04f3e571cb99656af2d9fe1e1/);
  assert.match(readFileSync(join(REAL_VENDOR, 'LICENSE.txt'), 'utf8'), /Apache License\s+Version 2\.0/);
  // Every listed file exists and nothing unlisted is there (the byte comparison
  // needs an upstream checkout; the live check runs it against one).
  const root = mkdtempSync(join(tmpdir(), 'vendor-real-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  cpSync(REAL_VENDOR, root, { recursive: true });
  const problems = checkDrift({ vendor: REAL_VENDOR, upstream: root }).problems;
  assert.deepEqual(problems, []);
});

test('the loader imports vendored TypeScript with extensionless relative imports', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'vendor-loader-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  write(join(root, 'pkg/a.ts'), 'import { b } from "./b";\nimport { c } from "./sub";\nimport type { T } from "./types";\nexport const a = (x: number): number => b(x) + c;\n');
  write(join(root, 'pkg/b.ts'), 'export function b(x: number): number { return x * 10; }\n');
  write(join(root, 'pkg/sub/index.ts'), 'export const c: number = 3;\n');
  addVendorRoot(root);
  const mod = await import(pathToFileURL(join(root, 'pkg/a.ts')).href);
  assert.equal(mod.a(4), 43);
});

test('outside a vendor root the loader changes nothing', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'not-vendor-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  write(join(root, 'a.ts'), 'import { b } from "./b";\nexport const a = b;\n');
  write(join(root, 'b.ts'), 'export const b = 1;\n');
  await assert.rejects(import(pathToFileURL(join(root, 'a.ts')).href), { code: 'ERR_MODULE_NOT_FOUND' });
});
