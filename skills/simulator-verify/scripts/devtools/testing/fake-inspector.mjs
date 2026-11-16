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
