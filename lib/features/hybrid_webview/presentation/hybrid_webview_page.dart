import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../config/app_config.dart';
import '../application/hybrid_webview_controller.dart';
import 'widgets/debug_tracker_overlay.dart';
import 'widgets/permission_chip.dart';

/// Halaman utama fitur Hybrid WebView.
///
/// Mengintegrasikan InAppWebView dengan controller untuk menangani navigasi aman,
/// komunikasi bridge dengan JS, dan perizinan sistem native.
class HybridWebViewPage extends StatefulWidget {
  const HybridWebViewPage({super.key, required this.config, required this.initialEnvironment});

  /// Injeksi konfigurasi aplikasi.
  final AppConfig config;

  /// Environment awal (hanya PROD yang didukung saat ini).
  final String initialEnvironment;

  @override
  State<HybridWebViewPage> createState() => _HybridWebViewPageState();
}

class _HybridWebViewPageState extends State<HybridWebViewPage> {
  late final HybridWebViewController _controller;

  /// Flag untuk menampilkan/menyembunyikan Debug Tracker Overlay.
  bool _showDebug = true;

  @override
  void initState() {
    super.initState();
    // Inisialisasi controller dengan konfigurasi yang disuntikkan.
    _controller = HybridWebViewController(config: widget.config);

    // Menjalankan permintaan izin startup setelah frame pertama dirender.
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
    // Mendengarkan perubahan state dari controller secara reaktif.
    return ValueListenableBuilder<HybridWebViewState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Hybrid WebView'),
            actions: [
              // Tombol toggle untuk Debug Tracker.
              IconButton(
                onPressed: () => setState(() => _showDebug = !_showDebug),
                icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined),
                tooltip: 'Toggle Debug Tracker',
              ),
              // Tombol reload halaman utama.
              IconButton(onPressed: _controller.reloadBasePage, icon: const Icon(Icons.refresh)),
            ],
          ),
          body: Column(
            children: [
              // Header bar: Menampilkan indikator izin dan status operasional.
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
                          // Widget WebView Inti.
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
                              // Optimalisasi untuk rendering halaman berat (Kartu Kredit/VA)
                              useWideViewPort: true,
                              loadWithOverviewMode: true,
                              supportZoom: true,
                              builtInZoomControls: true,
                              displayZoomControls: false,
                            ),
                            onWebViewCreated: (controller) {
                              print("DEBUG_UI: ✅ WebView Created");
                              _controller.webViewController = controller;

                              // Menambahkan handler untuk menginisialisasi bridge 'flutter_inappwebview' di JS.
                              controller.addJavaScriptHandler(
                                handlerName: 'initBridge',
                                callback: (args) => {},
                              );
                            },
                            // Trace saat page mulai load
                            onLoadStart: (controller, url) {
                              print("DEBUG_UI: 📍 onLoadStart -> $url");
                              _controller.addDebugLog("[UI] onLoadStart: $url");
                            },
                            // Trace saat page selesai load
                            onPageCommitVisible: (controller, url) {
                              print("DEBUG_UI: 🎨 onPageCommitVisible -> Content visible");
                              _controller.addDebugLog("[UI] onPageCommitVisible: Page rendered");
                            },
                            // Mencegah navigasi ke luar host aplikasi secara otomatis.
                            shouldOverrideUrlLoading: (controller, navigationAction) async {
                              final url = navigationAction.request.url?.toString() ?? 'unknown';
                              print("DEBUG_UI: 🚦 shouldOverrideUrlLoading called -> $url");
                              _controller.addDebugLog("[UI] shouldOverrideUrlLoading: $url");
                              return _controller.handleNavigation(navigationAction);
                            },
                            // Trace saat page selesai loading
                            onLoadStop: (controller, url) {
                              print("DEBUG_UI: ✅ onLoadStop -> Page loaded successfully");
                              _controller.addDebugLog("[UI] onLoadStop: Page load complete");
                            },
                            onLoadError: (controller, url, code, message) {
                              print(
                                "DEBUG_UI: ❌ onLoadError: Code=$code, Message=$message, URL=$url",
                              );
                              _controller.addDebugLog("[UI] ❌ onLoadError: $code - $message");
                              _controller.updateStatus("Error: $message");
                            },
                            onLoadHttpError: (controller, url, statusCode, description) {
                              print(
                                "DEBUG_UI: 🔴 onLoadHttpError: $statusCode - $description @ $url",
                              );
                              _controller.addDebugLog(
                                "[UI] 🔴 HTTP Error $statusCode: $description",
                              );
                              _controller.updateStatus("HTTP Error $statusCode");
                            },
                            // Capture console.log dari JavaScript
                            onConsoleMessage: (controller, consoleMessage) {
                              print("DEBUG_UI: 📱 JS Console: ${consoleMessage.message}");
                              _controller.addDebugLog("[JS] ${consoleMessage.message}");
                            },
                            // Trace jika WebView render process crash
                            onRenderProcessGone: (controller, detail) {
                              print(
                                "DEBUG_UI: ⚠️ onRenderProcessGone - WebView crashed! detail=$detail",
                              );
                              _controller.addDebugLog(
                                "[UI] ⚠️ Render process gone (crash detected)",
                              );
                              _controller.updateStatus("Render Process Crashed");
                            },
                            // Memberikan akses hardware setelah validasi native di startup.
                            onPermissionRequest: (controller, request) async {
                              print("DEBUG_UI: 🔐 onPermissionRequest: ${request.resources}");
                              _controller.addDebugLog(
                                "[UI] Permission request: ${request.resources.join(', ')}",
                              );
                              return _controller.handleWebPermissionRequest(request);
                            },
                            // Memberikan akses lokasi setelah validasi native di startup.
                            onGeolocationPermissionsShowPrompt: (controller, origin) async {
                              print("DEBUG_UI: 📍 Geolocation request from: $origin");
                              _controller.addDebugLog("[UI] Geolocation request: $origin");
                              return _controller.handleGeolocationPrompt(origin);
                            },
                            // Mengupdate progres pemuatan halaman.
                            onProgressChanged: (controller, progress) {
                              print("DEBUG_UI: 📊 Progress: $progress%");
                              _controller.updateProgress(progress / 100.0);
                            },
                          ),
                          // Indikator progres pemuatan di bagian atas WebView.
                          if (state.progress < 1)
                            const Align(
                              alignment: Alignment.topCenter,
                              child: LinearProgressIndicator(minHeight: 2),
                            ),
                        ],
                      ),
              ),
              // Overlay panel untuk memantau log sistem secara real-time.
              if (_showDebug) DebugTrackerOverlay(logs: state.logs),
            ],
          ),
        );
      },
    );
  }
}
