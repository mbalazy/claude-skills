// react-profile-fixture.mjs - for tests only: a small synthetic React profile
// in the format `rn-profile.mjs react stop` writes.

const mount = { isFirstMount: true, props: null, state: null, hooks: null, context: null, didHooksChange: false };
const change = (o) => ({ isFirstMount: false, props: [], state: null, hooks: [], context: false, didHooksChange: false, ...o });

// Screen > List > Row. Commit 1: Screen's state changes, List and Row re-render because of it;
// fiber 9 has no name (unmounted before stop). Commit 2: Row gets a new prop.
export const PROFILE = {
  format: 'rn-profile-react/1',
  durationMs: 2000,
  endedBy: 'stop',
  react: {
    displayNameById: { 1: 'Screen', 2: 'List', 3: 'Row' },
    dataForRoots: [{
      commitData: [
        { timestamp: 0, duration: 5,
          fiberActualDurations: [[1, 5], [2, 3], [3, 1]], fiberSelfDurations: [[1, 2], [2, 2], [3, 1]],
          changeDescriptions: [[1, mount], [2, mount], [3, mount]] },
        { timestamp: 500, duration: 30,
          fiberActualDurations: [[1, 28], [2, 20], [3, 6], [9, 2]], fiberSelfDurations: [[1, 8], [2, 14], [3, 6], [9, 2]],
          changeDescriptions: [[1, change({ hooks: [0], didHooksChange: true })], [2, change({})], [3, change({})]] },
        { timestamp: 1500, duration: 2,
          fiberActualDurations: [[3, 1.5], [2, 0]], fiberSelfDurations: [[3, 1.5], [2, 0]],
          changeDescriptions: [[3, change({ props: ['item'] })]] },
      ],
    }],
  },
  fiberMeta: {
    Screen: { hookTypes: ['State', 'Effect'], parentName: null, isCompilerOptimized: false },
    List: { hookTypes: null, parentName: 'Screen', isCompilerOptimized: false },
    Row: { hookTypes: null, parentName: 'List', isCompilerOptimized: false },
  },
  cpuProfile: null,
};
