import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../../../config/logger.dart';
import '../domain/web_navigation_guard.dart';
import '../presentation/payment_webview_page.dart';
import 'web_permission_service.dart';

/// Status perizinan saat startup aplikasi.
enum StartupPermissionState { requesting, ready, permanentlyDenied }

/// Immutable state yang dikelola oleh [HybridWebViewController].
///
/// Berisi informasi status UI, progress loading, dan kondisi perizinan
/// yang digunakan oleh [HybridWebViewPage] untuk merender tampilan.
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

  /// Membuat salinan state dengan field yang diubah.
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

/// Controller utama untuk fitur Hybrid WebView.
///
/// Mengelola seluruh lifecycle WebView Sambara termasuk:
/// - Navigasi aman via [WebNavigationGuard]
/// - Stack payment page (push/pop [PaymentWebViewPage])
/// - JavaScript bridge ([SapawargaChannel])
/// - Console message interception untuk deteksi payment event
/// - Perizinan hardware (kamera, lokasi)
///
/// Menggunakan [ValueNotifier] untuk reactive state management.
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
    AppLogger.d("[Init] Controller initialized");
  }

  final AppConfig _config;
  final WebPermissionService _permissionService;
  final WebNavigationGuard _navigationGuard;

  InAppWebViewController? _webViewController;
  InAppWebViewController? get webViewController => _webViewController;

  /// BuildContext dari [HybridWebViewPage] untuk operasi [Navigator].
  /// Di-set setiap kali page di-rebuild agar selalu up-to-date.
  BuildContext? navigatorContext;

  /// Guard untuk mencegah multiple payment page di stack.
  bool _isPaymentPageOpen = false;

  /// Setter untuk WebView controller. Otomatis setup JS bridge saat di-set.
  set webViewController(InAppWebViewController? controller) {
    _webViewController = controller;
    if (_webViewController != null) {
      _setupJavaScriptHandlers();
    }
  }

  // ── NAVIGATION ──────────────────────────────────────────────────────────────

  /// Navigasi "smart back" di dalam WebView Sambara.
  /// Memanfaatkan history stack WebView untuk kembali ke halaman sebelumnya.
  Future<void> smartGoBack() async {
    if (_webViewController == null) return;
    final canGoBack = await _webViewController!.canGoBack();
    if (canGoBack) {
      await _webViewController!.goBack();
    }
  }

  // ── PAYMENT PAGE (Stack Navigator) ──────────────────────────────────────────

  /// Push [PaymentWebViewPage] ke atas Sambara via [Navigator].
  ///
  /// Sambara tetap hidup di background — state tidak hilang.
  /// Saat user pop (back), method ini melanjutkan eksekusi:
  /// - Reset flag [_isPaymentPageOpen]
  /// - Dispatch [paymentHold] ke Sambara jika pembayaran belum selesai
  Future<void> _openPaymentPage(String url) async {
    final ctx = navigatorContext;
    if (ctx == null || !ctx.mounted) return;
    if (_isPaymentPageOpen) return;

    AppLogger.d("[Payment] Push payment page: ${_sanitizeUrl(url)}");
    _isPaymentPageOpen = true;

    // Blocking call — menunggu sampai user pop payment page
    await Navigator.of(ctx).push(
      MaterialPageRoute(builder: (_) => PaymentWebViewPage(paymentUrl: url)),
    );

    // Post-pop: user kembali ke Sambara
    AppLogger.d("[Payment] Payment page closed — back to Sambara");
    _isPaymentPageOpen = false;
    _notifyPaymentHold();
  }

  // ── EVENTS ──────────────────────────────────────────────────────────────────

  /// Dispatch event [paymentHold] ke WebView Sambara.
  /// Dipanggil saat user menutup payment page tanpa menyelesaikan pembayaran.
  void _notifyPaymentHold() {
    _webViewController?.evaluateJavascript(
      source: "window.dispatchEvent(new CustomEvent('paymentHold'));",
    );
  }

  /// Membersihkan URL untuk keperluan logging (tanpa query string).
  String _sanitizeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '[invalid-url]';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  // ── JS BRIDGE ───────────────────────────────────────────────────────────────

  /// Mendaftarkan handler JavaScript untuk bridge [SapawargaChannel].
  /// Bridge ini digunakan sebagai fallback komunikasi PKB → Host.
  void _setupJavaScriptHandlers() {
    _webViewController?.addJavaScriptHandler(
      handlerName: _config.bridgeName,
      callback: (args) {
        if (args.isEmpty) return;
        _processIncomingMessage(args[0]);
      },
    );
  }

  /// UserScript yang di-inject saat dokumen mulai dimuat.
  /// Membuat objek [SapawargaChannel] di window agar PKB bisa memanggil
  /// `SapawargaChannel.postMessage(url)` sebagai fallback navigasi.
  UserScript get bridgeUserScript => UserScript(
    groupName: '${_config.bridgeName.toLowerCase()}_bridge',
    source:
        """
      (function() {
        var name = '${_config.bridgeName}';
        window[name] = {
          postMessage: function(message) {
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
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  // ── CONSOLE MESSAGE HANDLER ─────────────────────────────────────────────────

  /// Intercept dan proses console.log dari Sambara WebView.
  ///
  /// Mendeteksi dua jenis pesan JSON:
  /// - Payload dengan field `url` (webview_navigation): buka [PaymentWebViewPage]
  /// - Payload dengan `type == "close_webview"`: tutup [PaymentWebViewPage]
  void handleConsoleMessage(BuildContext context, String message) {
    if (!message.contains('"url"') && !message.contains('close_webview')) {
      return;
    }

    try {
      final Map<String, dynamic> json = jsonDecode(message);

      // Trigger: Sambara kirim URL payment gateway untuk dibuka
      // Payload: {"url": "https://..."} — tidak ada field type
      final String? url = json['url']?.toString().trim();
      if (url != null && url.isNotEmpty) {
        AppLogger.d("[Console] Payment navigation: ${_sanitizeUrl(url)}");
        _openPaymentPage(url);
        return;
      }

      // Trigger: Sambara minta tutup payment page
      if (json['type'] == 'close_webview') {
        final String? reason = json['reason']?.toString();
        AppLogger.d("[Console] Close payment page (reason: $reason)");

        final ctx = navigatorContext;
        if (ctx != null && ctx.mounted && _isPaymentPageOpen) {
          _isPaymentPageOpen = false;
          Navigator.of(ctx).pop();
        }
      }
    } catch (_) {
      // Bukan JSON valid — abaikan
    }
  }

  // ── LIFECYCLE ───────────────────────────────────────────────────────────────


  // ── PUBLIC API ──────────────────────────────────────────────────────────────

  /// URL target WebView Sambara (dari konfigurasi).
  String get effectiveWebViewUrl => _config.targetUrl;

  /// Apakah masih dalam proses meminta izin startup.
  bool get isRequestingPermissions => value.permissionState == StartupPermissionState.requesting;

  /// Update progress bar loading WebView (0.0 - 1.0).
  void updateProgress(double progress) => value = value.copyWith(progress: progress);

  /// Update status text yang ditampilkan di header bar.
  void updateStatus(String status) {
    value = value.copyWith(status: status);
  }

  /// Meminta izin kamera dan lokasi dari sistem operasi.
  /// Dipanggil sekali saat startup setelah frame pertama dirender.
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

  /// Menangani permintaan izin hardware dari Web content (kamera, mikrofon).
  Future<PermissionResponse> handleWebPermissionRequest(PermissionRequest request) async {
    return _permissionService.handleWebPermissionRequest(request);
  }

  /// Menangani permintaan izin geolokasi dari Web content.
  Future<GeolocationPermissionShowPromptResponse> handleGeolocationPrompt(String origin) async {
    return _permissionService.handleGeolocationPrompt(origin);
  }

  /// Reload WebView Sambara ke URL awal (beranda).
  Future<void> reloadBasePage() async {
    if (_webViewController == null) return;
    await _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri.uri(Uri.parse(effectiveWebViewUrl))),
    );
  }

  /// Handler navigasi untuk WebView Sambara.
  ///
  /// Evaluasi setiap URL yang dimuat melalui [WebNavigationGuard]:
  /// - [allowWebView]: izinkan di WebView Sambara
  /// - [openPaymentPage]: push ke [PaymentWebViewPage]
  /// - [externalApp]: buka di app eksternal (deep link)
  /// - [cancel]: tolak navigasi
  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

    final decision = _navigationGuard.evaluate(rawUrl);
    switch (decision) {
      case NavigationHandling.allowWebView:
        return NavigationActionPolicy.ALLOW;
      case NavigationHandling.openPaymentPage:
        AppLogger.d('[Nav] External URL → payment page: ${_sanitizeUrl(rawUrl)}');
        _openPaymentPage(rawUrl);
        return NavigationActionPolicy.CANCEL;
      case NavigationHandling.externalApp:
        if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
        return NavigationActionPolicy.CANCEL;
      case NavigationHandling.cancel:
        return NavigationActionPolicy.CANCEL;
    }
  }

  /// Memproses pesan dari bridge [SapawargaChannel].
  /// Hanya menerima URL HTTPS untuk keamanan.
  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.scheme != 'https') return;
    AppLogger.d("[Bridge] Incoming URL → payment page: ${_sanitizeUrl(url)}");
    _openPaymentPage(url);
  }
}
