import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:url_launcher/url_launcher.dart';

import '../../../config/custom_tabs_config.dart';

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

  InAppWebViewController? _controller;
  late String _selectedEnvironment;

  String _status = _statusRequestingPermissions;
  double _progress = 0;
  _StartupPermissionState _permissionState = _StartupPermissionState.requesting;
  bool _hasPermissionIssue = false;

  @override
  void initState() {
    super.initState();
    _selectedEnvironment = CustomTabsConfig.normalizeEnvironment(widget.initialEnvironment);
    _requestStartupPermissions();
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

  Future<void> _openInCustomTabs(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      _updateStatus(_statusPaymentUrlInvalid);
      return;
    }

    bool opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      opened = false;
    }

    if (!opened) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }

    _updateStatus(opened ? _statusPaymentOpenSuccess : _statusPaymentOpenFailed);
  }

  Future<void> _reloadBasePage() async {
    await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(_effectiveWebViewUrl)));
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
      final results = await Future.wait([
        ph.Permission.camera.request(),
        ph.Permission.locationWhenInUse.request(),
      ]);
      final cameraStatus = results[0];
      final locationStatus = results[1];

      if (!mounted) return;
      setState(() {
        if (cameraStatus.isPermanentlyDenied || locationStatus.isPermanentlyDenied) {
          _permissionState = _StartupPermissionState.permanentlyDenied;
          _hasPermissionIssue = true;
          _status = _statusPermissionPermanentlyDenied;
          return;
        }

        if (cameraStatus.isDenied || locationStatus.isDenied) {
          _permissionState = _StartupPermissionState.ready;
          _hasPermissionIssue = true;
          _status = _statusPermissionDenied;
          return;
        }

        _permissionState = _StartupPermissionState.ready;
        _hasPermissionIssue = false;
        _status = _statusWebViewActive;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _permissionState = _StartupPermissionState.ready;
        _hasPermissionIssue = true;
        _status = _statusPermissionRequestFailed;
      });
    }
  }

  Future<bool> _isLocationReadyForWeb() async {
    final permission = await ph.Permission.locationWhenInUse.status;
    if (!permission.isGranted) {
      return false;
    }

    final serviceStatus = await ph.Permission.locationWhenInUse.serviceStatus;
    return serviceStatus == ph.ServiceStatus.enabled;
  }

  bool _requestNeedsCamera(List<PermissionResourceType> resources) {
    return resources.any((resource) => resource.toString().toLowerCase().contains('video'));
  }

  bool _requestNeedsMicrophone(List<PermissionResourceType> resources) {
    return resources.any((resource) => resource.toString().toLowerCase().contains('audio'));
  }

  Future<PermissionResponse> _handleWebPermissionRequest(PermissionRequest request) async {
    var isGranted = true;
    var hasPermanentDenial = false;

    if (_requestNeedsCamera(request.resources)) {
      final cameraStatus = await ph.Permission.camera.request();
      isGranted = isGranted && cameraStatus.isGranted;
      hasPermanentDenial = hasPermanentDenial || cameraStatus.isPermanentlyDenied;
    }

    if (_requestNeedsMicrophone(request.resources)) {
      final microphoneStatus = await ph.Permission.microphone.request();
      isGranted = isGranted && microphoneStatus.isGranted;
      hasPermanentDenial = hasPermanentDenial || microphoneStatus.isPermanentlyDenied;
    }

    if (!isGranted) {
      if (mounted) {
        setState(() {
          _hasPermissionIssue = true;
          if (hasPermanentDenial) {
            _permissionState = _StartupPermissionState.permanentlyDenied;
          }
        });
      }
      _updateStatus(_statusWebPermissionDenied);
    }

    return PermissionResponse(
      resources: request.resources,
      action: isGranted ? PermissionResponseAction.GRANT : PermissionResponseAction.DENY,
    );
  }

  Future<GeolocationPermissionShowPromptResponse> _handleGeolocationPrompt(String origin) async {
    var isReady = await _isLocationReadyForWeb();

    if (!isReady) {
      final requestStatus = await ph.Permission.locationWhenInUse.request();
      isReady = requestStatus.isGranted && await _isLocationReadyForWeb();
    }

    if (!isReady) {
      final serviceStatus = await ph.Permission.locationWhenInUse.serviceStatus;
      if (serviceStatus != ph.ServiceStatus.enabled) {
        if (mounted) {
          setState(() {
            _hasPermissionIssue = true;
          });
        }
        _updateStatus(_statusLocationServiceDisabled);
      } else {
        if (mounted) {
          setState(() {
            _hasPermissionIssue = true;
          });
        }
        _updateStatus(_statusPermissionDenied);
      }
    }

    return GeolocationPermissionShowPromptResponse(origin: origin, allow: isReady, retain: true);
  }

  Future<void> _openAppSettings() async {
    await ph.openAppSettings();
  }

  void _switchEnvironment(bool useProd) {
    final nextEnvironment = useProd ? CustomTabsConfig.prodEnv : CustomTabsConfig.devEnv;
    setState(() {
      _selectedEnvironment = nextEnvironment;
      _status = CustomTabsConfig.isTargetUrlOverridden
          ? 'TARGET_URL override aktif, switcher tidak mengubah URL target.'
          : 'Environment diubah ke $_selectedEnvironment. Memuat ulang WebView...';
    });
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
                          if (rawUrl.isEmpty) {
                            return NavigationActionPolicy.ALLOW;
                          }

                          if (CustomTabsConfig.shouldOpenInCustomTabs(rawUrl)) {
                            await _openInCustomTabs(rawUrl);
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
