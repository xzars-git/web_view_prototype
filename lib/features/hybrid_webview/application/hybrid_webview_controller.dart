import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../../../config/logger.dart';
import '../domain/web_navigation_guard.dart';
import '../presentation/payment_webview_page.dart';
import 'web_permission_service.dart';

enum StartupPermissionState { requesting, ready, permanentlyDenied }

class HybridWebViewState {
  final String status;
  final double progress;
  final StartupPermissionState permissionState;
  final bool hasPermissionIssue;
  final bool cameraGranted;
  final bool locationGranted;

  const HybridWebViewState({
    required this.status,
    required this.progress,
    required this.permissionState,
    required this.hasPermissionIssue,
    this.cameraGranted = false,
    this.locationGranted = false,
  });

  HybridWebViewState copyWith({
    String? status,
    double? progress,
    StartupPermissionState? permissionState,
    bool? hasPermissionIssue,
    bool? cameraGranted,
    bool? locationGranted,
  }) {
    return HybridWebViewState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      permissionState: permissionState ?? this.permissionState,
      hasPermissionIssue: hasPermissionIssue ?? this.hasPermissionIssue,
      cameraGranted: cameraGranted ?? this.cameraGranted,
      locationGranted: locationGranted ?? this.locationGranted,
    );
  }
}

class HybridWebViewController extends ValueNotifier<HybridWebViewState> {
  HybridWebViewController({
    required AppConfig config,
    WebPermissionService? permissionService,
    WebNavigationGuard? navigationGuard,
    Stream<Uri>? deepLinkStream,
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
    AppLogger.d("[System] Controller Initialized — Stack WebView Strategy");
  }

  final AppConfig _config;
  final WebPermissionService _permissionService;
  final WebNavigationGuard _navigationGuard;

  InAppWebViewController? _webViewController;
  InAppWebViewController? get webViewController => _webViewController;

  /// Navigator context — di-set dari page agar bisa push PaymentWebViewPage.
  BuildContext? navigatorContext;

  /// Flag: apakah payment page sedang terbuka di stack.
  bool _isPaymentPageOpen = false;

  StreamSubscription<Uri>? _linkSubscription;

  set webViewController(InAppWebViewController? controller) {
    _webViewController = controller;
    if (_webViewController != null) {
      _setupJavaScriptHandlers();
    }
  }

  // ── NAVIGATION ────────────────────────────────────────────────────────────

  bool isExternalPage(String url) {
    try {
      final currentUri = Uri.parse(url);
      final baseUri = Uri.parse(_config.targetUrl);
      return currentUri.host.isNotEmpty && currentUri.host != baseUri.host;
    } catch (_) {
      return false;
    }
  }

  void updateLastSafeUrl(String url) {
    if (!isExternalPage(url)) {
      AppLogger.d("[Nav] Sambara URL: ${Uri.tryParse(url)?.path}");
    }
  }

  Future<void> smartGoBack() async {
    if (_webViewController == null) return;
    final canGoBack = await _webViewController!.canGoBack();
    if (canGoBack) {
      AppLogger.d("[Nav] Standard goBack in Sambara");
      await _webViewController!.goBack();
    }
  }

  // ── OPEN PAYMENT PAGE (Stack Navigator) ──────────────────────────────────

  /// Push PaymentWebViewPage di atas Sambara.
  /// Sambara tetap hidup di background — state tidak hilang sama sekali.
  Future<void> _openPaymentPage(String url) async {
    final ctx = navigatorContext;
    if (ctx == null || !ctx.mounted) {
      AppLogger.d("[Payment] ❌ Navigator context tidak tersedia");
      return;
    }

    if (_isPaymentPageOpen) {
      AppLogger.d("[Payment] ⚠️ Payment page sudah terbuka — skip");
      return;
    }

    AppLogger.d("[Payment] ════════════════════════════════");
    AppLogger.d("[Payment] 🚀 Push PaymentWebViewPage ke stack");
    AppLogger.d("[Payment] URL: ${Uri.tryParse(url)?.host}${Uri.tryParse(url)?.path}");
    AppLogger.d("[Payment] Sambara tetap aktif di background ✅");
    AppLogger.d("[Payment] ════════════════════════════════");

    _isPaymentPageOpen = true;

    // Push payment page ke atas Sambara
    await Navigator.of(
      ctx,
    ).push(MaterialPageRoute(builder: (_) => PaymentWebViewPage(paymentUrl: url)));

    // Eksekusi di sini saat user POP (back) dari payment page
    AppLogger.d("[Payment] ════════════════════════════════");
    AppLogger.d("[Payment] 🔙 Payment page di-pop — kembali ke Sambara");
    AppLogger.d("[Payment] → Stop polling + dispatch paymentHold");
    AppLogger.d("[Payment] ════════════════════════════════");

    _isPaymentPageOpen = false;

    // Jika polling masih jalan (belum paid) → user cancel
    _notifyPaymentHold();
  }

  // ── EVENTS ────────────────────────────────────────────────────────────────

  void _notifyPaymentHold() {
    AppLogger.d("[Event] ════════════════════════════════");
    AppLogger.d("[Event] 🔴 DISPATCH 'paymentHold' ke Sambara");
    AppLogger.d("[Event] ════════════════════════════════");
    _webViewController?.evaluateJavascript(
      source: "window.dispatchEvent(new CustomEvent('paymentHold'));",
    );
  }

  String _sanitizeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '[invalid-url]';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  // ── JS BRIDGE ─────────────────────────────────────────────────────────────

  void _setupJavaScriptHandlers() {
    AppLogger.d("[Bridge] Setting up JavaScript handlers...");
    _webViewController?.addJavaScriptHandler(
      handlerName: _config.bridgeName,
      callback: (args) {
        if (args.isEmpty) return;
        _processIncomingMessage(args[0]);
      },
    );
  }

  UserScript get bridgeUserScript => UserScript(
    groupName: '${_config.bridgeName.toLowerCase()}_bridge',
    source:
        """
      (function() {
        var name = '${_config.bridgeName}';
        window[name] = {
          postMessage: function(message) {
            console.log('[Bridge] ' + name + '.postMessage called with: ' + message);
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler(name, message);
              return true;
            } else {
              window.addEventListener('flutterInAppWebViewPlatformReady', function() {
                window.flutter_inappwebview.callHandler(name, message);
              });
              return true;
            }
          }
        };
        console.log('[Bridge] ' + name + ' initialized');
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  // ── CONSOLE MESSAGE HANDLER ───────────────────────────────────────────────

  void handleConsoleMessage(BuildContext context, String message) {
    final preview = message.length > 120 ? '${message.substring(0, 120)}...' : message;
    AppLogger.d("[JS] $preview");

    if (!message.contains('webview_navigation')) return;

    AppLogger.d("[Console] ════════════════════════════════");
    AppLogger.d("[Console] 📨 Mendeteksi webview_navigation");

    try {
      final Map<String, dynamic> json = jsonDecode(message);

      if (json['type'] == 'webview_navigation') {
        final String? url = json['url']?.toString().trim();

        if (url == null || url.isEmpty) {
          AppLogger.d("[Console] ❌ URL kosong");
          AppLogger.d("[Console] ════════════════════════════════");
          return;
        }

        AppLogger.d("[Console] → Push PaymentWebViewPage ke stack");
        AppLogger.d("[Console] ════════════════════════════════");

        // Push payment page ke atas Sambara (tidak mengganggu state Sambara)
        _openPaymentPage(url);
      }

      if (json['type'] == 'close_webview') {
        final String? reason = json['reason']?.toString();

        AppLogger.d("[Console] ✅ type: close_webview");
        AppLogger.d("[Console] ℹ️ reason: $reason");

        if (reason == 'payment_success') {
          AppLogger.d("[Console] 💰 Payment success via close_webview");
        }

        // Pop payment page jika terbuka
        final ctx = navigatorContext;
        if (ctx != null && ctx.mounted && _isPaymentPageOpen) {
          AppLogger.d("[Console] → Pop payment page");
          _isPaymentPageOpen = false;
          Navigator.of(ctx).pop();
        }
        AppLogger.d("[Console] ════════════════════════════════");
      }
    } catch (e) {
      AppLogger.d("[Console] ❌ JSON parse error: $e");
    }
  }

  // ── LIFECYCLE ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  // ── PUBLIC API ────────────────────────────────────────────────────────────

  String get effectiveWebViewUrl => _config.targetUrl;
  bool get isRequestingPermissions => value.permissionState == StartupPermissionState.requesting;

  void updateProgress(double progress) => value = value.copyWith(progress: progress);
  void updateStatus(String status) {
    value = value.copyWith(status: status);
    AppLogger.d("[Status] $status");
  }

  Future<void> requestStartupPermissions() async {
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      final outcome = await _permissionService.requestStartupPermissions();
      final cam = await _permissionService.isCameraGranted();
      final loc = await _permissionService.isLocationGranted();
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
      AppLogger.e("Permission error", e, stack);
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

  /// Navigation handler untuk Sambara WebView.
  /// Payment URLs dari navigation guard juga di-push ke stack, bukan replace.
  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

    final decision = _navigationGuard.evaluate(rawUrl);
    switch (decision) {
      case NavigationHandling.allowWebView:
        updateLastSafeUrl(rawUrl);
        return NavigationActionPolicy.ALLOW;
      case NavigationHandling.openPaymentPage:
        // Stack Strategy: push PaymentWebViewPage
        AppLogger.d('[Nav] External URL → push payment page: ${_sanitizeUrl(rawUrl)}');
        _openPaymentPage(rawUrl);
        return NavigationActionPolicy.CANCEL;
      case NavigationHandling.externalApp:
        if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
        return NavigationActionPolicy.CANCEL;
      case NavigationHandling.cancel:
        return NavigationActionPolicy.CANCEL;
    }
  }

  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.scheme != 'https') {
      AppLogger.d("[Bridge] Rejected: invalid or non-HTTPS URL");
      return;
    }
    AppLogger.d("[Bridge] → push payment page: ${_sanitizeUrl(url)}");
    _openPaymentPage(url);
  }
}
