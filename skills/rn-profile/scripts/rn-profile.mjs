#!/usr/bin/env node
// rn-profile.mjs - profile a running React Native app (development build)
// from the command line. Node built-ins only; talks to the app's JS runtime
// over Metro's CDP inspector through simulator-verify's shared devtools code.
//
//   rn-profile.mjs react start  [target options] [--max S] [--interval-us N] [--takeover]
//   rn-profile.mjs react status [target options] [--json]
//   rn-profile.mjs react stop --out FILE [target options] [--top N] [--json]
//   rn-profile.mjs ios record --udid UDID [--app NAME] [--seconds N] [--leaks]
//                             [--out DIR] [--keep-trace] [--timeout S] [--top N] [--json]
//   rn-profile.mjs ios report DIR [--top N] [--json]
//
// Target options (as simulator-verify's rn-devtools.mjs): --port (default
// $METRO_PORT, else 8081), --device, --app, --page, --timeout S (default 10).
//
// react start begins a React profiler recording (every commit, with per-
// component render times) plus Hermes's CPU sampler (--interval-us, default
// 1000). It ends by itself after --max seconds (default 60, at most 600);
// stop still returns what was recorded up to then (the CPU sampler runs on
// until stop: the app cannot stop it). A second start while
// recording changes nothing; a recording another tool holds is refused unless
// --takeover. react status says whether a recording runs and for how long.
// react stop ends the recording, writes the whole profile as JSON to --out
// and prints a summary: commit count, total and slowest commit, the top
// components (--top, default 10) by renders and by self time. A JS reload
// loses a recording; stop then exits 1.
//
// ios record profiles the app's native side on the simulator --udid names
// (booted; never "booted" or a default): xctrace's Time Profiler for --seconds
// (default 15, at most 600), attached to the app by its display name (--app =
// bundle id, executable or display name; needed when several user apps run).
// It waits for xctrace, exports CPU samples and UI hangs into --out (default a
// new temp dir), deletes the .trace bundle unless --keep-trace, and prints the
// samples per thread, the hotspot functions (--top, default 10), the hangs and
// leaks. --leaks records with Argent's template (Allocations + Leaks), which
// leaves malloc stack logging on in the app until it is relaunched. --timeout
// (default --seconds + 90, export included) or Ctrl-C stops xctrace (SIGINT,
// then SIGTERM, then SIGKILL) or kills a running export, and exports nothing. ios report re-reads the exports in a DIR.
//
// Exit codes: 0 done; 1 nothing to talk to, no React DevTools hook (release
// build), nothing recording, another tool holds the profiler, no such booted
// simulator, the app not running, or xctrace failed; 2 ambiguous target or
// several apps; 3 no answer within --timeout; 64 usage; 130 interrupted.

import { parseArgs } from 'node:util';
import { writeFileSync, renameSync, accessSync, constants, existsSync, statSync, mkdirSync, mkdtempSync, readdirSync, rmdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { withRuntime, UsageError } from '../../simulator-verify/scripts/devtools/runtime.mjs';
import {
  startRecording, recordingStatus, stopRecording, summarize, formatSummary,
  DEFAULT_MAX_SECONDS, MAX_SECONDS_CAP, DEFAULT_INTERVAL_US,
} from './react-profile.mjs';

const TARGET_OPTIONS = {
  port: { type: 'string' },
  device: { type: 'string' },
  app: { type: 'string' },
  page: { type: 'string' },
  timeout: { type: 'string' },
};

function positiveNumber(name, value, { integer = false, max } = {}) {
  const n = Number(value);
  if (!(n > 0) || (integer && !Number.isInteger(n)) || (max !== undefined && n > max)) {
    throw new UsageError(`--${name} wants ${integer ? 'a whole number' : 'a number'} > 0${max !== undefined ? ` and <= ${max}` : ''}, got ${value}`);
  }
  return n;
}

function targetOpts(values) {
  return {
    port: values.port, device: values.device, app: values.app, page: values.page,
    timeoutMs: values.timeout === undefined ? undefined : Math.round(positiveNumber('timeout', values.timeout) * 1000),
  };
}

function parse(args, options) {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, strict: true, options: { ...TARGET_OPTIONS, ...options } });
  if (positionals.length) throw new UsageError(`unexpected argument: ${positionals.join(' ')}`);
  return values;
}

const secs = (ms) => `${(ms / 1000).toFixed(1)} s`;

async function reactStart(args) {
  const values = parse(args, { max: { type: 'string' }, 'interval-us': { type: 'string' }, takeover: { type: 'boolean' } });
  const maxSeconds = values.max === undefined ? DEFAULT_MAX_SECONDS : positiveNumber('max', values.max, { max: MAX_SECONDS_CAP });
  const intervalUs = values['interval-us'] === undefined ? DEFAULT_INTERVAL_US : positiveNumber('interval-us', values['interval-us'], { integer: true });
  const opts = targetOpts(values);
  const res = await withRuntime(opts, (client) => startRecording(client, { maxSeconds, intervalUs, takeover: values.takeover, timeoutMs: opts.timeoutMs }));
  if (res.already) {
    const elapsed = res.nowEpochMs - res.session.startedAtEpochMs;
    console.log(`already recording for ${secs(elapsed)} (limit ${secs(res.session.maxMs)}) - nothing changed`);
    return 0;
  }
  if (res.discarded) console.log(`note: an earlier recording that was never stopped (${res.discarded === 'time-limit' ? 'ended by its time limit' : res.discarded === 'stop' ? 'its stop did not finish' : 'stopped by another tool'}) was dropped`);
  console.log(`recording React commits and CPU samples; it ends by itself after ${secs(res.session.maxMs)} - run \`react stop --out FILE\``);
  return 0;
}

async function reactStatus(args) {
  const values = parse(args, { json: { type: 'boolean' } });
  const opts = targetOpts(values);
  const st = await withRuntime(opts, (client) => recordingStatus(client, opts));
  if (values.json) {
    process.stdout.write(`${JSON.stringify(st)}\n`);
    return 0;
  }
  if (st.recording) {
    console.log(`recording for ${secs(st.nowEpochMs - st.session.startedAtEpochMs)} (limit ${secs(st.session.maxMs)})`);
  } else if (st.session?.endedBy === 'time-limit') {
    console.log(`not recording: the recording ended by its ${secs(st.session.maxMs)} time limit and waits for \`react stop --out FILE\``);
  } else if (st.otherOwner) {
    console.log(`not recording here; React is being profiled by ${st.otherOwner}`);
  } else if (st.session) {
    console.log('not recording: the recording was stopped by another tool; `react stop` reads what is left');
  } else {
    console.log('not recording');
  }
  return 0;
}

async function reactStop(args) {
  const values = parse(args, { out: { type: 'string' }, top: { type: 'string' }, json: { type: 'boolean' } });
  if (!values.out) throw new UsageError('react stop needs --out FILE (the profile is written there)');
  const top = values.top === undefined ? 10 : positiveNumber('top', values.top, { integer: true });
  const opts = targetOpts(values);
  const out = resolve(values.out);
  // Stop hands the data over once: a place that cannot be written must fail before it,
  // without touching a file already there.
  try {
    accessSync(dirname(out), constants.W_OK);
    if (existsSync(out) && (statSync(out).isDirectory() || (accessSync(out, constants.W_OK), false))) throw new Error('it is a directory');
  } catch (err) { throw new UsageError(`cannot write --out ${out}: ${err.message}`); }
  const profile = await withRuntime(opts, (client) => stopRecording(client, opts));
  const tmp = `${out}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(profile));
  renameSync(tmp, out);
  const sum = summarize(profile, { top });
  if (values.json) {
    process.stdout.write(`${JSON.stringify({ file: out, ...sum })}\n`);
  } else {
    process.stdout.write(`${formatSummary(sum)}\n\nprofile written to ${out}\n`);
  }
  return 0;
}

const REACT = { start: reactStart, status: reactStatus, stop: reactStop };

async function iosRecord(args) {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, strict: true, options: {
    udid: { type: 'string' }, app: { type: 'string' }, seconds: { type: 'string' }, leaks: { type: 'boolean' }, out: { type: 'string' },
    'keep-trace': { type: 'boolean' }, timeout: { type: 'string' }, top: { type: 'string' }, json: { type: 'boolean' },
  } });
  if (positionals.length) throw new UsageError(`unexpected argument: ${positionals.join(' ')}`);
  if (!values.udid) throw new UsageError('ios record needs --udid UDID (the simulator; `xcrun simctl list devices` lists them)');
  const I = await import('./ios-profile.mjs');
  const seconds = values.seconds === undefined ? I.DEFAULT_SECONDS : positiveNumber('seconds', values.seconds, { integer: true, max: I.MAX_SECONDS });
  const top = values.top === undefined ? 10 : positiveNumber('top', values.top, { integer: true });
  // At most a day: setTimeout fires at once above ~24.8 days, which would stop the recording at its start.
  const timeoutMs = values.timeout === undefined ? undefined : Math.round(positiveNumber('timeout', values.timeout, { max: 86_400 }) * 1000);
  let outDir;
  let made = false;
  if (values.out) {
    outDir = resolve(values.out);
    made = !existsSync(outDir);
    mkdirSync(outDir, { recursive: true });
    const clash = readdirSync(outDir).filter((n) => n === 'native.trace' || /^native_raw_.*\.xml$/.test(n) || n === I.SUMMARY_FILE);
    if (clash.length) throw new UsageError(`--out ${outDir} already holds a recording (${clash.join(', ')}); pick an empty directory`);
  } else {
    outDir = mkdtempSync(join(tmpdir(), 'rn-profile-ios-'));
    made = true;
  }
  if (values.leaks) process.stderr.write('note: the leaks template turns malloc stack logging on in the app; it stays on until the app is relaunched and skews later CPU and hang readings\n');
  let sum;
  try {
    sum = await I.record({ udid: values.udid, app: values.app, seconds, leaks: values.leaks, outDir, keepTrace: values['keep-trace'], timeoutMs, top });
  } catch (err) {
    // A directory this command made and nothing went into is not left behind.
    if (made && !readdirSync(outDir).length) rmdirSync(outDir);
    throw err;
  }
  process.stdout.write(values.json ? `${JSON.stringify(sum)}\n` : `${I.formatSummary(sum)}\n\nexports and ${I.SUMMARY_FILE} in ${outDir}${sum.trace ? `; trace kept at ${sum.trace}` : ''}\n`);
  return 0;
}

async function iosReport(args) {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, strict: true, options: { top: { type: 'string' }, json: { type: 'boolean' } } });
  if (positionals.length !== 1) throw new UsageError(`ios report takes one DIR, got ${positionals.length ? positionals.join(' ') : 'nothing'}`);
  const top = values.top === undefined ? 10 : positiveNumber('top', values.top, { integer: true });
  const I = await import('./ios-profile.mjs');
  const sum = await I.reportDir(resolve(positionals[0]), { top });
  process.stdout.write(values.json ? `${JSON.stringify(sum)}\n` : `${I.formatSummary(sum)}\n`);
  return 0;
}

const AREAS = { react: REACT, ios: { record: iosRecord, report: iosReport } };
const USAGE = 'usage: rn-profile.mjs react start|status|stop ... | ios record|report ... (see the header of this file)';

async function main(argv) {
  const [area, cmd, ...rest] = argv;
  if (area === undefined || area === '-h' || area === '--help') {
    process.stderr.write(`${USAGE}\n`);
    return 0;
  }
  try {
    const handler = Object.hasOwn(AREAS, area) && Object.hasOwn(AREAS[area], cmd) ? AREAS[area][cmd] : null;
    if (!handler) throw new UsageError(USAGE);
    return await handler(rest);
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    if (typeof err.exitCode === 'number') return err.exitCode;
    if (err.code?.startsWith?.('ERR_PARSE_ARGS')) return 64;
    return 1;
  }
}

process.exitCode = await main(process.argv.slice(2));
