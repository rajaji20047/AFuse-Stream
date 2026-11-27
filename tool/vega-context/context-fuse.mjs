// Vega providerContext for Fuse — the Dart-side runtime (Phase 1).
//
// This is the Fuse variant of the Phase-0 spike's context-src.mjs: real axios
// + real cheerio from npm, bundled with esbuild (platform=browser,
// format=cjs, target=es2019) into assets/vega/vega_context_bundle.js.
//
// Differences from the spike shim:
//  - The HTTP transport is Fuse's Dart bridge, not a Node host fetch: the
//    axios adapter calls the worker global `_dartAsyncCall('http_request',
//    ...)` and maps the Dart reply ({code, body, headers, finalUrl} — see
//    JsEngineService._handleHttp) back into an axios response. The host side
//    enforces the existing 8 MB body cap, 15 s timeouts, and clearance
//    gating; a provider-configured `config.timeout` shorter than that is
//    enforced client-side with a setTimeout race (the underlying Dart
//    request is not cancelled by it — the namespace HTTP cancellation in
//    JsEngineService._retireInvoke covers the invoke-end case).
//  - No `atob` shim: Fuse's worker already defines globalThis.atob/btoa
//    (js_engine_worker.dart). QuickJS has neither by itself, so the spike
//    needed one; the shipped bundle must not ship a second copy.
//  - `createVegaProviderContext(token)` is a FACTORY, not a single shared
//    object: the bridge capability token is per-provider (one namespace +
//    token per Vega provider, exactly like .sky plugins), so the axios
//    adapter and the kvStore close over the token they were built with. A
//    shared context would let one provider's calls land in another's key
//    space.
//  - `kvStore` is backed by the bridge `get_storage` / `set_storage`
//    channels (namespaced per provider by the token — see
//    JsEngineService._handleBridgeRequest). `set_storage` never replies on
//    the Dart side, so writes go through fire-and-forget `sendMessage`
//    (the same pattern .sky setPreference uses); awaiting them would hang
//    forever. `get` returns `undefined` (not null) for a missing key.
//    `keys` / `clear` are served from a per-provider key index stored under
//    the reserved key `__vega_kv_keys`, because the bridge has no list
//    channel. Two concurrent `set` calls for different keys can race the
//    index read-modify-write and drop one entry from the index; the values
//    themselves are always intact and `get` still finds them.
//  - `openWebView` is a stub returning success:false (the template's own
//    test-stub shape). Real WAF handling via challenge_browser is a later
//    decision, not Phase 1.
//
// Build: `npm install && npm run build` in this directory.
// The built bundle is verified by `npm run smoke` (smoke-test.mjs).
import axios from 'axios';
import * as cheerio from 'cheerio';

// ---------------------------------------------------------------------------
// Small helpers (no URLSearchParams in QuickJS — serialize by hand).
// ---------------------------------------------------------------------------

function serializeParams(params) {
  const parts = [];
  const enc = encodeURIComponent;
  const add = (key, value) => {
    if (value === undefined || value === null) return;
    if (value instanceof Date) {
      parts.push(enc(key) + '=' + enc(value.toISOString()));
    } else if (typeof value === 'object') {
      parts.push(enc(key) + '=' + enc(JSON.stringify(value)));
    } else {
      parts.push(enc(key) + '=' + enc(String(value)));
    }
  };
  for (const key of Object.keys(params)) {
    const value = params[key];
    if (Array.isArray(value)) {
      for (const v of value) add(key, v);
    } else {
      add(key, value);
    }
  }
  return parts.join('&');
}

function canceledError(config) {
  const e = new Error('canceled');
  e.name = 'CanceledError';
  e.code = 'ERR_CANCELED';
  e.config = config;
  return e;
}

function timeoutError(config, timeoutMs) {
  const e = new Error('timeout of ' + timeoutMs + 'ms exceeded');
  e.name = 'AxiosError';
  e.code = 'ECONNABORTED';
  e.config = config;
  return e;
}

// ---------------------------------------------------------------------------
// kvStore index (reserved key — a provider must never use this key itself).
// ---------------------------------------------------------------------------

const KV_INDEX_KEY = '__vega_kv_keys';

// ---------------------------------------------------------------------------
// Factory.
// ---------------------------------------------------------------------------

export function createVegaProviderContext(token) {
  // -- axios ---------------------------------------------------------------
  // One instance per provider, so no adapter state is ever shared.
  const instance = axios.create();
  instance.defaults.adapter = async (config) => {
    if (config.signal && config.signal.aborted) {
      throw canceledError(config);
    }
    let url = config.url || '';
    if (config.params) {
      const qs = serializeParams(config.params);
      if (qs) url += (url.indexOf('?') >= 0 ? '&' : '?') + qs;
    }
    const method = (config.method || 'get').toLowerCase();
    let body;
    if (config.data !== undefined && config.data !== null) {
      body =
        typeof config.data === 'string'
          ? config.data
          : JSON.stringify(config.data);
    }
    const headers = { ...(config.headers || {}) };

    const call = _dartAsyncCall('http_request', {
      method,
      url,
      headers,
      body,
      __ssTok: token,
    });

    let res;
    const timeout = config.timeout;
    if (typeof timeout === 'number' && timeout > 0) {
      // Client-side race: the Dart side caps at 15 s regardless, so this
      // only ever fires for a shorter provider-configured timeout.
      res = await new Promise((resolve, reject) => {
        let done = false;
        const timer = setTimeout(() => {
          if (!done) {
            done = true;
            reject(timeoutError(config, timeout));
          }
        }, timeout);
        call.then(
          (v) => {
            if (!done) {
              done = true;
              clearTimeout(timer);
              resolve(v);
            }
          },
          (e) => {
            if (!done) {
              done = true;
              clearTimeout(timer);
              reject(e);
            }
          },
        );
      });
    } else {
      try {
        res = await call;
      } catch (e) {
        // The bridge rejected (isError): surface as a network error.
        const err = new Error(
          typeof e === 'string' ? e : (e && e.message) || 'Network Error',
        );
        err.code = 'ERR_NETWORK';
        err.config = config;
        throw err;
      }
    }

    // The Dart side answers errors as a value ({code: 0, error: ...}),
    // never as a rejection.
    if (res && res.error && (res.code === 0 || res.status === 0)) {
      const err = new Error(res.error || 'Network Error');
      err.code = 'ERR_NETWORK';
      err.config = config;
      throw err;
    }

    const status = (res && (res.code ?? res.status)) || 0;
    const headersOut = (res && res.headers) || {};
    const ct =
      headersOut['content-type'] || headersOut['Content-Type'] || '';
    let data = res && res.body !== undefined ? res.body : '';
    if (typeof data === 'string' && ct.indexOf('application/json') >= 0) {
      try {
        data = JSON.parse(data);
      } catch (e) {
        /* keep as text */
      }
    }
    const response = {
      data,
      status,
      statusText: '',
      headers: headersOut,
      config,
      request: {},
    };
    const validate = config.validateStatus;
    const ok =
      typeof validate === 'function'
        ? validate(status)
        : status >= 200 && status < 300;
    if (ok) return response;
    const err = new Error('Request failed with status code ' + status);
    err.response = response;
    err.config = config;
    err.code =
      status >= 400 && status < 500 ? 'ERR_BAD_REQUEST' : 'ERR_BAD_RESPONSE';
    throw err;
  };

  // -- kvStore -------------------------------------------------------------
  // Values are stored as JSON strings under the provider's own namespace
  // (the token selects it on the Dart side). Reads go through the async
  // bridge; writes are fire-and-forget sendMessage because set_storage
  // never replies (see the file header).
  const kvGetRaw = async (key) => {
    const raw = await _dartAsyncCall('get_storage', {
      key,
      __ssTok: token,
    });
    return raw;
  };
  const kvSetRaw = (key, value) => {
    sendMessage(
      'set_storage',
      JSON.stringify({ key, value, __ssTok: token }),
    );
  };
  const kvReadIndex = async () => {
    const raw = await kvGetRaw(KV_INDEX_KEY);
    if (raw === null || raw === undefined) return [];
    try {
      const arr = JSON.parse(raw);
      return Array.isArray(arr)
        ? arr.filter((k) => typeof k === 'string')
        : [];
    } catch (e) {
      return [];
    }
  };
  const kvWriteIndex = (keys) => {
    kvSetRaw(KV_INDEX_KEY, JSON.stringify(keys));
  };

  const kvStore = {
    get: async (key) => {
      const raw = await kvGetRaw(key);
      if (raw === null || raw === undefined) return undefined;
      try {
        return JSON.parse(raw);
      } catch (e) {
        return raw;
      }
    },
    set: async (key, value) => {
      kvSetRaw(key, JSON.stringify(value));
      const keys = await kvReadIndex();
      if (keys.indexOf(key) < 0) {
        keys.push(key);
        kvWriteIndex(keys);
      }
    },
    delete: async (key) => {
      const raw = await kvGetRaw(key);
      const existed = raw !== null && raw !== undefined;
      kvSetRaw(key, null);
      const keys = await kvReadIndex();
      const i = keys.indexOf(key);
      if (i >= 0) {
        keys.splice(i, 1);
        kvWriteIndex(keys);
      }
      return existed;
    },
    keys: async () => kvReadIndex(),
    clear: async () => {
      const keys = await kvReadIndex();
      for (const k of keys) kvSetRaw(k, null);
      kvWriteIndex([]);
    },
  };

  // -- commonHeaders -------------------------------------------------------
  // The template's Edge/Chrome-120 set, verbatim
  // (vega-org/providers-template providers/headers.ts).
  const commonHeaders = {
    'sec-ch-ua':
      '"Not_A Brand";v="8", "Chromium";v="120", "Microsoft Edge";v="120"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0',
  };

  // -- openWebView ---------------------------------------------------------
  // Stub: not available in Phase 1 (mirrors the template's own test stub,
  // which returns success:false). Real WAF handling via challenge_browser
  // is a later decision.
  const openWebView = async () => ({
    success: false,
    data: '',
    cookies: '',
    cookieMap: {},
    userAgent: '',
    url: '',
  });

  return {
    axios: instance,
    cheerio,
    commonHeaders,
    kvStore,
    openWebView,
  };
}
