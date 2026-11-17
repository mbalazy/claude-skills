// fake-react-app.mjs - for tests only: a node:vm context standing in for a
// React Native app's JS runtime with the React DevTools hook and one renderer
// interface, plus a CDP-like client over it with Hermes's Profiler methods.
//
// In the app: globalThis.commit([[fiberId, actualMs, selfMs], ...], durationMs)
// records a commit while profiling; globalThis.names maps fiber id -> display
// name (delete one to model a component that unmounted before stop).

import vm from 'node:vm';

const APP = `
globalThis.names = { 1: 'App', 2: 'ListScreen', 3: 'Row', 4: 'Spinner' };
var profiling = false, startedAt = 0, commits = [];
var ri = {
  flushInitialOperations: function() {},
  startProfiling: function() { profiling = true; startedAt = Date.now(); commits = []; },
  stopProfiling: function() { profiling = false; },
  getProfilingData: function() { return { dataForRoots: [{ rootID: 1, commitData: commits.slice() }] }; },
  getDisplayNameForElementID: function(id) { return globalThis.names[id] || null; },
};
var hook = { rendererInterfaces: new Map([[1, ri]]), onCommitFiberRoot: function() {} };
globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__ = hook;
globalThis.commit = function(fibers, duration) {
  if (!profiling) return false;
  commits.push({
    timestamp: Date.now() - startedAt, duration: duration,
    fiberActualDurations: fibers.map(function(f) { return [f[0], f[1]]; }),
    fiberSelfDurations: fibers.map(function(f) { return [f[0], f[2]]; }),
    changeDescriptions: [],
  });
  hook.onCommitFiberRoot(1, { current: null });
  return true;
};
`;

/** opts.hook = false: an app without the DevTools hook (a release build). */
export function fakeReactApp({ hook = true } = {}) {
  const ctx = vm.createContext({
    console,
    // The app's timers must not keep the test process alive.
    setTimeout: (fn, ms) => { const t = setTimeout(fn, ms); t.unref(); return t; },
  });
  if (hook) vm.runInContext(APP, ctx);
  const run = (code) => vm.runInContext(code, ctx);
  const sampler = { running: false, startedAt: 0, starts: 0, stops: 0 };
  const client = {
    sent: [],
    async evaluate(expr) {
      const v = run(expr);
      return v !== null && typeof v === 'object' ? JSON.parse(JSON.stringify(v)) : v;
    },
    async send(method, params = {}) {
      client.sent.push(method);
      if (method === 'Profiler.enable') throw Object.assign(new Error('Unsupported method'), { code: -32601 });
      if (method === 'Profiler.start') { sampler.running = true; sampler.startedAt = Date.now(); sampler.starts++; return {}; }
      if (method === 'Profiler.stop') {
        if (!sampler.running) throw new Error('Profiler not started');
        sampler.running = false;
        sampler.stops++;
        const ms = Math.max(1, Date.now() - sampler.startedAt);
        return { profile: { nodes: [{ id: 1, callFrame: { functionName: '(root)' } }], startTime: 0, endTime: ms * 1000,
          samples: Array(ms).fill(1), timeDeltas: Array(ms).fill(1000) } };
      }
      return {};
    },
  };
  return { ctx, run, client, sampler };
}
