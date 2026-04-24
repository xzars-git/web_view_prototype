import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../domain/web_navigation_guard.dart';
import 'web_permission_service.dart';

enum StartupPermissionState { requesting, ready, permanentlyDenied }

class HybridWebViewState {
  final String status;
  final double progress;
  final StartupPermissionState permissionState;
  final bool hasPermissionIssue;
  final bool cameraGranted;
  final bool locationGranted;
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
  InAppWebViewController? webViewController;

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  void _addLog(String message) {
    final now = DateTime.now();
    final time = "${now.hour}:${now.minute}:${now.second}";
    value = value.copyWith(logs: ["[$time] $message", ...value.logs.take(49)]);
    debugPrint("DEBUG_LOG: $message");
  }

  void _initDeepLinks() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _addLog("[DeepLink] Received: $uri");
      if (uri.scheme == 'pocapp' && uri.host == 'payment') {
        updateStatus('Pembayaran selesai, kembali ke aplikasi!');
        webViewController
            ?.evaluateJavascript(
              source: "javascript:window.dispatchEvent(new Event('paymentCompleted'));",
            )
            .catchError((e) {
          _addLog("[JS Error] $e");
        });
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
    _addLog("[Status] $status");
  }

  Future<void> requestStartupPermissions() async {
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
          status: 'Izin ditolak permanen.',
        );
        return;
      }

      value = value.copyWith(
        permissionState: StartupPermissionState.ready,
        hasPermissionIssue: false,
        status: 'Aplikasi siap.',
      );
    } catch (e) {
      _addLog("[Error] Permission Request: $e");
    }
  }

  Future<PermissionResponse> handleWebPermissionRequest(PermissionRequest request) async {
    _addLog("[WebPerm] Requesting: ${request.resources}");
    return _permissionService.handleWebPermissionRequest(request).then((d) => d.response);
  }

  Future<GeolocationPermissionShowPromptResponse> handleGeolocationPrompt(String origin) async {
    _addLog("[Geo] Requesting for: $origin");
    return _permissionService.handleGeolocationPrompt(origin).then((d) => d.response);
  }

  Future<void> reloadBasePage() async {
    if (webViewController == null) return;
    _addLog("[Reload] Loading base URL");
    await webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(Uri.parse(effectiveWebViewUrl))));
  }

  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    final handling = _navigationGuard.evaluate(rawUrl);

    _addLog("[Nav] ${handling.name.toUpperCase()} -> $rawUrl");

    if (handling == NavigationHandling.block) {
      // Jika navigasi diblokir (bukan host aplikasi),
      // kita asumsi sisi Web lupa kirim via Bridge, tapi kita blokir demi keamanan.
      _addLog("[Guard] Blocked navigation to external host: $rawUrl");
      return NavigationActionPolicy.CANCEL;
    }

    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _openInCustomTabs(String rawUrl) async {
    final cleanUrl = rawUrl.trim();
    final uri = Uri.tryParse(cleanUrl);
    
    if (uri == null || !uri.hasAbsolutePath) {
      _addLog("[Error] Malformed URL: $cleanUrl");
      return;
    }

    _addLog("[Bridge] Triggering CustomTabs for: ${uri.host}");
    try {
      bool opened = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
        webViewConfiguration: const WebViewConfiguration(enableJavaScript: true),
      );

      if (!opened) {
        _addLog("[Bridge] Failed CustomTabs, trying External App...");
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      }

      _addLog("[Bridge] Result: $opened");
    } catch (e) {
      _addLog("[Bridge Exception] $e");
    }
  }

  void handleWebMessage(WebMessage? message) {
    if (message != null && message.data != null) {
      final url = message.data.toString();
      _addLog("[Bridge] Received URL from Web: $url");
      _openInCustomTabs(url);
    }
  }
}
