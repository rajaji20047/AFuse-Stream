/// The Vega `openWebView` dialog: the visible half of the engine's
/// `open_webview` bridge channel (see [JsEngineService.openWebViewPresenter]).
///
/// A Vega provider calls `openWebView` only when a site's check (Cloudflare
/// and the like) blocks its HTTP. The page opens in the platform's own
/// browser engine ([ChallengeBrowser]) so the person can finish the check,
/// and the completed page's cookies, rendered HTML, user agent and final URL
/// come back, so the provider can retry its request with them.
///
/// How a call ends, first one wins:
/// * the waited cookie ([waitForCookie], e.g. `cf_clearance`) appears in the
///   engine's cookie jar — the sheet closes by itself as Verified;
/// * an injected script posts back via `window.ReactNativeWebView.postMessage`
///   with `__waf: true` (the Kartoons device-code sign-in) — the sheet closes
///   as Verified and `data` is the posted data, not the page HTML;
/// * the person taps Done — the current page state comes back;
/// * the person closes the sheet, or [timeout] passes — success:false.
/// The cookie is polled with native cookie reads only, never page JS while a
/// check runs: reading the check's own elements made Cloudflare loop (see the
/// challenge_browser README). Nothing here touches the clearance solver's
/// pages or cookies: the dialog owns its own short-lived page and disposes it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/device_info_provider.dart';
import '../../router/app_router.dart';
import 'js_engine.dart';

/// Opens [url] in a visible WebView dialog and resolves with what the
/// completed page holds, in the Vega `OpenWebViewResult` shape (`success`,
/// `data`, `cookies`, `cookie`, `cookieMap`, `userAgent`, `url`).
///
/// [headers] go on the first request only. Unless [force], a waited cookie
/// the engine already holds means the check is already solved and no dialog
/// opens at all. [timeout] auto-cancels the dialog (Vega's `timeoutMs`,
/// default 120 s). [injectedJavaScript] is installed at document start on
/// every navigation, as the Vega contract requires.
Future<Map<String, Object?>> presentVegaWebView({
  required String url,
  String? title,
  String? description,
  Map<String, String> headers = const {},
  String? waitForCookie,
  bool force = false,
  Duration timeout = const Duration(seconds: 120),
  String? injectedJavaScript,
  bool tv = false,
}) async {
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) {
    return _failure(url: url);
  }
  final ChallengeBrowser browser;
  try {
    browser = await ChallengeBrowser.create();
  } catch (_) {
    return _failure(url: url);
  }
  try {
    // The Vega contract's postMessage back-channel: injected scripts talk
    // back via window.ReactNativeWebView.postMessage(...). The challenge
    // browser names its own channel per page (browser.postScript); shim the
    // ReactNativeWebView object onto it at document start, so it exists
    // before the provider's own injected script runs and survives
    // navigations (addDocumentStartScript runs in every frame of every
    // later document).
    await browser.addDocumentStartScript(
      'window.ReactNativeWebView = { postMessage: ${browser.postScript} };',
    );
    if (injectedJavaScript != null && injectedJavaScript.isNotEmpty) {
      await browser.addDocumentStartScript(injectedJavaScript);
    }

    // Cookie shortcut: unless forced, a waited cookie the engine already
    // holds means the check is already solved — no dialog. (Every current
    // caller passes force:true, so this fires only for callers that don't.)
    final waitFor = waitForCookie != null && waitForCookie.isNotEmpty
        ? waitForCookie
        : null;
    if (!force && waitFor != null) {
      final existing = await _cookiesFor(browser, url);
      if (existing.any((c) => c.name == waitFor)) {
        return _collect(browser, url);
      }
    }

    // Completion: the waited cookie appears, or an injected script posts
    // back (__waf). Either completes `cleared`, and the sheet closes by
    // itself as Verified.
    final cleared = Completer<void>();
    var clearedDone = false;
    String? postedData;
    void completeCleared({String? data}) {
      if (clearedDone) return;
      clearedDone = true;
      postedData = data;
      cleared.complete();
    }
    var currentUrl = url;
    final subscription = browser.events.listen((event) {
      switch (event) {
        case PageStarted(:final url):
        case PageFinished(:final url):
          currentUrl = url.toString();
        case ScriptMessage(:final message):
          try {
            final decoded = jsonDecode(message);
            if (decoded is Map && decoded['__waf'] == true) {
              final data = decoded['data'];
              completeCleared(
                data: data is String ? data : jsonEncode(data),
              );
            }
          } catch (_) {
            // Not a __waf message; the page's own traffic.
          }
        default:
      }
    });

    // The load starts now; the sheet opens over it at once. A load that
    // never starts (bad URL, dead engine) still shows the sheet, and the
    // person sees the failure and closes it.
    unawaited(
      browser.load(url, headers: headers).catchError((_) {}),
    );

    // Cookie poll (native reads only — see the file doc). Guarded against
    // overlap: a slow platform call must not stack polls.
    Timer? poll;
    var polling = false;
    if (waitFor != null) {
      poll = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (clearedDone || polling) return;
        polling = true;
        try {
          final cookies = await _cookiesFor(browser, currentUrl);
          if (cookies.any((c) => c.name == waitFor)) {
            completeCleared();
          }
        } finally {
          polling = false;
        }
      });
    }

    // Timeout: auto-cancel the dialog (the Vega contract's timeoutMs). The
    // sheet has no timeout of its own, so the root navigator pops it — only
    // while this dialog is still the one on top: a newer Vega dialog may
    // have opened over it, and popping that one would answer the wrong
    // provider's call. The check and the pop run synchronously, so no user
    // close can slip between them; if a newer dialog did open, this one
    // stays until the person closes it or its own cookie/message fires.
    final generation = ++_openDialogGeneration;
    var sheetDone = false;
    final timer = Timer(timeout, () {
      if (_openDialogGeneration != generation ||
          clearedDone ||
          sheetDone) {
        return;
      }
      rootNavigatorKey.currentState?.pop();
    });

    // The sheet's own words are English whatever the app's language, as the
    // pages in it are (see the clearance sheet strings). The sheet has no
    // title slot: the address line shows the site, and the note carries the
    // provider's description (its title names the same site).
    final result = await showChallengeSheet(
      context,
      browser: browser,
      tv: tv,
      cleared: cleared.future,
      strings: ChallengeSheetStrings(
        note:
            description ??
            title ??
            'Complete the website verification to continue.',
        retry: 'Retry',
        fullScreen: 'Full screen',
        exitFullScreen: 'Exit full screen',
        close: 'Close',
        done: 'Done',
        verified: 'Verified',
      ),
    );
    sheetDone = true;
    await subscription.cancel();
    poll?.cancel();
    timer.cancel();

    switch (result) {
      case ChallengeSheetResult.verified:
      case ChallengeSheetResult.done:
        return _collect(browser, currentUrl, dataOverride: postedData);
      case ChallengeSheetResult.closed:
      case ChallengeSheetResult.quiet:
        return _failure(url: currentUrl, userAgent: await _userAgent(browser));
    }
  } finally {
    try {
      await browser.dispose();
    } catch (_) {
      // A dead engine must not mask the result.
    }
  }
}

/// Counts the Vega dialogs opened this run, so a timed-out dialog never pops
/// a newer one that opened over it.
int _openDialogGeneration = 0;

/// What the completed page holds, in the Vega `OpenWebViewResult` shape.
/// [dataOverride] is an injected script's posted data, which replaces the
/// page HTML (the Kartoons device-code sign-in reads it as the payload).
Future<Map<String, Object?>> _collect(
  ChallengeBrowser browser,
  String url, {
  String? dataOverride,
}) async {
  var finalUrl = url;
  try {
    final href = jsonDecode(await browser.evaluate('location.href'));
    if (href is String && href.isNotEmpty) finalUrl = href;
  } catch (_) {
    // Between documents; keep the requested URL.
  }
  var data = dataOverride ?? '';
  if (dataOverride == null) {
    try {
      final html = jsonDecode(
        await browser.evaluate('document.documentElement.outerHTML'),
      );
      if (html is String) data = html;
    } catch (_) {
      // Between documents; the cookies still carry the solve.
    }
  }
  final cookies = await _cookiesFor(browser, finalUrl);
  final header = cookies.map((c) => '${c.name}=${c.value}').join('; ');
  return <String, Object?>{
    'success': true,
    'data': data,
    'cookies': header,
    // uhd/katmovies read the singular `cookie`; most read `cookies`.
    'cookie': header,
    'cookieMap': {for (final c in cookies) c.name: c.value},
    'userAgent': await _userAgent(browser),
    'url': finalUrl,
  };
}

Future<List<BrowserCookie>> _cookiesFor(
  ChallengeBrowser browser,
  String url,
) async {
  try {
    return await browser.cookies(url);
  } catch (_) {
    return const [];
  }
}

Future<String> _userAgent(ChallengeBrowser browser) async {
  try {
    return await browser.userAgent;
  } catch (_) {
    return '';
  }
}

/// The `openWebView` answer when no dialog can open or the person cancels:
/// the Vega stub's shape (mirrored by the engine's `_openWebViewFailure`).
Map<String, Object?> _failure({
  required String url,
  String userAgent = '',
}) => <String, Object?>{
  'success': false,
  'data': '',
  'cookies': '',
  'cookie': '',
  'cookieMap': <String, String>{},
  'userAgent': userAgent,
  'url': url,
};

/// Mounts the Vega `openWebView` presenter: while this widget is in the tree,
/// a Vega provider's `openWebView` call opens the visible WebView dialog;
/// without it the channel answers success:false. Mount it next to
/// [ClearanceBridge] in the app root. The presenter is a static field on the
/// engine (see [VegaWebViewPresenter]) so mounting it creates no engine
/// eagerly: the engine still starts only when the extension system asks for it.
class VegaWebViewBridge extends ConsumerStatefulWidget {
  const VegaWebViewBridge({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VegaWebViewBridge> createState() => _VegaWebViewBridgeState();
}

class _VegaWebViewBridgeState extends ConsumerState<VegaWebViewBridge> {
  late final VegaWebViewPresenter _presenter;

  @override
  void initState() {
    super.initState();
    _presenter =
        ({
          required String url,
          String? title,
          String? description,
          Map<String, String> headers = const {},
          String? waitForCookie,
          bool force = false,
          Duration timeout = const Duration(seconds: 120),
          String? injectedJavaScript,
        }) => presentVegaWebView(
          url: url,
          title: title,
          description: description,
          headers: headers,
          waitForCookie: waitForCookie,
          force: force,
          timeout: timeout,
          injectedJavaScript: injectedJavaScript,
          // Read at call time, like the clearance bridge: the profile may
          // still be resolving when this widget mounts.
          tv: ref.read(deviceProfileProvider).value?.isTv ?? false,
        );
    JsEngineService.openWebViewPresenter = _presenter;
  }

  @override
  void dispose() {
    if (identical(JsEngineService.openWebViewPresenter, _presenter)) {
      JsEngineService.openWebViewPresenter = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
