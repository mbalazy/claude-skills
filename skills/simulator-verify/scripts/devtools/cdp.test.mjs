import test from 'node:test';
import assert from 'node:assert/strict';
import { connect, CdpError, exceptionText } from './cdp.mjs';
import { startFakeInspector } from './testing/fake-inspector.mjs';

// A runtime that answers like Hermes for the expressions the tests send.
function hermesLike(msg, session) {
  const { method, params } = msg;
  if (method !== 'Runtime.evaluate') return {};
  switch (params.expression) {
    case '1+1': return { result: { type: 'number', value: 2 } };
    case '({a: [1, "x"]})': return { result: { type: 'object', value: { a: [1, 'x'] } } };
    case 'undefined': return { result: { type: 'undefined' } };
    case 'boom()':
      return { result: { type: 'object' }, exceptionDetails: { text: 'Uncaught', exception: { description: 'ReferenceError: Property \'boom\' doesn\'t exist' } } };
    case 'hang': return undefined;
    case 'kick': setTimeout(() => session.close(1000, '[NEW_DEBUGGER_OPENED] New debugger opened for the same app instance'), 10); return undefined;
    case 'reload': setTimeout(() => session.close(1001, 'app reloaded'), 10); return undefined;
    case 'bad': return { error: { code: -32601, message: "Unsupported method 'X'" } };
    default:
      if (params.expression.startsWith('CALLBACK:')) {
        const [, requestId] = params.expression.split(':');
        setTimeout(() => session.event('Runtime.bindingCalled', { name: '__cb', payload: JSON.stringify({ requestId, result: 'tree' }) }), 10);
        return { result: { type: 'undefined' } };
      }
      return { result: { type: 'undefined' } };
  }
}

async function withSession(fn, handler = hermesLike) {
  const fake = await startFakeInspector({ handler });
  const client = await connect(`ws://localhost:${fake.port}/inspector/debug?device=fake&page=1`);
  try { await fn(client, fake); } finally { await client.close(); await fake.close(); }
}

test('evaluate returns a primitive value', () => withSession(async (c) => {
  assert.equal(await c.evaluate('1+1'), 2);
}));

test('evaluate returns an object by value', () => withSession(async (c) => {
  assert.deepEqual(await c.evaluate('({a: [1, "x"]})'), { a: [1, 'x'] });
}));

test('evaluate sends returnByValue and awaitPromise, and an Origin header', () => withSession(async (c, fake) => {
  await c.evaluate('undefined');
  const [session] = fake.sessions;
  const sent = session.received.find((m) => m.method === 'Runtime.evaluate');
  assert.equal(sent.params.returnByValue, true);
  assert.equal(sent.params.awaitPromise, true);
  assert.match(session.origin, /^http:\/\/127\.0\.0\.1:\d+$/);
}));

test('a JS exception rejects with kind "exception", exit 1 and the exception text', () => withSession(async (c) => {
  await assert.rejects(c.evaluate('boom()'), (err) => {
    assert.ok(err instanceof CdpError);
    assert.equal(err.kind, 'exception');
    assert.equal(err.exitCode, 1);
    assert.match(err.message, /ReferenceError: Property 'boom' doesn't exist/);
    return true;
  });
}));

test('no answer rejects with kind "timeout", exit 3, naming the method and the timeout', () => withSession(async (c) => {
  await assert.rejects(c.evaluate('hang', { timeoutMs: 150 }), (err) => {
    assert.equal(err.kind, 'timeout');
    assert.equal(err.exitCode, 3);
    assert.match(err.message, /Runtime\.evaluate got no answer within 150 ms/);
    return true;
  });
}));

test('a close with NEW_DEBUGGER_OPENED rejects the pending call with kind "taken" and what to close', () => withSession(async (c) => {
  await assert.rejects(c.evaluate('kick', { timeoutMs: 2000 }), (err) => {
    assert.equal(err.kind, 'taken');
    assert.equal(err.exitCode, 3);
    assert.match(err.message, /another debugger took the page/);
    assert.match(err.message, /--no-follow/);
    return true;
  });
  await assert.rejects(c.evaluate('1+1'), (err) => err.kind === 'taken');
}));

test('any other close rejects with kind "closed" carrying the code and reason', () => withSession(async (c) => {
  await assert.rejects(c.evaluate('reload', { timeoutMs: 2000 }), (err) => {
    assert.equal(err.kind, 'closed');
    assert.match(err.message, /1001 app reloaded/);
    return true;
  });
}));

test('a protocol error rejects with kind "protocol" naming the method', () => withSession(async (c) => {
  await assert.rejects(c.evaluate('bad'), (err) => err.kind === 'protocol' && /Runtime\.evaluate failed: Unsupported method/.test(err.message));
}));

test('evaluateWithBinding resolves with the payload carrying its requestId', () => withSession(async (c, fake) => {
  const got = await c.evaluateWithBinding('CALLBACK:req-7', { binding: '__cb', requestId: 'req-7', timeoutMs: 2000 });
  assert.deepEqual(got, { requestId: 'req-7', result: 'tree' });
  const [session] = fake.sessions;
  assert.ok(session.received.some((m) => m.method === 'Runtime.addBinding' && m.params.name === '__cb'));
  const ev = session.received.find((m) => m.method === 'Runtime.evaluate');
  assert.equal(ev.params.awaitPromise, false);
}));

test('evaluateWithBinding times out when the script never calls back', () => withSession(async (c) => {
  await assert.rejects(c.evaluateWithBinding('noop', { binding: '__cb', requestId: 'r', timeoutMs: 150 }), (err) => err.kind === 'timeout' && /__cb binding within 150 ms/.test(err.message));
}));

test('connecting to a port with nothing listening rejects with kind "connect", exit 1', async () => {
  const fake = await startFakeInspector();
  const port = fake.port;
  await fake.close();
  await assert.rejects(connect(`ws://localhost:${port}/inspector/debug?page=1`, { timeoutMs: 2000 }), (err) => err.kind === 'connect' && err.exitCode === 1);
});

test('exceptionText appends call frames only when the description has no stack', () => {
  const frames = { callFrames: [{ functionName: 'f', url: 'app.js', lineNumber: 0, columnNumber: 4 }] };
  assert.equal(exceptionText({ exception: { description: 'Error: x' }, stackTrace: frames }), 'Error: x\n  at f (app.js:1:5)');
  assert.equal(exceptionText({ exception: { description: 'Error: x\n    at g (a.js:1:1)' }, stackTrace: frames }), 'Error: x\n    at g (a.js:1:1)');
});
