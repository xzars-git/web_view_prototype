import 'dart:async';
import 'dart:convert';
import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../../../config/logger.dart';
import '../domain/web_navigation_guard.dart';
import 'web_permission_service.dart';

enum StartupPermissionState { requesting, ready, permanentlyDenied }

/// Immutable snapshot of the WebView UI state.
///
/// [paymentUrl] uses a sentinel in [copyWith] so it can be explicitly set to
/// null without being silently ignored by the `??` fallback.
class HybridWebViewState {
  final String status;
  final double progress;
  final StartupPermissionState permissionState;
  final bool hasPermissionIssue;
  final bool cameraGranted;
  final bool locationGranted;

  /// Non-null while the payment overlay is visible; null otherwise.
  final String? paymentUrl;

  const HybridWebViewState({
    required this.status,
    required this.progress,
    required this.permissionState,
    required this.hasPermissionIssue,
    this.cameraGranted = false,
    this.locationGranted = false,
    this.paymentUrl,
  });

  HybridWebViewState copyWith({
    String? status,
    double? progress,
    StartupPermissionState? permissionState,
    bool? hasPermissionIssue,
    bool? cameraGranted,
    bool? locationGranted,
    Object? paymentUrl = _sentinel,
  }) {
    return HybridWebViewState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      permissionState: permissionState ?? this.permissionState,
      hasPermissionIssue: hasPermissionIssue ?? this.hasPermissionIssue,
      cameraGranted: cameraGranted ?? this.cameraGranted,
      locationGranted: locationGranted ?? this.locationGranted,
      paymentUrl: paymentUrl == _sentinel ? this.paymentUrl : paymentUrl as String?,
    );
  }
}

const _sentinel = Object();

/// Orchestrates the hybrid WebView experience: permissions, navigation,
/// JS bridge, payment overlay, API polling, and deep-link handling.
///
/// Extends [ValueNotifier] so the presentation layer can rebuild reactively
/// without coupling to any external state-management package.
class HybridWebViewController extends ValueNotifier<HybridWebViewState> {
  HybridWebViewController({
    required AppConfig config,
    WebPermissionService? permissionService,
    WebNavigationGuard? navigationGuard,
  }) : _config = config,
       _permissionService = permissionService ?? WebPermissionService(),
       _navigationGuard = navigationGuard ?? WebNavigationGuard(config: config),
       super(
         const HybridWebViewState(
           status: 'Menyiapkan aplikasi...',
           progress: 0,
           permissionState: StartupPermissionState.requesting,
           hasPermissionIssue: false,
         ),
       ) {
    AppLogger.d('[Controller] Initialized');
    _initDeepLinks();
  }

  final AppConfig _config;
  final WebPermissionService _permissionService;
  final WebNavigationGuard _navigationGuard;

  InAppWebViewController? _webViewController;
  InAppWebViewController? get webViewController => _webViewController;

  /// Last known internal (same-host) URL — used as the safe landing point
  /// when the user presses Back from an external redirect page.
  String? _currentInternalUrl;
  String? _lastSafeUrl;

  /// kodeBayar from the active finpay_navigation payload.
  /// Cleared after every payment cycle.
  String? _activeKodeBayar;

  static const Duration _pollingInterval = Duration(seconds: 10);
  static const Duration _pollingMaxDuration = Duration(minutes: 15);
  Timer? _pollingTimer;
  Timer? _pollingMaxTimer;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    sendTimeout: const Duration(seconds: 8),
    contentType: 'application/json',
  ));

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  set webViewController(InAppWebViewController? controller) {
    _webViewController = controller;
    if (_webViewController != null) _setupJavaScriptHandlers();
  }

  // ── NAVIGATION ────────────────────────────────────────────────────────────

  /// Returns true if [url] belongs to a different host than the app's base URL.
  bool isExternalPage(String url) {
    try {
      final currentUri = Uri.parse(url);
      final baseUri = Uri.parse(_config.targetUrl);
      return currentUri.host.isNotEmpty && currentUri.host != baseUri.host;
    } catch (_) {
      return false;
    }
  }

  /// Navigates back intelligently: if the current page is external (e.g. a
  /// bank redirect), jump directly to the last safe internal URL instead of
  /// stepping through the external history stack one page at a time.
  Future<void> smartGoBack() async {
    if (_webViewController == null) return;
    final currentUrl = (await _webViewController?.getUrl())?.toString() ?? '';
    final canGoBack = await _webViewController!.canGoBack();

    AppLogger.d('[Nav] Back requested — current: ${_sanitizeUrl(currentUrl)}');

    if (isExternalPage(currentUrl)) {
      final target = _lastSafeUrl ?? _currentInternalUrl;
      if (target != null) {
        AppLogger.d('[Nav] External page detected — jumping to safe URL: ${_sanitizeUrl(target)}');
        await _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
        return;
      }
    }

    if (canGoBack) await _webViewController!.goBack();
  }

  /// Maintains a two-slot buffer of the last two internal URLs so [smartGoBack]
  /// always has a safe landing point regardless of history depth.
  void updateLastSafeUrl(String url) {
    if (!isExternalPage(url)) {
      if (_currentInternalUrl != null && _currentInternalUrl != url) {
        _lastSafeUrl = _currentInternalUrl;
      }
      _currentInternalUrl = url;
    }
  }

  // ── JS EVENTS ─────────────────────────────────────────────────────────────

  /// Dispatches a CustomEvent to the Sambara WebView with a standard payload.
  void _dispatchPaymentEvent(String eventName) {
    AppLogger.d('[Event] Dispatching "$eventName" — kodeBayar: ${_activeKodeBayar ?? '-'}');
    _webViewController?.evaluateJavascript(
      source:
          "window.dispatchEvent(new CustomEvent('$eventName', "
          "{detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}'}}));",
    );
  }

  void _notifyPaymentHold() => _dispatchPaymentEvent('paymentHold');
  void _notifyPaymentTabOpened() => _dispatchPaymentEvent('paymentTabOpened');
  void _notifyPaymentSuccess() => _dispatchPaymentEvent('paymentSuccess');

  /// Returns a sanitized URL (scheme + host + path only) safe for logging.
  String _sanitizeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '[invalid-url]';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  // ── JS BRIDGE ─────────────────────────────────────────────────────────────

  void _setupJavaScriptHandlers() {
    AppLogger.d('[Bridge] Registering JavaScript handler: ${_config.bridgeName}');
    _webViewController?.addJavaScriptHandler(
      handlerName: _config.bridgeName,
      callback: (args) {
        if (args.isEmpty) return;
        _processIncomingMessage(args[0]);
      },
    );
  }

  /// Injects the JS bridge object at document start so it is available before
  /// any page script runs. Falls back to the platform-ready event when the
  /// handler is not yet registered (e.g. very early page loads).
  UserScript get bridgeUserScript => UserScript(
    groupName: '${_config.bridgeName.toLowerCase()}_bridge',
    source: """
      (function() {
        var name = '${_config.bridgeName}';
        window[name] = {
          postMessage: function(message) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler(name, message);
            } else {
              window.addEventListener('flutterInAppWebViewPlatformReady', function() {
                window.flutter_inappwebview.callHandler(name, message);
              });
            }
            return true;
          }
        };
        console.log('[Bridge] ' + name + ' ready');
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  // ── CONSOLE MESSAGE HANDLER ───────────────────────────────────────────────

  /// Primary entry point for payment instructions from Sambara.
  ///
  /// Sambara sends a JSON payload via `console.log`:
  /// `{ "type": "finpay_navigation", "url": "https://...", "kodeBayar": "..." }`
  ///
  /// All other console messages are forwarded to the debug logger only.
  void handleConsoleMessage(String message) {
    final preview = message.length > 120 ? '${message.substring(0, 120)}...' : message;
    AppLogger.d('[WebConsole] $preview');

    if (!message.contains('finpay_navigation')) return;

    try {
      final Map<String, dynamic> json = jsonDecode(message);
      if (json['type'] != 'finpay_navigation') return;

      final String? url = json['url']?.toString().trim();
      final String? kodeBayar = json['kodeBayar']?.toString().trim();

      AppLogger.d('[Console] finpay_navigation received — host: ${url != null ? Uri.tryParse(url)?.host : 'null'}, kodeBayar: ${kodeBayar ?? 'null'}');

      if (url == null || url.isEmpty) {
        AppLogger.d('[Console] Rejected — URL is empty');
        return;
      }

      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https') {
        AppLogger.d('[Console] Rejected — non-HTTPS scheme: "${uri?.scheme}"');
        return;
      }

      _activeKodeBayar = kodeBayar;
      _webViewController?.stopLoading();
      _openPaymentWebView(url);
    } catch (e) {
      AppLogger.d('[Console] JSON parse error: $e');
    }
  }

  // ── PAYMENT WEBVIEW ───────────────────────────────────────────────────────

  void _openPaymentWebView(String url) {
    AppLogger.d('[PaymentOverlay] Opening — ${_sanitizeUrl(url)}');
    value = value.copyWith(paymentUrl: url);
    _notifyPaymentTabOpened();
    _startPaymentStatusPolling();
  }

  /// Called by the UI when the user closes the payment overlay (X button or Back).
  void onPaymentWebViewClosedByUser() {
    AppLogger.d('[PaymentOverlay] Closed by user');
    _stopPaymentStatusPolling();
    value = value.copyWith(paymentUrl: null);
    _notifyPaymentHold();
    _activeKodeBayar = null;
  }

  /// Closes the overlay programmatically (payment confirmed or deep link received).
  void _closePaymentWebView() {
    AppLogger.d('[PaymentOverlay] Closed by app');
    value = value.copyWith(paymentUrl: null);
  }

  // ── PAYMENT STATUS POLLING ────────────────────────────────────────────────

  /// Starts two timers:
  /// - [_pollingTimer]: fires every [_pollingInterval], hits the payment status API.
  /// - [_pollingMaxTimer]: hard stop after [_pollingMaxDuration] to prevent
  ///   indefinite resource usage if the payment never completes.
  void _startPaymentStatusPolling() {
    if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) {
      AppLogger.d('[Polling] Skipped — no active kodeBayar');
      return;
    }

    _stopPaymentStatusPolling();
    _dio.options.baseUrl = _config.paymentBaseUrl;

    AppLogger.d('[Polling] Started — kodeBayar: $_activeKodeBayar, interval: ${_pollingInterval.inSeconds}s, timeout: ${_pollingMaxDuration.inMinutes}m');

    _pollingTimer = Timer.periodic(_pollingInterval, (_) async {
      if (_activeKodeBayar == null) {
        _stopPaymentStatusPolling();
        return;
      }
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          '/api/check-dummy-payment-status',
          data: {'kodeBayar': _activeKodeBayar},
        );

        if (response.statusCode == 200 && response.data != null) {
          final body = response.data!;
          final bool isPaid = body['success'] == true && body['code'] == '0000';
          AppLogger.d('[Polling] Status check — isPaid: $isPaid');

          if (isPaid) {
            AppLogger.d('[Polling] Payment confirmed — closing overlay');
            _stopPaymentStatusPolling();
            _closePaymentWebView();
            _notifyPaymentSuccess();
            _activeKodeBayar = null;
          }
        }
      } catch (e) {
        AppLogger.d('[Polling] Request failed: $e');
      }
    });

    _pollingMaxTimer = Timer(_pollingMaxDuration, () {
      AppLogger.d('[Polling] Timeout after ${_pollingMaxDuration.inMinutes} minutes — stopping');
      _stopPaymentStatusPolling();
      _closePaymentWebView();
      _notifyPaymentHold();
      _activeKodeBayar = null;
    });
  }

  void _stopPaymentStatusPolling() {
    if (_pollingTimer != null) AppLogger.d('[Polling] Stopped');
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _pollingMaxTimer?.cancel();
    _pollingMaxTimer = null;
  }

  // ── DEEP LINKS ────────────────────────────────────────────────────────────

  /// Listens for the Finpay return deep link (`pocapp://payment/return`).
  /// On match, stops polling and signals Sambara that the payment succeeded.
  void _initDeepLinks() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      AppLogger.d('[DeepLink] Received — ${uri.scheme}://${uri.host}${uri.path}');

      if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
        if (uri.path.contains('return') || uri.path.contains('callback')) {
          AppLogger.d('[DeepLink] Payment return matched — closing overlay');
          _stopPaymentStatusPolling();
          _closePaymentWebView();
          _notifyPaymentSuccess();
          _activeKodeBayar = null;
        }
      }
    });
  }

  // ── LIFECYCLE ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _stopPaymentStatusPolling();
    _dio.close();
    _linkSubscription?.cancel();
    super.dispose();
  }

  // ── PUBLIC API ────────────────────────────────────────────────────────────

  String get effectiveWebViewUrl => _config.targetUrl;
  bool get isRequestingPermissions => value.permissionState == StartupPermissionState.requesting;

  void updateProgress(double progress) => value = value.copyWith(progress: progress);

  void updateStatus(String status) {
    value = value.copyWith(status: status);
    AppLogger.d('[Status] $status');
  }

  Future<void> requestStartupPermissions() async {
    // Small delay so the WebView has time to start rendering before the
    // system permission dialogs appear on top.
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      final outcome = await _permissionService.requestStartupPermissions();
      final cam = await _permissionService.isCameraGranted();
      final loc = await _permissionService.isLocationGranted();

      AppLogger.d('[Permission] Outcome: $outcome — camera: $cam, location: $loc');

      value = value.copyWith(
        cameraGranted: cam,
        locationGranted: loc,
        status: outcome == StartupPermissionOutcome.permanentlyDenied
            ? 'Izin ditolak permanen. Silakan cek pengaturan.'
            : 'Siap',
        permissionState: outcome == StartupPermissionOutcome.permanentlyDenied
            ? StartupPermissionState.permanentlyDenied
            : StartupPermissionState.ready,
        hasPermissionIssue: outcome != StartupPermissionOutcome.granted,
      );
    } catch (e, stack) {
      AppLogger.e('requestStartupPermissions failed', e, stack);
    }
  }

  Future<PermissionResponse> handleWebPermissionRequest(PermissionRequest request) async {
    return _permissionService.handleWebPermissionRequest(request).then((d) => d.response);
  }

  Future<GeolocationPermissionShowPromptResponse> handleGeolocationPrompt(String origin) async {
    return _permissionService.handleGeolocationPrompt(origin).then((d) => d.response);
  }

  Future<void> reloadBasePage() async {
    if (_webViewController == null) return;
    await _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri.uri(Uri.parse(effectiveWebViewUrl))),
    );
  }

  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

    final decision = _navigationGuard.evaluate(rawUrl);

    switch (decision) {
      case NavigationHandling.allowWebView:
        return NavigationActionPolicy.ALLOW;

      case NavigationHandling.openInCustomTab:
        // Guard against opening a second overlay while one is already active.
        if (value.paymentUrl == null) {
          _openPaymentWebView(rawUrl);
        } else {
          AppLogger.d('[Nav] Payment overlay already open — ignoring duplicate request');
        }
        return NavigationActionPolicy.CANCEL;

      case NavigationHandling.externalApp:
        if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
        return NavigationActionPolicy.CANCEL;

      case NavigationHandling.cancel:
        return NavigationActionPolicy.CANCEL;
    }
  }

  /// Handles postMessage from the [bridgeUserScript] fallback.
  /// Accepts HTTPS URLs only; opens the payment overlay on success.
  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.scheme != 'https') {
      AppLogger.d('[Bridge] Rejected — invalid or non-HTTPS URL');
      return;
    }

    AppLogger.d('[Bridge] Opening payment overlay via postMessage — ${_sanitizeUrl(url)}');
    _webViewController?.stopLoading();
    _openPaymentWebView(url);
  }
}
