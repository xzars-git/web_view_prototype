import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:url_launcher/url_launcher.dart';

import '../../../config/custom_tabs_config.dart';
import '../application/web_permission_service.dart';
import '../domain/web_navigation_guard.dart';

enum _StartupPermissionState { requesting, ready, permanentlyDenied }

class HybridWebViewPage extends StatefulWidget {
  const HybridWebViewPage({super.key, required this.initialEnvironment});

  final String initialEnvironment;

  @override
  State<HybridWebViewPage> createState() => _HybridWebViewPageState();
}

class _HybridWebViewPageState extends State<HybridWebViewPage> {
  static const String _statusRequestingPermissions = 'Meminta izin camera dan location...';
  static const String _statusPermissionDenied =
      'Izin camera/location ditolak. Beberapa fitur web mungkin tidak berjalan.';
  static const String _statusPermissionPermanentlyDenied =
      'Izin camera/location ditolak permanen. Aktifkan dari pengaturan perangkat.';
  static const String _statusPermissionRequestFailed =
      'Gagal meminta izin camera/location dari perangkat.';
  static const String _statusLocationServiceDisabled =
      'Layanan lokasi perangkat mati. Aktifkan GPS untuk fitur lokasi di web.';
  static const String _statusWebPermissionDenied =
      'Izin camera/microphone untuk web ditolak. Fitur media mungkin tidak berjalan.';
  static const String _statusWebViewActive =
      'WebView aktif. Halaman payment akan dibuka di Custom Tabs.';
  static const String _statusPaymentUrlInvalid = 'URL payment tidak valid.';
  static const String _statusPaymentOpenSuccess =
      'Halaman payment dibuka di Custom Tabs. Tutup tab untuk kembali ke WebView.';
  static const String _statusPaymentOpenFailed = 'Gagal membuka halaman payment di Custom Tabs.';
  static const String _statusNavigationBlocked =
      'Navigasi diblokir karena URL tidak ada di allowlist.';

  InAppWebViewController? _controller;
  late String _selectedEnvironment;
  final WebPermissionService _permissionService = WebPermissionService();
  final WebNavigationGuard _navigationGuard = const WebNavigationGuard();

  String _status = _statusRequestingPermissions;
  double _progress = 0;
  _StartupPermissionState _permissionState = _StartupPermissionState.requesting;
  bool _hasPermissionIssue = false;

  @override
  void initState() {
    super.initState();
    _selectedEnvironment = CustomTabsConfig.normalizeEnvironment(widget.initialEnvironment);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestStartupPermissions();
    });
  }

  String get _effectiveWebViewUrl {
    if (CustomTabsConfig.isTargetUrlOverridden) {
      return CustomTabsConfig.targetUrl;
    }
    return CustomTabsConfig.urlForEnvironment(_selectedEnvironment);
  }

  bool get _isProdSelected => _selectedEnvironment == CustomTabsConfig.prodEnv;

  bool get _isRequestingPermissions => _permissionState == _StartupPermissionState.requesting;

  bool get _isPermanentlyDenied => _permissionState == _StartupPermissionState.permanentlyDenied;

  bool get _showRetryPermissionButton {
    return _permissionState == _StartupPermissionState.ready && _hasPermissionIssue;
  }

  void _updateStatus(String value) {
    if (!mounted) return;
    setState(() {
      _status = value;
    });
  }

  void _logError(String context, Object error, StackTrace stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'hybrid_webview',
        context: ErrorDescription(context),
      ),
    );
  }

  Future<void> _openInCustomTabs(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      _updateStatus(_statusPaymentUrlInvalid);
      return;
    }

    bool opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (error, stackTrace) {
      _logError('open payment in custom tab', error, stackTrace);
      opened = false;
    }

    if (!opened) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (error, stackTrace) {
        _logError('open payment in external application', error, stackTrace);
        opened = false;
      }
    }

    _updateStatus(opened ? _statusPaymentOpenSuccess : _statusPaymentOpenFailed);
  }

  Future<void> _reloadBasePage() async {
    if (_controller == null) {
      _updateStatus('WebView belum siap. Memuat ulang dibatalkan.');
      return;
    }

    final uri = Uri.tryParse(_effectiveWebViewUrl);
    if (uri == null) {
      _updateStatus('URL tidak valid: $_effectiveWebViewUrl');
      return;
    }

    await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
    _updateStatus('Memuat ulang halaman utama di WebView.');
  }

  Future<void> _requestStartupPermissions() async {
    if (!mounted) return;
    setState(() {
      _permissionState = _StartupPermissionState.requesting;
      _status = _statusRequestingPermissions;
      _hasPermissionIssue = false;
    });

    try {
      final outcome = await _permissionService.requestStartupPermissions();

      if (!mounted) return;
      setState(() {
        if (outcome == StartupPermissionOutcome.permanentlyDenied) {
          _permissionState = _StartupPermissionState.permanentlyDenied;
          _hasPermissionIssue = true;
          _status = _statusPermissionPermanentlyDenied;
          return;
        }

        if (outcome == StartupPermissionOutcome.denied) {
          _permissionState = _StartupPermissionState.ready;
          _hasPermissionIssue = true;
          _status = _statusPermissionDenied;
          return;
        }

        if (outcome == StartupPermissionOutcome.failed) {
          _permissionState = _StartupPermissionState.ready;
          _hasPermissionIssue = true;
          _status = _statusPermissionRequestFailed;
          return;
        }

        _permissionState = _StartupPermissionState.ready;
        _hasPermissionIssue = false;
        _status = _statusWebViewActive;
      });
    } catch (error, stackTrace) {
      _logError('request startup permissions', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _permissionState = _StartupPermissionState.ready;
        _hasPermissionIssue = true;
        _status = _statusPermissionRequestFailed;
      });
    }
  }

  Future<PermissionResponse> _handleWebPermissionRequest(PermissionRequest request) async {
    try {
      final decision = await _permissionService.handleWebPermissionRequest(request);
      if (!decision.granted) {
        if (mounted) {
          setState(() {
            _hasPermissionIssue = true;
            if (decision.permanentlyDenied) {
              _permissionState = _StartupPermissionState.permanentlyDenied;
            }
          });
        }
        _updateStatus(_statusWebPermissionDenied);
      }
      return decision.response;
    } catch (error, stackTrace) {
      _logError('web permission request', error, stackTrace);
      return PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      );
    }
  }

  Future<GeolocationPermissionShowPromptResponse> _handleGeolocationPrompt(String origin) async {
    try {
      final decision = await _permissionService.handleGeolocationPrompt(origin);
      if (!decision.response.allow) {
        if (mounted) {
          setState(() {
            _hasPermissionIssue = true;
          });
        }

        if (!decision.locationServiceEnabled) {
          _updateStatus(_statusLocationServiceDisabled);
        } else {
          _updateStatus(_statusPermissionDenied);
        }
      }
      return decision.response;
    } catch (error, stackTrace) {
      _logError('geolocation prompt', error, stackTrace);
      return GeolocationPermissionShowPromptResponse(
        origin: origin,
        allow: false,
        retain: false,
      );
    }
  }

  Future<void> _openAppSettings() async {
    await ph.openAppSettings();
  }

  void _switchEnvironment(bool useProd) {
    final nextEnvironment = useProd ? CustomTabsConfig.prodEnv : CustomTabsConfig.devEnv;
    setState(() {
      _selectedEnvironment = nextEnvironment;
    });

    if (_controller == null) {
      _updateStatus(
        'Environment diubah ke $_selectedEnvironment. WebView akan memuat URL ini saat siap.',
      );
      return;
    }

    _updateStatus(
      CustomTabsConfig.isTargetUrlOverridden
          ? 'TARGET_URL override aktif, switcher tidak mengubah URL target.'
          : 'Environment diubah ke $_selectedEnvironment. Memuat ulang WebView...',
    );
    _reloadBasePage();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hybrid WebView + Custom Tabs'),
        actions: [
          IconButton(
            onPressed: _reloadBasePage,
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
                Text(_status, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 4),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _isProdSelected,
                  onChanged: _switchEnvironment,
                  title: const Text('Use PROD'),
                  subtitle: const Text('Off = DEV, On = PROD'),
                ),
                if (_isPermanentlyDenied)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _openAppSettings,
                      icon: const Icon(Icons.settings),
                      label: const Text('Buka Pengaturan Izin'),
                    ),
                  ),
                if (_showRetryPermissionButton && !_isPermanentlyDenied)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _requestStartupPermissions,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Minta Ulang Izin'),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _isRequestingPermissions
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(_effectiveWebViewUrl)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          useShouldOverrideUrlLoading: true,
                          geolocationEnabled: true,
                          databaseEnabled: true,
                          domStorageEnabled: true,
                          mediaPlaybackRequiresUserGesture: false,
                        ),
                        onWebViewCreated: (controller) {
                          _controller = controller;
                        },
                        shouldOverrideUrlLoading: (controller, navigationAction) async {
                          final uri = navigationAction.request.url;
                          final rawUrl = uri?.toString() ?? '';
                          final handling = _navigationGuard.evaluate(rawUrl);
                          if (handling == NavigationHandling.openInCustomTabs) {
                            await _openInCustomTabs(rawUrl);
                            return NavigationActionPolicy.CANCEL;
                          }

                          if (handling == NavigationHandling.block) {
                            _updateStatus(_statusNavigationBlocked);
                            return NavigationActionPolicy.CANCEL;
                          }

                          return NavigationActionPolicy.ALLOW;
                        },
                        onPermissionRequest: (controller, request) async {
                          return _handleWebPermissionRequest(request);
                        },
                        onGeolocationPermissionsShowPrompt: (controller, origin) async {
                          return _handleGeolocationPrompt(origin);
                        },
                        onProgressChanged: (controller, progress) {
                          if (!mounted) return;
                          setState(() {
                            _progress = progress / 100.0;
                          });
                        },
                      ),
                      if (_progress < 1)
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
  }
}
