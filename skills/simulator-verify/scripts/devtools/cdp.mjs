// cdp.mjs - a small Chrome DevTools Protocol client for React Native's
// runtime pages, on Node's built-in WebSocket (no npm dependencies).
//
// One-shot by design: connect, send what the command needs, close. Nothing in
// here reconnects or retries - a lost page is reported, not hidden.
//
// Metro lets ONE debugger hold an app instance. A newer connection closes the
// older one with reason "[NEW_DEBUGGER_OPENED] ...". So connecting here kicks
// React Native DevTools or a log tap off the page, and a log tap in follow mode
// (read-rn-logs-cdp.py without --no-follow) reconnects and kicks this client
// in turn. Such a close is reported as CdpError kind "taken" with what to do.

export class CdpError extends Error {
  /** kind: "connect" | "timeout" | "closed" | "taken" | "protocol" | "exception" */
  constructor(message, kind, exitCode) {
    super(message);
    this.kind = kind;
    this.exitCode = exitCode;
  }
}

export const DEFAULT_TIMEOUT_MS = 10_000;

const AWAIT_BINDING = '__rn_devtools_await';
// Runs with `this` = the evaluated object. Returns false for a non-thenable;
// for a thenable, reports its outcome over the binding once it settles.
const AWAIT_FUNCTION = `function (binding, requestId) {
  if (this === null || this === undefined || typeof this.then !== 'function') return false;
  var send = function (o) { o.requestId = requestId; globalThis[binding](JSON.stringify(o)); };
  Promise.resolve(this).then(
    function (v) { send(v === undefined ? {} : { value: v }); },
    function (e) { send({ error: String((e && e.stack) || e) }); });
  return true;
}`;

const TAKEN_HINT =
  'another debugger took the page (Metro allows one per app). Close React Native DevTools, ' +
  'or run read-rn-logs-cdp.py with --no-follow, then retry once.';

function closeError(code, reason) {
  if (/NEW_DEBUGGER_OPENED/.test(reason ?? '')) return new CdpError(`Connection closed: ${TAKEN_HINT}`, 'taken', 3);
  const why = reason ? `${code} ${reason}` : String(code);
  return new CdpError(`Connection to the app's runtime closed (${why}) - app restarted or reloaded?`, 'closed', 3);
}

/** The text of a Runtime.evaluate exception, with call frames when the description has none. */
export function exceptionText(details) {
  const description = details?.exception?.description ?? details?.text ?? 'Script evaluation threw an exception';
  if (description.includes('\n    at ') || description.includes('\n  at ')) return description;
  const frames = details?.stackTrace?.callFrames ?? [];
  if (!frames.length) return description;
  const lines = frames.map((f) => `  at ${f.functionName || '<anonymous>'} (${f.url || '<anonymous>'}:${f.lineNumber + 1}:${f.columnNumber + 1})`);
  return `${description}\n${lines.join('\n')}`;
}

/**
 * Open a CDP session on a target's webSocketDebuggerUrl.
 * Sends Origin http://127.0.0.1:<port> (newer Metro requires an Origin; older ignores it).
 */
export function connect(wsUrl, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const { host } = new URL(wsUrl);
  const origin = `http://${host.replace('localhost', '127.0.0.1')}`;
  return new Promise((resolve, reject) => {
    let ws;
    try {
      ws = new WebSocket(wsUrl, { headers: { Origin: origin } });
    } catch (err) {
      reject(new CdpError(`Cannot open ${wsUrl}: ${err.message}`, 'connect', 1));
      return;
    }
    const client = new CdpClient(ws);
    const timer = setTimeout(() => {
      ws.close();
      reject(new CdpError(`The WebSocket handshake with ${wsUrl} did not finish within ${timeoutMs} ms.`, 'timeout', 3));
    }, timeoutMs);
    ws.addEventListener('open', () => { clearTimeout(timer); resolve(client); }, { once: true });
    ws.addEventListener('error', () => {
      clearTimeout(timer);
      reject(new CdpError(`Cannot connect to ${wsUrl} - the page went away, or Metro refused the upgrade.`, 'connect', 1));
    }, { once: true });
  });
}

class CdpClient {
  #ws;
  #nextId = 1;
  #pending = new Map();
  #listeners = new Map();
  #closed = null;

  constructor(ws) {
    this.#ws = ws;
    ws.addEventListener('message', (ev) => this.#onMessage(ev.data));
    ws.addEventListener('close', (ev) => {
      this.#closed = closeError(ev.code, ev.reason);
      for (const p of this.#pending.values()) { clearTimeout(p.timer); p.reject(this.#closed); }
      this.#pending.clear();
      this.#emit('close', { code: ev.code, reason: ev.reason });
    });
  }

  /** Why the socket closed, or null while it is open. */
  get closed() { return this.#closed; }

  /** Subscribe to a CDP event by method name ("close" for the socket closing). Returns an unsubscribe. */
  on(method, fn) {
    if (!this.#listeners.has(method)) this.#listeners.set(method, new Set());
    this.#listeners.get(method).add(fn);
    return () => this.#listeners.get(method)?.delete(fn);
  }

  #emit(method, params) {
    for (const fn of this.#listeners.get(method) ?? []) fn(params);
  }

  #onMessage(data) {
    let msg;
    try { msg = JSON.parse(typeof data === 'string' ? data : Buffer.from(data).toString()); } catch { return; }
    if (typeof msg.id === 'number' && this.#pending.has(msg.id)) {
      const p = this.#pending.get(msg.id);
      this.#pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new CdpError(`${p.method} failed: ${msg.error.message ?? JSON.stringify(msg.error)}`, 'protocol', 1));
      else p.resolve(msg.result ?? {});
      return;
    }
    if (typeof msg.method === 'string') this.#emit(msg.method, msg.params ?? {});
  }

  /** Send one CDP command; resolves with its result, rejects with CdpError. */
  send(method, params = {}, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
    if (this.#closed) return Promise.reject(this.#closed);
    return new Promise((resolve, reject) => {
      const id = this.#nextId++;
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new CdpError(
          `${method} got no answer within ${timeoutMs} ms - the JS runtime may be busy, frozen or paused at a breakpoint.`,
          'timeout', 3));
      }, timeoutMs);
      this.#pending.set(id, { resolve, reject, timer, method });
      this.#ws.send(JSON.stringify({ id, method, params }));
    });
  }

  #runtimeReady = null;

  /** Runtime.enable + the await binding, once per session (callFunctionOn needs the domain). */
  #ensureRuntime(timeoutMs) {
    this.#runtimeReady ??= (async () => {
      await this.send('Runtime.enable', {}, { timeoutMs });
      await this.send('Runtime.addBinding', { name: AWAIT_BINDING }, { timeoutMs });
    })();
    return this.#runtimeReady;
  }

  /**
   * Evaluate in the app's global scope and return the value (as JSON would
   * carry it). A JS exception, or a rejected Promise, rejects with CdpError
   * kind "exception" carrying its text.
   *
   * CDP's own awaitPromise does not work in React Native: `Promise` there is
   * a polyfill Hermes does not recognise, so a Promise came back as its
   * internals ({"_h":0,...}). A thenable result is therefore awaited in the
   * app (Promise.resolve(it).then(...)) and the outcome sent back over a
   * Runtime binding; `awaitPromise: false` returns the object as it is.
   */
  async evaluate(expression, { timeoutMs = DEFAULT_TIMEOUT_MS, awaitPromise = true } = {}) {
    const res = await this.send('Runtime.evaluate', { expression, returnByValue: false, awaitPromise: false }, { timeoutMs });
    if (res.exceptionDetails) throw new CdpError(exceptionText(res.exceptionDetails), 'exception', 1);
    const remote = res.result ?? {};
    if (!remote.objectId) return remote.value;

    await this.#ensureRuntime(timeoutMs);
    if (awaitPromise) {
      const requestId = `await-${this.#nextId}`;
      const settled = this.#waitForBinding(AWAIT_BINDING, requestId, timeoutMs, 'The Promise did not settle');
      const isThenable = await this.send('Runtime.callFunctionOn', {
        objectId: remote.objectId, functionDeclaration: AWAIT_FUNCTION, returnByValue: true,
        arguments: [{ value: AWAIT_BINDING }, { value: requestId }],
      }, { timeoutMs });
      if (isThenable.result?.value === true) {
        const outcome = await settled.promise;
        if ('error' in outcome) throw new CdpError(`Promise rejected: ${outcome.error}`, 'exception', 1);
        return outcome.value;
      }
      settled.cancel();
    }
    const byValue = await this.send('Runtime.callFunctionOn', {
      objectId: remote.objectId, functionDeclaration: 'function () { return this; }', returnByValue: true,
    }, { timeoutMs });
    if (byValue.exceptionDetails) throw new CdpError(exceptionText(byValue.exceptionDetails), 'exception', 1);
    return byValue.result?.value;
  }

  /** Resolves with the parsed payload a binding delivers for requestId; cancel() drops the wait. */
  #waitForBinding(binding, requestId, timeoutMs, what) {
    let cancel;
    const promise = new Promise((resolve, reject) => {
      const done = (fn, v) => { clearTimeout(timer); off(); offClose(); fn(v); };
      const timer = setTimeout(() => done(reject, new CdpError(
        `${what} within ${timeoutMs} ms (no answer over the ${binding} binding) - the runtime may be paused or frozen.`,
        'timeout', 3)), timeoutMs);
      const off = this.on('Runtime.bindingCalled', (p) => {
        if (p.name !== binding) return;
        let payload;
        try { payload = JSON.parse(p.payload); } catch { return; }
        if (payload?.requestId === requestId) done(resolve, payload);
      });
      const offClose = this.on('close', () => done(reject, this.#closed));
      cancel = () => { clearTimeout(timer); off(); offClose(); };
    });
    promise.catch(() => {});
    return { promise, cancel };
  }

  /**
   * Run a script that answers over a Runtime binding: the script calls
   * `<binding>(JSON.stringify({ requestId, ... }))`; this resolves with that
   * parsed object. The evaluate itself is fire-and-forget (no await, no
   * value), as Argent's binding-based scripts expect.
   */
  async evaluateWithBinding(expression, { binding, requestId, timeoutMs = DEFAULT_TIMEOUT_MS }) {
    await this.#ensureRuntime(timeoutMs);
    await this.send('Runtime.addBinding', { name: binding }, { timeoutMs });
    const answer = this.#waitForBinding(binding, requestId, timeoutMs, 'The script never answered');
    try {
      const res = await this.send('Runtime.evaluate', { expression, awaitPromise: false, returnByValue: false }, { timeoutMs });
      if (res.exceptionDetails) throw new CdpError(exceptionText(res.exceptionDetails), 'exception', 1);
    } catch (err) {
      answer.cancel();
      throw err;
    }
    return answer.promise;
  }

  /** Close the socket; resolves when it is closed (or after 1 s). */
  close() {
    if (this.#closed || this.#ws.readyState === WebSocket.CLOSED) return Promise.resolve();
    return new Promise((resolve) => {
      const t = setTimeout(resolve, 1000);
      this.#ws.addEventListener('close', () => { clearTimeout(t); resolve(); }, { once: true });
      this.#ws.close();
    });
  }
}
