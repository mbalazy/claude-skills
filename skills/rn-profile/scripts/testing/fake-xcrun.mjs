#!/usr/bin/env node
// fake-xcrun.mjs - for tests only: stands in for `xcrun` (simctl, xctrace) and
// for `xctrace` itself when linked under those names in a directory put first
// in PATH. Behaviour comes from the JSON file $FAKE_XCRUN_SCENARIO:
//   devices    `simctl list devices -j` payload
//   launchctl  `simctl spawn <udid> launchctl list` output
//   containers bundle id -> app path (`simctl get_app_container`)
//   record     { rc, delayMs, ignoreSigint, output } for `xctrace record`
//   exports    schema / track name -> file to copy for `xctrace export --xpath`
//   exportDelayMs  how long each export takes
// Every call is appended to $FAKE_XCRUN_SCENARIO.log as one JSON line.
import { readFileSync, appendFileSync, mkdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';

const sc = JSON.parse(readFileSync(process.env.FAKE_XCRUN_SCENARIO, 'utf8'));
let args = process.argv.slice(2);
if (basename(process.argv[1]) === 'xctrace') args = ['xctrace', ...args];
appendFileSync(`${process.env.FAKE_XCRUN_SCENARIO}.log`, `${JSON.stringify(args)}\n`);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const fail = (msg, code = 1) => { process.stderr.write(`${msg}\n`); process.exit(code); };

if (args[0] === 'simctl') {
  if (args[1] === 'list') { process.stdout.write(JSON.stringify(sc.devices)); process.exit(0); }
  if (args[1] === 'spawn') { process.stdout.write(sc.launchctl ?? ''); process.exit(0); }
  if (args[1] === 'get_app_container') {
    const p = sc.containers?.[args[3]];
    if (!p) fail('No such file or directory', 2);
    process.stdout.write(`${p}\n`);
    process.exit(0);
  }
  fail(`fake simctl: ${args.join(' ')}`);
}

if (args[0] === 'xctrace' && args[1] === 'record') {
  const r = sc.record ?? {};
  const out = opt('--output');
  writeFileSync(`${process.env.FAKE_XCRUN_SCENARIO}.pid`, String(process.pid));
  const save = () => { mkdirSync(out, { recursive: true }); writeFileSync(`${out}/fake`, 'trace'); };
  process.stdout.write(r.output ?? 'Starting recording\n');
  process.on('SIGINT', () => { if (r.ignoreSigint) return; save(); process.exit(0); });
  process.on('SIGTERM', () => { if (r.ignoreSigterm) return; process.exit(143); });
  setTimeout(() => {
    if ((r.rc ?? 0) === 0) save(); else process.stderr.write(r.stderr ?? 'Cannot find process matching name\n');
    process.exit(r.rc ?? 0);
  }, r.delayMs ?? 0);
} else if (args[0] === 'xctrace' && args[1] === 'export') {
  const exports = sc.exports ?? {};
  if (args.includes('--toc')) {
    process.stdout.write(`<trace-toc>${Object.keys(exports).map((s) => `<table schema="${s}"/>`).join('')}</trace-toc>`);
    process.exit(0);
  }
  const xpath = opt('--xpath') ?? '';
  const key = xpath.match(/schema="([^"]+)"/)?.[1] ?? xpath.match(/track\[@name="([^"]+)"\]/)?.[1];
  writeFileSync(`${process.env.FAKE_XCRUN_SCENARIO}.export.pid`, String(process.pid));
  setTimeout(() => {
    if (!exports[key]) fail(`Export failed: no data for ${xpath}`);
    copyFileSync(exports[key], opt('--output'));
    process.exit(0);
  }, sc.exportDelayMs ?? 0);
} else if (args[0] !== 'xctrace') {
  fail(`fake xcrun: ${args.join(' ')}`);
}
