// vendor-loader.mjs - lets our .mjs glue import the vendored Argent files
// exactly as upstream wrote them.
//
// Node runs TypeScript by stripping types (no build step), but Argent writes
// relative imports without an extension (`from "./xml-parser"`), which Node's
// ESM resolver refuses. This module registers a resolve hook that, for
// importers inside the vendor directory only, tries `<spec>.ts` and
// `<spec>/index.ts`, and maps the few npm package names a vendored file needs
// to small local shims (SHIMS below; empty until a vendored file needs one).
//
// Import it once, before the first vendored import:
//   import { vendorPath } from './vendor-loader.mjs';
//   const { something } = await import(vendorPath('packages/tool-server/src/...ts'));

import { registerHooks } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { realpathSync, existsSync } from 'node:fs';

export const VENDOR_ROOT = fileURLToPath(new URL('./vendor/argent/', import.meta.url));

/** npm name -> absolute path of a local shim module. */
export const SHIMS = new Map();

if (process.features?.typescript !== 'strip' && process.features?.typescript !== 'transform') {
  throw new Error(
    `This Node (${process.version}) cannot run TypeScript without a build step; ` +
      'the vendored Argent files need Node >= 23.6 with type stripping on.'
  );
}

// Node identifies a module by its real path, so the roots are compared real.
const real = (dir) => (existsSync(dir) ? realpathSync(dir) : dir);
const asRootURL = (dir) => pathToFileURL(real(dir)).href.replace(/\/?$/, '/');
const roots = new Set([asRootURL(VENDOR_ROOT)]);

/** Treat another directory like the vendor root (tests use a temporary copy). */
export function addVendorRoot(dir) {
  roots.add(asRootURL(dir));
}

const insideVendor = (parentURL) => !!parentURL && [...roots].some((r) => parentURL.startsWith(r));
const RELATIVE_NO_EXT = /^\.{1,2}\/.*?(?<!\.(?:ts|mts|js|mjs|cjs|json))$/;

registerHooks({
  resolve(specifier, context, next) {
    if (insideVendor(context.parentURL)) {
      if (SHIMS.has(specifier)) return next(pathToFileURL(SHIMS.get(specifier)).href, context);
      if (RELATIVE_NO_EXT.test(specifier)) {
        for (const candidate of [`${specifier}.ts`, `${specifier}/index.ts`]) {
          try { return next(candidate, context); } catch { /* try the next form */ }
        }
      }
    }
    return next(specifier, context);
  },
});

/** Absolute file URL of a vendored file, by its upstream path. */
export function vendorPath(upstreamPath) {
  return pathToFileURL(join(VENDOR_ROOT, upstreamPath)).href;
}
