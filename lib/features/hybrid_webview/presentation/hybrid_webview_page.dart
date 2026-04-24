import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../../config/app_config.dart';
import '../application/hybrid_webview_controller.dart';

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

  Future<void> _openAppSettings() async {
    await ph.openAppSettings();
  }

  Widget _buildPermissionChip(String label, bool granted) {
    return Chip(
      avatar: Icon(
        granted ? Icons.check_circle : Icons.cancel,
        color: granted ? Colors.green : Colors.red,
        size: 14,
      ),
      label: Text(label, style: const TextStyle(fontSize: 10)),
      backgroundColor: granted ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HybridWebViewState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Hybrid WebView'),
            actions: [
              IconButton(
                onPressed: () => setState(() => _showDebug = !_showDebug),
                icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined),
                tooltip: 'Toggle Debug Tracker',
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
                    _buildPermissionChip('Cam', state.cameraGranted),
                    const SizedBox(width: 4),
                    _buildPermissionChip('Loc', state.locationGranted),
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
                          InAppWebView(
                            initialUrlRequest: URLRequest(url: WebUri(_controller.effectiveWebViewUrl)),
                            initialSettings: InAppWebViewSettings(
                              javaScriptEnabled: true,
                              useShouldOverrideUrlLoading: true,
                              geolocationEnabled: true,
                              databaseEnabled: true,
                              domStorageEnabled: true,
                              mediaPlaybackRequiresUserGesture: false,
                            ),
                            onWebViewCreated: (controller) {
                              _controller.webViewController = controller;
                              
                              // Dummy handler untuk inisialisasi bridge flutter_inappwebview
                              controller.addJavaScriptHandler(
                                handlerName: 'initBridge',
                                callback: (args) => {},
                              );

                              controller.addWebMessageListener(
                                WebMessageListener(
                                  jsObjectName: "SapawargaChannel",
                                  onPostMessage: (message, sourceOrigin, isMainFrame, replyProxy) {
                                    _controller.handleWebMessage(message);
                                  },
                                ),
                              );
                            },
                            shouldOverrideUrlLoading: (controller, navigationAction) async {
                              return _controller.handleNavigation(navigationAction);
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
              ),
              if (_showDebug)
                Container(
                  height: 150,
                  color: Colors.black.withOpacity(0.85),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        color: Colors.grey[800],
                        child: const Row(
                          children: [
                            Icon(Icons.terminal, color: Colors.white, size: 14),
                            SizedBox(width: 4),
                            Text("DEBUG TRACKER", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.all(4),
                          itemCount: state.logs.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                state.logs[index],
                                style: const TextStyle(color: Colors.greenAccent, fontSize: 9, fontFamily: 'monospace'),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
