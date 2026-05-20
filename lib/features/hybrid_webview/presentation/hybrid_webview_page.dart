import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../../../config/logger.dart';
import '../application/hybrid_webview_controller.dart';
import 'widgets/debug_tracker_overlay.dart';
import 'widgets/permission_chip.dart';

class HybridWebViewPage extends StatefulWidget {
  const HybridWebViewPage({
    super.key,
    required this.config,
    required this.initialEnvironment,
  });

  final AppConfig config;
  final String initialEnvironment;

  @override
  State<HybridWebViewPage> createState() => _HybridWebViewPageState();
}

class _HybridWebViewPageState extends State<HybridWebViewPage> {
  late final HybridWebViewController _controller;
  bool _showDebug = true;

  @override
  void initState() {
    super.initState();
    _controller = HybridWebViewController(config: widget.config);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.requestStartupPermissions();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HybridWebViewState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            // Kalau payment WebView sedang terbuka, tutup dulu (= user cancel)
            if (state.paymentUrl != null) {
              _controller.onPaymentWebViewClosedByUser();
              return;
            }
            await _controller.smartGoBack();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.config.appBarTitle),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () async {
                  if (state.paymentUrl != null) {
                    _controller.onPaymentWebViewClosedByUser();
                    return;
                  }
                  final controller = _controller.webViewController;
                  if (controller != null && await controller.canGoBack()) {
                    await _controller.smartGoBack();
                  } else {
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
              ),
              actions: [
                IconButton(
                  onPressed: () => setState(() => _showDebug = !_showDebug),
                  icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined),
                ),
                IconButton(
                  onPressed: _controller.reloadBasePage,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    children: [
                      PermissionChip(label: 'Cam', granted: state.cameraGranted),
                      const SizedBox(width: 4),
                      PermissionChip(label: 'Loc', granted: state.locationGranted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          state.status,
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Stack(
                    children: [
                      // ── Sambara WebView (utama) ──────────────────────────
                      if (_controller.isRequestingPermissions)
                        const Center(child: CircularProgressIndicator())
                      else
                        Stack(
                          children: [
                            InAppWebView(
                              initialUrlRequest: URLRequest(
                                url: WebUri(_controller.effectiveWebViewUrl),
                              ),
                              initialUserScripts: UnmodifiableListView<UserScript>([
                                _controller.bridgeUserScript,
                              ]),
                              initialSettings: InAppWebViewSettings(
                                javaScriptEnabled: true,
                                useShouldOverrideUrlLoading: true,
                                geolocationEnabled: true,
                                databaseEnabled: true,
                                domStorageEnabled: true,
                                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                                mediaPlaybackRequiresUserGesture: false,
                                supportMultipleWindows: false,
                                javaScriptCanOpenWindowsAutomatically: false,
                                useWideViewPort: true,
                                loadWithOverviewMode: true,
                                supportZoom: true,
                                builtInZoomControls: true,
                                displayZoomControls: false,
                              ),
                              onWebViewCreated: (controller) {
                                _controller.webViewController = controller;
                              },
                              onLoadStart: (controller, url) {
                                if (url != null) _controller.updateLastSafeUrl(url.toString());
                                AppLogger.d('[WebView] Load started: $url');
                              },
                              onPageCommitVisible: (controller, url) {
                                AppLogger.d('[WebView] Page commit visible');
                              },
                              shouldOverrideUrlLoading: (controller, navigationAction) async {
                                return _controller.handleNavigation(navigationAction);
                              },
                              onLoadStop: (controller, url) {
                                AppLogger.d('[WebView] Load finished');
                              },
                              onReceivedError: (controller, request, error) {
                                AppLogger.d('[WebView] Error: ${error.description}');
                                _controller.updateStatus('Error: ${error.description}');
                              },
                              onReceivedHttpError: (controller, request, errorResponse) {
                                AppLogger.d('[WebView] HTTP ${errorResponse.statusCode}: ${request.url}');
                                _controller.updateStatus('HTTP ${errorResponse.statusCode}');
                              },
                              onConsoleMessage: (controller, consoleMessage) {
                                _controller.handleConsoleMessage(consoleMessage.message);
                              },
                              onRenderProcessGone: (controller, detail) {
                                AppLogger.d('[WebView] Render process terminated');
                                _controller.updateStatus('WebView crashed');
                              },
                              onPermissionRequest: (controller, request) async {
                                return _controller.handleWebPermissionRequest(request);
                              },
                              onGeolocationPermissionsShowPrompt: (controller, origin) async {
                                return _controller.handleGeolocationPrompt(origin);
                              },
                              onProgressChanged: (controller, progress) {
                                _controller.updateProgress(progress / 100.0);
                              },
                            ),
                            if (state.progress < 1)
                              const Align(
                                alignment: Alignment.topCenter,
                                child: LinearProgressIndicator(minHeight: 2),
                              ),
                          ],
                        ),

                      // ── Payment WebView Overlay (Finpay) ─────────────────
                      if (state.paymentUrl != null)
                        _PaymentWebViewOverlay(
                          url: state.paymentUrl!,
                          onClose: _controller.onPaymentWebViewClosedByUser,
                        ),
                    ],
                  ),
                ),
                if (_showDebug)
                  ValueListenableBuilder<List<String>>(
                    valueListenable: AppLogger.logsNotifier,
                    builder: (context, logs, _) => DebugTrackerOverlay(logs: logs),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// WebView overlay full-screen untuk halaman pembayaran Finpay.
/// App tetap foreground → Timer.periodic bisa polling tanpa throttling di kedua platform.

// Cached UA — stripped " wv" agar tidak terdeteksi sebagai WebView oleh Shopee Pay, dll.
String? _cachedUserAgent;

Future<String> _getCleanUserAgent() async {
  if (_cachedUserAgent != null) return _cachedUserAgent!;
  final webView = HeadlessInAppWebView(initialUrlRequest: URLRequest(url: WebUri('about:blank')));
  await webView.run();
  final ua = await webView.webViewController?.evaluateJavascript(source: 'navigator.userAgent') as String? ?? '';
  await webView.dispose();
  _cachedUserAgent = ua.replaceAll(' wv', '');
  return _cachedUserAgent!;
}

class _PaymentWebViewOverlay extends StatefulWidget {
  const _PaymentWebViewOverlay({required this.url, required this.onClose});

  final String url;
  final VoidCallback onClose;

  @override
  State<_PaymentWebViewOverlay> createState() => _PaymentWebViewOverlayState();
}

class _PaymentWebViewOverlayState extends State<_PaymentWebViewOverlay> {
  String? _userAgent;

  @override
  void initState() {
    super.initState();
    _getCleanUserAgent().then((ua) {
      if (mounted) setState(() => _userAgent = ua);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_userAgent == null) {
      return const ColoredBox(color: Colors.white, child: Center(child: CircularProgressIndicator()));
    }
    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: [
          // Header dengan tombol close
          SafeArea(
            bottom: false,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                    tooltip: 'Tutup pembayaran',
                  ),
                  const Expanded(
                    child: Text(
                      'Pembayaran',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // WebView Finpay
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                userAgent: _userAgent,
              ),
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url;
                if (uri == null) return NavigationActionPolicy.CANCEL;
                // Non-HTTP schemes (shopee://, dana://, etc.) are native app deep
                // links generated by the payment page — hand them to the OS.
                // catchError handles the case where the target app is not installed.
                if (uri.scheme != 'http' && uri.scheme != 'https') {
                  final launched = await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  ).catchError((_) => false);
                  if (!launched) {
                    AppLogger.d('[PaymentOverlay] Deep link failed — app not installed: ${uri.scheme}');
                  }
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
            ),
          ),
        ],
      ),
    );
  }
}
