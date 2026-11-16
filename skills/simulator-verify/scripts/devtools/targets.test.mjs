import test from 'node:test';
import assert from 'node:assert/strict';
import { selectTarget, pageId, TargetError } from './targets.mjs';

// Synthetic /json/list entries in the shape Metro (RN 0.81, bridgeless) serves.
function target({ device = 'iPhone 17 Test', app = 'com.example.app', page = 1, desc, fusebox, title }) {
  return {
    id: `abc-${page}`,
    title: title ?? `${app} (${device})`,
    description: desc ?? 'React Native Bridgeless [C++ connection]',
    appId: app,
    type: 'node',
    webSocketDebuggerUrl: `ws://localhost:8081/inspector/debug?device=abc&page=${page}`,
    deviceName: device,
    reactNative: { capabilities: { prefersFuseboxFrontend: fusebox ?? page === 1 } },
  };
}
const main = (o = {}) => target({ page: 1, fusebox: true, ...o });
const ui = (o = {}) => target({ page: 2, desc: 'UI [C++ connection]', fusebox: false, ...o });

function throwsWith(fn, exitCode, pattern) {
  assert.throws(fn, (err) => {
    assert.ok(err instanceof TargetError, `expected TargetError, got ${err}`);
    assert.equal(err.exitCode, exitCode);
    if (pattern) assert.match(err.message, pattern);
    return true;
  });
}

test('picks the main runtime and skips the UI worklet runtime', () => {
  assert.equal(pageId(selectTarget([main(), ui()])), '1');
});

test('an explicit page wins over every other rule, including a worklet runtime', () => {
  assert.equal(pageId(selectTarget([main(), ui()], { page: 2 })), '2');
});

test('an unknown page is exit 1 listing what exists', () => {
  throwsWith(() => selectTarget([main(), ui()], { page: 7 }), 1, /page=7[\s\S]*UI \[C\+\+ connection\]/);
});

test('two devices on one Metro is exit 2 naming both', () => {
  throwsWith(() => selectTarget([main({ device: 'iPhone A' }), main({ device: 'iPhone B', page: 3 })]), 2, /iPhone A[\s\S]*iPhone B/);
});

test('--device picks one of two devices by substring', () => {
  const t = selectTarget([main({ device: 'iPhone 17 Test' }), main({ device: 'iPad Air', page: 3 })], { device: 'ipad' });
  assert.equal(t.deviceName, 'iPad Air');
});

test('an exact device name beats the substring match', () => {
  const t = selectTarget([main({ device: 'iPhone' }), main({ device: 'iPhone 17 Test', page: 3 })], { device: 'iPhone' });
  assert.equal(t.deviceName, 'iPhone');
});

test('--device matching nothing is exit 1 naming the search and the existing targets', () => {
  throwsWith(() => selectTarget([main(), ui()], { device: 'no-such-device' }), 1, /device "no-such-device"[\s\S]*iPhone 17 Test/);
});

test('--app filters by bundle id', () => {
  const t = selectTarget([main({ app: 'com.example.one' }), main({ app: 'com.example.two', device: 'iPhone 17 Test', page: 3 })], { app: 'com.example.two' });
  assert.equal(t.appId, 'com.example.two');
});

test('two app runtimes of one device (two apps on one sim) is exit 2, not the first one', () => {
  throwsWith(() => selectTarget([main({ app: 'com.example.one' }), main({ app: 'com.example.two', page: 3, fusebox: true })]), 2, /Several runtimes[\s\S]*com\.example\.one[\s\S]*com\.example\.two/);
});

test('no targets at all is exit 1 saying the app is not connected', () => {
  throwsWith(() => selectTarget([]), 1, /none - is the app running/);
});

test('without the Fusebox flag the bridge runtime is chosen over a worklet runtime', () => {
  const bridge = target({ page: 1, fusebox: false, title: 'React Native Bridge', desc: '' });
  const worklet = target({ page: 2, fusebox: false, title: 'Reanimated UI runtime', desc: '' });
  assert.equal(pageId(selectTarget([worklet, bridge])), '1');
});

test('without the Fusebox flag the legacy Hermes title is recognised, with or without the C++ suffix', () => {
  const app = target({ page: 4, fusebox: false, title: 'Hermes React Native [C++ connection]', desc: '' });
  const worklet = target({ page: 5, fusebox: false, title: 'Reanimated UI runtime', desc: '' });
  assert.equal(pageId(selectTarget([worklet, app])), '4');
});

test('non-node entries (e.g. a page for another frontend) are ignored', () => {
  const other = { ...main({ page: 9 }), type: 'page' };
  assert.equal(pageId(selectTarget([other, main(), ui()])), '1');
});
