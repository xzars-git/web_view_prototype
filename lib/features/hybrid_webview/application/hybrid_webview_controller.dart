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
  }) : _config = config,
       _permissionService = permissionService ?? WebPermissionService(),
       _navigationGuard = navigationGuard ?? WebNavigationGuard(config: config),
       super(
         const HybridWebViewState(
           status: 'Menyiapkan aplikasi...',
           progress: 0,
           permissionState: StartupPermissionState.requesting,
           hasPermissionIssue: false,
           logs: ['[System] App Initialized'],
         ),
       ) {
    _addLog("[System] Controller Initialized");
    _addLog("[Config] Target URL: $effectiveWebViewUrl");
    _initBrowser();
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
  late final ChromeSafariBrowser _browser;

  void _initBrowser() {
    _browser = _PaymentChromeBrowser(
      onClosedCallback: () {
        _addLog("[Browser] Closed manually by user");
        _notifyPaymentCompleted();
      },
    );
  }

  void _notifyPaymentCompleted() {
    print("DEBUG_NOTIFY: 📢 Notifying Web: paymentCompleted");
    _addLog("[System] Notifying Web: paymentCompleted");
    _webViewController?.evaluateJavascript(
      source: "window.dispatchEvent(new Event('paymentCompleted'));",
    );
    print("DEBUG_NOTIFY: ✅ paymentCompleted event sent");
  }

  /// Mendaftarkan handler JavaScript agar Web bisa memanggil fungsi Flutter.
  void _setupJavaScriptHandlers() {
    print("DEBUG_BRIDGE: 🔧 [START] Setting up JavaScript handlers...");
    _webViewController?.addJavaScriptHandler(
      handlerName: 'SapawargaChannel',
      callback: (args) {
        print("DEBUG_BRIDGE: 📥 MESSAGE RECEIVED FROM WEB!");
        print("DEBUG_BRIDGE: Number of arguments: ${args.length}");
        
        if (args.isEmpty) {
          print("DEBUG_BRIDGE: ⚠️ No data received in arguments");
          _addLog("[Bridge] ⚠️ Received empty message");
          return;
        }

        for (var i = 0; i < args.length; i++) {
          final arg = args[i];
          print("DEBUG_BRIDGE: Arg[$i] Content: $arg (Type: ${arg.runtimeType})");
          _addLog("[Bridge] Arg[$i]: $arg");
        }

        _processIncomingMessage(args[0]);
      },
    );
    print("DEBUG_BRIDGE: ✅ JavaScript handlers registered");
    _addLog("[Bridge] JavaScript handlers registered");
  }

  /// Menyiapkan script bridge yang akan disuntikkan di awal pemuatan (document_start).
  /// Ini menjamin objek SapawargaChannel tersedia sebelum Web berjalan.
  UserScript get bridgeUserScript => UserScript(
    groupName: "bridge",
    source: """
      (function() {
        window.SapawargaChannel = {
          postMessage: function(message) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('SapawargaChannel', message);
            } else {
                window.addEventListener('flutterInAppWebViewPlatformReady', function(event) {
                    window.flutter_inappwebview.callHandler('SapawargaChannel', message);
                });
            }
          }
        };
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  void _addLog(String message) {
    if (kReleaseMode) return;
    final now = DateTime.now();
    final time =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    value = value.copyWith(logs: ["[$time] $message", ...value.logs.take(49)]);
    print("DEBUG_LOG: $message");
  }

  /// Public method untuk UI add debug log
  void addDebugLog(String message) {
    _addLog(message);
  }

  void _initDeepLinks() {
    print("DEBUG_DEEPLINK: 🔗 Initializing deep link listener...");
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      print("DEBUG_DEEPLINK: 📨 Deep link received: $uri");
      _addLog("[DeepLink] Received: $uri");

      if (uri.scheme == 'pocapp' && uri.host == 'payment') {
        final path = uri.path.toLowerCase();
        print("DEBUG_DEEPLINK: Payment return path detected: $path");

        if (path.contains('return') || path.contains('callback')) {
          print("DEBUG_DEEPLINK: ✅ Payment return callback confirmed");
          _addLog("[DeepLink] Payment return confirmed");

          if (_browser.isOpened()) {
            print("DEBUG_DEEPLINK: Closing Custom Tab browser...");
            await _browser.close();
            _addLog("[DeepLink] Custom Tab closed");
          }

          print("DEBUG_DEEPLINK: Dispatching paymentCompleted event to JS");
          _webViewController?.evaluateJavascript(
            source: "window.dispatchEvent(new Event('paymentCompleted'));",
          );
          _addLog("[DeepLink] paymentCompleted event dispatched");
          print("DEBUG_DEEPLINK: ✅ Event dispatched successfully");
        } else {
          print("DEBUG_DEEPLINK: Unknown payment path: $path");
        }
      } else {
        print("DEBUG_DEEPLINK: Non-payment deep link: scheme=${uri.scheme}, host=${uri.host}");
      }
    });
    print("DEBUG_DEEPLINK: ✅ Deep link listener initialized");
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
    print("DEBUG_PERM: 🔐 [START] Requesting startup permissions...");
    _addLog("[System] Requesting permissions");
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      print("DEBUG_PERM: Calling permission service...");
      final outcome = await _permissionService.requestStartupPermissions();
      print("DEBUG_PERM: Permission outcome: ${outcome.name}");

      final cam = await _permissionService.isCameraGranted();
      final loc = await _permissionService.isLocationGranted();
      print("DEBUG_PERM: Camera granted: $cam");
      print("DEBUG_PERM: Location granted: $loc");

      value = value.copyWith(
        cameraGranted: cam,
        locationGranted: loc,
        permissionState: outcome == StartupPermissionOutcome.permanentlyDenied
            ? StartupPermissionState.permanentlyDenied
            : StartupPermissionState.ready,
        hasPermissionIssue: outcome != StartupPermissionOutcome.granted,
      );
      print("DEBUG_PERM: ✅ [END] Startup Permissions Ready");
      _addLog("[System] Startup Permissions Ready (Camera: $cam, Location: $loc)");
    } catch (e) {
      print("DEBUG_PERM: ❌ Permission Request Error: $e");
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
    print("DEBUG_RELOAD: 🔄 Reloading base page...");
    _addLog("[System] Reloading page");
    if (_webViewController == null) {
      print("DEBUG_RELOAD: ❌ WebViewController is null!");
      return;
    }
    await _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri.uri(Uri.parse(effectiveWebViewUrl))),
    );
    print("DEBUG_RELOAD: ✅ Page reload command sent");
  }

  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    print("DEBUG_NAV: 🔍 [START] handleNavigation called");
    print("DEBUG_NAV: URL = $rawUrl");
    print("DEBUG_NAV: isForMainFrame = ${navigationAction.isForMainFrame}");

    if (rawUrl.isEmpty) {
      print("DEBUG_NAV: ⚠️ Empty URL, allowing");
      _addLog("[Nav] Empty URL, allowing");
      return NavigationActionPolicy.ALLOW;
    }

    // 1. Tangani Deep Link (Skema non-HTTP seperti dana://, whatsapp://, dll)
    if (uri != null && !uri.scheme.startsWith('http')) {
      print("DEBUG_NAV: 🔗 Non-HTTP scheme detected: ${uri.scheme}");
      _addLog("[DeepLink] Detected scheme ${uri.scheme}, launching external app...");
      launchUrl(uri, mode: LaunchMode.externalApplication);
      print("DEBUG_NAV: ✅ External app launched");
      return NavigationActionPolicy.CANCEL;
    }

    // Prioritas utama: URL payment tidak boleh sempat lanjut di WebView.
    final lowerUrl = rawUrl.toLowerCase();
    final isAutoBridgeUrl =
        lowerUrl.contains('dana.id') ||
        lowerUrl.contains('shopee.co.id') ||
        lowerUrl.contains('shopeepay');
    if (isAutoBridgeUrl) {
      print("DEBUG_NAV: 💳 PAYMENT URL DETECTED - divert to Custom Tab");
      _addLog("[Guard] Payment URL intercepted before WebView load");
      await _openInCustomTabs(rawUrl);
      print("DEBUG_NAV: ✅ Custom Tab opened, cancelling WebView navigation");
      return NavigationActionPolicy.CANCEL;
    }

    // Navigasi non-main-frame tetap diizinkan untuk resource internal non-payment.
    if (!navigationAction.isForMainFrame) {
      print("DEBUG_NAV: 📦 Non-main-frame navigation, allowing");
      _addLog("[Nav] Non-main-frame resource, allowing");
      return NavigationActionPolicy.ALLOW;
    }

    print("DEBUG_NAV: 🎯 Evaluating with guard...");
    final handling = _navigationGuard.evaluate(rawUrl);
    print("DEBUG_NAV: Guard result = ${handling.name}");
    _addLog("[Nav] ${handling.name.toUpperCase()} -> $rawUrl");

    if (handling == NavigationHandling.block) {
      print("DEBUG_NAV: 🛑 BLOCKED");
      _addLog("[Guard] Blocked: $rawUrl");
      return NavigationActionPolicy.CANCEL;
    }

    print("DEBUG_NAV: ✅ [END] Allowing navigation");
    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _openInCustomTabs(String rawUrl) async {
    print("DEBUG_CUSTOMTAB: 🎯 [START] Opening Custom Tab");
    print("DEBUG_CUSTOMTAB: Raw URL: $rawUrl");

    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) {
      print("DEBUG_CUSTOMTAB: ❌ Invalid URI, cannot parse");
      _addLog("[Bridge] ❌ Invalid URL format");
      return;
    }
    print("DEBUG_CUSTOMTAB: ✅ URI parsed successfully");

    try {
      if (!uri.scheme.startsWith('http')) {
        print("DEBUG_CUSTOMTAB: 🔗 Non-HTTP scheme, launching external app: ${uri.scheme}");
        _addLog("[Bridge] Launching external app (non-http): $rawUrl");
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        print("DEBUG_CUSTOMTAB: ✅ External app launched");
        return;
      }

      print("DEBUG_CUSTOMTAB: 📱 Opening Chrome Custom Tab...");
      _addLog("[Bridge] Opening Custom Tab: $rawUrl");
      await _browser.open(
        url: WebUri.uri(uri),
        settings: ChromeSafariBrowserSettings(
          shareState: CustomTabsShareState.SHARE_STATE_OFF,
          showTitle: true,
          noHistory: false,
        ),
      );
      print("DEBUG_CUSTOMTAB: ✅ Custom Tab opened successfully");
    } catch (e) {
      print("DEBUG_CUSTOMTAB: ❌ Error opening Custom Tab: $e");
      _addLog("[Bridge Error] $e");
      print("DEBUG_CUSTOMTAB: Falling back to external app...");
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      print("DEBUG_CUSTOMTAB: ✅ Fallback to external app completed");
    }
    print("DEBUG_CUSTOMTAB: ✅ [END] Custom Tab operation completed");
  }

  void _processIncomingMessage(dynamic data) {
    print("DEBUG_MESSAGE: ⚙️ [START] Processing message from bridge");
    final String url = data.toString().trim();
    
    if (url.isEmpty) {
      print("DEBUG_MESSAGE: ❌ Aborting - URL is empty");
      _addLog("[Bridge] ❌ Received empty URL");
      return;
    }

    print("DEBUG_MESSAGE: 🚦 URL Received: $url");
    
    // Log hasil evaluasi guard untuk informasi saja
    final handling = _navigationGuard.evaluate(url);
    print("DEBUG_MESSAGE: 🛡️ Guard Info: ${handling.name}");

    // Jika dipanggil via Bridge, kita anggap ini instruksi EKSPLISIT untuk membuka Custom Tab,
    // meskipun URL tersebut masuk dalam whitelist 'allowWebView' (seperti Finpay).
    print("DEBUG_MESSAGE: 📱 Bridge call is explicit. Triggering Custom Tab...");
    _addLog("[Bridge] Triggering Custom Tab for: $url");
    
    // Hentikan loading di WebView utama agar tidak double loading
    _webViewController?.stopLoading();
    print("DEBUG_MESSAGE: 🛑 Main WebView loading stopped");
    
    _openInCustomTabs(url);
    print("DEBUG_MESSAGE: ✅ [END] Message processed");
  }

  void handleWebMessage(WebMessage? message) {
    if (message != null && message.data != null) {
      _processIncomingMessage(message.data);
    }
  }
}
