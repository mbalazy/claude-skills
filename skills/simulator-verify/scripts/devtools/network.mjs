// network.mjs - a log of the HTTP requests the app's JavaScript makes.
//
// start installs Argent's network interceptor (vendored unmodified,
// vendor/argent/packages/tool-server/src/utils/debugger/scripts/network-interceptor.ts)
// in the app: it patches XMLHttpRequest (React Native's fetch is built on
// it, and the interceptor marks fetch's Request), Expo's native fetch and
// React Native's network module, and keeps the
// records in the app's globals, so they survive between one-shot commands
// until the JS reloads. read serves them with the vendored read scripts.
//
// The interceptor has no way to remove itself. So start first runs
// SNAPSHOT_SCRIPT (ours), which keeps every function the interceptor is
// about to replace, and stop (STOP_SCRIPT, ours) puts them back and deletes
// the records. Requests made by native code (native SDKs, images) never pass
// through JavaScript and are not seen.

import { vendorPath } from './vendor-loader.mjs';
import { CdpError } from './cdp.mjs';

const VENDORED = 'packages/tool-server/src/utils/debugger/scripts/network-interceptor.ts';
const vendored = () => import(vendorPath(VENDORED));

export class NotInstalledError extends Error {
  constructor() {
    super('The network log is not running in the app (never started, or the JS reloaded since). Run `net start`, then make the requests.');
    this.exitCode = 1;
  }
}

/**
 * Runs in the app before the interceptor. Keeps, in globalThis.__rn_devtools_net_saved,
 * every function the interceptor replaces. The places mirror the interceptor's
 * (its RCTNetworking lookup, which may load that module, as its own would).
 */
export const SNAPSHOT_SCRIPT = `(function() {
  var g = globalThis;
  if (g.__argent_network_v2) return { already: true, restorable: !!g.__rn_devtools_net_saved };
  var hasOwn = Object.prototype.hasOwnProperty;
  var saved = [];
  function keep(holder, key) {
    if (!holder || (typeof holder !== 'object' && typeof holder !== 'function')) return;
    saved.push({ holder: holder, key: key, value: holder[key], own: hasOwn.call(holder, key) });
  }
  var XHR = g.XMLHttpRequest;
  if (typeof XHR === 'function') ['open', 'setRequestHeader', 'send', 'abort'].forEach(function(k) { keep(XHR.prototype, k); });
  if (typeof g.Request === 'function') keep(g.Request.prototype, '_initBody');
  var expoFetch;
  try { expoFetch = g.expo && g.expo.modules && g.expo.modules.ExpoFetchModule; } catch (e) {}
  if (expoFetch) {
    keep(expoFetch, 'NativeRequest');
    if (typeof expoFetch.NativeRequest === 'function') ['start', 'cancel'].forEach(function(k) { keep(expoFetch.NativeRequest.prototype, k); });
    var responseProto = expoFetch.NativeResponse && expoFetch.NativeResponse.prototype;
    if (responseProto) ['arrayBuffer', 'startStreaming', 'text'].forEach(function(k) { keep(responseProto, k); });
  }
  var PATH = /(^|[\\\\/])Libraries[\\\\/]Network[\\\\/]RCTNetworking(\\.[a-z]+)?\\.js$/;
  var modules;
  try { modules = typeof g.__r === 'function' && typeof g.__r.getModules === 'function' ? g.__r.getModules() : null; } catch (e) {}
  if (modules && typeof modules === 'object') {
    var matches = [];
    var check = function(mod, id) { if (mod && typeof mod.verboseName === 'string' && PATH.test(mod.verboseName)) matches.push({ mod: mod, id: Number(id) }); };
    if (typeof modules.forEach === 'function') modules.forEach(check);
    else for (var key in modules) if (hasOwn.call(modules, key)) check(modules[key], key);
    matches.sort(function(a, b) { return (b.mod.isInitialized ? 1 : 0) - (a.mod.isInitialized ? 1 : 0); });
    for (var i = 0; i < matches.length; i++) {
      var exports;
      try { exports = matches[i].mod.isInitialized ? matches[i].mod.publicModule && matches[i].mod.publicModule.exports : g.__r(matches[i].id); } catch (e) {}
      var api = exports && typeof exports === 'object' && exports.default ? exports.default : exports;
      if (api && typeof api.sendRequest === 'function' && typeof api.abortRequest === 'function' && typeof api.addListener === 'function') {
        keep(api, 'sendRequest');
        keep(api, 'abortRequest');
        break;
      }
    }
  }
  g.__rn_devtools_net_saved = saved;
  return { already: false, saved: saved.length };
})()`;

/** Runs in the app: puts back what SNAPSHOT_SCRIPT kept, deletes the records and the interceptor's flags. */
export const STOP_SCRIPT = `(function() {
  var g = globalThis;
  if (!g.__argent_network_v2) return JSON.stringify({ installed: false });
  var hasOwn = Object.prototype.hasOwnProperty;
  var log = g.__argent_network_log;
  var cleared = Array.isArray(log) ? log.length : 0;
  var saved = g.__rn_devtools_net_saved;
  if (!Array.isArray(saved)) {
    // Installed by another tool: nothing to put back, and its records are its own.
    return JSON.stringify({ installed: true, restorable: false, cleared: 0 });
  }
  // A key wrapped again after start (another tool) is left alone, and so is everything else:
  // putting the original back would throw that tool's wrapper away with ours.
  var foreign = [];
  for (var j = 0; j < saved.length; j++) {
    var cur = saved[j].holder[saved[j].key];
    if (cur !== saved[j].patched && cur !== saved[j].value) foreign.push(saved[j].key);
  }
  if (foreign.length) return JSON.stringify({ installed: true, restorable: true, restored: 0, failed: [], foreign: foreign, cleared: 0 });
  var restored = 0, failed = [];
  for (var i = 0; i < saved.length; i++) {
    var s = saved[i];
    try {
      if (s.own) { if (s.holder[s.key] !== s.value) { s.holder[s.key] = s.value; restored++; } }
      else if (hasOwn.call(s.holder, s.key)) { delete s.holder[s.key]; restored++; }
    } catch (e) {}
    if (s.own ? s.holder[s.key] !== s.value : hasOwn.call(s.holder, s.key)) failed.push(s.key);
  }
  if (failed.length) return JSON.stringify({ installed: true, restorable: true, restored: restored, failed: failed, cleared: 0 });
  ['__argent_network_v2', '__argent_network_installed', '__argent_network_log', '__argent_network_by_id',
   '__argent_network_decode', '__rn_devtools_net_saved'].forEach(function(name) { try { delete g[name]; } catch (e) { g[name] = undefined; } });
  return JSON.stringify({ installed: true, restorable: true, restored: restored, failed: [], cleared: cleared });
})()`;

/** Install (idempotent). Resolves with { installed: true } or { already: true, restorable, count }. */
export async function startNetworkLog(client, { timeoutMs } = {}) {
  const { NETWORK_INTERCEPTOR_SCRIPT } = await vendored();
  const out = await client.evaluate(`(function() {
    var snap = ${SNAPSHOT_SCRIPT};
    if (snap.already) {
      var log = globalThis.__argent_network_log;
      return JSON.stringify({ already: true, restorable: snap.restorable, count: Array.isArray(log) ? log.length : 0 });
    }
    var res = JSON.parse(${NETWORK_INTERCEPTOR_SCRIPT});
    var saved = globalThis.__rn_devtools_net_saved;
    if (!res.installed) delete globalThis.__rn_devtools_net_saved;
    else for (var i = 0; i < saved.length; i++) saved[i].patched = saved[i].holder[saved[i].key];
    return JSON.stringify({ installed: !!res.installed, reason: res.reason, saved: snap.saved });
  })()`, { timeoutMs });
  return JSON.parse(out);
}

/** Restore and clear. Rejects with exit 1 when the patches cannot be put back. */
export async function stopNetworkLog(client, { timeoutMs } = {}) {
  const res = JSON.parse(await client.evaluate(STOP_SCRIPT, { timeoutMs }));
  if (res.installed && !res.restorable) {
    throw new CdpError('The network log was installed by another tool, so there is nothing to put back. Nothing was changed; fetch/XHR stay patched until the JS reloads.', 'exception', 1);
  }
  if (res.installed && res.foreign?.length) {
    throw new CdpError(`Something wrapped ${res.foreign.join(', ')} again after \`net start\` (another debugging tool?); putting the original back would remove its wrapper too. Nothing was changed and the records were kept; reload the JS to remove the network log.`, 'exception', 1);
  }
  if (res.installed && res.failed.length) {
    throw new CdpError(`Could not put back: ${res.failed.join(', ')}. The records were kept; reload the JS to remove the network log.`, 'exception', 1);
  }
  return res;
}

/**
 * Captured requests with their details, oldest first. filter: { grep, since (epoch s) }.
 * Rejects with NotInstalledError when the interceptor is not in the app.
 */
export async function readNetworkLog(client, { metroPort, grep, since, limit = 50, full = false, timeoutMs } = {}) {
  const { makeNetworkLogReadScript, makeNetworkDetailReadScript } = await vendored();
  const list = JSON.parse(await client.evaluate(makeNetworkLogReadScript(0, 100000, metroPort), { timeoutMs }));
  if (!list.interceptorInstalled) throw new NotInstalledError();
  const re = grep ? new RegExp(grep, 'i') : null;
  const kept = list.entries.filter((e) => (!re || re.test(e.request?.url ?? '')) && (since === undefined || (e.timestamp ?? 0) >= since));
  const shown = kept.slice(-limit);
  let details = [];
  if (shown.length) {
    // Without full, the bodies are cut in the app: up to 1 MiB each would cross CDP only to be cut here.
    const scripts = shown.map((e) => (full ? makeNetworkDetailReadScript(e.requestId) : cutInApp(makeNetworkDetailReadScript(e.requestId))));
    details = (await client.evaluate(`[${scripts.join(',\n')}]`, { timeoutMs })).map((s) => JSON.parse(s));
  }
  // An entry the interceptor evicted between the two reads comes back as { error }: it is gone.
  const gone = details.filter((d) => d.error).length;
  return { total: list.total - gone, matched: kept.length - gone, entries: details.filter((d) => !d.error) };
}

// ---- output -------------------------------------------------------------

export const SECRET_HEADERS = new Set(['authorization', 'proxy-authorization', 'cookie', 'set-cookie']);
export const BODY_PREVIEW = 500;

/** A detail script whose bodies come back cut to BODY_PREVIEW chars, their full length kept beside them. */
function cutInApp(detailScript) {
  return `(function() {
    var d = JSON.parse(${detailScript});
    var max = ${BODY_PREVIEW};
    if (typeof d.responseBody === 'string' && d.responseBody.length > max) {
      d.responseBodyFullLength = d.responseBody.length;
      d.responseBody = d.responseBody.slice(0, max);
    }
    if (d.request && typeof d.request.postData === 'string' && d.request.postData.length > max) {
      d.request.postDataFullLength = d.request.postData.length;
      d.request.postData = d.request.postData.slice(0, max);
    }
    return JSON.stringify(d);
  })()`;
}

/** Header values that carry credentials, replaced by their length. */
export function redactHeaders(headers, { showSecrets = false } = {}) {
  if (!headers || typeof headers !== 'object' || showSecrets) return headers;
  const out = {};
  for (const [name, value] of Object.entries(headers)) {
    out[name] = SECRET_HEADERS.has(name.toLowerCase()) ? `<redacted, ${String(value).length} chars>` : value;
  }
  return out;
}

/**
 * A body cut to `max` chars with a visible marker; whole when full. `length` is
 * the body's full length when the app already cut it (cutInApp).
 */
export function truncate(text, { full = false, max = BODY_PREVIEW, length = text?.length } = {}) {
  if (typeof text !== 'string') return text;
  if (full || length <= max) return text;
  return `${text.slice(0, max)}...[${length - max} more chars; --full prints all]`;
}

/** "30s", "5m", "2h" ago, or an ISO date/time -> epoch seconds. */
export function parseSince(value, now = Date.now()) {
  const m = /^(\d+(?:\.\d+)?)(s|m|h)$/.exec(value);
  if (m) return (now - Number(m[1]) * { s: 1e3, m: 6e4, h: 3.6e6 }[m[2]]) / 1000;
  const t = Date.parse(value);
  if (Number.isNaN(t)) return null;
  return t / 1000;
}

/** One entry as shown: redacted headers, truncated bodies. */
export function present(entry, { full = false, showSecrets = false } = {}) {
  const req = entry.request ?? {};
  const res = entry.response;
  return {
    id: entry.id,
    state: entry.state,
    method: req.method,
    url: req.url,
    status: res?.status,
    statusText: res?.statusText,
    durationMs: entry.durationMs,
    timestamp: entry.timestamp,
    mimeType: res?.mimeType,
    error: entry.errorText,
    requestHeaders: redactHeaders(req.headers, { showSecrets }),
    requestBody: truncate(req.postData, { full, length: req.postDataFullLength ?? req.postData?.length }),
    requestBodyLength: req.postDataFullLength ?? (typeof req.postData === 'string' ? req.postData.length : undefined),
    responseHeaders: redactHeaders(res?.headers, { showSecrets }),
    responseBody: truncate(entry.responseBody, { full, length: entry.responseBodyFullLength ?? entry.responseBody?.length }),
    responseBodyLength: entry.bodyLength ?? entry.responseBodyFullLength ?? (typeof entry.responseBody === 'string' ? entry.responseBody.length : undefined),
    bodyCutByInterceptor: entry.bodyTruncated || undefined,
    bodyOmitted: entry.bodyOmitted || undefined,
  };
}

const clock = (ts) => (typeof ts === 'number' ? new Date(ts * 1000).toISOString().slice(11, 23) : '?');

/** The text form of read. */
export function formatLog(result, { full = false, showSecrets = false, headers = false } = {}) {
  const lines = [`${result.entries.length} request(s) shown, ${result.matched} matched, ${result.total} captured (times UTC)`];
  for (const raw of result.entries) {
    const e = present(raw, { full, showSecrets });
    const status = e.state === 'pending' ? 'pending' : e.error ? `failed (${e.error})` : `${e.status ?? '?'}${e.statusText ? ` ${e.statusText}` : ''}`;
    const took = typeof e.durationMs === 'number' ? ` ${e.durationMs} ms` : '';
    lines.push('', `#${e.id} ${clock(e.timestamp)} ${e.method ?? '?'} ${status}${took} ${e.url ?? ''}`);
    if (headers && e.requestHeaders) lines.push(`  > headers ${JSON.stringify(e.requestHeaders)}`);
    if (e.requestBody !== undefined) lines.push(`  > body (${e.requestBodyLength} chars) ${e.requestBody}`);
    if (headers && e.responseHeaders) lines.push(`  < headers ${JSON.stringify(e.responseHeaders)}`);
    if (e.responseBody !== undefined) {
      const cut = e.bodyCutByInterceptor ? ', cut by the interceptor at 1 MiB' : '';
      lines.push(`  < body (${e.responseBodyLength ?? '?'} chars${e.mimeType ? `, ${e.mimeType}` : ''}${cut}) ${e.responseBody}`);
    } else if (e.bodyOmitted) {
      lines.push('  < body not recorded (binary or over the cap)');
    }
  }
  return lines.join('\n');
}
