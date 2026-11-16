#!/usr/bin/env node
// vendor-drift.mjs - prove the vendored Argent files are what the NOTICE says.
//
// Usage:
//   vendor-drift.mjs --upstream DIR [--vendor DIR]
//
//   --upstream DIR  an Argent checkout at the commit named in the NOTICE
//                   (default: $ARGENT_UPSTREAM). Read only; nothing is fetched.
//   --vendor DIR    the vendor directory (default: ./vendor/argent next to this file)
//
// Checks, in order:
//   1. every file in the vendor directory (besides LICENSE.txt and NOTICE) is
//      listed in the NOTICE's "Copied files" section, and every listed file exists
//   2. each listed file marked "unmodified" is byte-identical to <upstream>/<path>
//   3. LICENSE.txt is byte-identical to <upstream>/LICENSE.txt
// Exit 0 = no drift; 1 = drift (every difference listed); 64 = usage.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const OWN_FILES = new Set(['LICENSE.txt', 'NOTICE']);

/** The "Copied files" entries of a NOTICE: [{ path, change }]. */
export function parseNotice(text) {
  const start = text.indexOf('Copied files (path | change):');
  if (start < 0) throw new Error('NOTICE has no "Copied files (path | change):" section');
  const entries = [];
  for (const line of text.slice(start).split('\n').slice(1)) {
    const m = /^- (\S+) \| (.+)$/.exec(line.trim());
    if (m) entries.push({ path: m[1], change: m[2].trim() });
  }
  return entries;
}

function walk(dir, root = dir, out = []) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, root, out);
    else out.push(relative(root, full).split(sep).join('/'));
  }
  return out;
}

const same = (a, b) => existsSync(a) && existsSync(b) && readFileSync(a).equals(readFileSync(b));

/** Returns a list of problems (empty = no drift). */
export function checkDrift({ vendor, upstream }) {
  const problems = [];
  const notice = readFileSync(join(vendor, 'NOTICE'), 'utf8');
  const entries = parseNotice(notice);
  const listed = new Set(entries.map((e) => e.path));
  const onDisk = walk(vendor).filter((p) => !OWN_FILES.has(p) && !p.endsWith('.DS_Store'));

  for (const p of onDisk) if (!listed.has(p)) problems.push(`not listed in NOTICE: ${p}`);
  for (const e of entries) {
    const mine = join(vendor, e.path);
    if (!existsSync(mine)) { problems.push(`listed in NOTICE but missing: ${e.path}`); continue; }
    if (e.change !== 'unmodified') continue;
    const theirs = join(upstream, e.path);
    if (!existsSync(theirs)) problems.push(`not in upstream: ${e.path}`);
    else if (!same(mine, theirs)) problems.push(`differs from upstream: ${e.path}`);
  }
  if (!same(join(vendor, 'LICENSE.txt'), join(upstream, 'LICENSE.txt'))) problems.push('LICENSE.txt differs from upstream (or is missing)');
  return { problems, checked: entries.length };
}

function main(argv) {
  let values;
  try {
    ({ values } = parseArgs({ args: argv, options: { upstream: { type: 'string' }, vendor: { type: 'string' } }, strict: true }));
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    return 64;
  }
  const upstream = values.upstream ?? process.env.ARGENT_UPSTREAM;
  if (!upstream) {
    process.stderr.write('vendor-drift.mjs: pass --upstream <Argent checkout at the NOTICE commit> (or set ARGENT_UPSTREAM)\n');
    return 64;
  }
  if (!existsSync(join(upstream, 'LICENSE.txt'))) {
    process.stderr.write(`vendor-drift.mjs: ${upstream} does not look like an Argent checkout (no LICENSE.txt)\n`);
    return 64;
  }
  const vendor = values.vendor ?? join(HERE, 'vendor', 'argent');
  const { problems, checked } = checkDrift({ vendor, upstream });
  if (problems.length) {
    process.stdout.write(`DRIFT in ${vendor} against ${upstream}:\n${problems.map((p) => `  ${p}`).join('\n')}\n`);
    return 1;
  }
  process.stdout.write(`no drift: ${checked} vendored file(s) + LICENSE.txt match ${upstream}\n`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) process.exitCode = main(process.argv.slice(2));
