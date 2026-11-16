#!/usr/bin/env node
// rn-devtools.mjs - ask the running React Native app things over Metro's CDP
// inspector: which runtime pages exist, what a JS expression evaluates to
// inside the app, and which React components the screen is made of. Node
// built-ins only.
//
// Usage:
//   rn-devtools.mjs targets [--port N] [--json]
//   rn-devtools.mjs eval EXPRESSION [target options] [--timeout S] [--no-await]
//   rn-devtools.mjs tree [target options] [--grep REGEX] [--id TESTID] [--ids]
//                        [--json] [--all] [--max-nodes N]
//
// Target options (the rules of read-rn-logs-cdp.py):
//   --port N        Metro port (default: $METRO_PORT, else 8081)
//   --device NAME   deviceName contains NAME (an exact name wins)
//   --app ID        appId equals ID (bundle id)
//   --page N        this page id, nothing else consulted (e.g. a worklet runtime)
//   --timeout S     seconds to wait for the connection and each answer (default 10)
//
// eval prints the value as JSON (a bare `undefined` when there is none). The
// expression runs in the app's global scope; a Promise is awaited unless
// --no-await.
//
// tree prints the React component tree of the screen the app shows, one
// component per line (two spaces per level): name, "text" (or the
// accessibility label), [testID=...] and (tap X,Y) = the centre of its rect in
// points. Layout-only wrappers are pruned (Argent's rules; a missing wrapper
// proves nothing). --grep keeps components whose name, text, label or testID
// match REGEX (case-insensitive), --id the one testID, both with their
// ancestors; --ids prints only the testIDs, one per line; --json the same
// nodes as JSON; --all keeps off-screen components; --max-nodes collapses
// wrapper chains past N. Its --timeout default is 15.
//
// Exit codes:
//   0  done
//   1  nothing to talk to (Metro not on the port, no matching target, socket
//      refused), the expression threw or its Promise rejected (the text on
//      stderr), or the result is a value JSON cannot carry (NaN, a BigInt, a cycle)
//   2  several targets match - refusing to guess, the candidates are listed
//   3  no answer in time, or the page went away mid-command - including
//      another debugger taking it (Metro allows one per app: connecting here
//      kicks React Native DevTools, and a log tap in follow mode kicks back)
//   64 usage error

import { parseArgs } from 'node:util';
import { fetchTargets, selectTarget, describeTarget, pageId } from './devtools/targets.mjs';
import { withRuntime, metroPort, UsageError } from './devtools/runtime.mjs';

const TARGET_OPTIONS = {
  port: { type: 'string' },
  device: { type: 'string' },
  app: { type: 'string' },
  page: { type: 'string' },
  timeout: { type: 'string' },
};

function timeoutMs(value) {
  if (value === undefined) return undefined;
  const s = Number(value);
  if (!(s > 0)) throw new UsageError(`--timeout wants seconds > 0, got ${value}`);
  return Math.round(s * 1000);
}

function targetOpts(values) {
  return { port: values.port, device: values.device, app: values.app, page: values.page, timeoutMs: timeoutMs(values.timeout) };
}

async function cmdTargets(args) {
  const { values } = parseArgs({ args, options: { port: { type: 'string' }, json: { type: 'boolean' } }, strict: true });
  const port = metroPort(values.port);
  const targets = await fetchTargets(port);
  let chosen = null;
  let why = '';
  try { chosen = selectTarget(targets, {}); } catch (err) { why = err.message.split('\n')[0]; }
  if (values.json) {
    process.stdout.write(JSON.stringify({ port, targets, selected: chosen ? pageId(chosen) : null }, null, 2) + '\n');
    return 0;
  }
  console.log(`Metro on port ${port}: ${targets.length} target(s)  (page | app | device | runtime)`);
  for (const t of targets) console.log(`${t === chosen ? '*' : ' '} ${describeTarget(t)}`);
  console.log(chosen ? '* = the page commands use without --page' : `no default page: ${why}`);
  return 0;
}

async function cmdEval(args) {
  const { values, positionals } = parseArgs({
    args, allowPositionals: true, strict: true,
    options: { ...TARGET_OPTIONS, 'no-await': { type: 'boolean' } },
  });
  if (positionals.length !== 1) throw new UsageError('eval takes exactly one EXPRESSION (quote it)');
  const opts = targetOpts(values);
  const value = await withRuntime(opts, (client) =>
    client.evaluate(positionals[0], { timeoutMs: opts.timeoutMs, awaitPromise: !values['no-await'] }));
  process.stdout.write((value === undefined ? 'undefined' : JSON.stringify(value)) + '\n');
  return 0;
}

async function cmdTree(args) {
  const { values, positionals } = parseArgs({
    args, allowPositionals: true, strict: true,
    options: {
      ...TARGET_OPTIONS,
      grep: { type: 'string' }, id: { type: 'string' }, ids: { type: 'boolean' },
      json: { type: 'boolean' }, all: { type: 'boolean' }, 'max-nodes': { type: 'string' },
    },
  });
  if (positionals.length) throw new UsageError(`tree takes no positional arguments, got: ${positionals.join(' ')}`);
  if (values.ids && values.json) throw new UsageError('--ids and --json exclude each other');
  let maxNodes;
  if (values['max-nodes'] !== undefined) {
    maxNodes = Number(values['max-nodes']);
    if (!Number.isInteger(maxNodes) || maxNodes < 1) throw new UsageError(`--max-nodes wants a whole number >= 1, got ${values['max-nodes']}`);
  }
  if (values.grep !== undefined) {
    try { new RegExp(values.grep); } catch (err) { throw new UsageError(`--grep: ${err.message}`); }
  }
  // Loaded here, not at the top: it needs Node's TypeScript support (the
  // vendored script), which `targets` and `eval` do not.
  const { readComponentTree, pruneTree, filterNodes, makeMatcher, formatText, toJson, testIDs, TREE_TIMEOUT_MS } =
    await import('./devtools/component-tree.mjs');
  const opts = targetOpts(values);
  const raw = await withRuntime(opts, (client) => readComponentTree(client, { timeoutMs: opts.timeoutMs ?? TREE_TIMEOUT_MS }));
  const tree = pruneTree(raw, { onScreenOnly: !values.all, maxNodes });
  const filtered = values.grep !== undefined || values.id !== undefined;
  const nodes = filtered ? filterNodes(tree.nodes, makeMatcher({ grep: values.grep, id: values.id })) : tree.nodes;
  if (values.ids) {
    const ids = testIDs(nodes);
    if (ids.length) process.stdout.write(ids.join('\n') + '\n');
  } else if (values.json) {
    process.stdout.write(JSON.stringify(toJson(tree, nodes)) + '\n');
  } else {
    process.stdout.write(formatText(tree, nodes) + '\n');
  }
  // A filter that matched nothing is an answer ("not on this screen"), not a failure.
  return 0;
}

const COMMANDS = { targets: cmdTargets, eval: cmdEval, tree: cmdTree };

async function main(argv) {
  const [cmd, ...rest] = argv;
  const run = COMMANDS[cmd];
  if (!run) {
    process.stderr.write(`usage: rn-devtools.mjs ${Object.keys(COMMANDS).join('|')} ... (see the header of this file)\n`);
    return cmd === undefined || cmd === '-h' || cmd === '--help' ? 0 : 64;
  }
  try {
    return await run(rest);
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    if (typeof err.exitCode === 'number') return err.exitCode;
    if (err.code?.startsWith?.('ERR_PARSE_ARGS')) return 64;
    return 1;
  }
}

process.exitCode = await main(process.argv.slice(2));
