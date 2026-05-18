import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../config/app_config.dart';
import '../../../config/logger.dart';
import '../application/hybrid_webview_controller.dart';
import 'widgets/debug_tracker_overlay.dart';
import 'widgets/permission_chip.dart';
import 'widgets/simulation_toolbar.dart';


/// Halaman utama fitur Hybrid WebView.
///
/// Widget ini merupakan entry point untuk menampilkan konten web di dalam aplikasi native.
/// Mengintegrasikan [InAppWebView] dengan [HybridWebViewController] untuk menangani:
/// 1. Navigasi aman (Navigation Guard)
/// 2. Komunikasi Bridge (JavaScript Handlers)
/// 3. Perizinan Hardware (Kamera & Lokasi)
/// 4. Indikator Progress dan Debug Tracker
class HybridWebViewPage extends StatefulWidget {
  /// Membuat instance [HybridWebViewPage].
  ///
  /// Memerlukan [config] untuk pengaturan domain/bridge dan [initialEnvironment].
  const HybridWebViewPage({
    super.key, 
    required this.config, 
    required this.initialEnvironment,
  });

  /// Injeksi konfigurasi aplikasi.
  final AppConfig config;

  /// Environment awal yang akan digunakan.
  final String initialEnvironment;

  @override
  State<HybridWebViewPage> createState() => _HybridWebViewPageState();
}

class _HybridWebViewPageState extends State<HybridWebViewPage> {
  /// Controller utama untuk mengelola logika WebView.
  late final HybridWebViewController _controller;

  /// Status apakah panel Debug Tracker ditampilkan di layar.
  bool _showDebug = true;

  @override
  void initState() {
    super.initState();
    // Inisialisasi controller dengan konfigurasi yang disuntikkan.
    _controller = HybridWebViewController(config: widget.config);

    // Menjalankan permintaan izin startup (Kamera & Lokasi) setelah frame pertama dirender.
    // Hal ini menjamin konteks UI siap sebelum dialog sistem muncul.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.requestStartupPermissions();
    });
  }

  @override
  void dispose() {
    // Memastikan controller dibersihkan untuk mencegah kebocoran memori.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mendengarkan perubahan state dari controller secara reaktif menggunakan ValueListenableBuilder.
    return ValueListenableBuilder<HybridWebViewState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        return PopScope(
          // canPop: false mematikan navigasi back default sistem.
          // Kita menghandle navigasi back secara manual via smartGoBack.
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            // Pemicu navigasi back cerdas (melompati halaman redirect jika perlu).
            await _controller.smartGoBack();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.config.appBarTitle),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () async {
                  final controller = _controller.webViewController;
                  // Jika WebView bisa kembali, gunakan smartGoBack.
                  if (controller != null && await controller.canGoBack()) {
                    await _controller.smartGoBack();
                  } else {
                    // Jika tidak bisa kembali di history web, tutup halaman native.
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
              ),
              actions: [
                // Tombol toggle untuk menampilkan/menyembunyikan Debug Tracker Overlay.
                IconButton(
                  onPressed: () => setState(() => _showDebug = !_showDebug),
                  icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined),
                  tooltip: 'Toggle Debug Tracker',
                ),
                // Tombol reload untuk memuat ulang halaman utama dari awal.
                IconButton(
                  onPressed: _controller.reloadBasePage, 
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            body: Column(
              children: [
                // Header bar: Menampilkan indikator izin Kamera/Lokasi dan status operasional.
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
                  flex: 3,
                  child: _controller.isRequestingPermissions
                      ? const Center(child: CircularProgressIndicator())
                      : Stack(
                          children: [
                            // Widget WebView Utama.
                            InAppWebView(
                              initialUrlRequest: URLRequest(
                                url: WebUri(_controller.effectiveWebViewUrl),
                              ),
                              // Menyuntikkan JavaScript Bridge (SapawargaChannel) sebelum dokumen dimuat.
                              initialUserScripts: UnmodifiableListView<UserScript>([
                                _controller.bridgeUserScript,
                                _controller.paymentInfoBridgeScript,
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
                                // Optimalisasi rendering untuk halaman eksternal yang berat.
                                useWideViewPort: true,
                                loadWithOverviewMode: true,
                                supportZoom: true,
                                builtInZoomControls: true,
                                displayZoomControls: false,
                              ),
                              onWebViewCreated: (controller) {
                                _controller.webViewController = controller;
                                // Inisialisasi bridge sisi JS sudah dihandle di controller via UserScript
                              },
                              onLoadStart: (controller, url) {
                                // Mencatat URL internal terakhir untuk keperluan navigasi 'Smart Back'.
                                if (url != null) {
                                  _controller.updateLastSafeUrl(url.toString());
                                }
                                AppLogger.d("[UI] onLoadStart: $url");
                              },
                              onPageCommitVisible: (controller, url) {
                                AppLogger.d("[UI] onPageCommitVisible: Content rendered");
                              },
                              shouldOverrideUrlLoading: (controller, navigationAction) async {
                                // Delegasi validasi navigasi ke controller (Navigation Guard).
                                return _controller.handleNavigation(navigationAction);
                              },

                              onLoadStop: (controller, url) {
                                AppLogger.d("[UI] onLoadStop: Load complete");
                              },
                              onReceivedError: (controller, request, error) {
                                AppLogger.d("[UI] ❌ Error: ${error.description}");
                                _controller.updateStatus("Error: ${error.description}");
                              },
                              onReceivedHttpError: (controller, request, errorResponse) {
                                AppLogger.d("[UI] 🔴 HTTP Error ${errorResponse.statusCode}");
                                _controller.updateStatus("HTTP Error ${errorResponse.statusCode}");
                              },
                              onConsoleMessage: (controller, consoleMessage) {
                                // Menangkap log dari konsol browser dan mengarahkannya ke logger app.
                                AppLogger.d("[JS] ${consoleMessage.message}");
                              },
                              onRenderProcessGone: (controller, detail) {
                                AppLogger.d("[UI] ⚠️ WebView Crash Detected!");
                                _controller.updateStatus("WebView Crashed");
                              },
                              onPermissionRequest: (controller, request) async {
                                // Menangani permintaan izin hardware dari Web (Kamera, Mic, dll).
                                AppLogger.d("[UI] Web permission req: ${request.resources}");
                                return _controller.handleWebPermissionRequest(request);
                              },
                              onGeolocationPermissionsShowPrompt: (controller, origin) async {
                                // Menangani permintaan izin lokasi dari Web.
                                AppLogger.d("[UI] Geolocation req from: $origin");
                                return _controller.handleGeolocationPrompt(origin);
                              },
                              onProgressChanged: (controller, progress) {
                                // Memperbarui indikator loading linear.
                                _controller.updateProgress(progress / 100.0);
                              },
                            ),
                            // Indikator progres pemuatan (Top Bar).
                            if (state.progress < 1)
                              const Align(
                                alignment: Alignment.topCenter,
                                child: LinearProgressIndicator(minHeight: 2),
                              ),
                          ],
                        ),
                ),
                // Panel Debug: Toolbar simulasi + log tracker.
                if (_showDebug) ...[
                  SimulationToolbar(controller: _controller),
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
