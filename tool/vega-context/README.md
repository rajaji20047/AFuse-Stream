# Vega providerContext bundle — build tooling

This directory builds the JavaScript runtime that Vega providers run
against inside Fuse (Phase 1 of the Vega bridge). The output is a single
file shipped as a Flutter asset and loaded at runtime:

- **Source:** `context-fuse.mjs` — real axios + real cheerio from npm,
  with the HTTP transport delegated to Fuse's Dart bridge
  (`_dartAsyncCall('http_request', …)`), a kvStore backed by the bridge
  `get_storage` / `set_storage` channels, `commonHeaders`, and an
  `openWebView` stub. It exports a per-provider factory,
  `createVegaProviderContext(token)`, because the bridge capability token
  is per-provider (one namespace + token per Vega provider).
- **Output:** `../../assets/vega/vega_context_bundle.js` — loaded once per
  app run by `VegaProviderContext.ensureLoaded` (see
  `lib/core/extensions/engine/vega_provider_context.dart`).
- **Why an asset file, not a Dart string:** the bundle is ~750 KB of
  minified JS. An asset keeps it out of the Dart source and out of the
  compiled snapshot; it is read with `rootBundle.loadString` only when a
  Vega provider is first used.

## Rebuild

```sh
cd tool/vega-context
npm install   # axios, cheerio, esbuild (+ quickjs-emscripten for the smoke test)
npm run build # writes ../../assets/vega/vega_context_bundle.js
npm run smoke # runs the bundle in QuickJS against the live Internet Archive
```

The build fails if the bundle still contains a bare `require()` call:
QuickJS has no module loader, and the Dart-side CJS loader only stubs
`require` for node builtins.

## Notes

- No `atob` shim is bundled: Fuse's JS worker already defines
  `globalThis.atob` / `btoa` (`js_engine_worker.dart`).
- The `set_storage` bridge channel never replies on the Dart side, so
  kvStore writes go through fire-and-forget `sendMessage` (the same
  pattern `.sky` `setPreference` uses). Awaiting them would hang forever.
- `openWebView` is a stub returning `success: false` for now. Real WAF
  handling via `challenge_browser` is a later decision.
- Pinned versions match the Phase-0 spike (axios 1.21.1, cheerio 1.2.0,
  esbuild 0.27.0, quickjs-emscripten 0.32.0).
