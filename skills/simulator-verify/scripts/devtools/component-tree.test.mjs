import test from 'node:test';
import assert from 'node:assert/strict';
import { pruneTree, filterNodes, makeMatcher, formatText, toJson, testIDs, tapPoint, readComponentTree, TREE_BINDING } from './component-tree.mjs';
import { connect } from './cdp.mjs';
import { startFakeInspector, withTreeScript } from './testing/fake-inspector.mjs';

// A synthetic screen, 400x800 pt, in the shape the in-app script reports.
let nextId = 0;
const comps = [];
function c(name, parentIdx, rect, extra = {}) {
  const e = { id: nextId++, name, rect: rect && { x: rect[0], y: rect[1], w: rect[2], h: rect[3] }, parentIdx, ...extra };
  comps.push(e);
  return e.id;
}
const root = c('App', -1, [0, 0, 400, 800]);                                    // full-screen, no content: pruned
const screen = c('Screen', root, [0, 0, 400, 800], { testID: 'Main-root' });
const scroll = c('ScrollView', screen, [0, 100, 400, 700]);
c('ScrollView', scroll, [0, 100, 400, 700]);                                    // same name + rect as parent: merged
const header = c('Header', screen, [0, 0, 400, 100], { testID: 'Main-header' });
c('Text', header, [10, 10, 200, 40], { text: 'Hello there' });
c('Text', header, [10, 10, 100, 20], { text: 'Hello' });                        // shown by an ancestor? no - sibling text, kept
const btn = c('Button', screen, [20, 600, 100, 40], { testID: 'Main-go', accLabel: 'Go' });
c('Text', btn, [20, 600, 100, 40], { text: 'Go' });                             // ancestor shows "Go": dropped
const card = c('Card', scroll, [0, 200, 400, 100], { testID: 'Card-1' });
c('Card', card, [0, 200, 400, 100], { testID: 'Card-1-inner' });                // same name + rect, OWN testID: kept
const offscreen = c('Drawer', screen, [-500, 0, 300, 800], { testID: 'Drawer' }); // off screen: pruned with its subtree
c('Text', offscreen, null, { text: 'menu item' });
const RAW = { screenW: 400, screenH: 800, components: comps };

test('pruning follows Argent: wrappers, same-name chains, off-screen subtrees and repeated text go', () => {
  const t = pruneTree(RAW);
  const names = t.nodes.map((n) => `${'  '.repeat(n.depth)}${n.entry.name}${n.entry.testID ? `[${n.entry.testID}]` : ''}`);
  assert.deepEqual(names, [
    'Screen[Main-root]',
    '  ScrollView',
    '    Card[Card-1]',
    '      Card[Card-1-inner]',
    '  Header[Main-header]',
    '    Text',
    '    Text',
    '  Button[Main-go]',
  ]);
  assert.equal(t.stats.offScreen, 2);
  assert.equal(t.stats.sameNameDedup, 1);
  assert.equal(t.stats.fullScreenWrapper, 1);
});

test('a component whose edge shows at the bottom of the screen stays; one fully below goes', () => {
  const raw = { screenW: 400, screenH: 800, components: [
    { id: 0, name: 'List', rect: { x: 0, y: 0, w: 400, h: 2000 }, parentIdx: -1, testID: 'L' },
    { id: 1, name: 'Card', rect: { x: 0, y: 780, w: 300, h: 400 }, parentIdx: 0, testID: 'peeking' },
    { id: 2, name: 'Card', rect: { x: 0, y: 1200, w: 300, h: 400 }, parentIdx: 0, testID: 'below' },
    { id: 3, name: 'Card', rect: { x: 390, y: 100, w: 300, h: 400 }, parentIdx: 0, testID: 'right-edge' },
  ] };
  assert.deepEqual(testIDs(pruneTree(raw).nodes), ['L', 'peeking', 'right-edge']);
});

test('stacked same-name layers keep the testIDs and text inside each; empty twins are skipped', () => {
  const r = { x: 0, y: 0, w: 300, h: 300 };
  const raw = { screenW: 400, screenH: 800, components: [
    { id: 0, name: 'Root', rect: { x: 0, y: 0, w: 400, h: 400 }, parentIdx: -1, testID: 'root' },
    { id: 1, name: 'Layer', rect: r, parentIdx: 0 },
    { id: 2, name: 'Btn', rect: { x: 10, y: 10, w: 50, h: 20 }, parentIdx: 1, testID: 'a-btn' },
    { id: 3, name: 'Layer', rect: r, parentIdx: 0 },
    { id: 4, name: 'Btn', rect: { x: 10, y: 50, w: 50, h: 20 }, parentIdx: 3, testID: 'b-btn', text: 'Pay' },
    { id: 5, name: 'Layer', rect: r, parentIdx: 0 },
    { id: 6, name: 'Shape', rect: { x: 10, y: 90, w: 5, h: 5 }, parentIdx: 5 },
  ] };
  const t = pruneTree(raw);
  assert.deepEqual(testIDs(t.nodes), ['a-btn', 'b-btn', 'root']);
  assert.match(formatText(t), /"Pay"/);
  assert.equal(t.nodes.filter((n) => n.entry.name === 'Layer').length, 2);
});

test('an on-screen child of a composite measured off screen stays; a rectless testID under a merged twin stays', () => {
  const raw = { screenW: 400, screenH: 800, components: [
    { id: 0, name: 'Shell', rect: { x: -400, y: 0, w: 300, h: 800 }, parentIdx: -1 },
    { id: 1, name: 'Drawer', rect: { x: -400, y: 0, w: 300, h: 800 }, parentIdx: 0, testID: 'drawer' },
    { id: 2, name: 'DrawerItem', rect: null, parentIdx: 1, testID: 'drawer-item' },
    { id: 3, name: 'Main', rect: { x: 0, y: 0, w: 400, h: 700 }, parentIdx: 0, testID: 'main' },
    { id: 4, name: 'ScrollView', rect: { x: 0, y: 100, w: 400, h: 600 }, parentIdx: 3, testID: 'list' },
    { id: 5, name: 'ScrollView', rect: { x: 0, y: 100, w: 400, h: 600 }, parentIdx: 4 },
    { id: 6, name: 'Item', rect: null, parentIdx: 5, testID: 'item-1' },
  ] };
  const t = pruneTree(raw);
  assert.deepEqual(testIDs(t.nodes), ['item-1', 'list', 'main']);
  assert.equal(t.stats.offScreen, 3);
});

test('the tap point is the centre of the visible part; none for a rect fully off screen', () => {
  assert.deepEqual(tapPoint({ x: 0, y: 780, w: 300, h: 400 }, 400, 800), { x: 150, y: 790 });
  assert.deepEqual(tapPoint({ x: 20, y: 600, w: 100, h: 40 }, 400, 800), { x: 70, y: 620 });
  assert.equal(tapPoint({ x: -500, y: 0, w: 300, h: 800 }, 400, 800), null);
  assert.deepEqual(tapPoint({ x: 0, y: 780, w: 300, h: 400 }), { x: 150, y: 980 });
  const t = pruneTree({ screenW: 400, screenH: 800, components: [{ id: 0, name: 'Card', rect: { x: 0, y: 780, w: 300, h: 400 }, parentIdx: -1, testID: 'peek' }] });
  assert.match(formatText(t), /Card \[testID=peek\] \(tap 150,790\)/);
});

test('onScreenOnly false keeps off-screen subtrees', () => {
  const ids = testIDs(pruneTree(RAW, { onScreenOnly: false }).nodes);
  assert.ok(ids.includes('Drawer'));
  assert.ok(!testIDs(pruneTree(RAW).nodes).includes('Drawer'));
});

test('a testID drilled through layers is shown once, on the topmost', () => {
  const raw = { screenW: 400, screenH: 800, components: [
    { id: 0, name: 'Wrapper', rect: { x: 0, y: 0, w: 50, h: 50 }, parentIdx: -1, testID: 'X' },
    { id: 1, name: 'Inner', rect: { x: 0, y: 0, w: 50, h: 50 }, parentIdx: 0, testID: 'X' },
    { id: 2, name: 'Leaf', rect: { x: 0, y: 0, w: 10, h: 10 }, parentIdx: 1, text: 'hi' },
  ] };
  const t = pruneTree(raw);
  assert.deepEqual(t.nodes.map((n) => n.entry.name), ['Wrapper', 'Leaf']);
  assert.equal(t.stats.sameTestID, 1);
});

test('a content-free sole leaf under a testID goes; a leaf with text stays', () => {
  const raw = { screenW: 400, screenH: 800, components: [
    { id: 0, name: 'Btn', rect: { x: 0, y: 0, w: 50, h: 50 }, parentIdx: -1, testID: 'B' },
    { id: 1, name: 'Icon', rect: { x: 5, y: 5, w: 10, h: 10 }, parentIdx: 0 },
    { id: 2, name: 'Btn2', rect: { x: 0, y: 60, w: 50, h: 50 }, parentIdx: -1, testID: 'B2' },
    { id: 3, name: 'Label', rect: { x: 5, y: 65, w: 10, h: 10 }, parentIdx: 2, text: 'Submit' },
  ] };
  const t = pruneTree(raw);
  assert.deepEqual(t.nodes.map((n) => n.entry.name), ['Btn', 'Btn2', 'Label']);
  assert.equal(t.stats.soleChildLeaf, 1);
});

test('maxNodes collapses the longest wrapper chain and says so', () => {
  const components = [{ id: 0, name: 'Top', rect: { x: 0, y: 0, w: 100, h: 100 }, parentIdx: -1, testID: 'top' }];
  for (let i = 1; i <= 4; i++) components.push({ id: i, name: `W${i}`, rect: { x: i * 2, y: i * 2, w: 90 - i * 10, h: 90 - i * 10 }, parentIdx: i - 1 });
  components.push({ id: 5, name: 'Leaf', rect: { x: 40, y: 40, w: 5, h: 5 }, parentIdx: 4, testID: 'leaf' });
  const raw = { screenW: 400, screenH: 800, components };
  assert.equal(pruneTree(raw).nodes.length, 6);
  const t = pruneTree(raw, { maxNodes: 3 });
  assert.equal(t.collapsedCount, 3);
  assert.deepEqual(t.nodes.map((n) => [n.entry.name, n.via ?? 0]), [['Top', 0], ['W1', 4], ['Leaf', 0]]);
  assert.match(formatText(t), /\.\.\. via 4 wrappers[\s\S]*3 wrapper nodes collapsed\. Run without --max-nodes/);
  const tight = pruneTree(raw, { maxNodes: 1 });
  assert.equal(tight.collapsedCount, 3, 'only the outer chain hides nodes');
  assert.equal(tight.nodes.length, 3);
});

test('the text form: name, text, testID and tap point in points, two spaces per level', () => {
  const text = formatText(pruneTree(RAW));
  assert.match(text, /^Screen: 400x800 pt/);
  assert.match(text, /\n {2}Button "Go" \[testID=Main-go\] \(tap 70,620\)\n?/);
  assert.match(text, /\n {4}Text "Hello there" \(tap 110,30\)/);
});

test('an empty screen says so', () => {
  assert.equal(formatText(pruneTree({ screenW: 400, screenH: 800, components: [] })), 'No visible components found on screen.');
});

test('--grep keeps matches and their ancestors; --id matches one testID exactly', () => {
  const t = pruneTree(RAW);
  const g = filterNodes(t.nodes, makeMatcher({ grep: 'hello there' }));
  assert.deepEqual(g.map((n) => n.entry.name), ['Screen', 'Header', 'Text']);
  const byId = filterNodes(t.nodes, makeMatcher({ id: 'Card-1' }));
  assert.deepEqual(byId.map((n) => n.entry.testID ?? n.entry.name), ['Main-root', 'ScrollView', 'Card-1']);
  const none = filterNodes(t.nodes, makeMatcher({ id: 'nope' }));
  assert.deepEqual(none, []);
  assert.match(formatText(t, none), /nothing matches the filter/);
});

test('the JSON form carries depth, parent position, rect and tap', () => {
  const t = pruneTree(RAW);
  const j = toJson(t, filterNodes(t.nodes, makeMatcher({ id: 'Main-go' })));
  assert.deepEqual(j.screen, { w: 400, h: 800 });
  assert.deepEqual(j.nodes[1], { depth: 1, parent: 0, name: 'Button', accLabel: 'Go', testID: 'Main-go', rect: [20, 600, 100, 40], tap: { x: 70, y: 620 } });
  assert.equal(j.nodes[0].parent, null);
});

test('testIDs lists each shown testID once, sorted', () => {
  assert.deepEqual(testIDs(pruneTree(RAW).nodes), ['Card-1', 'Card-1-inner', 'Main-go', 'Main-header', 'Main-root']);
});

async function withFake(answer, fn) {
  const fake = await startFakeInspector({ handler: withTreeScript(answer) });
  const client = await connect(`ws://localhost:${fake.port}/inspector/debug?device=fake&page=1`);
  try { await fn(client, fake); } finally { await client.close(); await fake.close(); }
}

test('readComponentTree runs the vendored script over the binding and returns its data', () => withFake(RAW, async (client, fake) => {
  const raw = await readComponentTree(client);
  assert.equal(raw.components.length, RAW.components.length);
  const [session] = fake.sessions;
  assert.ok(session.received.some((m) => m.method === 'Runtime.addBinding' && m.params.name === TREE_BINDING));
}));

test('an error from the script (no DevTools hook) rejects with exit 1 and its text', () => withFake({ error: 'No DevTools hook' }, async (client) => {
  await assert.rejects(readComponentTree(client), (err) => err.exitCode === 1 && /could not be read: No DevTools hook/.test(err.message));
}));

test('no answer rejects with exit 3 naming the timeout', () => withFake(null, async (client) => {
  await assert.rejects(readComponentTree(client, { timeoutMs: 200 }), (err) => err.exitCode === 3 && /within 200 ms/.test(err.message));
}));
