// Switches for rig experiments (edit the constants, then reload). Imported FIRST by the entry.
import { TurboModuleRegistry } from 'react-native';
export const PROBE_PORT = 8199;
export const THROW_AT_LOAD = false;
export const ENFORCE_MISSING = false;
if (THROW_AT_LOAD) throw new Error('[FIXTURE] deliberate throw at load');
if (ENFORCE_MISSING) TurboModuleRegistry.getEnforcing('NoSuchModule');
