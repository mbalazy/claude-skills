// runtime.mjs - one-shot access to the app's JS runtime: list Metro's
// targets, pick the app's page, connect, run, close. Every command of
// rn-devtools.mjs goes through withRuntime(), so target selection, error
// wording and exit codes are the same everywhere.

import { fetchTargets, selectTarget } from './targets.mjs';
import { connect, DEFAULT_TIMEOUT_MS } from './cdp.mjs';

/** Metro port: explicit option, else $METRO_PORT, else 8081 (read-rn-logs-cdp.py's default). */
export function metroPort(value) {
  const raw = value ?? process.env.METRO_PORT ?? '8081';
  const port = Number(raw);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new UsageError(`not a port: ${raw}`);
  return port;
}

export class UsageError extends Error {
  constructor(message) { super(message); this.exitCode = 64; }
}

/**
 * opts: { port, device, app, page, timeoutMs }.
 * fn(client, target) runs with an open session; the session is closed after it.
 */
export async function withRuntime(opts, fn) {
  const port = metroPort(opts.port);
  const target = selectTarget(await fetchTargets(port), opts);
  const client = await connect(target.webSocketDebuggerUrl, { timeoutMs: opts.timeoutMs ?? DEFAULT_TIMEOUT_MS });
  try {
    return await fn(client, target);
  } finally {
    await client.close();
  }
}
