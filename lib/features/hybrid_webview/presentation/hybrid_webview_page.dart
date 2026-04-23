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

  @override
  void initState() {
    super.initState();
    _controller = HybridWebViewController(
      config: widget.config,
      initialEnvironment: widget.initialEnvironment,
    );
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

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HybridWebViewState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Hybrid WebView + Custom Tabs'),
            actions: [
              IconButton(
                onPressed: _controller.reloadBasePage,
                icon: const Icon(Icons.refresh),
                tooltip: 'Reload halaman utama',
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(state.status, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _controller.isProdSelected,
                      onChanged: _controller.switchEnvironment,
                      title: const Text('Use PROD'),
                      subtitle: const Text('Off = DEV, On = PROD'),
                    ),
                    if (_controller.isPermanentlyDenied)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _openAppSettings,
                          icon: const Icon(Icons.settings),
                          label: const Text('Buka Pengaturan Izin'),
                        ),
                      ),
                    if (_controller.showRetryPermissionButton && !_controller.isPermanentlyDenied)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _controller.requestStartupPermissions,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Minta Ulang Izin'),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
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
            ],
          ),
        );
      },
    );
  }
}
