import 'package:flutter/services.dart';

import 'js_engine.dart';

/// Loads the Vega providerContext bundle into the shared QuickJS worker.
///
/// The bundle (`assets/vega/vega_context_bundle.js`, built from
/// `tool/vega-context/context-fuse.mjs`) publishes a factory,
/// `globalThis.__vegaCreateProviderContext(token)`, that builds one
/// `providerContext` per Vega provider: real axios (Dart-bridge transport),
/// real cheerio, a kvStore backed by the bridge storage channels,
/// `commonHeaders`, and a real `openWebView` (visible WebView dialog via
/// the `open_webview` bridge channel).
///
/// The bundle is loaded once per engine, not once per provider: the factory
/// is shared, and each provider's installer calls it with its own bridge
/// token. Loading is guarded on both sides — a Dart-side engine-identity
/// check (so a fresh engine reloads it) and a JS-side guard (so a repeat
/// load is a no-op).
///
/// The asset is read with `rootBundle.loadString` at first use and never
/// embedded as a Dart string: it is ~750 KB of minified JS.
class VegaProviderContext {
  VegaProviderContext._();

  /// The shipped bundle.
  static const String kContextBundleAsset =
      'assets/vega/vega_context_bundle.js';

  /// Global the bundle's factory is published on after loading.
  static const String kFactoryGlobal = '__vegaCreateProviderContext';

  static int? _loadedForEngineHash;

  /// Loads the context bundle into [engine]'s worker if it is not already
  /// there. Throws when the asset cannot be read or the eval fails, so a
  /// Vega provider init fails closed instead of running without a context.
  static Future<void> ensureLoaded(JsEngineService engine) async {
    final engineHash = identityHashCode(engine);
    if (_loadedForEngineHash == engineHash) return;

    final bundle = await rootBundle.loadString(kContextBundleAsset);
    await engine.loadScript(
      """
(function(){
if (globalThis["$kFactoryGlobal"]) return;
var module = {exports: {}};
var exports = module.exports;
var require = function(name) {
  if (name.indexOf("node:") === 0) return {};
  var builtins = ["fs","path","http","https","stream","zlib","url","os","crypto","buffer","events","util","querystring","net","tls","child_process"];
  if (builtins.indexOf(name) >= 0) return {};
  throw new Error("require(" + name + ") is not available in the Vega sandbox");
};
$bundle
globalThis["$kFactoryGlobal"] = module.exports.createVegaProviderContext;
})();
""",
      tag: 'vega-context',
    );
    _loadedForEngineHash = engineHash;
  }
}
