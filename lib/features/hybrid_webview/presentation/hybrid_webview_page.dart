import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../config/app_config.dart';
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
              if (_showDebug) DebugTrackerOverlay(logs: state.logs),
            ],
          ),
        );
      },
    );
  }
}
