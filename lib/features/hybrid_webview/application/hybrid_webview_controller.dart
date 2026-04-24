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
  
  InAppWebViewController? _webViewController;
  InAppWebViewController? get webViewController => _webViewController;

  set webViewController(InAppWebViewController? controller) {
    _webViewController = controller;
    if (_webViewController != null) {
      _setupJavaScriptHandlers();
    }
  }

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  final ChromeSafariBrowser _browser = ChromeSafariBrowser();

  /// Mendaftarkan handler JavaScript agar Web bisa memanggil fungsi Flutter.
  void _setupJavaScriptHandlers() {
    _webViewController?.addJavaScriptHandler(
      handlerName: 'SapawargaChannel',
      callback: (args) {
        _addLog("[JS Bridge] Received: $args");
        if (args.isNotEmpty) {
          _processIncomingMessage(args[0]);
        }
      },
    );
  }

  /// Menyiapkan script bridge yang akan disuntikkan di awal pemuatan (document_start).
  /// Ini menjamin objek SapawargaChannel tersedia sebelum Web berjalan.
  UserScript get bridgeUserScript => UserScript(
    groupName: "bridge",
    source: """
      (function() {
        window.SapawargaChannel = {
          postMessage: function(message) {
            window.flutter_inappwebview.callHandler('SapawargaChannel', message);
          }
        };
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  void _addLog(String message) {
    if (kReleaseMode) return;
    final now = DateTime.now();
    final time = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    value = value.copyWith(logs: ["[$time] $message", ...value.logs.take(49)]);
    debugPrint("DEBUG_LOG: $message");
  }

  void _initDeepLinks() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      _addLog("[DeepLink] Received: $uri");
      
      if (uri.scheme == 'pocapp' && uri.host == 'payment') {
        final path = uri.path.toLowerCase();
        if (path.contains('return') || path.contains('callback')) {
          if (_browser.isOpened()) {
            await _browser.close();
          }
          _webViewController?.evaluateJavascript(
            source: "window.dispatchEvent(new Event('paymentCompleted'));",
          );
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
    _addLog("[Status] $status");
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
        permissionState: outcome == StartupPermissionOutcome.permanentlyDenied 
            ? StartupPermissionState.permanentlyDenied 
            : StartupPermissionState.ready,
        hasPermissionIssue: outcome != StartupPermissionOutcome.granted,
      );
    } catch (e) {
      _addLog("[Error] Permission Request: $e");
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
    await _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(Uri.parse(effectiveWebViewUrl))));
  }

  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    
    // Perbaikan: Selalu izinkan jika navigasi berasal dari frame yang sama (internal redirect)
    if (!navigationAction.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }

    final handling = _navigationGuard.evaluate(rawUrl);
    _addLog("[Nav] ${handling.name.toUpperCase()} -> $rawUrl");

    if (handling == NavigationHandling.block) {
      _addLog("[Guard] Blocked: $rawUrl");
      return NavigationActionPolicy.CANCEL;
    }

    return NavigationActionPolicy.ALLOW;
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
    } catch (e) {
      _addLog("[Bridge Error] $e");
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;

    _addLog("[Bridge] Triggering Custom Tab for: $url");
    _webViewController?.stopLoading();
    _openInCustomTabs(url);
  }

  void handleWebMessage(WebMessage? message) {
    if (message != null && message.data != null) {
      _processIncomingMessage(message.data);
    }
  }
}
