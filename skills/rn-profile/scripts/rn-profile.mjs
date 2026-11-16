#!/usr/bin/env node
// rn-profile.mjs - profile a running React Native app (development build)
// from the command line. Node built-ins only; talks to the app's JS runtime
// over Metro's CDP inspector through simulator-verify's shared devtools code.
//
//   rn-profile.mjs react start  [target options] [--max S] [--interval-us N] [--takeover]
//   rn-profile.mjs react status [target options] [--json]
//   rn-profile.mjs react stop --out FILE [target options] [--top N] [--json]
//
// Target options (as simulator-verify's rn-devtools.mjs): --port (default
// $METRO_PORT, else 8081), --device, --app, --page, --timeout S (default 10).
//
// react start begins a React profiler recording (every commit, with per-
// component render times) plus Hermes's CPU sampler (--interval-us, default
// 1000). It ends by itself after --max seconds (default 60, at most 600);
// stop still returns what was recorded up to then. A second start while
// recording changes nothing; a recording another tool holds is refused unless
// --takeover. react status says whether a recording runs and for how long.
// react stop ends the recording, writes the whole profile as JSON to --out
// and prints a summary: commit count, total and slowest commit, the top
// components (--top, default 10) by renders and by self time. A JS reload
// loses a recording; stop then exits 1.
//
// Exit codes: 0 done; 1 nothing to talk to, no React DevTools hook (release
// build), nothing recording, or another tool holds the profiler; 2 ambiguous
// target; 3 no answer within --timeout; 64 usage.

import { parseArgs } from 'node:util';
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
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
  if (res.discarded) console.log(`note: an earlier recording that was never stopped (${res.discarded === 'time-limit' ? 'ended by its time limit' : 'still running'}) was dropped`);
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
  // Stop hands the data over once: a file that cannot be written must fail before it.
  try { writeFileSync(out, ''); } catch (err) { throw new UsageError(`cannot write --out ${out}: ${err.message}`); }
  const profile = await withRuntime(opts, (client) => stopRecording(client, opts));
  writeFileSync(out, JSON.stringify(profile));
  const sum = summarize(profile, { top });
  if (values.json) {
    process.stdout.write(`${JSON.stringify({ file: out, ...sum })}\n`);
  } else {
    process.stdout.write(`${formatSummary(sum)}\n\nprofile written to ${out}\n`);
  }
  return 0;
}

const REACT = { start: reactStart, status: reactStatus, stop: reactStop };

async function main(argv) {
  const [area, cmd, ...rest] = argv;
  if (area === undefined || area === '-h' || area === '--help') {
    process.stderr.write('usage: rn-profile.mjs react start|status|stop ... (see the header of this file)\n');
    return 0;
  }
  try {
    if (area !== 'react' || !REACT[cmd]) throw new UsageError('usage: rn-profile.mjs react start|status|stop ... (see the header of this file)');
    return await REACT[cmd](rest);
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    if (typeof err.exitCode === 'number') return err.exitCode;
    if (err.code?.startsWith?.('ERR_PARSE_ARGS')) return 64;
    return 1;
  }
}

process.exitCode = await main(process.argv.slice(2));
