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
//  - Missing JS globals the Vega sandbox contract does not inject are
//    defined here, on globalThis, as guarded additive shims (see the
//    "Missing JS globals" section): fetch, URLSearchParams, Headers,
//    TextDecoder/TextEncoder, AbortController/AbortSignal, FormData.
//    QuickJS provides none of these, and 26/42 enabled Zenda-Cross
//    providers call at least one of them unguarded. The shims never touch
//    the axios adapter, cheerio, kvStore, or commonHeaders.
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
// Missing JS globals (QuickJS provides none of these; the Vega sandbox
// contract only injects axios/cheerio/kvStore/commonHeaders/openWebView
// through the factory). Every shim below is ADDITIVE and guarded: if the
// worker ever defines a native one, the native wins and the shim is
// skipped. Providers call these unguarded, so they must live on globalThis
// itself, not only on providerContext. Nothing here touches the axios
// adapter, cheerio, kvStore, or commonHeaders.
// ---------------------------------------------------------------------------

function abortError() {
  const e = new Error('The user aborted a request.');
  e.name = 'AbortError';
  return e;
}

// -- AbortSignal / AbortController -----------------------------------------
// Minimal DOM-style abort: .aborted flag, addEventListener('abort', fn),
// onabort, throwIfAborted(). The fetch shim (below) races on it, and
// providers that construct their own AbortController (animesalt,
// animeworld stream paths) get a working one; the axios adapter only
// reads .aborted, which already worked with a plain object.
class VegaAbortSignal {
  constructor() {
    this.aborted = false;
    this.reason = undefined;
    this.onabort = null;
    this._listeners = [];
  }
  addEventListener(type, fn) {
    if (type === 'abort' && typeof fn === 'function') this._listeners.push(fn);
  }
  removeEventListener(type, fn) {
    if (type !== 'abort') return;
    const i = this._listeners.indexOf(fn);
    if (i >= 0) this._listeners.splice(i, 1);
  }
  throwIfAborted() {
    if (this.aborted) throw this.reason || abortError();
  }
  _fire(reason) {
    if (this.aborted) return;
    this.aborted = true;
    if (reason !== undefined) this.reason = reason;
    if (this.reason === undefined) this.reason = abortError();
    const listeners = this._listeners.slice();
    for (const fn of listeners) {
      try {
        fn.call(this, { type: 'abort', target: this });
      } catch (e) {
        /* a listener throwing must not break the abort */
      }
    }
    if (typeof this.onabort === 'function') {
      try {
        this.onabort.call(this, { type: 'abort', target: this });
      } catch (e) {
        /* same */
      }
    }
  }
}

class VegaAbortController {
  constructor() {
    this.signal = new VegaAbortSignal();
  }
  abort(reason) {
    this.signal._fire(reason);
  }
}

// -- Headers ---------------------------------------------------------------
// Minimal fetch Headers: case-insensitive get/set/append/has/delete plus
// iteration. Stored as [lowerName, value] pairs so duplicate names (e.g.
// set-cookie) survive; get() joins duplicates with ', ' like the spec.
class VegaHeaders {
  constructor(init) {
    this._entries = [];
    if (init === undefined || init === null) return;
    if (init instanceof VegaHeaders) {
      for (const pair of init._entries) {
        this._entries.push([pair[0], pair[1]]);
      }
    } else if (Array.isArray(init)) {
      for (const pair of init) {
        if (Array.isArray(pair) && pair.length >= 2) {
          this.append(pair[0], pair[1]);
        }
      }
    } else if (typeof init === 'object') {
      for (const key of Object.keys(init)) this.append(key, init[key]);
    }
  }
  _norm(name) {
    return String(name).toLowerCase();
  }
  append(name, value) {
    this._entries.push([this._norm(name), String(value)]);
  }
  set(name, value) {
    const n = this._norm(name);
    this._entries = this._entries.filter((pair) => pair[0] !== n);
    this._entries.push([n, String(value)]);
  }
  get(name) {
    const n = this._norm(name);
    const found = [];
    for (const pair of this._entries) {
      if (pair[0] === n) found.push(pair[1]);
    }
    if (found.length === 0) return null;
    return found.join(', ');
  }
  has(name) {
    const n = this._norm(name);
    for (const pair of this._entries) {
      if (pair[0] === n) return true;
    }
    return false;
  }
  delete(name) {
    const n = this._norm(name);
    this._entries = this._entries.filter((pair) => pair[0] !== n);
  }
  forEach(callback, thisArg) {
    for (const pair of this._entries) {
      callback.call(thisArg, pair[1], pair[0], this);
    }
  }
  *entries() {
    for (const pair of this._entries) yield [pair[0], pair[1]];
  }
  *keys() {
    for (const pair of this._entries) yield pair[0];
  }
  *values() {
    for (const pair of this._entries) yield pair[1];
  }
  [Symbol.iterator]() {
    return this.entries();
  }
  toObject() {
    const obj = {};
    for (const pair of this._entries) {
      if (obj[pair[0]] === undefined) obj[pair[0]] = pair[1];
      else obj[pair[0]] = obj[pair[0]] + ', ' + pair[1];
    }
    return obj;
  }
}

// -- URLSearchParams -------------------------------------------------------
// Query-string codec. The worker's URL class (js_engine_worker.dart) reads
// this lazily through globalThis.URLSearchParams for its live searchParams
// getter, so the constructor must accept a plain query string AND support
// being built empty and filled via set/append; toString() serialises as
// k=v&k2=v2 with application/x-www-form-urlencoded percent-encoding
// (space becomes '+', matching the spec serialiser).
function decodeQueryComponent(s) {
  try {
    return decodeURIComponent(s.replace(/\+/g, ' '));
  } catch (e) {
    return s;
  }
}

function encodeQueryComponent(s) {
  return encodeURIComponent(s).replace(/%20/g, '+');
}

class VegaURLSearchParams {
  constructor(init) {
    this._pairs = [];
    if (init === undefined || init === null) return;
    if (typeof init === 'string') {
      const qs = init.charAt(0) === '?' ? init.slice(1) : init;
      if (!qs) return;
      const parts = qs.split('&');
      for (const part of parts) {
        if (!part) continue;
        const eq = part.indexOf('=');
        if (eq >= 0) {
          this._pairs.push([
            decodeQueryComponent(part.slice(0, eq)),
            decodeQueryComponent(part.slice(eq + 1)),
          ]);
        } else {
          this._pairs.push([decodeQueryComponent(part), '']);
        }
      }
    } else if (init instanceof VegaURLSearchParams) {
      for (const pair of init._pairs) this._pairs.push([pair[0], pair[1]]);
    } else if (Array.isArray(init)) {
      for (const pair of init) {
        if (Array.isArray(pair) && pair.length >= 2) {
          this._pairs.push([String(pair[0]), String(pair[1])]);
        } else {
          throw new TypeError('URLSearchParams sequence items must be pairs');
        }
      }
    } else if (typeof init === 'object') {
      for (const key of Object.keys(init)) {
        this._pairs.push([key, String(init[key])]);
      }
    }
  }
  get size() {
    return this._pairs.length;
  }
  append(name, value) {
    this._pairs.push([String(name), String(value)]);
  }
  delete(name) {
    const n = String(name);
    this._pairs = this._pairs.filter((pair) => pair[0] !== n);
  }
  get(name) {
    const n = String(name);
    for (const pair of this._pairs) {
      if (pair[0] === n) return pair[1];
    }
    return null;
  }
  getAll(name) {
    const n = String(name);
    const out = [];
    for (const pair of this._pairs) {
      if (pair[0] === n) out.push(pair[1]);
    }
    return out;
  }
  has(name) {
    const n = String(name);
    for (const pair of this._pairs) {
      if (pair[0] === n) return true;
    }
    return false;
  }
  set(name, value) {
    const n = String(name);
    const v = String(value);
    let seen = false;
    const kept = [];
    for (const pair of this._pairs) {
      if (pair[0] === n) {
        if (!seen) {
          seen = true;
          kept.push([n, v]);
        }
      } else {
        kept.push(pair);
      }
    }
    if (!seen) kept.push([n, v]);
    this._pairs = kept;
  }
  sort() {
    this._pairs.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  }
  toString() {
    const parts = [];
    for (const pair of this._pairs) {
      parts.push(
        encodeQueryComponent(pair[0]) + '=' + encodeQueryComponent(pair[1]),
      );
    }
    return parts.join('&');
  }
  forEach(callback, thisArg) {
    for (const pair of this._pairs) {
      callback.call(thisArg, pair[1], pair[0], this);
    }
  }
  *entries() {
    for (const pair of this._pairs) yield [pair[0], pair[1]];
  }
  *keys() {
    for (const pair of this._pairs) yield pair[0];
  }
  *values() {
    for (const pair of this._pairs) yield pair[1];
  }
  [Symbol.iterator]() {
    return this.entries();
  }
}

// -- TextDecoder / TextEncoder ---------------------------------------------
// UTF-8 only (QuickJS has neither). animesalt decodes a base64 helper
// through TextDecoder. Invalid sequences become U+FFFD unless fatal:true,
// which throws like the spec.
function utf8DecodeBytes(bytes, fatal) {
  let out = '';
  let i = 0;
  const len = bytes.length;
  const bad = () => {
    if (fatal) throw new TypeError('Invalid UTF-8 sequence');
    return '\uFFFD';
  };
  while (i < len) {
    const b0 = bytes[i++];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      continue;
    }
    let cp;
    let need;
    if ((b0 & 0xe0) === 0xc0) {
      cp = b0 & 0x1f;
      need = 1;
    } else if ((b0 & 0xf0) === 0xe0) {
      cp = b0 & 0x0f;
      need = 2;
    } else if ((b0 & 0xf8) === 0xf0) {
      cp = b0 & 0x07;
      need = 3;
    } else {
      out += bad();
      continue;
    }
    let ok = true;
    for (let j = 0; j < need; j++) {
      if (i >= len) {
        ok = false;
        break;
      }
      const bx = bytes[i];
      if ((bx & 0xc0) !== 0x80) {
        ok = false;
        break;
      }
      i++;
      cp = (cp << 6) | (bx & 0x3f);
    }
    if (!ok) {
      out += bad();
      continue;
    }
    if (
      (need === 1 && cp < 0x80) ||
      (need === 2 && cp < 0x800) ||
      (need === 3 && cp < 0x10000) ||
      cp > 0x10ffff ||
      (cp >= 0xd800 && cp <= 0xdfff)
    ) {
      out += bad();
      continue;
    }
    if (cp <= 0xffff) {
      out += String.fromCharCode(cp);
    } else {
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    }
  }
  return out;
}

function utf8EncodeString(str) {
  const bytes = [];
  for (let i = 0; i < str.length; i++) {
    let cp = str.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < str.length) {
      const lo = str.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        i++;
      }
    }
    if (cp < 0x80) {
      bytes.push(cp);
    } else if (cp < 0x800) {
      bytes.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      bytes.push(
        0xe0 | (cp >> 12),
        0x80 | ((cp >> 6) & 0x3f),
        0x80 | (cp & 0x3f),
      );
    } else {
      bytes.push(
        0xf0 | (cp >> 18),
        0x80 | ((cp >> 12) & 0x3f),
        0x80 | ((cp >> 6) & 0x3f),
        0x80 | (cp & 0x3f),
      );
    }
  }
  return new Uint8Array(bytes);
}

class VegaTextDecoder {
  constructor(label, options) {
    const l =
      label === undefined
        ? 'utf-8'
        : String(label).toLowerCase().replace(/_/g, '-');
    if (l !== 'utf-8' && l !== 'utf8' && l !== 'unicode-1-1-utf-8') {
      throw new RangeError('Unsupported encoding: ' + String(label));
    }
    this.encoding = 'utf-8';
    this.fatal = !!(options && options.fatal);
    this.ignoreBOM = !!(options && options.ignoreBOM);
  }
  decode(input) {
    if (input === undefined || input === null) return '';
    let bytes;
    if (input instanceof Uint8Array) {
      bytes = input;
    } else if (typeof ArrayBuffer !== 'undefined' && input instanceof ArrayBuffer) {
      bytes = new Uint8Array(input);
    } else if (
      input &&
      typeof input === 'object' &&
      typeof input.length === 'number'
    ) {
      bytes = Uint8Array.from(input);
    } else {
      throw new TypeError(
        'TextDecoder.decode requires a Uint8Array or ArrayBuffer',
      );
    }
    let start = 0;
    if (
      !this.ignoreBOM &&
      bytes.length >= 3 &&
      bytes[0] === 0xef &&
      bytes[1] === 0xbb &&
      bytes[2] === 0xbf
    ) {
      start = 3;
    }
    const view = start > 0 ? bytes.subarray(start) : bytes;
    return utf8DecodeBytes(view, this.fatal);
  }
}

class VegaTextEncoder {
  constructor() {
    this.encoding = 'utf-8';
  }
  encode(str) {
    return utf8EncodeString(str === undefined ? '' : String(str));
  }
  encodeInto(str, dest) {
    const bytes = utf8EncodeString(String(str));
    const n = Math.min(bytes.length, dest.length);
    dest.set(bytes.subarray(0, n));
    return { read: String(str).length, written: n };
  }
}

// -- FormData --------------------------------------------------------------
// Minimal: string values only (QuickJS has no Blob/File; the audit's only
// user is the gdflix resumeBot flow, which posts string fields). When
// passed as a fetch body it serialises as application/x-www-form-urlencoded
// (see the fetch shim); Dart defaults POST/PUT to that content type too.
class VegaFormData {
  constructor() {
    this._entries = [];
  }
  append(name, value) {
    this._entries.push([
      String(name),
      value === undefined ? 'undefined' : String(value),
    ]);
  }
  set(name, value) {
    const n = String(name);
    this._entries = this._entries.filter((pair) => pair[0] !== n);
    this.append(n, value);
  }
  get(name) {
    const n = String(name);
    for (const pair of this._entries) {
      if (pair[0] === n) return pair[1];
    }
    return null;
  }
  getAll(name) {
    const n = String(name);
    const out = [];
    for (const pair of this._entries) {
      if (pair[0] === n) out.push(pair[1]);
    }
    return out;
  }
  has(name) {
    const n = String(name);
    for (const pair of this._entries) {
      if (pair[0] === n) return true;
    }
    return false;
  }
  delete(name) {
    const n = String(name);
    this._entries = this._entries.filter((pair) => pair[0] !== n);
  }
  forEach(callback, thisArg) {
    for (const pair of this._entries) {
      callback.call(thisArg, pair[1], pair[0], this);
    }
  }
  *entries() {
    for (const pair of this._entries) yield [pair[0], pair[1]];
  }
  *keys() {
    for (const pair of this._entries) yield pair[0];
  }
  *values() {
    for (const pair of this._entries) yield pair[1];
  }
  [Symbol.iterator]() {
    return this.entries();
  }
  toString() {
    const parts = [];
    for (const pair of this._entries) {
      parts.push(
        encodeQueryComponent(pair[0]) + '=' + encodeQueryComponent(pair[1]),
      );
    }
    return parts.join('&');
  }
}

// -- fetch -----------------------------------------------------------------
// Backed by the same _dartAsyncCall('http_request') transport as the axios
// adapter (same request/response shape). Differences from axios:
//  - Response-like return (no throw on HTTP errors): {ok, status,
//    statusText, headers, url, text(), json(), arrayBuffer()}.
//  - `url` is the FINAL url after redirects (Dart's finalUrl): hubcloud /
//    zcloud check fRes.url for googleusercontent redirects.
//  - `redirect` is always 'follow': Dart's Dio follows redirects and the
//    bridge cannot opt out per request; no audited provider asks for
//    'manual' or 'error'.
//  - No __ssTok is sent: a global fetch has no per-provider token, and
//    stamping it with the most recently created provider's token would
//    misattribute one provider's traffic to another (the W12 failure
//    mode in JsEngineService._handleBridgeRequest). The Dart side
//    tolerates unattributed http_request calls (scope null -> default
//    clearance handling); storage channels still require a token and are
//    untouched by this shim.
function networkError(e) {
  return new TypeError(
    typeof e === 'string' ? e : (e && e.message) || 'Network request failed',
  );
}

function normalizeFetchBody(body) {
  if (body === undefined || body === null) return { body: undefined };
  if (typeof body === 'string') return { body };
  if (body instanceof VegaFormData) {
    return {
      body: body.toString(),
      contentType: 'application/x-www-form-urlencoded',
    };
  }
  if (body instanceof VegaURLSearchParams) {
    return {
      body: body.toString(),
      contentType: 'application/x-www-form-urlencoded',
    };
  }
  if (body instanceof Uint8Array || body instanceof ArrayBuffer) {
    throw new TypeError(
      'fetch body as binary is not supported by the Vega bridge',
    );
  }
  if (typeof body === 'object') {
    return { body: JSON.stringify(body), contentType: 'application/json' };
  }
  return { body: String(body) };
}

async function vegaFetch(input, init) {
  const opts = init || {};
  let url;
  let inputHeaders;
  let inputSignal;
  let inputBody;
  if (input !== null && typeof input === 'object') {
    if (typeof input.url === 'string') url = input.url;
    else url = String(input);
    inputHeaders = input.headers;
    inputSignal = input.signal;
    inputBody = input.body;
  } else {
    url = String(input);
  }
  const method = String(
    opts.method ||
      (input !== null && typeof input === 'object' && input.method) ||
      'GET',
  ).toUpperCase();
  const headers = new VegaHeaders(
    opts.headers !== undefined ? opts.headers : inputHeaders,
  );
  const signal = opts.signal !== undefined ? opts.signal : inputSignal;
  if (signal && signal.aborted) throw abortError();
  const bodyInit = opts.body !== undefined ? opts.body : inputBody;
  const norm = normalizeFetchBody(bodyInit);
  if (norm.contentType && !headers.has('content-type')) {
    headers.set('Content-Type', norm.contentType);
  }

  const call = _dartAsyncCall('http_request', {
    method: method.toLowerCase(),
    url,
    headers: headers.toObject(),
    body: norm.body,
  });

  let res;
  if (signal && typeof signal.addEventListener === 'function') {
    // Abort race: the underlying Dart request keeps running (same as the
    // axios adapter's timeout race), but the fetch promise rejects.
    res = await new Promise((resolve, reject) => {
      let done = false;
      const onAbort = () => {
        if (!done) {
          done = true;
          reject(abortError());
        }
      };
      signal.addEventListener('abort', onAbort);
      const detach = () => {
        if (typeof signal.removeEventListener === 'function') {
          signal.removeEventListener('abort', onAbort);
        }
      };
      call.then(
        (v) => {
          if (!done) {
            done = true;
            detach();
            resolve(v);
          }
        },
        (e) => {
          if (!done) {
            done = true;
            detach();
            reject(networkError(e));
          }
        },
      );
    });
  } else {
    try {
      res = await call;
    } catch (e) {
      throw networkError(e);
    }
  }

  // The Dart side answers transport errors as a value
  // ({code: 0, error: ...}), never as a rejection.
  if (res && res.error && (res.code === 0 || res.status === 0)) {
    throw new TypeError(res.error || 'Network request failed');
  }
  const status = (res && (res.code ?? res.status)) || 0;
  const headersOut = new VegaHeaders((res && res.headers) || {});
  const bodyText =
    res && res.body !== undefined && res.body !== null ? String(res.body) : '';
  const finalUrl = (res && res.finalUrl) || url;
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: '',
    headers: headersOut,
    url: finalUrl,
    redirected: finalUrl !== url,
    text: async () => bodyText,
    json: async () => JSON.parse(bodyText),
    arrayBuffer: async () => new VegaTextEncoder().encode(bodyText).buffer,
  };
}

// Publish the globals (guarded — a native worker global always wins).
if (typeof globalThis.AbortSignal === 'undefined') {
  globalThis.AbortSignal = VegaAbortSignal;
}
if (typeof globalThis.AbortController === 'undefined') {
  globalThis.AbortController = VegaAbortController;
}
if (typeof globalThis.Headers === 'undefined') {
  globalThis.Headers = VegaHeaders;
}
if (typeof globalThis.URLSearchParams === 'undefined') {
  globalThis.URLSearchParams = VegaURLSearchParams;
}
if (typeof globalThis.TextDecoder === 'undefined') {
  globalThis.TextDecoder = VegaTextDecoder;
}
if (typeof globalThis.TextEncoder === 'undefined') {
  globalThis.TextEncoder = VegaTextEncoder;
}
if (typeof globalThis.FormData === 'undefined') {
  globalThis.FormData = VegaFormData;
}
if (typeof globalThis.fetch === 'undefined') {
  globalThis.fetch = vegaFetch;
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
