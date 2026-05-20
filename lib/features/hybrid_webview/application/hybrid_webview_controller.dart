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
       _deepLinkStreamOverride = deepLinkStream,
       super(
         const HybridWebViewState(
           status: 'Menyiapkan aplikasi...',
           progress: 0,
           permissionState: StartupPermissionState.requesting,
           hasPermissionIssue: false,
         ),
       ) {
    AppLogger.d("[System] Controller Initialized — Stack WebView Strategy");
    _initDeepLinks();
  }

  final AppConfig _config;
  final WebPermissionService _permissionService;
  final WebNavigationGuard _navigationGuard;
  final Stream<Uri>? _deepLinkStreamOverride;

  InAppWebViewController? _webViewController;
  InAppWebViewController? get webViewController => _webViewController;

  /// Navigator context — di-set dari page agar bisa push PaymentWebViewPage.
  BuildContext? navigatorContext;

  /// Kode bayar aktif saat ini.
  String? _activeKodeBayar;

  /// Flag: apakah payment page sedang terbuka di stack.
  bool _isPaymentPageOpen = false;

  /// Timer polling & batas waktu.
  Timer? _paymentStatusPoller;
  Timer? _pollingMaxTimer;

  /// Guard concurrent polling.
  bool _isPollingPayment = false;

  /// Error log suppression.
  int _pollingErrorCount = 0;
  static const int _maxPollingErrorLog = 3;

  /// Konfigurasi durasi polling.
  static const Duration _pollingInterval = Duration(seconds: 5);
  static const Duration _pollingMaxDuration = Duration(minutes: 15);

  /// Dio instance — persistent connection pool.
  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'http://192.168.99.46:8700',
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 5),
      contentType: 'application/json',
    ),
  );

  late AppLinks _appLinks;
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
  Future<void> _openPaymentPage(String url, String? kodeBayar) async {
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
    AppLogger.d("[Payment] kodeBayar: ${kodeBayar ?? 'null'}");
    AppLogger.d("[Payment] Sambara tetap aktif di background ✅");
    AppLogger.d("[Payment] ════════════════════════════════");

    _activeKodeBayar = kodeBayar;
    _isPaymentPageOpen = true;
    _pollingErrorCount = 0;

    // Jalankan polling SEBELUM push — agar polling tidak bergantung pada UI
    _startPaymentStatusPolling();

    // Push payment page ke atas Sambara
    await Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => PaymentWebViewPage(paymentUrl: url, kodeBayar: kodeBayar ?? ''),
      ),
    );

    // Eksekusi di sini saat user POP (back) dari payment page
    AppLogger.d("[Payment] ════════════════════════════════");
    AppLogger.d("[Payment] 🔙 Payment page di-pop — kembali ke Sambara");
    AppLogger.d("[Payment] → Stop polling + dispatch paymentHold");
    AppLogger.d("[Payment] ════════════════════════════════");

    _isPaymentPageOpen = false;

    // Jika polling masih jalan (belum paid) → user cancel
    if (_paymentStatusPoller != null) {
      _stopPaymentStatusPolling();
      _notifyPaymentHold();
    }
    _activeKodeBayar = null;
  }

  // ── EVENTS ────────────────────────────────────────────────────────────────

  void _notifyPaymentHold() {
    AppLogger.d("[Event] ════════════════════════════════");
    AppLogger.d("[Event] 🔴 DISPATCH 'paymentHold' ke Sambara");
    AppLogger.d("[Event] kodeBayar: ${_activeKodeBayar ?? 'null'}");
    AppLogger.d("[Event] ════════════════════════════════");
    _webViewController?.evaluateJavascript(
      source:
          "window.dispatchEvent(new CustomEvent('paymentHold', "
          "{detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}'}}));",
    );
  }

  void _notifyPaymentCompleted() {
    AppLogger.d("[Event] ════════════════════════════════");
    AppLogger.d("[Event] 💰 DISPATCH 'paymentCompleted' ke Sambara");
    AppLogger.d("[Event] kodeBayar: ${_activeKodeBayar ?? 'null'}");
    AppLogger.d("[Event] ════════════════════════════════");
    _webViewController?.evaluateJavascript(
      source:
          "window.dispatchEvent(new CustomEvent('paymentCompleted', "
          "{detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}', status:'success'}}));",
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

  void handleConsoleMessage(String message) {
    final preview = message.length > 120 ? '${message.substring(0, 120)}...' : message;
    AppLogger.d("[JS] $preview");

    if (!message.contains('finpay_navigation')) return;

    AppLogger.d("[Console] ════════════════════════════════");
    AppLogger.d("[Console] 📨 Mendeteksi finpay_navigation");

    try {
      final Map<String, dynamic> json = jsonDecode(message);
      if (json['type'] != 'finpay_navigation') {
        AppLogger.d("[Console] ⚠️ type='${json['type']}' — skip");
        return;
      }

      final String? url = json['url']?.toString().trim();
      final String? kodeBayar = json['kodeBayar']?.toString().trim();

      AppLogger.d("[Console] ✅ type: finpay_navigation");
      AppLogger.d("[Console] 🔑 kodeBayar: ${kodeBayar ?? 'NULL'}");
      AppLogger.d("[Console] 🔗 host: ${url != null ? Uri.tryParse(url)?.host : 'null'}");

      if (url == null || url.isEmpty) {
        AppLogger.d("[Console] ❌ URL kosong");
        AppLogger.d("[Console] ════════════════════════════════");
        return;
      }

      AppLogger.d("[Console] → Push PaymentWebViewPage ke stack");
      AppLogger.d("[Console] ════════════════════════════════");

      // Push payment page ke atas Sambara (tidak mengganggu state Sambara)
      _openPaymentPage(url, kodeBayar);
    } catch (e) {
      AppLogger.d("[Console] ❌ JSON parse error: $e");
      AppLogger.d("[Console] ════════════════════════════════");
    }
  }

  // ── PAYMENT STATUS POLLING ────────────────────────────────────────────────

  void _startPaymentStatusPolling() {
    if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) {
      AppLogger.d("[Polling] ⚠️ Tidak ada kodeBayar — skip");
      return;
    }

    _stopPaymentStatusPolling();
    _pollingErrorCount = 0;

    AppLogger.d("[Polling] ▶️ Polling DIMULAI");
    AppLogger.d("[Polling] kodeBayar  : $_activeKodeBayar");
    AppLogger.d("[Polling] interval   : ${_pollingInterval.inSeconds} detik");
    AppLogger.d("[Polling] max durasi : ${_pollingMaxDuration.inMinutes} menit");
    AppLogger.d("[Polling] base url   : ${_dio.options.baseUrl}");

    _paymentStatusPoller = Timer.periodic(_pollingInterval, (_) {
      _checkPaymentStatus();
    });

    _pollingMaxTimer = Timer(_pollingMaxDuration, () {
      AppLogger.d("[Polling] ⏰ Batas ${_pollingMaxDuration.inMinutes} menit — stop");
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
      final requestBody = {'kodeBayar': _activeKodeBayar};

      AppLogger.d("[Polling] 🔄 POST /api/check-dummy-payment-status");
      AppLogger.d("[Polling] Request body: $requestBody");

      final response = await _dio.post<Map<String, dynamic>>(
        '/api/check-dummy-payment-status',
        data: requestBody,
      );

      AppLogger.d("[Polling] Response status : ${response.statusCode}");
      AppLogger.d("[Polling] Response body   : ${response.data}");

      if (response.statusCode == 200 && response.data != null) {
        final body = response.data!;

        AppLogger.d("[Polling] ── Parsed Response ──");
        AppLogger.d("[Polling]   success : ${body['success']}");
        AppLogger.d("[Polling]   code    : ${body['code']}");
        AppLogger.d("[Polling]   message : ${body['message']}");
        AppLogger.d("[Polling]   param   : ${body['param']}");

        final bool isPaid = body['success'] == true && body['code'] == '0000';
        AppLogger.d("[Polling]   isPaid  : $isPaid");
        AppLogger.d("[Polling] ────────────────────");

        _pollingErrorCount = 0;

        if (isPaid) {
          AppLogger.d("[Polling] ════════════════════════════════");
          AppLogger.d("[Polling] 💰 LUNAS — kodeBayar: $_activeKodeBayar");
          AppLogger.d("[Polling] → Pop payment page + dispatch paymentCompleted");
          AppLogger.d("[Polling] ════════════════════════════════");

          _stopPaymentStatusPolling();

          // Pop payment page — Sambara muncul kembali dalam kondisi terakhir
          final ctx = navigatorContext;
          if (ctx != null && ctx.mounted && _isPaymentPageOpen) {
            _isPaymentPageOpen = false;
            Navigator.of(ctx).pop();
          }

          // Dispatch paymentCompleted ke Sambara setelah pop
          Future.delayed(const Duration(milliseconds: 500), () {
            _notifyPaymentCompleted();
            _activeKodeBayar = null;
          });

          return;
        } else {
          AppLogger.d("[Polling] ⏳ Belum lunas — lanjut polling");
        }
      }
    } on DioException catch (e) {
      _pollingErrorCount++;
      if (_pollingErrorCount <= _maxPollingErrorLog) {
        AppLogger.d("[Polling] ❌ DioError ke-$_pollingErrorCount/$_maxPollingErrorLog");
        AppLogger.d("[Polling]   type    : ${e.type.name}");
        AppLogger.d("[Polling]   message : ${e.message}");
        if (e.response != null) {
          AppLogger.d("[Polling]   status  : ${e.response?.statusCode}");
          AppLogger.d("[Polling]   body    : ${e.response?.data}");
        }
        if (_pollingErrorCount == 1) {
          AppLogger.d(
            "[Polling] 💡 Cek: device & PC di WiFi yang sama? Server di ${_dio.options.baseUrl}?",
          );
        }
        if (_pollingErrorCount == _maxPollingErrorLog) {
          AppLogger.d("[Polling] 🔕 Log disuppress — polling tetap berjalan.");
        }
      }
    } catch (e) {
      _pollingErrorCount++;
      if (_pollingErrorCount <= _maxPollingErrorLog) {
        AppLogger.d("[Polling] ❌ Error ke-$_pollingErrorCount/$_maxPollingErrorLog: $e");
      }
    } finally {
      _isPollingPayment = false;
    }
  }

  // ── DEEP LINKS ────────────────────────────────────────────────────────────

  void _initDeepLinks() {
    _appLinks = AppLinks();
    final stream = _deepLinkStreamOverride ?? _appLinks.uriLinkStream;
    _linkSubscription = stream.listen((uri) async {
      AppLogger.d("[DeepLink] ════════════════════════════════");
      AppLogger.d("[DeepLink] 📲 Diterima: ${uri.scheme}://${uri.host}${uri.path}");
      if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
        AppLogger.d("[DeepLink] ✅ Cocok — stop polling + pop payment page");
        _stopPaymentStatusPolling();
        final ctx = navigatorContext;
        if (ctx != null && ctx.mounted && _isPaymentPageOpen) {
          _isPaymentPageOpen = false;
          Navigator.of(ctx).pop();
        }
        _activeKodeBayar = null;
      } else {
        AppLogger.d("[DeepLink] ⚠️ Tidak cocok — diabaikan");
      }
      AppLogger.d("[DeepLink] ════════════════════════════════");
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
        _openPaymentPage(rawUrl, _activeKodeBayar);
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
    _openPaymentPage(url, _activeKodeBayar);
  }
}
