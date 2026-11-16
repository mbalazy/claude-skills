import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { makeAppContext } from './testing/fake-app.mjs';
import {
  startNetworkLog, stopNetworkLog, readNetworkLog, NotInstalledError,
  redactHeaders, truncate, parseSince, present, formatLog, BODY_PREVIEW,
} from './network.mjs';

function fakeApp() {
  const ctx = makeAppContext();
  const originals = vm.runInContext('({ open: XMLHttpRequest.prototype.open, send: XMLHttpRequest.prototype.send, initBody: Request.prototype._initBody })', ctx);
  // Values cross as JSON, as returnByValue carries them over CDP.
  const client = { evaluate: async (expr) => {
    const v = vm.runInContext(expr, ctx);
    return v !== null && typeof v === 'object' ? JSON.parse(JSON.stringify(v)) : v;
  } };
  return { ctx, client, originals, run: (code) => vm.runInContext(code, ctx) };
}

test('start installs the vendored interceptor; a second start does not wrap XHR again', async () => {
  const app = fakeApp();
  assert.deepEqual(await startNetworkLog(app.client), { installed: true, saved: 5 });
  const patched = app.run('XMLHttpRequest.prototype.open');
  assert.notEqual(patched, app.originals.open);
  const again = await startNetworkLog(app.client);
  assert.deepEqual(again, { already: true, restorable: true, count: 0 });
  assert.equal(app.run('XMLHttpRequest.prototype.open'), patched, 'the second start must not wrap open again');
  await app.run('request("GET", "https://api.example.test/v1/search?query=yoga")');
  const log = await readNetworkLog(app.client, { metroPort: 8081 });
  assert.equal(log.total, 1, 'one request after two starts is captured once');
});

test('read returns method, URL, status, duration and both bodies; grep and since filter', async () => {
  const app = fakeApp();
  await startNetworkLog(app.client);
  await app.run('request("POST", "https://api.example.test/v1/login", JSON.stringify({ user: "a" }), { Authorization: "Bearer secret" })');
  await app.run('request("GET", "https://api.example.test/v1/search?query=yoga")');
  await app.run('request("GET", "http://localhost:8081/symbolicate")');
  const all = await readNetworkLog(app.client, { metroPort: 8081 });
  assert.equal(all.total, 2, "Metro's own traffic is left out");
  const [login, search] = all.entries;
  assert.equal(login.request.method, 'POST');
  assert.equal(login.request.postData, '{"user":"a"}');
  assert.equal(login.response.status, 200);
  assert.equal(typeof login.durationMs, 'number');
  assert.match(search.responseBody, /"items":\[1,2,3\]/);
  const grep = await readNetworkLog(app.client, { metroPort: 8081, grep: 'query=yoga' });
  assert.equal(grep.matched, 1);
  assert.equal(grep.entries[0].request.url, 'https://api.example.test/v1/search?query=yoga');
  const future = await readNetworkLog(app.client, { metroPort: 8081, since: Date.now() / 1000 + 60 });
  assert.deepEqual([future.matched, future.entries.length], [0, 0]);
});

test('stop puts the original functions back, deletes the records, and read then says it is not running', async () => {
  const app = fakeApp();
  await startNetworkLog(app.client);
  await app.run('request("GET", "https://api.example.test/a")');
  const res = await stopNetworkLog(app.client);
  assert.deepEqual(res, { installed: true, restorable: true, restored: 5, failed: [], cleared: 1 });
  assert.equal(app.run('XMLHttpRequest.prototype.open'), app.originals.open);
  assert.equal(app.run('XMLHttpRequest.prototype.send'), app.originals.send);
  assert.equal(app.run('Request.prototype._initBody'), app.originals.initBody);
  assert.equal(app.run('typeof globalThis.__argent_network_log'), 'undefined');
  await assert.rejects(readNetworkLog(app.client, { metroPort: 8081 }), NotInstalledError);
  await app.run('request("GET", "https://api.example.test/b")');
  // start again after stop: a fresh install that records again
  assert.equal((await startNetworkLog(app.client)).installed, true);
  await app.run('request("GET", "https://api.example.test/c")');
  const log = await readNetworkLog(app.client, { metroPort: 8081 });
  assert.deepEqual(log.entries.map((e) => e.request.url), ['https://api.example.test/c']);
});

test('without full, read cuts long bodies in the app and keeps their full length; full brings them whole', async () => {
  const app = fakeApp();
  await startNetworkLog(app.client);
  await app.run('request("POST", "https://api.example.test/upload", "p".repeat(2000))');
  const cut = (await readNetworkLog(app.client, { metroPort: 8081 })).entries[0];
  assert.equal(cut.request.postData.length, BODY_PREVIEW);
  assert.equal(cut.request.postDataFullLength, 2000);
  assert.ok(cut.responseBody.length <= BODY_PREVIEW);
  const shown = present(cut);
  assert.equal(shown.requestBodyLength, 2000);
  assert.match(shown.requestBody, /\.\.\.\[1500 more chars; --full prints all\]$/);
  const whole = (await readNetworkLog(app.client, { metroPort: 8081, full: true })).entries[0];
  assert.equal(whole.request.postData.length, 2000);
  assert.equal(present(whole, { full: true }).requestBody.length, 2000);
});

test('stop leaves everything as it is when another tool wrapped a patched function after start', async () => {
  const app = fakeApp();
  await startNetworkLog(app.client);
  app.run('var inner = XMLHttpRequest.prototype.open; globalThis.otherTool = function() { return inner.apply(this, arguments); }; XMLHttpRequest.prototype.open = globalThis.otherTool;');
  await app.run('request("GET", "https://api.example.test/a")');
  await assert.rejects(stopNetworkLog(app.client), (err) => err.exitCode === 1 && /wrapped open again[\s\S]*Nothing was changed/.test(err.message));
  assert.equal(app.run('XMLHttpRequest.prototype.open === globalThis.otherTool'), true);
  assert.equal(app.run('XMLHttpRequest.prototype.send') === app.originals.send, false, 'send still patched: nothing restored');
  assert.equal((await readNetworkLog(app.client, { metroPort: 8081 })).total, 1);
});

test('read before any start, and stop with nothing installed', async () => {
  const app = fakeApp();
  await assert.rejects(readNetworkLog(app.client, { metroPort: 8081 }), (err) => err instanceof NotInstalledError && err.exitCode === 1 && /net start/.test(err.message));
  assert.deepEqual(await stopNetworkLog(app.client), { installed: false });
});

test('stop of an interceptor another tool installed clears the records and exits 1 saying the patches stay', async () => {
  const app = fakeApp();
  await startNetworkLog(app.client);
  app.run('delete globalThis.__rn_devtools_net_saved');
  await app.run('request("GET", "https://api.example.test/a")');
  await assert.rejects(stopNetworkLog(app.client), (err) => err.exitCode === 1 && /another tool[\s\S]*1 records were cleared[\s\S]*until the JS reloads/.test(err.message));
  assert.equal(app.run('globalThis.__argent_network_log.length'), 0);
});

test('redaction replaces credentials in headers unless asked, case-insensitively', () => {
  const h = { Authorization: 'Bearer abc', cookie: 'a=1', 'Set-Cookie': 's=2', 'Content-Type': 'application/json' };
  assert.deepEqual(redactHeaders(h), {
    Authorization: '<redacted, 10 chars>', cookie: '<redacted, 3 chars>', 'Set-Cookie': '<redacted, 3 chars>', 'Content-Type': 'application/json',
  });
  assert.equal(redactHeaders(h, { showSecrets: true }), h);
});

test('bodies are cut with a visible marker unless full', () => {
  const long = 'x'.repeat(BODY_PREVIEW + 20);
  assert.equal(truncate(long), `${'x'.repeat(BODY_PREVIEW)}...[20 more chars; --full prints all]`);
  assert.equal(truncate(long, { full: true }), long);
  assert.equal(truncate('short'), 'short');
});

test('since takes 30s / 5m / 2h ago or an ISO time', () => {
  const now = Date.UTC(2026, 0, 1, 12, 0, 0);
  assert.equal(parseSince('30s', now), now / 1000 - 30);
  assert.equal(parseSince('5m', now), now / 1000 - 300);
  assert.equal(parseSince('2h', now), now / 1000 - 7200);
  assert.equal(parseSince('2026-01-01T11:00:00Z', now), now / 1000 - 3600);
  assert.equal(parseSince('yesterday-ish', now), null);
});

const ENTRY = {
  id: 7, state: 'complete', timestamp: Date.UTC(2026, 0, 1, 12, 0, 1, 250) / 1000, durationMs: 143,
  request: { method: 'POST', url: 'https://api.example.test/v1/items', headers: { authorization: 'Bearer abc' }, postData: '{"name":"n"}' },
  response: { status: 201, statusText: 'Created', mimeType: 'application/json', headers: { 'set-cookie': 's=1' } },
  responseBody: '{"id":1}', bodyLength: 8,
};

test('the text form: one block per request with status, duration, bodies; headers only on request, redacted', () => {
  const r = { total: 3, matched: 1, entries: [ENTRY] };
  const text = formatLog(r);
  assert.match(text, /^1 request\(s\) shown, 1 matched, 3 captured/);
  assert.match(text, /\n#7 12:00:01\.250 POST 201 Created 143 ms https:\/\/api\.example\.test\/v1\/items\n {2}> body \(12 chars\) \{"name":"n"\}\n {2}< body \(8 chars, application\/json\) \{"id":1\}/);
  assert.doesNotMatch(text, /headers/);
  const withHeaders = formatLog(r, { headers: true });
  assert.match(withHeaders, /> headers \{"authorization":"<redacted, 10 chars>"\}/);
  assert.doesNotMatch(withHeaders, /Bearer abc/);
  assert.match(formatLog(r, { headers: true, showSecrets: true }), /Bearer abc/);
});

test('pending and failed requests read as such', () => {
  const r = { total: 2, matched: 2, entries: [
    { id: 1, state: 'pending', timestamp: 1, request: { method: 'GET', url: 'https://a.test/' } },
    { id: 2, state: 'failed', timestamp: 1, errorText: 'Network request failed', request: { method: 'GET', url: 'https://b.test/' } },
  ] };
  const text = formatLog(r);
  assert.match(text, /#1 \S+ GET pending https:\/\/a\.test\//);
  assert.match(text, /#2 \S+ GET failed \(Network request failed\) https:\/\/b\.test\//);
});

test('the JSON form is redacted and truncated too', () => {
  const p = present({ ...ENTRY, responseBody: 'y'.repeat(BODY_PREVIEW + 1) });
  assert.equal(p.requestHeaders.authorization, '<redacted, 10 chars>');
  assert.match(p.responseBody, /\.\.\.\[1 more chars; --full prints all\]$/);
});
