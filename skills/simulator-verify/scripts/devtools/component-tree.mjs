// component-tree.mjs - the React component tree of the screen the app shows.
//
// readComponentTree() runs Argent's component-tree script (vendored unmodified,
// vendor/argent/packages/tool-server/src/utils/debugger/scripts/component-tree.ts)
// in the app: it walks the React fiber tree, measures host views and answers
// over a Runtime binding with { screenW, screenH, components }.
//
// pruneTree() is a port of buildTextTree() from Argent's
// packages/tool-server/src/tools/debugger/debugger-component-tree.ts
// (Copyright 2026 Software Mansion S.A., Apache License 2.0; see
// vendor/argent/NOTICE). The pruning rules are Argent's. Changed here:
//   - it returns a node list (depth, entry, collapsed wrappers) that both the
//     text and the JSON output are made from, instead of the text alone;
//   - no screen orientation input: the tool reads it from Argent's native
//     service, which is not used here, so rects stay in the app window's axes;
//   - the tap point is the rect's centre in points (what `sim-ui.sh tap X Y`
//     takes on a portrait simulator), not a 0..1 fraction of the screen;
//   - a component carrying a testID its parent does not carry is never merged
//     into that parent (same name, same rect), and a sibling repeating the
//     previous one is skipped only when nothing inside it carries a testID or
//     text, so every testID the app renders on screen stays in the output;
//   - the "sole-child leaf" rule drops only a leaf with no text and no label
//     (Argent's comment says content-free; its code also dropped a leaf with
//     text, e.g. the "Submit" inside a Button carrying only a testID);
//   - "off screen" means the rect does not touch the screen at all; Argent
//     tests the rect's centre, which dropped a card whose top edge shows at
//     the bottom of the screen while the accessibility tree lists it;
//   - filters (grep, testID) and a testID list are ours.

import { vendorPath } from './vendor-loader.mjs';
import { CdpError } from './cdp.mjs';

export const TREE_BINDING = '__argent_callback';
export const TREE_TIMEOUT_MS = 15_000;

/** Runs the vendored script in the app; resolves with the raw { screenW, screenH, components }. */
export async function readComponentTree(client, { includeSkipped = false, timeoutMs = TREE_TIMEOUT_MS } = {}) {
  const { makeComponentTreeScript } = await import(vendorPath('packages/tool-server/src/utils/debugger/scripts/component-tree.ts'));
  const requestId = crypto.randomUUID();
  const script = makeComponentTreeScript({ includeSkipped, requestId });
  const payload = await client.evaluateWithBinding(script, { binding: TREE_BINDING, requestId, timeoutMs });
  if (typeof payload.result !== 'string') throw new CdpError('The component-tree script answered without a result.', 'protocol', 1);
  const raw = JSON.parse(payload.result);
  if (raw.error) throw new CdpError(`The component tree could not be read: ${raw.error}`, 'exception', 1);
  return raw;
}

/** c carries a testID that other does not: merging c away would lose it. */
const ownTestID = (c, other) => !!c.testID && c.testID !== other.testID;

const near = (a, b) =>
  Math.abs(a.x - b.x) < 8 && Math.abs(a.y - b.y) < 8 && Math.abs(a.w - b.w) < 8 && Math.abs(a.h - b.h) < 8;

/**
 * Argent's pruning of the raw component list. Returns
 * { screenW, screenH, nodes: [{ id, depth, entry, via? }], collapsedCount, stats }
 * in render order; `via` = number of single-child wrappers collapsed under a node.
 * opts: { onScreenOnly = true, maxNodes }
 */
export function pruneTree(data, { onScreenOnly = true, maxNodes } = {}) {
  const { screenW, screenH, components } = data;
  const stats = { sameNameDedup: 0, offScreen: 0, sameTestID: 0, fullScreenWrapper: 0, ancestorText: 0, contentFreeWrapper: 0, soleChildLeaf: 0 };
  const result = { screenW, screenH, nodes: [], collapsedCount: 0, stats };
  if (!components?.length) return result;

  const canNormalize = screenW > 0 && screenH > 0;
  const removed = new Set();
  const liveParent = (idx) => {
    while (idx >= 0 && removed.has(idx)) idx = components[idx].parentIdx;
    return idx;
  };

  // Same name and nearly the same rect as the parent (ScrollView x3 and the like).
  for (const c of components) {
    if (removed.has(c.id)) continue;
    const p = liveParent(c.parentIdx);
    const parent = p >= 0 ? components[p] : null;
    if (parent && parent.name === c.name && parent.rect && c.rect && near(parent.rect, c.rect) && !ownTestID(c, parent)) {
      removed.add(c.id);
      stats.sameNameDedup++;
    }
  }

  // Off-screen subtrees (drawers, hidden tabs), rectless children included.
  if (canNormalize && onScreenOnly) {
    const kids = new Map();
    for (const c of components) {
      if (c.parentIdx >= 0) (kids.get(c.parentIdx) ?? kids.set(c.parentIdx, []).get(c.parentIdx)).push(c.id);
    }
    const removeSubtree = (id) => {
      removed.add(id);
      stats.offScreen++;
      for (const k of kids.get(id) ?? []) removeSubtree(k);
    };
    for (const c of components) {
      if (removed.has(c.id) || !c.rect) continue;
      const r = c.rect;
      if (r.x >= screenW || r.y >= screenH || r.x + r.w <= 0 || r.y + r.h <= 0) removeSubtree(c.id);
    }
    for (const c of components) {
      if (removed.has(c.id) || c.rect) continue;
      let a = c.parentIdx;
      while (a >= 0 && !components[a].rect) {
        if (removed.has(a)) break;
        a = components[a].parentIdx;
      }
      if (a >= 0 && removed.has(a)) {
        removed.add(c.id);
        stats.offScreen++;
      }
    }
  }

  // A testID drilled through HOC layers: keep the topmost.
  for (const c of components) {
    if (removed.has(c.id) || !c.testID) continue;
    for (let a = c.parentIdx; a >= 0; a = components[a].parentIdx) {
      if (!removed.has(a) && components[a].testID === c.testID) {
        removed.add(c.id);
        stats.sameTestID++;
        break;
      }
    }
  }

  // Full-screen spans with nothing on them.
  if (canNormalize) {
    for (const c of components) {
      if (removed.has(c.id) || c.text || c.testID || c.accLabel || !c.rect) continue;
      if (Math.abs(c.rect.x) <= 5 && Math.abs(c.rect.y) <= 5 && Math.abs(c.rect.w - screenW) <= 5 && Math.abs(c.rect.h - screenH) <= 5) {
        removed.add(c.id);
        stats.fullScreenWrapper++;
      }
    }
  }

  // Text an ancestor (up to 6 levels) already shows.
  for (const c of components) {
    const shown = c.text ?? c.accLabel;
    if (removed.has(c.id) || !shown || c.testID) continue;
    let a = c.parentIdx;
    let depth = 0;
    while (a >= 0 && depth < 6) {
      if (removed.has(a)) { a = components[a].parentIdx; continue; }
      const aShown = components[a].text ?? components[a].accLabel;
      if (aShown && aShown.length >= shown.length && aShown.includes(shown)) {
        removed.add(c.id);
        stats.ancestorText++;
        break;
      }
      a = components[a].parentIdx;
      depth++;
    }
  }

  // Content-free wrappers the size of their parent.
  for (const c of components) {
    if (removed.has(c.id) || c.text || c.testID || c.accLabel || !c.rect) continue;
    const p = liveParent(c.parentIdx);
    const parent = p >= 0 ? components[p] : null;
    if (parent && parent.rect && near(parent.rect, c.rect)) {
      removed.add(c.id);
      stats.contentFreeWrapper++;
    }
  }

  let childrenOf = new Map();
  let roots = [];
  const link = () => {
    childrenOf = new Map();
    roots = [];
    for (const c of components) {
      if (removed.has(c.id)) continue;
      const p = liveParent(c.parentIdx);
      if (p === -1) roots.push(c.id);
      else (childrenOf.get(p) ?? childrenOf.set(p, []).get(p)).push(c.id);
    }
  };
  link();

  // A content-free leaf that is the only child of a parent with text or a testID.
  // (Argent drops the leaf even when it carries text; the text is kept here.)
  const soleLeaves = [];
  for (const [parentId, children] of childrenOf) {
    if (children.length !== 1) continue;
    const child = components[children[0]];
    const parent = components[parentId];
    if (child.testID || child.text || child.accLabel || (!parent.text && !parent.accLabel && !parent.testID) || childrenOf.has(child.id)) continue;
    soleLeaves.push(child.id);
  }
  if (soleLeaves.length) {
    for (const id of soleLeaves) removed.add(id);
    stats.soleChildLeaf += soleLeaves.length;
    link();
  }

  // Over maxNodes: collapse the longest chains of single-child wrappers first.
  const collapsed = new Map();
  const count = (id) => 1 + (childrenOf.get(id) ?? []).reduce((n, k) => n + count(k), 0);
  const total = roots.reduce((n, r) => n + count(r), 0);
  const isWrapper = (id) => {
    const c = components[id];
    return (childrenOf.get(id)?.length === 1) && !c.text && !c.testID && !c.accLabel;
  };
  if (maxNodes !== undefined && total > maxNodes) {
    const chains = [];
    const findChains = (id) => {
      if (isWrapper(id)) {
        let len = 0;
        for (let cur = id; isWrapper(cur); cur = childrenOf.get(cur)[0]) len++;
        if (len >= 2) chains.push({ start: id, len });
      }
      for (const k of childrenOf.get(id) ?? []) findChains(k);
    };
    roots.forEach(findChains);
    chains.sort((a, b) => b.len - a.len);
    const excess = total - maxNodes;
    for (const ch of chains) {
      if (result.collapsedCount >= excess) break;
      collapsed.set(ch.start, ch.len);
      result.collapsedCount += ch.len - 1;
    }
  }

  const carriesContent = (id) => {
    const e = components[id];
    return !!(e.testID || e.text || e.accLabel) || (childrenOf.get(id) ?? []).some(carriesContent);
  };
  const render = (id, depth) => {
    const c = components[id];
    if (!c) return;
    const via = collapsed.get(id);
    if (via !== undefined) {
      let cur = id;
      for (let i = 0; i < via; i++) cur = childrenOf.get(cur)[0];
      result.nodes.push({ id, depth, entry: c, via });
      render(cur, depth + 1);
      return;
    }
    result.nodes.push({ id, depth, entry: c });
    let prev = null;
    for (const k of childrenOf.get(id) ?? []) {
      const child = components[k];
      // A sibling repeating the previous one (same name, same place) is skipped,
      // unless something in it carries a testID or text (stacked layers).
      if (prev && child.name === prev.name && child.rect && prev.rect && near(child.rect, prev.rect) && !carriesContent(k)) continue;
      render(k, depth + 1);
      prev = child;
    }
  };
  for (const r of roots) render(r, 0);
  return result;
}

/**
 * Keep the nodes for which match(entry) is true, plus their ancestors (so the
 * nesting still reads). Depths are kept. Without a match the list is empty.
 */
export function filterNodes(nodes, match) {
  const keep = new Set();
  const stack = [];
  nodes.forEach((n, i) => {
    stack.length = n.depth;
    stack.push(i);
    if (match(n.entry)) for (const j of stack) keep.add(j);
  });
  return nodes.filter((_, i) => keep.has(i));
}

/** A matcher for --grep (regex on name, text, accessibility label or testID) and --id (exact testID). */
export function makeMatcher({ grep, id } = {}) {
  const re = grep ? new RegExp(grep, 'i') : null;
  return (e) => (id === undefined || e.testID === id) &&
    (!re || [e.name, e.text, e.accLabel, e.testID].some((v) => typeof v === 'string' && re.test(v)));
}

export function tapPoint(rect) {
  return rect ? { x: Math.round(rect.x + rect.w / 2), y: Math.round(rect.y + rect.h / 2) } : null;
}

function label(e) {
  let s = e.name;
  const shown = e.text ?? e.accLabel;
  if (shown) s += ` "${shown}"`;
  if (e.testID) s += ` [testID=${e.testID}]`;
  const tap = tapPoint(e.rect);
  if (tap) s += ` (tap ${tap.x},${tap.y})`;
  return s;
}

/** The text form: one line per component, two spaces per level. */
export function formatText(tree, nodes = tree.nodes) {
  if (!tree.nodes.length) return 'No visible components found on screen.';
  const lines = [`Screen: ${tree.screenW}x${tree.screenH} pt (tap = rect centre in points)`, ''];
  for (const n of nodes) {
    const indent = '  '.repeat(n.depth);
    lines.push(indent + label(n.entry));
    if (n.via) lines.push(`${indent}  ... via ${n.via} wrapper${n.via > 1 ? 's' : ''}`);
  }
  if (!nodes.length) lines.push('(nothing matches the filter)');
  if (tree.collapsedCount > 0) {
    lines.push('', `... ${tree.collapsedCount} wrapper node${tree.collapsedCount > 1 ? 's' : ''} collapsed. Run without --max-nodes to see the full tree.`);
  }
  return lines.join('\n');
}

/** The JSON form: the same nodes, flat, with depth and parent position. */
export function toJson(tree, nodes = tree.nodes) {
  const parents = [];
  return {
    screen: { w: tree.screenW, h: tree.screenH },
    collapsed: tree.collapsedCount,
    nodes: nodes.map((n, i) => {
      parents.length = n.depth;
      const parent = n.depth > 0 ? parents[n.depth - 1] ?? null : null;
      parents.push(i);
      const e = n.entry;
      return {
        depth: n.depth, parent, name: e.name,
        ...(e.text !== undefined && { text: e.text }),
        ...(e.accLabel !== undefined && { accLabel: e.accLabel }),
        ...(e.testID !== undefined && { testID: e.testID }),
        rect: e.rect ? [e.rect.x, e.rect.y, e.rect.w, e.rect.h] : null,
        tap: tapPoint(e.rect),
        ...(n.via && { via: n.via }),
      };
    }),
  };
}

/** Unique testIDs of the given nodes, sorted. */
export function testIDs(nodes) {
  return [...new Set(nodes.map((n) => n.entry.testID).filter(Boolean))].sort();
}
