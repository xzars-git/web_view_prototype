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
  void onClosed() {
    onClosedCallback();
  }
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
        AppLogger.d("[Browser] Closed manually by user");
        _notifyPaymentCompleted();
        smartGoBack();
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

  void _notifyPaymentCompleted() {
    AppLogger.d("[System] Notifying Web: ${_config.paymentEventName}");
    _webViewController?.evaluateJavascript(
      source: "window.dispatchEvent(new Event('${_config.paymentEventName}'));",
    );
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
      if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
        if (uri.path.contains('return') || uri.path.contains('callback')) {
          if (_browser.isOpened()) await _browser.close();
          _webViewController?.evaluateJavascript(
            source: "window.dispatchEvent(new Event('${_config.paymentEventName}'));",
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

    // 1. Deep Link
    if (uri != null && !uri.scheme.startsWith('http')) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
      return NavigationActionPolicy.CANCEL;
    }

    // 2. Navigation Guard cerdas
    final handling = _navigationGuard.evaluate(rawUrl);
    
    if (handling == NavigationHandling.openInCustomTab) {
      AppLogger.d("[Nav] Diverting to Custom Tab (Unknown Host)");
      _openInCustomTabs(rawUrl);
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
    } catch (e, stack) {
      AppLogger.e("Custom Tab error", e, stack);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _processIncomingMessage(dynamic data) {
    final String url = data.toString().trim();
    if (url.isEmpty) return;
    _webViewController?.stopLoading();
    _openInCustomTabs(url);
  }
}
