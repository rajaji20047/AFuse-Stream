// Builds the Vega providerContext bundle for Fuse.
//
//   npm install && npm run build
//
// Output: assets/vega/vega_context_bundle.js (loaded at runtime by
// VegaProviderContext from the Flutter asset bundle — never embedded as a
// Dart string).
//
// The bundle must contain no bare require() calls: QuickJS has no module
// loader, and the Dart-side CJS loader only provides a stub that returns {}
// for node builtins and throws otherwise. The build fails if one remains.
import * as esbuild from 'esbuild';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const dir = path.dirname(fileURLToPath(import.meta.url));
const outFile = path.resolve(dir, '../../assets/vega/vega_context_bundle.js');

await esbuild.build({
  entryPoints: [path.join(dir, 'context-fuse.mjs')],
  bundle: true,
  platform: 'browser',
  format: 'cjs',
  target: 'es2019',
  outfile: outFile,
  banner: {
    js: '// Vega providerContext bundle — built from tool/vega-context/context-fuse.mjs. Do not edit by hand.',
  },
});

const out = readFileSync(outFile, 'utf8');
const requires = out.match(/(^|[^a-zA-Z0-9_$])require\s*\(/g);
if (requires) {
  console.error(
    `FAIL: built bundle still contains ${requires.length} require() call(s)`,
  );
  process.exit(1);
}
console.log(`OK: ${outFile} (${out.length} bytes, no require() calls)`);
