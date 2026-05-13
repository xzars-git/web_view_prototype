import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../../../config/logger.dart';
import '../domain/web_navigation_guard.dart';
import 'web_permission_service.dart';

enum StartupPermissionState { requesting, ready, permanentlyDenied }

class _PaymentChromeBrowser extends ChromeSafariBrowser {
  _PaymentChromeBrowser({required this.onClosedCallback});
  final VoidCallback onClosedCallback;
  @override
  void onClosed() => onClosedCallback();
}

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
    ChromeSafariBrowser? browser,
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
    AppLogger.d("[System] Controller Initialized");
    _initBrowser(browser);
    _initDeepLinks();
  }

  final AppConfig _config;
  final WebPermissionService _permissionService;
  final WebNavigationGuard _navigationGuard;

  InAppWebViewController? _webViewController;
  InAppWebViewController? get webViewController => _webViewController;

  String? _currentInternalUrl;
  String? _lastSafeUrl;

  /// Guard untuk mencegah double-fire event paymentCompleted.
  /// Di-set true saat notify dipanggil, auto-reset setelah 3 detik.
  bool _paymentNotified = false;

  set webViewController(InAppWebViewController? controller) {
    _webViewController = controller;
    if (_webViewController != null) {
      _setupJavaScriptHandlers();
    }
  }

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  late final ChromeSafariBrowser _browser;
  Timer? _demoAutoCloseTimer;

  void _initBrowser([ChromeSafariBrowser? browser]) {
    _browser = browser ?? _PaymentChromeBrowser(
      onClosedCallback: () {
        // Production: user tutup Custom Tab manual → beritahu PKB cek status.
        // PKB yang mengontrol navigasi setelah menerima event ini.
        AppLogger.d("[Browser] Closed manually by user");
        Future.delayed(const Duration(milliseconds: 500), () {
          _notifyPaymentCompleted();
        });
      },
    );
  }

  bool isExternalPage(String url) {
    try {
      final currentUri = Uri.parse(url);
      final baseUri = Uri.parse(_config.targetUrl);
      return currentUri.host.isNotEmpty && currentUri.host != baseUri.host;
    } catch (_) {
      return false;
    }
  }

  Future<void> smartGoBack() async {
    if (_webViewController == null) return;
    final currentUrl = (await _webViewController?.getUrl())?.toString() ?? '';
    final canGoBack = await _webViewController!.canGoBack();
    
    AppLogger.d("[Nav] SmartBack attempt from: $currentUrl");

    if (isExternalPage(currentUrl)) {
      final target = _lastSafeUrl ?? _currentInternalUrl;
      if (target != null) {
        AppLogger.d("[Nav] Forcing return to internal safe URL: $target");
        await _webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(target)),
        );
        return;
      }
    } 
    
    if (canGoBack) {
      AppLogger.d("[Nav] Standard goBack");
      await _webViewController!.goBack();
    }
  }

  void updateLastSafeUrl(String url) {
    if (!isExternalPage(url)) {
      if (_currentInternalUrl != null && _currentInternalUrl != url) {
        _lastSafeUrl = _currentInternalUrl;
        AppLogger.d("[Nav] Safe history updated: $_lastSafeUrl");
      }
      _currentInternalUrl = url;
    }
  }

  /// Dispatch event 'paymentCompleted' ke PKB WebView.
  /// Guard double-fire: jika sudah dipanggil dalam 3 detik terakhir, skip.
  void _notifyPaymentCompleted() {
    if (_paymentNotified) {
      AppLogger.d("[Payment] Already notified — skipping duplicate dispatch");
      return;
    }
    _paymentNotified = true;
    AppLogger.d("[Payment] Dispatching '${_config.paymentEventName}' event");
    _webViewController?.evaluateJavascript(
      // CustomEvent dengan detail memudahkan tracing di PKB side
      source: "window.dispatchEvent(new CustomEvent('${_config.paymentEventName}', {detail:{ts:Date.now()}}));",
    );
    // Auto-reset flag setelah 3 detik agar bisa handle transaksi berikutnya
    Future.delayed(const Duration(seconds: 3), () => _paymentNotified = false);
  }

  /// Sanitasi URL untuk logging — hanya tampilkan scheme://host/path,
  /// query params dihilangkan untuk mencegah token/session bocor ke log.
  String _sanitizeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '[invalid-url]';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

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
    groupName: _config.bridgeName.toLowerCase(),
    source: """
      (function() {
        var bridgeName = '${_config.bridgeName}';
        window[bridgeName] = {
          postMessage: function(message) {
            console.log('[Bridge] ' + bridgeName + '.postMessage called');
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler(bridgeName, message);
                return true; 
            } else {
                window.addEventListener('flutterInAppWebViewPlatformReady', function(event) {
                    window.flutter_inappwebview.callHandler(bridgeName, message);
                });
                return true;
            }
          }
        };
        console.log('[Bridge] ' + bridgeName + ' initialized');
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  void addDebugLog(String message) => AppLogger.d(message);

  void _initDeepLinks() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      // Log deep link yang diterima (tanpa query params)
      AppLogger.d("[DeepLink] Received: ${uri.scheme}://${uri.host}${uri.path}");
      if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
        if (uri.path.contains('return') || uri.path.contains('callback')) {
          // URUTAN PENTING: notify DULU sebelum close browser,
          // agar onClosed() callback tidak re-fire (flag sudah true).
          _notifyPaymentCompleted();
          if (_browser.isOpened()) await _browser.close();
        }
      }
    });
  }

  void _startDemoAutoClose() {
    _demoAutoCloseTimer?.cancel();
    _demoAutoCloseTimer = Timer(const Duration(seconds: 7), () async {
      if (_browser.isOpened()) {
        AppLogger.d('[Sim] Auto-triggering E-Wallet success after 7s');
        _paymentNotified = false;
        _notifyPaymentCompleted();
        await _browser.close();
      }
    });
  }

  @override
  void dispose() {
    _demoAutoCloseTimer?.cancel();
    _linkSubscription?.cancel();
    super.dispose();
  }

  // ── SIMULASI (hanya untuk testing/demo) ───────────────────────────────────
  // Tombol simulasi mereproduksi urutan PERSIS yang terjadi di production:
  //   1. _notifyPaymentCompleted() → dispatch event ke PKB
  //   2. _browser.close() → tutup Custom Tab (jika terbuka)
  // HAPUS blok ini di production build.
  // ─────────────────────────────────────────────────────────────────────────

  /// [SIM] Jalur A: CC/VA — Finpay redirect ke halaman result.
  /// Production: handleNavigation deteksi result URL → _notifyPaymentCompleted().
  Future<void> simulatePaymentCompleted() async {
    AppLogger.d('[Sim] 💳 CC/VA — dispatch paymentCompleted');
    _paymentNotified = false;
    _notifyPaymentCompleted();  // ← sama persis dengan production
  }

  /// [SIM] Jalur B (manual close): User tutup Custom Tab e-wallet.
  /// Production: onClosed() → _notifyPaymentCompleted().
  Future<void> simulateCustomTabClose() async {
    AppLogger.d('[Sim] 📱 E-Wallet manual close — notify + close tab');
    _paymentNotified = false;
    _notifyPaymentCompleted();                        // ← production step 1
    if (_browser.isOpened()) await _browser.close();   // ← production step 2
  }

  /// [SIM] Jalur B (deep link): Finpay kirim pocapp://payment/return.
  /// Production: _initDeepLinks listener → _notifyPaymentCompleted() → close.
  Future<void> simulateDeepLink() async {
    AppLogger.d('[Sim] 🔗 Deep link pocapp://payment/return — notify + close tab');
    _paymentNotified = false;
    _notifyPaymentCompleted();                        // ← production step 1
    if (_browser.isOpened()) await _browser.close();   // ← production step 2
  }
  // ─────────────────────────────────────────────────────────────────────────

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

  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

    // Delegasi ke WebNavigationGuard
    final decision = _navigationGuard.evaluate(rawUrl);

    switch (decision) {
      case NavigationHandling.allowWebView:
        // Deteksi halaman hasil Finpay (CC/VA) → notifikasi ke PKB.
        // Sesuai spec bagian 2: handleNavigation deteksi result URL.
        if (_config.isPaymentResultUrl(rawUrl)) {
          AppLogger.d('[Nav] Payment result URL detected — notifying PKB');
          _notifyPaymentCompleted();
        }
        return NavigationActionPolicy.ALLOW;
        
      case NavigationHandling.openInCustomTab:
        // Jangan buka Custom Tab baru jika:
        // (a) Custom Tab sudah terbuka — mencegah loop reopen
        // (b) Payment baru saja di-notify — PKB navigasi balik setelah event diterima
        if (!_browser.isOpened() && !_paymentNotified) {
          _openInCustomTabs(rawUrl);
        } else {
          AppLogger.d('[Nav] Custom Tab sudah terbuka / payment notified — skip reopen (${_sanitizeUrl(rawUrl)})');
        }
        return NavigationActionPolicy.CANCEL;

      case NavigationHandling.externalApp:
        if (uri != null) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        return NavigationActionPolicy.CANCEL;

      case NavigationHandling.cancel:
        return NavigationActionPolicy.CANCEL;
    }
  }

  Future<void> _openInCustomTabs(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return;
    try {
      if (!uri.scheme.startsWith('http')) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
      await _browser.open(
        url: WebUri.uri(uri),
        settings: ChromeSafariBrowserSettings(
          shareState: CustomTabsShareState.SHARE_STATE_OFF,
          showTitle: true,
          noHistory: false,
        ),
      );
      AppLogger.d('[Nav] Custom Tab opened — waiting for deep link or manual close');
      _startDemoAutoClose();
    } catch (e, stack) {
      AppLogger.e("Custom Tab error", e, stack);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;

    // Validasi: hanya terima URL https:// dari bridge.
    // Semua e-wallet (DANA, ShopeePay, LinkAja) menggunakan HTTPS.
    // Menolak scheme lain mencegah penyalahgunaan bridge.
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      AppLogger.d("[Bridge] Rejected: malformed URL from PKB");
      return;
    }
    if (uri.scheme != 'https') {
      AppLogger.d("[Bridge] Rejected: non-HTTPS scheme '${uri.scheme}' — only https:// allowed");
      return;
    }

    AppLogger.d("[Bridge] Opening in Custom Tab: ${_sanitizeUrl(url)}");
    _webViewController?.stopLoading();
    _openInCustomTabs(url);
  }
}
