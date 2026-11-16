// fake-inspector.mjs - an in-process stand-in for Metro's inspector proxy, for
// tests only: GET /json/list serves a given target list, and a WebSocket
// upgrade on any path becomes a CDP session answered by a handler.
//
//   const fake = await startFakeInspector({ targets: (port) => [...], handler });
//   handler(msg, session) -> a result object, { error }, { exceptionDetails },
//                            or undefined to send nothing (a hung runtime).
//   session.event(method, params)  push a CDP event
//   session.close(code, reason)    close from the server side
//   fake.port, fake.close()
//
// The WebSocket framing is the minimum RFC 6455 needs for small text frames
// between localhost peers: masked client frames in, unmasked frames out.

import http from 'node:http';
import vm from 'node:vm';
import { createHash } from 'node:crypto';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function encodeFrame(opcode, payload) {
  const len = payload.length;
  let header;
  if (len < 126) header = Buffer.from([0x80 | opcode, len]);
  else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2); }
  return Buffer.concat([header, payload]);
}

function* decodeFrames(state) {
  for (;;) {
    const buf = state.buf;
    if (buf.length < 2) return;
    const opcode = buf[0] & 0x0f;
    const masked = (buf[1] & 0x80) !== 0;
    let len = buf[1] & 0x7f;
    let off = 2;
    if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
    else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
    const maskOff = off;
    if (masked) off += 4;
    if (buf.length < off + len) return;
    const payload = Buffer.from(buf.subarray(off, off + len));
    if (masked) for (let i = 0; i < len; i++) payload[i] ^= buf[maskOff + (i % 4)];
    state.buf = buf.subarray(off + len);
    yield { opcode, payload };
  }
}

export async function startFakeInspector({ targets = () => [], handler = () => ({}) } = {}) {
  const sessions = new Set();
  const server = http.createServer((req, res) => {
    if (req.url === '/json/list' || req.url === '/json') {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify(targets(server.address().port)));
      return;
    }
    res.statusCode = 404;
    res.end();
  });

  server.on('upgrade', (req, socket) => {
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + GUID).digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const state = { buf: Buffer.alloc(0) };
    const session = {
      origin: req.headers.origin,
      path: req.url,
      received: [],
      send(obj) { if (!socket.destroyed) socket.write(encodeFrame(1, Buffer.from(JSON.stringify(obj)))); },
      event(method, params = {}) { this.send({ method, params }); },
      close(code = 1000, reason = '') {
        const body = Buffer.alloc(2 + Buffer.byteLength(reason));
        body.writeUInt16BE(code, 0);
        body.write(reason, 2);
        if (!socket.destroyed) socket.write(encodeFrame(8, body));
        setTimeout(() => socket.destroy(), 50);
      },
    };
    sessions.add(session);
    socket.on('close', () => sessions.delete(session));
    socket.on('error', () => {});
    socket.on('data', async (chunk) => {
      state.buf = Buffer.concat([state.buf, chunk]);
      for (const { opcode, payload } of decodeFrames(state)) {
        if (opcode === 8) { session.close(1000); continue; }
        if (opcode !== 1) continue;
        const msg = JSON.parse(payload.toString());
        session.received.push(msg);
        const out = await handler(msg, session);
        if (out === undefined) continue;
        if (out.error) session.send({ id: msg.id, error: out.error });
        else session.send({ id: msg.id, result: out });
      }
    });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    port,
    sessions,
    close() {
      for (const s of sessions) s.close(1001, 'test over');
      return new Promise((resolve) => { server.close(() => resolve()); server.closeAllConnections(); });
    },
  };
}

/**
 * A handler that behaves like React Native's Hermes runtime for a fixed set of
 * expressions. specs: { [expression]: spec }, spec one of
 *   { value }                 a primitive or a JSON object (objects get an objectId)
 *   { throws: 'description' } a JS exception
 *   { unserializable: 'NaN' } a primitive CDP sends as unserializableValue (NaN, -0, 10n)
 *   { resolve: v, delay }     a Promise (as RN's polyfill: an Object, no CDP await)
 *   { reject: 'Error: x' }    a rejected Promise
 *   { resolveUnserializable: 'msg' } a Promise whose value JSON cannot carry
 *   { pending: true }         a Promise that never settles
 *   { hang: true }            no answer at all
 *   { close: [code, reason] } the server closes the socket instead of answering
 * Runtime.callFunctionOn needs Runtime.enable first, as on Hermes.
 */
export function fakeRuntime(specs) {
  return (msg, session) => {
    session.objects ??= new Map();
    const { method, params = {} } = msg;
    if (method === 'Runtime.enable') { session.enabled = true; return {}; }
    if (method === 'Runtime.addBinding') { (session.bindings ??= new Set()).add(params.name); return {}; }
    if (method === 'Runtime.evaluate') {
      const spec = specs[params.expression];
      if (!spec) return { result: { type: 'undefined' } };
      if (spec.hang) return undefined;
      if (spec.close) { setTimeout(() => session.close(...spec.close), 10); return undefined; }
      if (spec.unserializable) return { result: { type: spec.unserializable.endsWith('n') ? 'bigint' : 'number', unserializableValue: spec.unserializable, description: spec.unserializable } };
      if (spec.throws) return { result: { type: 'object' }, exceptionDetails: { text: 'Uncaught', exception: { description: spec.throws } } };
      if ('value' in spec && (spec.value === null || typeof spec.value !== 'object')) {
        return { result: spec.value === undefined ? { type: 'undefined' } : { type: typeof spec.value, value: spec.value } };
      }
      const objectId = String(session.objects.size + 1);
      session.objects.set(objectId, spec);
      if (params.returnByValue) return { result: { type: 'object', value: 'value' in spec ? spec.value : { _h: 0 } } };
      return { result: { type: 'object', className: 'Object', description: 'Object', objectId } };
    }
    if (method === 'Runtime.callFunctionOn') {
      if (!session.enabled) return { error: { code: -32000, message: 'Runtime domain not enabled' } };
      const spec = session.objects.get(params.objectId);
      if (!spec) return { error: { code: -32000, message: 'Could not find object with given id' } };
      const isPromise = 'resolve' in spec || 'reject' in spec || 'resolveUnserializable' in spec || spec.pending;
      if (params.functionDeclaration.includes('.then')) {
        if (!isPromise) return { result: { type: 'boolean', value: false } };
        const [binding, requestId] = params.arguments.map((a) => a.value);
        const payload = 'resolve' in spec ? (spec.resolve === undefined ? { requestId } : { requestId, value: spec.resolve })
          : 'resolveUnserializable' in spec ? { requestId, unserializable: spec.resolveUnserializable } : { requestId, error: spec.reject };
        if (!spec.pending && session.bindings?.has(binding)) {
          setTimeout(() => session.event('Runtime.bindingCalled', { name: binding, payload: JSON.stringify(payload) }), spec.delay ?? 5);
        }
        return { result: { type: 'boolean', value: true } };
      }
      return { result: { type: 'object', value: isPromise ? { _h: 0, _i: 0 } : spec.value } };
    }
    return {};
  };
}

/**
 * A handler that evaluates every expression in a node:vm context standing in
 * for the app, so scripts that patch the app's globals really run. Objects
 * get an objectId; callFunctionOn returns them by value (as JSON) or answers
 * the await probe with false (nothing here is a thenable).
 */
export function vmRuntime(ctx) {
  return (msg, session) => {
    session.objects ??= new Map();
    const { method, params = {} } = msg;
    if (method === 'Runtime.enable' || method === 'Runtime.addBinding') return {};
    if (method === 'Runtime.evaluate') {
      let v;
      try { v = vm.runInContext(params.expression, ctx); } catch (err) {
        return { result: { type: 'object' }, exceptionDetails: { text: 'Uncaught', exception: { description: String(err && err.stack || err) } } };
      }
      if (v === undefined) return { result: { type: 'undefined' } };
      if (v === null || typeof v !== 'object') return { result: { type: typeof v, value: v } };
      const objectId = String(session.objects.size + 1);
      session.objects.set(objectId, v);
      return { result: { type: 'object', objectId } };
    }
    if (method === 'Runtime.callFunctionOn') {
      const v = session.objects.get(params.objectId);
      if (params.functionDeclaration.includes('.then')) return { result: { type: 'boolean', value: false } };
      return { result: { type: 'object', value: JSON.parse(JSON.stringify(v)) } };
    }
    return {};
  };
}

/** A Metro-shaped target entry pointing at the fake inspector. */
export function fakeTarget(port, { page = 1, device = 'iPhone 17 Test', app = 'com.example.app', fusebox = page === 1, description } = {}) {
  return {
    id: `fake-${page}`,
    title: `${app} (${device})`,
    description: description ?? (page === 1 ? 'React Native Bridgeless [C++ connection]' : 'UI [C++ connection]'),
    appId: app,
    type: 'node',
    webSocketDebuggerUrl: `ws://localhost:${port}/inspector/debug?device=fake&page=${page}`,
    deviceName: device,
    reactNative: { capabilities: { prefersFuseboxFrontend: fusebox } },
  };
}
