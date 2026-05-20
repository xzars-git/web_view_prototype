import 'dart:async';
import 'dart:convert';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
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

  /// Kode bayar aktif saat ini — diset dari console message finpay_navigation.
  String? _activeKodeBayar;

  /// Timer polling status pembayaran via API.
  Timer? _paymentStatusPoller;

  /// Timer batas maksimal polling (15 menit).
  Timer? _pollingMaxTimer;

  /// Flag untuk mencegah polling concurrent.
  bool _isPollingPayment = false;

  /// Counter error berturut-turut saat polling — untuk suppress noise di log.
  int _pollingErrorCount = 0;
  static const int _maxPollingErrorLog = 3;

  /// Durasi polling & batas waktu.
  static const Duration _pollingInterval = Duration(seconds: 5);
  static const Duration _pollingMaxDuration = Duration(minutes: 15);

  set webViewController(InAppWebViewController? controller) {
    _webViewController = controller;
    if (_webViewController != null) {
      _setupJavaScriptHandlers();
    }
  }

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  late final ChromeSafariBrowser _browser;

  void _initBrowser([ChromeSafariBrowser? browser]) {
    _browser = browser ?? _PaymentChromeBrowser(
      onClosedCallback: () {
        // User tutup Custom Tab → langsung kirim paymentHold ke PKB.
        // Dialog konfirmasi ditampilkan oleh sisi Sambara/WebView, bukan host app.
        AppLogger.d("[Browser] ════════════════════════════════");
        AppLogger.d("[Browser] 🔴 Custom Tab DITUTUP oleh user");
        AppLogger.d("[Browser] kodeBayar aktif: ${_activeKodeBayar ?? 'null'}");
        AppLogger.d("[Browser] → Stop polling + kirim paymentHold ke PKB");
        AppLogger.d("[Browser] ════════════════════════════════");
        _stopPaymentStatusPolling();
        _notifyPaymentHold();
        _activeKodeBayar = null;
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

  // ── PAYMENT HOLD EVENT ──────────────────────────────────────────────────
  // Dikirim ke PKB saat user menutup Custom Tab.
  // Dialog konfirmasi pembatalan ditampilkan oleh Sambara (WebView), BUKAN host app.
  // ────────────────────────────────────────────────────────────────────────

  /// Dispatch event 'paymentHold' ke PKB WebView.
  /// Menginformasikan bahwa user menutup Custom Tab tanpa menyelesaikan pembayaran.
  void _notifyPaymentHold() {
    AppLogger.d("[Payment] ════════════════════════════════");
    AppLogger.d("[Payment] 🔴 DISPATCH event 'paymentHold' ke PKB");
    AppLogger.d("[Payment] kodeBayar: ${_activeKodeBayar ?? 'null'}");
    AppLogger.d("[Payment] Sambara akan menampilkan dialog konfirmasi pembatalan");
    AppLogger.d("[Payment] ════════════════════════════════");
    _webViewController?.evaluateJavascript(
      source: "window.dispatchEvent(new CustomEvent('paymentHold', {detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}'}}));",
    );
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

    // SapawargaChannel: terima URL e-wallet → buka di Custom Tab
    // Tetap dipertahankan sebagai fallback bridge tradisional
    _webViewController?.addJavaScriptHandler(
      handlerName: _config.bridgeName,
      callback: (args) {
        if (args.isEmpty) return;
        _processIncomingMessage(args[0]);
      },
    );
  }

  /// UserScript untuk SapawargaChannel (e-wallet → Custom Tab).
  /// Dipertahankan sebagai fallback — primary handler sekarang via console.log.
  UserScript get bridgeUserScript => UserScript(
    groupName: '${_config.bridgeName.toLowerCase()}_bridge',
    source: """
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

  // ── CONSOLE MESSAGE HANDLER ──────────────────────────────────────────────
  // Primary handler: intercept console.log JSON dari WebView PKB.
  // Format: { "type": "finpay_navigation", "url": "https://...", "kodeBayar": "..." }
  // ────────────────────────────────────────────────────────────────────────

  void handleConsoleMessage(String message) {
    final preview = message.length > 120 ? '${message.substring(0, 120)}...' : message;
    AppLogger.d("[JS] $preview");

    if (!message.contains('finpay_navigation')) return;

    AppLogger.d("[Console] ════════════════════════════════");
    AppLogger.d("[Console] 📨 Mendeteksi finpay_navigation di console message");

    try {
      final Map<String, dynamic> json = jsonDecode(message);
      if (json['type'] != 'finpay_navigation') {
        AppLogger.d("[Console] ⚠️ JSON valid tapi type='${json['type']}' — skip");
        return;
      }

      final String? url = json['url']?.toString().trim();
      final String? kodeBayar = json['kodeBayar']?.toString().trim();

      AppLogger.d("[Console] ✅ type: finpay_navigation");
      AppLogger.d("[Console] 🔑 kodeBayar: ${kodeBayar ?? '⚠️ NULL — polling tidak akan berjalan!'}");
      AppLogger.d("[Console] 🔗 url host: ${url != null ? Uri.tryParse(url)?.host ?? 'parse error' : 'null'}");

      if (url == null || url.isEmpty) {
        AppLogger.d("[Console] ❌ URL kosong — batalkan proses");
        AppLogger.d("[Console] ════════════════════════════════");
        return;
      }

      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https') {
        AppLogger.d("[Console] ❌ URL ditolak — scheme='${uri?.scheme}', harus https://");
        AppLogger.d("[Console] ════════════════════════════════");
        return;
      }

      _activeKodeBayar = kodeBayar;
      _pollingErrorCount = 0;

      AppLogger.d("[Console] → Membuka Custom Tab + memulai polling (max ${_pollingMaxDuration.inMinutes} menit)");
      AppLogger.d("[Console] ════════════════════════════════");

      _webViewController?.stopLoading();
      _openInCustomTabs(url);

    } catch (e) {
      AppLogger.d("[Console] ❌ JSON parse error: $e");
      AppLogger.d("[Console] ════════════════════════════════");
    }
  }

  // ── PAYMENT STATUS POLLING ───────────────────────────────────────────────
  // Polling API check-dummy-payment-status setiap 5 detik, maks 15 menit.
  // Jika status paid → close Custom Tab saja (TIDAK kirim event ke PKB).
  // ────────────────────────────────────────────────────────────────────────

  void _startPaymentStatusPolling() {
    if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) {
      AppLogger.d("[Polling] ⚠️ Tidak ada kodeBayar — polling tidak dimulai");
      return;
    }

    _stopPaymentStatusPolling();
    _pollingErrorCount = 0;

    AppLogger.d("[Polling] ▶️ Polling DIMULAI");
    AppLogger.d("[Polling] kodeBayar  : $_activeKodeBayar");
    AppLogger.d("[Polling] interval   : ${_pollingInterval.inSeconds} detik");
    AppLogger.d("[Polling] max durasi : ${_pollingMaxDuration.inMinutes} menit");
    AppLogger.d("[Polling] endpoint   : http://192.168.99.46:8700/api/check-dummy-payment-status");

    _paymentStatusPoller = Timer.periodic(_pollingInterval, (_) {
      _checkPaymentStatus();
    });

    // Auto-stop polling setelah 15 menit
    _pollingMaxTimer = Timer(_pollingMaxDuration, () {
      AppLogger.d("[Polling] ════════════════════════════════");
      AppLogger.d("[Polling] ⏰ Batas waktu ${_pollingMaxDuration.inMinutes} menit tercapai");
      AppLogger.d("[Polling] Polling dihentikan otomatis — pembayaran belum terdeteksi");
      AppLogger.d("[Polling] ════════════════════════════════");
      _stopPaymentStatusPolling();
    });
  }

  void _stopPaymentStatusPolling() {
    if (_paymentStatusPoller != null) {
      AppLogger.d("[Polling] ⏹️ Polling DIHENTIKAN");
    }
    _paymentStatusPoller?.cancel();
    _paymentStatusPoller = null;
    _pollingMaxTimer?.cancel();
    _pollingMaxTimer = null;
    _isPollingPayment = false;
  }

  Future<void> _checkPaymentStatus() async {
    if (_isPollingPayment) return;
    if (_activeKodeBayar == null) {
      _stopPaymentStatusPolling();
      return;
    }

    _isPollingPayment = true;
    try {
      final endpoint = Uri.parse('http://192.168.99.46:8700/api/check-dummy-payment-status');
      final requestBody = jsonEncode({'kodeBayar': _activeKodeBayar});

      AppLogger.d("[Polling] 🔄 POST $endpoint");
      AppLogger.d("[Polling] Request body: $requestBody");

      final response = await http
          .post(endpoint, headers: {'Content-Type': 'application/json'}, body: requestBody)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw TimeoutException(
              'Request timeout 5 detik — pastikan device dan server di WiFi yang sama'),
          );

      AppLogger.d("[Polling] Response status : ${response.statusCode}");
      AppLogger.d("[Polling] Response body   : ${response.body}");

      if (response.statusCode == 200) {
        final Map<String, dynamic> body = jsonDecode(response.body);

        // Log field-field response dari API
        AppLogger.d("[Polling] ── Parsed Response ──");
        AppLogger.d("[Polling]   success : ${body['success']}");
        AppLogger.d("[Polling]   code    : ${body['code']}");
        AppLogger.d("[Polling]   message : ${body['message']}");
        AppLogger.d("[Polling]   param   : ${body['param']}");

        // Cek apakah pembayaran sudah berhasil
        // API return: { success: true, code: "0000", message: "...sudah berhasil dibayar" }
        final bool isPaid = body['success'] == true && body['code'] == '0000';

        AppLogger.d("[Polling]   isPaid  : $isPaid");
        AppLogger.d("[Polling] ────────────────────");

        _pollingErrorCount = 0;

        if (isPaid) {
          AppLogger.d("[Polling] ════════════════════════════════");
          AppLogger.d("[Polling] 💰 LUNAS — kodeBayar: $_activeKodeBayar");
          AppLogger.d("[Polling] → Menutup Custom Tab (TIDAK kirim event ke PKB)");
          AppLogger.d("[Polling] ════════════════════════════════");
          _stopPaymentStatusPolling();

          if (_browser.isOpened()) {
            AppLogger.d("[Polling] 🔒 Menutup Custom Tab...");
            await _browser.close();
          }

          _activeKodeBayar = null;
          return;
        } else {
          AppLogger.d("[Polling] ⏳ Belum lunas — lanjut polling");
        }
      } else {
        AppLogger.d("[Polling] ⚠️ HTTP ${response.statusCode} — response tidak 200");
      }
    } catch (e) {
      _pollingErrorCount++;
      if (_pollingErrorCount <= _maxPollingErrorLog) {
        AppLogger.d("[Polling] Error ke-$_pollingErrorCount/$_maxPollingErrorLog: $e");
        if (_pollingErrorCount == 1) {
          AppLogger.d("[Polling] 💡 Cek: device & PC di WiFi yang sama? Server jalan di 192.168.99.46:8700?");
        }
        if (_pollingErrorCount == _maxPollingErrorLog) {
          AppLogger.d("[Polling] 🔕 Error log disuppress — polling tetap berjalan.");
        }
      }
    } finally {
      _isPollingPayment = false;
    }
  }

  void _initDeepLinks() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      AppLogger.d("[DeepLink] ════════════════════════════════");
      AppLogger.d("[DeepLink] 📲 Diterima: ${uri.scheme}://${uri.host}${uri.path}");
      if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
        if (uri.path.contains('return') || uri.path.contains('callback')) {
          AppLogger.d("[DeepLink] ✅ Cocok — menutup Custom Tab");
          _stopPaymentStatusPolling();
          if (_browser.isOpened()) await _browser.close();
          _activeKodeBayar = null;
        } else {
          AppLogger.d("[DeepLink] ⚠️ Path '${uri.path}' tidak cocok — diabaikan");
        }
      } else {
        AppLogger.d("[DeepLink] ⚠️ Scheme/host tidak cocok — diabaikan");
      }
      AppLogger.d("[DeepLink] ════════════════════════════════");
    });
  }

  @override
  void dispose() {
    _stopPaymentStatusPolling();
    _linkSubscription?.cancel();
    super.dispose();
  }

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

    final decision = _navigationGuard.evaluate(rawUrl);

    switch (decision) {
      case NavigationHandling.allowWebView:
        return NavigationActionPolicy.ALLOW;
        
      case NavigationHandling.openInCustomTab:
        if (!_browser.isOpened()) {
          _openInCustomTabs(rawUrl);
        } else {
          AppLogger.d('[Nav] Custom Tab sudah terbuka — skip (${_sanitizeUrl(rawUrl)})');
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
    if (uri == null) {
      AppLogger.d("[CustomTab] ❌ URL tidak valid");
      return;
    }
    AppLogger.d("[CustomTab] ════════════════════════════════");
    AppLogger.d("[CustomTab] 🌐 Membuka Custom Tab");
    AppLogger.d("[CustomTab] host : ${uri.host}");
    AppLogger.d("[CustomTab] path : ${uri.path}");
    try {
      if (!uri.scheme.startsWith('http')) {
        AppLogger.d("[CustomTab] scheme non-http → launchUrl external");
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
      AppLogger.d("[CustomTab] ✅ Berhasil dibuka");
      AppLogger.d("[CustomTab] ════════════════════════════════");
      _startPaymentStatusPolling();
    } catch (e, stack) {
      AppLogger.e("[CustomTab] ❌ Gagal — fallback ke launchUrl", e, stack);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      AppLogger.d("[Bridge] Rejected: malformed URL from PKB");
      return;
    }
    if (uri.scheme != 'https') {
      AppLogger.d("[Bridge] Rejected: non-HTTPS scheme '${uri.scheme}'");
      return;
    }

    AppLogger.d("[Bridge] Opening in Custom Tab: ${_sanitizeUrl(url)}");
    _webViewController?.stopLoading();
    _openInCustomTabs(url);
  }
}
