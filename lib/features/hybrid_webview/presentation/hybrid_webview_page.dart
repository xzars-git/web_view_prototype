import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../config/app_config.dart';
import '../../../config/logger.dart';
import '../application/hybrid_webview_controller.dart';
import 'widgets/debug_tracker_overlay.dart';
import 'widgets/permission_chip.dart';

/// Halaman utama fitur Hybrid WebView (Sambara).
///
/// Entry point untuk menampilkan konten web Sambara di dalam aplikasi native.
/// Mengintegrasikan [InAppWebView] dengan [HybridWebViewController] untuk:
/// - Navigasi aman via [WebNavigationGuard]
/// - Komunikasi bridge JavaScript ([SapawargaChannel])
/// - Perizinan hardware (kamera & lokasi)
/// - Stack payment page (push [PaymentWebViewPage] di atas Sambara)
/// - Debug tracker overlay untuk monitoring
class HybridWebViewPage extends StatefulWidget {
  /// Memerlukan [config] dan [initialEnvironment] untuk inisialisasi.
  const HybridWebViewPage({
    super.key,
    required this.config,
    required this.initialEnvironment,
  });

  /// Konfigurasi aplikasi (domain, bridge name, whitelist, dll).
  final AppConfig config;

  /// Environment yang akan digunakan (e.g. 'prod').
  final String initialEnvironment;

  @override
  State<HybridWebViewPage> createState() => _HybridWebViewPageState();
}

class _HybridWebViewPageState extends State<HybridWebViewPage> {
  /// Controller utama untuk logika WebView dan payment.
  late final HybridWebViewController _controller;

  /// Toggle visibility panel Debug Tracker.
  bool _showDebug = true;

  @override
  void initState() {
    super.initState();
    _controller = HybridWebViewController(config: widget.config);

    // Request izin hardware setelah frame pertama dirender
    // agar dialog sistem tidak muncul sebelum UI siap.
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
    // Update navigator context setiap build untuk operasi Navigator di controller
    _controller.navigatorContext = context;

    return ValueListenableBuilder<HybridWebViewState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        return PopScope(
          // Disable default back — handle manual via smartGoBack
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            await _controller.smartGoBack();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.config.appBarTitle),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () async {
                  final controller = _controller.webViewController;
                  if (controller != null && await controller.canGoBack()) {
                    await _controller.smartGoBack();
                  } else {
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
              ),
              actions: [
                // Toggle Debug Tracker
                IconButton(
                  onPressed: () => setState(() => _showDebug = !_showDebug),
                  icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined),
                  tooltip: 'Toggle Debug Tracker',
                ),
                // Reload ke beranda
                IconButton(
                  onPressed: _controller.reloadBasePage,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            body: Column(
              children: [
                // Header: status perizinan kamera & lokasi
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

                // WebView utama (Sambara)
                Expanded(
                  flex: 3,
                  child: _controller.isRequestingPermissions
                      ? const Center(child: CircularProgressIndicator())
                      : Stack(
                          children: [
                            InAppWebView(
                              initialUrlRequest: URLRequest(
                                url: WebUri(_controller.effectiveWebViewUrl),
                              ),
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
                              shouldOverrideUrlLoading: (controller, navigationAction) async {
                                return _controller.handleNavigation(navigationAction);
                              },
                              onReceivedError: (controller, request, error) {
                                AppLogger.e("WebView error: ${error.description}");
                                _controller.updateStatus("Error: ${error.description}");
                              },
                              onReceivedHttpError: (controller, request, errorResponse) {
                                _controller.updateStatus("HTTP ${errorResponse.statusCode}");
                              },
                              onConsoleMessage: (controller, consoleMessage) {
                                // Primary handler: intercept console.log dari PKB
                                _controller.handleConsoleMessage(context, consoleMessage.message);
                              },
                              onRenderProcessGone: (controller, detail) {
                                AppLogger.e("WebView process crashed");
                                _controller.updateStatus("WebView Crashed");
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
                            // Progress bar loading
                            if (state.progress < 1)
                              const Align(
                                alignment: Alignment.topCenter,
                                child: LinearProgressIndicator(minHeight: 2),
                              ),
                          ],
                        ),
                ),

                // Debug Tracker panel
                if (_showDebug) ...[
                  ValueListenableBuilder<List<String>>(
                    valueListenable: AppLogger.logsNotifier,
                    builder: (context, logs, _) {
                      return DebugTrackerOverlay(logs: logs);
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
