import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../domain/web_navigation_guard.dart';
import 'web_permission_service.dart';

/// Status siklus hidup perizinan aplikasi saat startup.
enum StartupPermissionState { requesting, ready, permanentlyDenied }

/// Representasi state untuk fitur Hybrid WebView.
class HybridWebViewState {
  /// Pesan status operasional aplikasi.
  final String status;
  
  /// Progress pemuatan WebView (0.0 ke 1.0).
  final double progress;
  
  /// Tahap perizinan sistem saat ini.
  final StartupPermissionState permissionState;
  
  /// Flag jika terdeteksi isu perizinan (misal ditolak).
  final bool hasPermissionIssue;
  
  /// Status izin kamera sistem.
  final bool cameraGranted;
  
  /// Status izin lokasi sistem.
  final bool locationGranted;
  
  /// Daftar riwayat log untuk Debug Tracker.
  final List<String> logs;

  const HybridWebViewState({
    required this.status,
    required this.progress,
    required this.permissionState,
    required this.hasPermissionIssue,
    this.cameraGranted = false,
    this.locationGranted = false,
    this.logs = const [],
  });

  /// Helper untuk membuat copy dari state dengan perubahan beberapa field.
  HybridWebViewState copyWith({
    String? status,
    double? progress,
    StartupPermissionState? permissionState,
    bool? hasPermissionIssue,
    bool? cameraGranted,
    bool? locationGranted,
    List<String>? logs,
  }) {
    return HybridWebViewState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      permissionState: permissionState ?? this.permissionState,
      hasPermissionIssue: hasPermissionIssue ?? this.hasPermissionIssue,
      cameraGranted: cameraGranted ?? this.cameraGranted,
      locationGranted: locationGranted ?? this.locationGranted,
      logs: logs ?? this.logs,
    );
  }
}

/// Controller utama yang mengelola logika bisnis dan state untuk Hybrid WebView.
/// 
/// Menggunakan [ValueNotifier] agar UI dapat merespon perubahan state secara reaktif.
class HybridWebViewController extends ValueNotifier<HybridWebViewState> {
  HybridWebViewController({
    required AppConfig config,
    WebPermissionService? permissionService,
    WebNavigationGuard? navigationGuard,
  })  : _config = config,
        _permissionService = permissionService ?? WebPermissionService(),
        _navigationGuard = navigationGuard ?? WebNavigationGuard(config: config),
        super(const HybridWebViewState(
          status: 'Menyiapkan aplikasi...',
          progress: 0,
          permissionState: StartupPermissionState.requesting,
          hasPermissionIssue: false,
          logs: ['[System] App Initialized'],
        )) {
    _initDeepLinks();
  }

  final AppConfig _config;
  final WebPermissionService _permissionService;
  final WebNavigationGuard _navigationGuard;
  
  /// Referensi ke InAppWebViewController untuk manipulasi WebView secara langsung.
  InAppWebViewController? webViewController;

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  /// Instance browser untuk Chrome Custom Tabs (Android) atau SFSafariViewController (iOS).
  /// Digunakan agar kita bisa menutup browser secara programatik.
  final ChromeSafariBrowser _browser = ChromeSafariBrowser();

  /// Mencatat pesan ke dalam riwayat log Debug Tracker.
  void _addLog(String message) {
    if (kReleaseMode) return;
    final now = DateTime.now();
    final time = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    value = value.copyWith(logs: ["[$time] $message", ...value.logs.take(49)]);
    debugPrint("DEBUG_LOG: $message");
  }

  /// Menginisialisasi pendengar Deep Link (pocapp://).
  void _initDeepLinks() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      _addLog("[DeepLink] Received: $uri");
      
      // Menangani callback pembayaran kembali ke aplikasi secara aman.
      // Kita mengecek scheme, host, dan memastikan path diawali dengan 
      // kata kunci yang kita kenali (seperti return atau callback).
      if (uri.scheme == 'pocapp' && uri.host == 'payment') {
        final path = uri.path.toLowerCase();
        final isReturnPath = path.contains('return') || path.contains('callback');

        if (isReturnPath) {
          _addLog("[DeepLink] Valid payment return path detected: $path");
          updateStatus('Pembayaran selesai!');

          // TUTUP OTOMATIS: Jika Custom Tab masih terbuka, tutup secara paksa.
          if (_browser.isOpened()) {
            _addLog("[DeepLink] Closing Custom Tab...");
            await _browser.close();
          }

          // Mengirimkan event ke JavaScript di dalam WebView.
          webViewController?.evaluateJavascript(
            source: "window.dispatchEvent(new Event('paymentCompleted'));",
          );
        } else {
          _addLog("[DeepLink Warning] Ignored unknown path: $path");
        }
      }
    });
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  /// URL utama yang harus dimuat oleh WebView.
  String get effectiveWebViewUrl => _config.targetUrl;

  bool get isRequestingPermissions => value.permissionState == StartupPermissionState.requesting;
  bool get isPermanentlyDenied => value.permissionState == StartupPermissionState.permanentlyDenied;
  bool get showRetryPermissionButton =>
      value.permissionState == StartupPermissionState.ready && value.hasPermissionIssue;

  /// Memperbarui progres pemuatan halaman.
  void updateProgress(double progress) {
    value = value.copyWith(progress: progress);
  }

  /// Memperbarui pesan status dan mencatatnya ke log.
  void updateStatus(String status) {
    value = value.copyWith(status: status);
    _addLog("[Status] $status");
  }

  /// Meminta izin sistem (Lokasi & Kamera) secara sekuensial.
  Future<void> requestStartupPermissions() async {
    // Delay singkat untuk stabilitas inisialisasi UI.
    await Future.delayed(const Duration(milliseconds: 500));
    updateStatus('Meminta izin kamera dan lokasi...');

    try {
      final outcome = await _permissionService.requestStartupPermissions();
      final cam = await _permissionService.isCameraGranted();
      final loc = await _permissionService.isLocationGranted();
      
      value = value.copyWith(
        cameraGranted: cam,
        locationGranted: loc,
      );

      _addLog("[Perms] Cam: $cam, Loc: $loc, Outcome: $outcome");

      if (outcome == StartupPermissionOutcome.permanentlyDenied) {
        value = value.copyWith(
          permissionState: StartupPermissionState.permanentlyDenied,
          hasPermissionIssue: true,
          status: 'Izin ditolak permanen. Aktifkan dari pengaturan perangkat.',
        );
        return;
      }

      value = value.copyWith(
        permissionState: StartupPermissionState.ready,
        hasPermissionIssue: outcome != StartupPermissionOutcome.granted,
        status: 'Aplikasi siap.',
      );
    } catch (e) {
      _addLog("[Error] Permission Request: $e");
    }
  }

  /// Menangani permintaan izin dari dalam WebView (Android).
  Future<PermissionResponse> handleWebPermissionRequest(PermissionRequest request) async {
    _addLog("[WebPerm] Requesting: ${request.resources}");
    // Mengembalikan status GRANT karena izin sistem sudah divalidasi di startup.
    return _permissionService.handleWebPermissionRequest(request).then((d) => d.response);
  }

  /// Menangani permintaan izin geolokasi dari dalam WebView.
  Future<GeolocationPermissionShowPromptResponse> handleGeolocationPrompt(String origin) async {
    _addLog("[Geo] Requesting for: $origin");
    // Mengembalikan status ALLOW karena izin sistem sudah divalidasi di startup.
    return _permissionService.handleGeolocationPrompt(origin).then((d) => d.response);
  }

  /// Memuat ulang halaman utama aplikasi.
  Future<void> reloadBasePage() async {
    if (webViewController == null) return;
    _addLog("[Reload] Loading base URL");
    await webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(Uri.parse(effectiveWebViewUrl))));
  }

  /// Mengevaluasi setiap navigasi URL yang terjadi di WebView.
  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    final handling = _navigationGuard.evaluate(rawUrl);

    _addLog("[Nav] ${handling.name.toUpperCase()} -> $rawUrl");

    if (handling == NavigationHandling.block) {
      _addLog("[Guard] Blocked navigation to external host: $rawUrl");
      return NavigationActionPolicy.CANCEL;
    }

    return NavigationActionPolicy.ALLOW;
  }

  /// Membuka URL pembayaran secara cerdas.
  /// 
  /// 1. Jika skema bukan HTTP/HTTPS (seperti dana://), buka aplikasi luar secara langsung.
  /// 2. Jika HTTP/HTTPS (seperti link Finpay/Shopee), gunakan Custom Tabs.
  ///    Custom Tabs menjaga konteks navigasi agar tidak lari ke Google Chrome standalone.
  Future<void> _openInCustomTabs(String rawUrl) async {
    final cleanUrl = rawUrl.trim();
    final uri = Uri.tryParse(cleanUrl);
    
    if (uri == null || !uri.hasAbsolutePath) {
      _addLog("[Error] Malformed URL: $cleanUrl");
      return;
    }

    _addLog("[Bridge] Processing URL: ${uri.host}");

    try {
      // JIKA BUKAN HTTP/HTTPS (Contoh: dana://, whatsapp://)
      if (!uri.scheme.startsWith('http')) {
        _addLog("[Bridge] Direct Scheme detected. Launching External...");
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }

      // JIKA HTTP/HTTPS (Link Pembayaran)
      // Kita gunakan ChromeSafariBrowser agar navigasi tetap dalam satu 'task' aplikasi.
      // Jika kita gunakan 'externalNonBrowserApplication' pada link HTTPS, 
      // OS akan memutus konteks dan seringkali lari ke Google Chrome standalone.
      _addLog("[Bridge] Opening via Custom Tab to maintain context...");
      
      await _browser.open(
        url: WebUri.uri(uri),
        settings: ChromeSafariBrowserSettings(
          shareState: CustomTabsShareState.SHARE_STATE_OFF,
          showTitle: true,
          enableUrlBarHiding: true,
          noHistory: false,
        ),
      );
    } catch (e) {
      _addLog("[Bridge Exception] $e");
      // Upaya terakhir: Buka di browser eksternal apa pun
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Handler untuk pesan yang diterima dari JavaScript via 'SapawargaChannel'.
  void handleWebMessage(WebMessage? message) {
    if (message != null && message.data != null) {
      final url = message.data.toString();
      _addLog("[Bridge] Received URL from Web: $url");
      // Hentikan loading di WebView utama untuk mencegah konflik navigasi
      webViewController?.stopLoading();
      // Langsung proses link secara cerdas
      _openInCustomTabs(url);
    }
  }
}
