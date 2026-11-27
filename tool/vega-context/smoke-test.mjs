// Smoke test for the shipped Vega providerContext bundle.
//
// Runs assets/vega/vega_context_bundle.js inside QuickJS
// (quickjs-emscripten — same engine family as Fuse's flutter_js_ng worker)
// with host stubs standing in for the Dart bridge:
//
//   _dartAsyncCall('http_request', …)  -> node fetch (15 s cap, like _handleHttp)
//   _dartAsyncCall('get_storage', …)   -> in-memory Map (null when missing)
//   sendMessage('set_storage', …)      -> in-memory Map (null value deletes)
//   setTimeout / clearTimeout          -> node timers (the worker has them too)
//   atob                               -> pure-JS shim (the Fuse worker has it)
//
// Then loads the real Zenda-Cross Internet Archive dist bundles and runs the
// known-good chain: getPosts -> getMeta ("Sex Madness") -> getStream.
// Every call must succeed; the Sex Madness stream list must hold 4 streams.
//
// Usage: npm run smoke   (needs network — it fetches the provider bundles
// from raw.githubusercontent.com, like the app will).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { newAsyncRuntime } from 'quickjs-emscripten';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const CALL_TIMEOUT_MS = 60000;
const IA_BASE =
  'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/main/dist/internetArchive';

const failures = [];
function check(name, ok, detail) {
  console.log(`[${ok ? 'OK  ' : 'FAIL'}] ${name} ${detail || ''}`);
  if (!ok) failures.push(name);
}

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`fetch ${url} -> ${res.status}`);
  return res.text();
}

async function main() {
  const runtime = await newAsyncRuntime();
  const vm = runtime.newContext();

  // ---------- in-memory bridge store (stands in for _extensionsBox) ------
  const store = new Map();

  // ---------- host functions ----------
  const dartAsyncCallFn = vm.newFunction(
    '_dartAsyncCall',
    (messageIdHandle, paramsHandle) => {
      const messageId = vm.getString(messageIdHandle);
      const params = vm.dump(paramsHandle) || {};
      const deferred = vm.newPromise();
      (async () => {
        try {
          if (messageId === 'http_request') {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 15000);
            try {
              const res = await fetch(params.url, {
                method: params.method || 'GET',
                headers: params.headers || {},
                body: params.body,
                signal: controller.signal,
              });
              const bodyText = await res.text();
              const headers = {};
              res.headers.forEach((v, k) => {
                headers[k] = v;
              });
              const obj = vm.newObject();
              vm.setProp(obj, 'code', vm.newNumber(res.status));
              vm.setProp(obj, 'statusCode', vm.newNumber(res.status));
              vm.setProp(obj, 'status', vm.newNumber(res.status));
              const hObj = vm.newObject();
              for (const [k, v] of Object.entries(headers)) {
                vm.setProp(hObj, k, vm.newString(v));
              }
              vm.setProp(obj, 'headers', hObj);
              vm.setProp(obj, 'body', vm.newString(bodyText));
              vm.setProp(obj, 'finalUrl', vm.newString(res.url));
              deferred.resolve(obj);
              obj.dispose();
              hObj.dispose();
            } finally {
              clearTimeout(timer);
            }
          } else if (messageId === 'get_storage') {
            const v = store.has(params.key) ? store.get(params.key) : null;
            deferred.resolve(v === null ? vm.null : vm.newString(v));
          } else {
            deferred.reject(vm.newString(`unknown bridge channel ${messageId}`));
          }
        } catch (e) {
          deferred.reject(vm.newString(String((e && e.message) || e)));
        }
        // NOTE: no deferred.dispose() here, deliberately. Disposing the
        // deferred synchronously after resolving frees the promise handle
        // before the guest's `await` has attached to it, and the guest then
        // throws QuickJSUseAfterFree (bisected 2026-11-27: sync
        // resolve+dispose fails, resolve-then-dispose-on-a-later-tick and
        // never-dispose both pass). The real Dart bridge has no such handle
        // — _resolveDartAsync just splices JSON into an eval — so this is a
        // quickjs-emscripten host-stub concern only. The test process is
        // short-lived; leaking one deferred per bridge call is harmless.
      })();
      return deferred.handle;
    },
  );
  vm.setProp(vm.global, '_dartAsyncCall', dartAsyncCallFn);
  dartAsyncCallFn.dispose();

  const sendMessageFn = vm.newFunction('sendMessage', (chHandle, jsonHandle) => {
    const ch = vm.getString(chHandle);
    const json = vm.getString(jsonHandle);
    if (ch === 'set_storage') {
      try {
        const p = JSON.parse(json);
        if (p.value === null || p.value === undefined) store.delete(p.key);
        else store.set(p.key, p.value);
      } catch (e) {
        console.error('sendMessage set_storage parse error', e);
      }
    }
    return vm.null;
  });
  vm.setProp(vm.global, 'sendMessage', sendMessageFn);
  sendMessageFn.dispose();

  // setTimeout / clearTimeout (the Fuse worker provides them via js_set_timeout).
  let timerSeq = 0;
  const nodeTimers = new Map();
  const setTimeoutFn = vm.newFunction('setTimeout', (fnHandle, delayHandle) => {
    const id = ++timerSeq;
    const delay = vm.getNumber(delayHandle) || 0;
    const handle = setTimeout(() => {
      nodeTimers.delete(id);
      try {
        vm.callFunction(fnHandle, vm.undefined);
      } catch (e) {
        console.error('timer callback error', e);
      }
    }, delay);
    nodeTimers.set(id, handle);
    return vm.newNumber(id);
  });
  vm.setProp(vm.global, 'setTimeout', setTimeoutFn);
  setTimeoutFn.dispose();
  const clearTimeoutFn = vm.newFunction('clearTimeout', (idHandle) => {
    const id = vm.getNumber(idHandle);
    const h = nodeTimers.get(id);
    if (h) {
      clearTimeout(h);
      nodeTimers.delete(id);
    }
    return vm.undefined;
  });
  vm.setProp(vm.global, 'clearTimeout', clearTimeoutFn);
  clearTimeoutFn.dispose();

  // atob shim (the Fuse worker defines it; plain QuickJS does not).
  const atobCode = `
function atob(input) {
  var str = String(input).replace(/=+$/, '');
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = '';
  var i = 0;
  for (; i + 4 <= str.length; i += 4) {
    var n = (chars.indexOf(str[i]) << 18) | (chars.indexOf(str[i+1]) << 12) | (chars.indexOf(str[i+2]) << 6) | chars.indexOf(str[i+3]);
    out += String.fromCharCode((n >> 16) & 255, (n >> 8) & 255, n & 255);
  }
  var rem = str.length - i;
  if (rem === 2) {
    var n2 = (chars.indexOf(str[i]) << 2) | (chars.indexOf(str[i+1]) >> 4);
    out += String.fromCharCode(n2 & 255);
  } else if (rem === 3) {
    var n3 = (chars.indexOf(str[i]) << 10) | (chars.indexOf(str[i+1]) << 4) | (chars.indexOf(str[i+2]) >> 2);
    out += String.fromCharCode((n3 >> 8) & 255, n3 & 255);
  }
  return out;
}
`;
  vm.unwrapResult(vm.evalCode(atobCode, 'atob-shim.js')).dispose();

  // require stub (mirrors the Vega build's node-builtin stripping).
  const requireFn = vm.newFunction('require', (nameHandle) => {
    const name = vm.getString(nameHandle);
    if (
      name.startsWith('node:') ||
      ['fs', 'path', 'http', 'https', 'stream', 'zlib', 'url', 'os', 'crypto', 'buffer', 'events', 'util', 'querystring', 'net', 'tls', 'child_process'].includes(name)
    ) {
      return vm.newObject();
    }
    return {
      error: vm.newError({
        name: 'Error',
        message: `require(${name}) not available in smoke VM`,
      }),
    };
  });

  // ---------- CJS loader ----------
  function loadCJS(code, filename) {
    const wrapped = `(function(module, exports, require) {\n${code}\n})`;
    const fn = vm.unwrapResult(vm.evalCode(wrapped, filename));
    const moduleHandle = vm.newObject();
    const exportsHandle = vm.newObject();
    vm.setProp(moduleHandle, 'exports', exportsHandle);
    vm.unwrapResult(
      vm.callFunction(fn, vm.undefined, moduleHandle, exportsHandle, requireFn),
    );
    const out = vm.getProp(moduleHandle, 'exports');
    fn.dispose();
    moduleHandle.dispose();
    exportsHandle.dispose();
    return out;
  }

  function isVmHandle(v) {
    return (
      v !== null &&
      typeof v === 'object' &&
      typeof v.dispose === 'function' &&
      'alive' in v
    );
  }
  function toVM(value) {
    if (isVmHandle(value)) return value;
    if (value === undefined) return vm.undefined;
    if (value === null) return vm.null;
    if (typeof value === 'string') return vm.newString(value);
    if (typeof value === 'number') return vm.newNumber(value);
    if (typeof value === 'boolean') return value ? vm.true : vm.false;
    if (Array.isArray(value)) {
      const arr = vm.newArray();
      value.forEach((v, i) => vm.setProp(arr, i, toVM(v)));
      return arr;
    }
    if (typeof value === 'object') {
      const obj = vm.newObject();
      for (const [k, v] of Object.entries(value)) vm.setProp(obj, k, toVM(v));
      return obj;
    }
    throw new Error(`toVM: unsupported ${typeof value}`);
  }

  const signalHandle = vm.unwrapResult(
    vm.evalCode(
      `({aborted: false, addEventListener: function(){}, removeEventListener: function(){}, throwIfAborted: function(){ if (this.aborted) throw new Error('aborted'); }})`,
      'signal.js',
    ),
  );

  async function awaitGuestPromise(promiseHandle, timeoutMs = CALL_TIMEOUT_MS) {
    const settledPromise = vm.resolvePromise(promiseHandle);
    let done = false;
    settledPromise.then(
      () => {
        done = true;
      },
      () => {
        done = true;
      },
    );
    const deadline = Date.now() + timeoutMs;
    while (!done) {
      runtime.executePendingJobs();
      if (done) break;
      if (Date.now() > deadline) {
        throw new Error(`guest promise timed out after ${timeoutMs}ms`);
      }
      await new Promise((r) => setTimeout(r, 5));
    }
    return settledPromise;
  }

  async function callExport(exportsHandle, name, params) {
    const fnHandle = vm.getProp(exportsHandle, name);
    const paramsHandle = toVM(params);
    const callRes = vm.callFunction(fnHandle, vm.undefined, paramsHandle);
    const promiseHandle = vm.unwrapResult(callRes);
    const settled = await awaitGuestPromise(promiseHandle);
    const valueHandle = vm.unwrapResult(settled);
    const value = vm.dump(valueHandle);
    fnHandle.dispose();
    paramsHandle.dispose();
    promiseHandle.dispose();
    valueHandle.dispose();
    return value;
  }

  // ---------- load the shipped context bundle ----------
  const ctxCode = fs.readFileSync(
    path.join(DIR, '../../assets/vega/vega_context_bundle.js'),
    'utf8',
  );
  const ctxExports = loadCJS(ctxCode, 'vega_context_bundle.js');
  const factoryHandle = vm.getProp(ctxExports, 'createVegaProviderContext');
  check(
    'context bundle exports createVegaProviderContext',
    (() => {
      try {
        const t = vm.getString(vm.getProp(factoryHandle, 'name'));
        return t === 'createVegaProviderContext';
      } catch {
        return false;
      }
    })(),
  );

  // Call the factory with a test token; the returned context is passed to
  // the provider functions exactly like the Dart wrapper will pass it.
  const tokenHandle = vm.newString('smoke-test-token');
  const ctxCall = vm.callFunction(factoryHandle, vm.undefined, tokenHandle);
  const providerContextHandle = vm.unwrapResult(ctxCall);
  tokenHandle.dispose();
  factoryHandle.dispose();

  // ---------- kvStore round-trip through the bridge stubs ----------
  const kvGet = async (key) => {
    const kvHandle = vm.getProp(providerContextHandle, 'kvStore');
    const getHandle = vm.getProp(kvHandle, 'get');
    const p = vm.callFunction(getHandle, kvHandle, vm.newString(key));
    const settled = await awaitGuestPromise(vm.unwrapResult(p));
    const v = vm.dump(vm.unwrapResult(settled));
    getHandle.dispose();
    kvHandle.dispose();
    return v === null ? undefined : v;
  };
  const kvSet = async (key, value) => {
    const kvHandle = vm.getProp(providerContextHandle, 'kvStore');
    const setHandle = vm.getProp(kvHandle, 'set');
    const valueHandle = toVM(value);
    const p = vm.callFunction(
      setHandle,
      kvHandle,
      vm.newString(key),
      valueHandle,
    );
    await awaitGuestPromise(vm.unwrapResult(p));
    valueHandle.dispose();
    setHandle.dispose();
    kvHandle.dispose();
  };
  await kvSet('smoke-key', { a: 1 });
  // set() is fire-and-forget on the bridge (sendMessage) but the index
  // write goes through get_storage, so a tick lets the writes land.
  await new Promise((r) => setTimeout(r, 50));
  const missing = await kvGet('no-such-key');
  check('kvStore.get missing key -> undefined', missing === undefined);
  const stored = await kvGet('smoke-key');
  check(
    'kvStore.set/get round-trip',
    stored !== undefined && stored.a === 1,
    `stored=${JSON.stringify(stored)}`,
  );

  // ---------- fetch + load the Internet Archive provider ----------
  console.log('\n===== provider: internetArchive =====');
  const load = async (mod) =>
    loadCJS(await fetchText(`${IA_BASE}/${mod}.js`), `internetArchive/${mod}.js`);

  const catalogExports = await load('catalog');
  const catalogHandle = vm.getProp(catalogExports, 'catalog');
  const catalog = vm.dump(catalogHandle);
  catalogHandle.dispose();
  check(
    'catalog',
    Array.isArray(catalog) && catalog.length > 0,
    `entries=${catalog.length}, first=${JSON.stringify(catalog[0])}`,
  );
  catalogExports.dispose();

  const postsExports = await load('posts');
  const posts = await callExport(postsExports, 'getPosts', {
    filter: catalog[0].filter,
    page: 1,
    providerValue: 'internetArchive',
    signal: signalHandle,
    providerContext: providerContextHandle,
  });
  const postsOk =
    Array.isArray(posts) &&
    posts.length > 0 &&
    posts.every((p) => typeof p.title === 'string' && p.title);
  check('getPosts', postsOk, `count=${posts.length}, first=${JSON.stringify(posts[0])}`);
  const search = await callExport(postsExports, 'getSearchPosts', {
    searchQuery: 'charlie chaplin',
    page: 1,
    providerValue: 'internetArchive',
    signal: signalHandle,
    providerContext: providerContextHandle,
  });
  check(
    'getSearchPosts',
    Array.isArray(search) && search.length > 0,
    `count=${Array.isArray(search) ? search.length : '?'}, first=${JSON.stringify(search && search[0])}`,
  );
  postsExports.dispose();

  // Find Sex Madness in the first page (the spike's known-good item).
  const sexMadness = (posts || []).find(
    (p) => typeof p.title === 'string' && p.title.indexOf('Sex Madness') >= 0,
  );
  check('Sex Madness on first page', !!sexMadness, JSON.stringify(sexMadness));

  const metaExports = await load('meta');
  const streamExports = await load('stream');
  if (sexMadness) {
    const meta = await callExport(metaExports, 'getMeta', {
      link: sexMadness.link,
      providerContext: providerContextHandle,
    });
    check(
      'getMeta(Sex Madness)',
      meta && meta.title === 'Sex Madness' && meta.type === 'movie',
      `type=${meta && meta.type}, linkList=${meta && meta.linkList && meta.linkList.length}`,
    );
    const directLink =
      meta &&
      meta.linkList &&
      meta.linkList[0] &&
      meta.linkList[0].directLinks &&
      meta.linkList[0].directLinks[0] &&
      meta.linkList[0].directLinks[0].link;
    const streams = await callExport(streamExports, 'getStream', {
      link: directLink,
      type: 'movie',
      signal: signalHandle,
      providerContext: providerContextHandle,
    });
    const streamsOk =
      Array.isArray(streams) &&
      streams.length === 4 &&
      streams.every((s) => s.server && s.link && s.type);
    check(
      'getStream(Sex Madness) = 4 streams',
      streamsOk,
      `count=${Array.isArray(streams) ? streams.length : '?'}, first=${JSON.stringify(streams && streams[0])}`,
    );
    const hasSub = (streams || []).some(
      (s) => Array.isArray(s.subtitles) && s.subtitles.length > 0,
    );
    check('streams carry subtitles', hasSub);
    const dlStreams = await callExport(streamExports, 'getStream', {
      link: directLink,
      type: 'movie',
      signal: signalHandle,
      providerContext: providerContextHandle,
      isDownload: true,
    });
    check(
      'getStream(isDownload=true)',
      Array.isArray(dlStreams) && dlStreams.length > 0,
      `count=${Array.isArray(dlStreams) ? dlStreams.length : '?'}`,
    );
  }
  metaExports.dispose();
  streamExports.dispose();

  const settingsExports = await load('settings');
  const schema = await callExport(settingsExports, 'getSettingsSchema', {
    providerContext: providerContextHandle,
  });
  check(
    'getSettingsSchema',
    Array.isArray(schema) && schema.length > 0,
    `fields=${Array.isArray(schema) ? schema.map((f) => f.key).join(',') : '?'}`,
  );
  settingsExports.dispose();

  providerContextHandle.dispose();
  ctxExports.dispose();
  signalHandle.dispose();
  requireFn.dispose();

  console.log(
    failures.length === 0
      ? '\nSMOKE OK — the shipped bundle works end to end.'
      : `\nSMOKE FAILED: ${failures.join(', ')}`,
  );
  process.exit(failures.length === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('SMOKE FAILED:', e);
  process.exit(1);
});
