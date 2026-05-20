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

  /// Guard untuk mencegah double-fire event paymentCompleted.
  /// Di-set true saat notify dipanggil, auto-reset setelah 3 detik.
  bool _paymentNotified = false;

  /// URL terakhir Custom Tab yang dibuka — digunakan untuk reopen setelah paymentHold.
  String? _lastCustomTabUrl;

  /// Kode bayar aktif saat ini — diset dari console message finpay_navigation.
  String? _activeKodeBayar;

  /// Timer polling status pembayaran via API.
  Timer? _paymentStatusPoller;

  /// Flag untuk mencegah polling concurrent.
  bool _isPollingPayment = false;

  /// Counter error berturut-turut saat polling — untuk suppress noise di log.
  int _pollingErrorCount = 0;
  static const int _maxPollingErrorLog = 3; // log error hanya N kali berturut-turut

  /// BuildContext untuk menampilkan dialog — di-set dari page.
  BuildContext? _dialogContext;

  /// Setter untuk dialog context, dipanggil dari presentation layer.
  set dialogContext(BuildContext? ctx) => _dialogContext = ctx;

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
        AppLogger.d("[Browser] ════════════════════════════════");
        AppLogger.d("[Browser] 🔴 Custom Tab DITUTUP oleh user");
        AppLogger.d("[Browser] kodeBayar aktif: ${_activeKodeBayar ?? 'null'}");
        AppLogger.d("[Browser] → Stop polling + tampilkan dialog konfirmasi");
        AppLogger.d("[Browser] ════════════════════════════════");
        _stopPaymentStatusPolling();
        _showPaymentHoldDialog();
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
      AppLogger.d("[Payment] ⚠️ Duplicate dispatch dicegah — sudah dikirim dalam 3 detik terakhir");
      return;
    }
    _paymentNotified = true;
    AppLogger.d("[Payment] ════════════════════════════════");
    AppLogger.d("[Payment] ✅ DISPATCH event '${_config.paymentEventName}' ke PKB");
    AppLogger.d("[Payment] ════════════════════════════════");
    _webViewController?.evaluateJavascript(
      source: "window.dispatchEvent(new CustomEvent('${_config.paymentEventName}', {detail:{ts:Date.now()}}));",
    );
    Future.delayed(const Duration(seconds: 3), () => _paymentNotified = false);
  }

  /// Dispatch event 'paymentHold' ke PKB WebView.
  /// Menginformasikan bahwa user menutup Custom Tab tanpa menyelesaikan pembayaran.
  void _notifyPaymentHold() {
    AppLogger.d("[Payment] ════════════════════════════════");
    AppLogger.d("[Payment] 🔴 DISPATCH event 'paymentHold' ke PKB");
    AppLogger.d("[Payment] kodeBayar: ${_activeKodeBayar ?? 'null'}");
    AppLogger.d("[Payment] PKB diharapkan hit API pembatalan setelah ini");
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

  void addDebugLog(String message) => AppLogger.d(message);

  // ── CONSOLE MESSAGE HANDLER ──────────────────────────────────────────────
  // Primary handler: intercept console.log JSON dari WebView PKB.
  // Format yang diharapkan:
  // {
  //   "type": "finpay_navigation",
  //   "url": "https://...",
  //   "kodeBayar": "3222002005265231"
  // }
  // ────────────────────────────────────────────────────────────────────────

  /// Dipanggil dari onConsoleMessage di presentation layer.
  /// Mendeteksi JSON finpay_navigation dan memproses pembukaan Custom Tab.
  void handleConsoleMessage(String message) {
    // Log semua console message (kecuali yg terlalu panjang)
    final preview = message.length > 120 ? '${message.substring(0, 120)}...' : message;
    AppLogger.d("[JS] $preview");

    // Quick-check sebelum JSON parse
    if (!message.contains('finpay_navigation')) return;

    AppLogger.d("[Console] ════════════════════════════════");
    AppLogger.d("[Console] 📨 Mendeteksi finpay_navigation di console message");

    try {
      final Map<String, dynamic> json = jsonDecode(message);
      if (json['type'] != 'finpay_navigation') {
        AppLogger.d("[Console] ⚠️ JSON valid tapi type='${json['type']}' — bukan finpay_navigation, skip");
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

      // Validasi scheme
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https') {
        AppLogger.d("[Console] ❌ URL ditolak — scheme='${uri?.scheme}', harus https://");
        AppLogger.d("[Console] ════════════════════════════════");
        return;
      }

      // Simpan state
      _activeKodeBayar = kodeBayar;
      _lastCustomTabUrl = url;
      _pollingErrorCount = 0; // reset error counter untuk transaksi baru

      AppLogger.d("[Console] → Membuka Custom Tab + memulai polling");
      AppLogger.d("[Console] ════════════════════════════════");

      _webViewController?.stopLoading();
      _openInCustomTabs(url);

    } catch (e) {
      AppLogger.d("[Console] ❌ JSON parse error: $e");
      AppLogger.d("[Console] Raw message: $message");
      AppLogger.d("[Console] ════════════════════════════════");
    }
  }

  // ── PAYMENT STATUS POLLING ───────────────────────────────────────────────
  // Polling API check-dummy-payment-status setiap 3 detik.
  // Jika status true → close Custom Tab otomatis + notify PKB.
  // ────────────────────────────────────────────────────────────────────────

  void _startPaymentStatusPolling() {
    if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) {
      AppLogger.d("[Polling] ⚠️ Tidak ada kodeBayar — polling tidak dimulai");
      return;
    }

    _stopPaymentStatusPolling();
    _pollingErrorCount = 0;
    AppLogger.d("[Polling] ▶️ Polling DIMULAI");
    AppLogger.d("[Polling] kodeBayar : $_activeKodeBayar");
    AppLogger.d("[Polling] interval  : 3 detik");
    AppLogger.d("[Polling] endpoint  : http://192.168.99.46:8700/api/check-dummy-payment-status");

    _paymentStatusPoller = Timer.periodic(const Duration(seconds: 3), (_) {
      _checkPaymentStatus();
    });
  }

  void _stopPaymentStatusPolling() {
    if (_paymentStatusPoller != null) {
      AppLogger.d("[Polling] ⏹️ Polling DIHENTIKAN");
    }
    _paymentStatusPoller?.cancel();
    _paymentStatusPoller = null;
    _isPollingPayment = false;
  }

  Future<void> _checkPaymentStatus() async {
    if (_isPollingPayment) return; // guard concurrent
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
          .post(
            endpoint,
            headers: {'Content-Type': 'application/json'},
            body: requestBody,
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw Exception('Request timeout setelah 5 detik — pastikan device dan server di WiFi yang sama'),
          );

      AppLogger.d("[Polling] Response status : ${response.statusCode}");
      AppLogger.d("[Polling] Response body   : ${response.body}");

      if (response.statusCode == 200) {
        final Map<String, dynamic> body = jsonDecode(response.body);
        final bool isPaid = body['data']?['status'] == true ||
                            body['data']?['is_paid'] == true ||
                            (body['success'] == true && body['data']?['status_payment'] == true);

        AppLogger.d("[Polling] isPaid: $isPaid");
        _pollingErrorCount = 0; // reset karena request berhasil

        if (isPaid) {
          AppLogger.d("[Polling] ════════════════════════════════");
          AppLogger.d("[Polling] 💰 Status LUNAS — menutup Custom Tab otomatis");
          AppLogger.d("[Polling] ════════════════════════════════");
          _stopPaymentStatusPolling();
          _paymentNotified = false;
          _notifyPaymentCompleted();
          if (_browser.isOpened()) {
            AppLogger.d("[Polling] 🔒 Menutup Custom Tab...");
            await _browser.close();
          }
          _activeKodeBayar = null;
          _lastCustomTabUrl = null;
          return;
        } else {
          AppLogger.d("[Polling] ⏳ Status belum lunas — lanjut polling");
        }
      } else {
        AppLogger.d("[Polling] ⚠️ HTTP ${response.statusCode} — response tidak 200");
      }
    } catch (e) {
      _pollingErrorCount++;
      // Log error penuh hanya N kali pertama — setelah itu ringkas, agar tidak spam
      if (_pollingErrorCount <= _maxPollingErrorLog) {
        AppLogger.d("[Polling] Error ke-$_pollingErrorCount/$_maxPollingErrorLog: $e");
        if (_pollingErrorCount == 1) {
          AppLogger.d("[Polling] 💡 Cek: device & PC di WiFi yang sama? Server jalan di 192.168.99.46:8700?");
        }
        if (_pollingErrorCount == _maxPollingErrorLog) {
          AppLogger.d("[Polling] 🔕 Error log disuppress — server tidak reachable. Polling tetap berjalan.");
        }
      }
    } finally {
      _isPollingPayment = false;
    }
  }

  // ── PAYMENT HOLD DIALOG ──────────────────────────────────────────────────
  // Ditampilkan saat user menutup Custom Tab.
  // Opsi: "Batal" (reopen Custom Tab) atau "Batalkan Transaksi" (kirim paymentHold).
  // ────────────────────────────────────────────────────────────────────────

  void _showPaymentHoldDialog() {
    final ctx = _dialogContext;
    if (ctx == null || !ctx.mounted) {
      AppLogger.d("[Dialog] No valid context — sending paymentHold directly");
      _notifyPaymentHold();
      return;
    }

    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Konfirmasi Pembatalan Transaksi',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1B5E20),
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Info kode bayar
            if (_activeKodeBayar != null && _activeKodeBayar!.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Kode Bayar',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _activeKodeBayar!,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              'Anda menutup halaman pembayaran. Apakah Anda ingin membatalkan transaksi ini atau melanjutkan pembayaran?',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          // Tombol "Batal" → reopen Custom Tab
          TextButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              _reopenCustomTab();
            },
            child: const Text(
              'Lanjutkan Bayar',
              style: TextStyle(
                color: Color(0xFF1B5E20),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // Tombol "Batalkan Transaksi" → kirim paymentHold event
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              AppLogger.d("[Payment] User confirmed cancellation — sending paymentHold");
              _notifyPaymentHold();
              // Bersihkan state pembayaran
              _activeKodeBayar = null;
              _lastCustomTabUrl = null;
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red[700],
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Batalkan Transaksi'),
          ),
        ],
      ),
    );
  }

  /// Membuka kembali Custom Tab dengan URL terakhir.
  /// Dipanggil saat user memilih "Batal" di dialog paymentHold.
  void _reopenCustomTab() {
    if (_lastCustomTabUrl == null || _lastCustomTabUrl!.isEmpty) {
      AppLogger.d("[Payment] No stored URL to reopen Custom Tab");
      return;
    }
    AppLogger.d("[Payment] Reopening Custom Tab: ${_sanitizeUrl(_lastCustomTabUrl!)}");
    _openInCustomTabs(_lastCustomTabUrl!);
  }

  void _initDeepLinks() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      AppLogger.d("[DeepLink] ════════════════════════════════");
      AppLogger.d("[DeepLink] 📲 Diterima: ${uri.scheme}://${uri.host}${uri.path}");
      if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
        if (uri.path.contains('return') || uri.path.contains('callback')) {
          AppLogger.d("[DeepLink] ✅ Cocok — pembayaran selesai via deep link");
          AppLogger.d("[DeepLink] → Stop polling + dispatch paymentCompleted + close tab");
          _stopPaymentStatusPolling();
          _paymentNotified = false;
          _notifyPaymentCompleted();
          if (_browser.isOpened()) await _browser.close();
          _activeKodeBayar = null;
          _lastCustomTabUrl = null;
        } else {
          AppLogger.d("[DeepLink] ⚠️ Path '${uri.path}' tidak mengandung 'return'/'callback' — diabaikan");
        }
      } else {
        AppLogger.d("[DeepLink] ⚠️ Scheme/host tidak cocok (expected ${_config.deepLinkScheme}://${_config.deepLinkHost}) — diabaikan");
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

    // Delegasi ke WebNavigationGuard
    final decision = _navigationGuard.evaluate(rawUrl);

    switch (decision) {
      case NavigationHandling.allowWebView:
        // Deteksi halaman hasil Finpay (CC/VA) → notifikasi ke PKB.
        if (_config.isPaymentResultUrl(rawUrl)) {
          AppLogger.d('[Nav] Payment result URL detected — notifying PKB');
          _stopPaymentStatusPolling();
          _paymentNotified = false;
          _notifyPaymentCompleted();
        }
        return NavigationActionPolicy.ALLOW;
        
      case NavigationHandling.openInCustomTab:
        // Jangan buka Custom Tab baru jika sudah terbuka atau baru saja di-notify
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
    if (uri == null) {
      AppLogger.d("[CustomTab] ❌ URL tidak valid — batal buka Custom Tab");
      return;
    }
    AppLogger.d("[CustomTab] ════════════════════════════════");
    AppLogger.d("[CustomTab] 🌐 Membuka Custom Tab");
    AppLogger.d("[CustomTab] host : ${uri.host}");
    AppLogger.d("[CustomTab] path : ${uri.path}");
    try {
      if (!uri.scheme.startsWith('http')) {
        AppLogger.d("[CustomTab] scheme non-http ('${uri.scheme}') → launchUrl external");
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
      AppLogger.d("[CustomTab] ✅ Custom Tab berhasil dibuka");
      AppLogger.d("[CustomTab] ════════════════════════════════");
      _startPaymentStatusPolling();
    } catch (e, stack) {
      AppLogger.e("[CustomTab] ❌ Gagal buka Custom Tab — fallback ke launchUrl", e, stack);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;

    // Validasi: hanya terima URL https:// dari bridge.
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
    _lastCustomTabUrl = url;
    _webViewController?.stopLoading();
    _openInCustomTabs(url);
  }
}

