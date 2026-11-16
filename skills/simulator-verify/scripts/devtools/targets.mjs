// targets.mjs - list Metro's inspector targets and pick the app's main JS
// runtime without guessing.
//
// The rules are read-rn-logs-cdp.py's (that script stays the reference):
//   --page N   an explicit page id, nothing else is consulted
//   --app ID   only targets whose appId equals ID
//   --device S only targets whose deviceName contains S (case-insensitive);
//              an exact name wins over the substring match, because a physical
//              iPhone registers as plain "iPhone", a substring of "iPhone 17"
//   then the main runtime: the targets that prefer the Fusebox frontend
//   (RN >= 0.76 marks the app runtime that way; the Reanimated "UI" runtime
//   does not). Older apps with no such flag fall back to the names React
//   Native registers its app runtime under.
// Several devices, or several runtimes left on one device, is an error that
// lists them (exit 2) - never a guess. Nothing left is exit 1 naming what was
// searched and what exists.

export class TargetError extends Error {
  constructor(message, exitCode) {
    super(message);
    this.exitCode = exitCode;
  }
}

/** GET http://localhost:<port>/json/list. Metro down = TargetError exit 1 naming the port. */
export async function fetchTargets(port, { timeoutMs = 5000 } = {}) {
  let res;
  try {
    res = await fetch(`http://localhost:${port}/json/list`, { signal: AbortSignal.timeout(timeoutMs) });
  } catch (err) {
    const why = err?.cause?.code ?? err?.name ?? String(err);
    throw new TargetError(
      `Metro is not answering on port ${port} (${why}). Is Metro running there? ` +
        `Pass --port or set METRO_PORT.`,
      1
    );
  }
  if (!res.ok) {
    throw new TargetError(`GET http://localhost:${port}/json/list answered HTTP ${res.status} - not Metro's inspector?`, 1);
  }
  const body = await res.json().catch(() => null);
  if (!Array.isArray(body)) {
    throw new TargetError(`http://localhost:${port}/json/list did not return a JSON list - not Metro's inspector?`, 1);
  }
  return body;
}

/** One line per target, for error messages and `targets`. */
export function describeTarget(t) {
  return `${pageId(t) ?? '?'} | ${t.appId ?? '?'} | ${t.deviceName ?? '?'} | ${t.description ?? t.title ?? '?'}`;
}

/** The page number Metro puts at the end of the debugger url (`...&page=1`). */
export function pageId(t) {
  const m = /[?&]page=([^&]+)$/.exec(t.webSocketDebuggerUrl ?? '');
  return m ? m[1] : null;
}

// Names React Native gives the app runtime on architectures without the
// Fusebox flag (bridge: HermesExecutorFactory, bridgeless: HermesInstance).
const LEGACY_APP_RUNTIME_TITLES = new Set(['Hermes React Native', 'Hermes Bridgeless React Native']);
const CXX_SUFFIX = / \[C\+\+ connection\]$/;

function prefersFusebox(t) {
  return t.reactNative?.capabilities?.prefersFuseboxFrontend === true;
}

function mainRuntimes(candidates) {
  const fusebox = candidates.filter(prefersFusebox);
  if (fusebox.length) return fusebox;
  const bridge = candidates.filter((t) => (t.title ?? '').startsWith('React Native Bridge') ||
    (t.description ?? '').startsWith('React Native Bridge'));
  if (bridge.length) return bridge;
  const legacy = candidates.filter((t) => LEGACY_APP_RUNTIME_TITLES.has((t.title ?? '').replace(CXX_SUFFIX, '')));
  if (legacy.length) return legacy;
  return candidates;
}

/**
 * Pick one target. opts: { page, app, device }. A worklet runtime (Reanimated's
 * "UI") is reached only by an explicit page.
 * Throws TargetError (exitCode 1 = nothing matches, 2 = ambiguous).
 */
export function selectTarget(targets, opts = {}) {
  const all = targets.filter((t) => t && typeof t.webSocketDebuggerUrl === 'string');
  const listing = () => (all.length ? all.map((t) => `  ${describeTarget(t)}`).join('\n') : '  (none - is the app running and connected to this Metro?)');

  if (opts.page != null && opts.page !== '') {
    const hit = all.find((t) => pageId(t) === String(opts.page));
    if (!hit) throw new TargetError(`No target with page=${opts.page}. All targets (page | app | device | runtime):\n${listing()}`, 1);
    return hit;
  }

  let candidates = all.filter((t) => t.type === 'node');
  if (opts.app) candidates = candidates.filter((t) => t.appId === opts.app);
  if (opts.device) {
    const wanted = String(opts.device).toLowerCase();
    const exact = candidates.filter((t) => (t.deviceName ?? '').toLowerCase() === wanted);
    candidates = exact.length ? exact : candidates.filter((t) => (t.deviceName ?? '').toLowerCase().includes(wanted));
  }

  if (!candidates.length) {
    const searched = [opts.app && `app "${opts.app}"`, opts.device && `device "${opts.device}"`].filter(Boolean).join(', ') || 'any app runtime';
    throw new TargetError(`No inspector target matches ${searched}. All targets (page | app | device | runtime):\n${listing()}`, 1);
  }

  const devices = [...new Set(candidates.map((t) => t.deviceName ?? '?'))].sort();
  if (devices.length > 1) {
    throw new TargetError(`Several devices on this Metro - refusing to guess. Pass --device:\n${devices.map((d) => `  ${d}`).join('\n')}`, 2);
  }

  candidates = mainRuntimes(candidates);
  if (candidates.length > 1) {
    throw new TargetError(
      `Several runtimes match on ${devices[0]} - refusing to guess. Pass --page:\n${candidates.map((t) => `  ${describeTarget(t)}`).join('\n')}`,
      2
    );
  }
  return candidates[0];
}
