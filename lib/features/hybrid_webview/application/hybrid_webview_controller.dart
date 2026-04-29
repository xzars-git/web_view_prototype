import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../../../config/logger.dart';
import '../domain/web_navigation_guard.dart';
import 'web_permission_service.dart';

/// Status siklus hidup perizinan aplikasi saat startup.
enum StartupPermissionState { requesting, ready, permanentlyDenied }

class _PaymentChromeBrowser extends ChromeSafariBrowser {
  _PaymentChromeBrowser({required this.onClosedCallback});

  final VoidCallback onClosedCallback;

  @override
  void onClosed() {
    onClosedCallback();
  }
}

/// Representasi state untuk fitur Hybrid WebView.
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
    AppLogger.d("[Config] Target URL: $effectiveWebViewUrl");
    _initBrowser();
    _initDeepLinks();
  }

  final AppConfig _config;
  final WebPermissionService _permissionService;
  final WebNavigationGuard _navigationGuard;

  InAppWebViewController? _webViewController;
  InAppWebViewController? get webViewController => _webViewController;

  /// URL internal yang sedang aktif.
  String? _currentInternalUrl;

  /// URL internal sebelum yang aktif (Halaman asal sebelum proses pembayaran dimulai).
  String? _lastSafeUrl;

  set webViewController(InAppWebViewController? controller) {
    _webViewController = controller;
    if (_webViewController != null) {
      _setupJavaScriptHandlers();
    }
  }

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  late final ChromeSafariBrowser _browser;

  void _initBrowser() {
    _browser = _PaymentChromeBrowser(
      onClosedCallback: () {
        AppLogger.d("[Browser] Closed manually by user");
        _notifyPaymentCompleted();
        // Otomatis deteksi jika kita stuck di halaman redirect/pembayaran
        smartGoBack();
      },
    );
  }

  /// Menentukan apakah URL saat ini berada di luar domain utama aplikasi.
  bool isExternalPage(String url) {
    try {
      final currentUri = Uri.parse(url);
      final baseUri = Uri.parse(_config.targetUrl);
      
      // Jika host berbeda dan bukan kosong, anggap sebagai halaman eksternal (pembayaran/bank)
      return currentUri.host.isNotEmpty && currentUri.host != baseUri.host;
    } catch (_) {
      return false;
    }
  }

  /// Fungsi cerdas untuk kembali: Jika di halaman luar (pembayaran), lompat ke halaman aman terakhir.
  Future<void> smartGoBack() async {
    if (_webViewController == null) return;

    final currentUrl = (await _webViewController?.getUrl())?.toString() ?? '';
    final canGoBack = await _webViewController!.canGoBack();
    
    AppLogger.d("[Nav] SmartBack attempt from: $currentUrl");

    // Jika user berada di domain luar (VA/CC di Finpay/Bank)
    if (isExternalPage(currentUrl)) {
      // Kita prioritaskan balik ke halaman internal yang 'benar-benar aman' (sebelum redirector)
      final target = _lastSafeUrl ?? _currentInternalUrl;
      if (target != null) {
        AppLogger.d("[Nav] Stuck in external page (VA/CC), forcing jump to safe internal URL: $target");
        await _webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(target)),
        );
        return;
      }
    } 
    
    // Jika masih di domain internal tapi canGoBack true
    if (canGoBack) {
      AppLogger.d("[Nav] Standard goBack");
      await _webViewController!.goBack();
    } else {
      AppLogger.d("[Nav] No history to go back, closing page");
    }
  }

  void updateLastSafeUrl(String url) {
    if (!isExternalPage(url)) {
      // Jika URL internal berubah, kita geser history-nya.
      // _lastSafeUrl akan menyimpan halaman SEBELUM halaman sekarang.
      if (_currentInternalUrl != null && _currentInternalUrl != url) {
        _lastSafeUrl = _currentInternalUrl;
        AppLogger.d("[Nav] Safe history updated. Last Safe: $_lastSafeUrl, Current: $url");
      }
      _currentInternalUrl = url;
    }
  }

  void _notifyPaymentCompleted() {
    AppLogger.d("[System] Notifying Web: ${_config.paymentEventName}");
    _webViewController?.evaluateJavascript(
      source: "window.dispatchEvent(new Event('${_config.paymentEventName}'));",
    );
  }

  /// Mendaftarkan handler JavaScript agar Web bisa memanggil fungsi Flutter.
  void _setupJavaScriptHandlers() {
    AppLogger.d("[Bridge] Setting up JavaScript handlers...");
    _webViewController?.addJavaScriptHandler(
      handlerName: _config.bridgeName,
      callback: (args) {
        if (args.isEmpty) {
          AppLogger.d("[Bridge] ⚠️ Received empty message");
          return;
        }

        for (var i = 0; i < args.length; i++) {
          final arg = args[i];
          AppLogger.d("[Bridge] Arg[$i]: $arg");
        }

        _processIncomingMessage(args[0]);
      },
    );
    AppLogger.d("[Bridge] JavaScript handlers registered");
  }

  /// Menyiapkan script bridge yang akan disuntikkan di awal pemuatan (document_start).
  /// Ini menjamin objek bridge tersedia sebelum Web berjalan.
  UserScript get bridgeUserScript => UserScript(
    groupName: _config.bridgeName.toLowerCase(),
    source: """
      (function() {
        window.${_config.bridgeName} = {
          postMessage: function(message) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('${_config.bridgeName}', message);
            } else {
                window.addEventListener('flutterInAppWebViewPlatformReady', function(event) {
                    window.flutter_inappwebview.callHandler('${_config.bridgeName}', message);
                });
            }
          }
        };
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  /// Public method untuk UI add debug log
  void addDebugLog(String message) {
    AppLogger.d(message);
  }

  void _initDeepLinks() {
    AppLogger.d("[DeepLink] Initializing listener...");
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      AppLogger.d("[DeepLink] Received: $uri");

      if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
        final path = uri.path.toLowerCase();
        if (path.contains('return') || path.contains('callback')) {
          AppLogger.d("[DeepLink] Payment return confirmed");

          if (_browser.isOpened()) {
            await _browser.close();
            AppLogger.d("[DeepLink] Custom Tab closed");
          }

          _webViewController?.evaluateJavascript(
            source: "window.dispatchEvent(new Event('${_config.paymentEventName}'));",
          );
          AppLogger.d("[DeepLink] ${_config.paymentEventName} event dispatched");
        }
      }
    });
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  String get effectiveWebViewUrl => _config.targetUrl;

  bool get isRequestingPermissions => value.permissionState == StartupPermissionState.requesting;
  bool get isPermanentlyDenied => value.permissionState == StartupPermissionState.permanentlyDenied;
  bool get showRetryPermissionButton =>
      value.permissionState == StartupPermissionState.ready && value.hasPermissionIssue;

  void updateProgress(double progress) {
    value = value.copyWith(progress: progress);
  }

  void updateStatus(String status) {
    value = value.copyWith(status: status);
    AppLogger.d("[Status] $status");
  }

  Future<void> requestStartupPermissions() async {
    AppLogger.d("[System] Requesting startup permissions...");
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      final outcome = await _permissionService.requestStartupPermissions();
      final cam = await _permissionService.isCameraGranted();
      final loc = await _permissionService.isLocationGranted();

      value = value.copyWith(
        cameraGranted: cam,
        locationGranted: loc,
        permissionState: outcome == StartupPermissionOutcome.permanentlyDenied
            ? StartupPermissionState.permanentlyDenied
            : StartupPermissionState.ready,
        hasPermissionIssue: outcome != StartupPermissionOutcome.granted,
      );
      AppLogger.d("[System] Permissions Ready (Camera: $cam, Location: $loc)");
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
    AppLogger.d("[System] Reloading base page");
    if (_webViewController == null) return;
    await _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri.uri(Uri.parse(effectiveWebViewUrl))),
    );
  }

  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    AppLogger.d("[Nav] handleNavigation: $rawUrl");

    if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

    // 1. Tangani Deep Link (Skema non-HTTP seperti dana://, whatsapp://, dll)
    if (uri != null && !uri.scheme.startsWith('http')) {
      AppLogger.d("[DeepLink] Launching external app for: ${uri.scheme}");
      launchUrl(uri, mode: LaunchMode.externalApplication);
      return NavigationActionPolicy.CANCEL;
    }

    // Navigasi non-main-frame tetap diizinkan untuk resource internal non-payment.
    if (!navigationAction.isForMainFrame) return NavigationActionPolicy.ALLOW;

    final handling = _navigationGuard.evaluate(rawUrl);
    AppLogger.d("[Nav] Guard: ${handling.name} -> $rawUrl");

    if (handling == NavigationHandling.block) {
      AppLogger.d("[Guard] Blocked: $rawUrl");
      return NavigationActionPolicy.CANCEL;
    }

    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _openInCustomTabs(String rawUrl) async {
    AppLogger.d("[Bridge] Opening Custom Tab for: $rawUrl");

    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) {
      AppLogger.d("[Bridge] ❌ Invalid URL format");
      return;
    }

    try {
      if (!uri.scheme.startsWith('http')) {
        AppLogger.d("[Bridge] Launching external app (non-http): $rawUrl");
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
    } catch (e, stack) {
      AppLogger.e("Custom Tab error", e, stack);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;
    
    AppLogger.d("[Bridge] Triggering Custom Tab via postMessage");
    _webViewController?.stopLoading();
    _openInCustomTabs(url);
  }

  void handleWebMessage(WebMessage? message) {
    if (message != null && message.data != null) {
      _processIncomingMessage(message.data);
    }
  }
}
