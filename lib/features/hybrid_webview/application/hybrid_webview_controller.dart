import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/app_config.dart';
import '../domain/web_navigation_guard.dart';
import 'web_permission_service.dart';

enum StartupPermissionState { requesting, ready, permanentlyDenied }

class HybridWebViewState {
  final String status;
  final double progress;
  final StartupPermissionState permissionState;
  final bool hasPermissionIssue;
  final String selectedEnvironment;

  const HybridWebViewState({
    required this.status,
    required this.progress,
    required this.permissionState,
    required this.hasPermissionIssue,
    required this.selectedEnvironment,
  });

  HybridWebViewState copyWith({
    String? status,
    double? progress,
    StartupPermissionState? permissionState,
    bool? hasPermissionIssue,
    String? selectedEnvironment,
  }) {
    return HybridWebViewState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      permissionState: permissionState ?? this.permissionState,
      hasPermissionIssue: hasPermissionIssue ?? this.hasPermissionIssue,
      selectedEnvironment: selectedEnvironment ?? this.selectedEnvironment,
    );
  }
}

class HybridWebViewController extends ValueNotifier<HybridWebViewState> {
  HybridWebViewController({
    required AppConfig config,
    required String initialEnvironment,
    WebPermissionService? permissionService,
    WebNavigationGuard? navigationGuard,
  })  : _config = config,
        _permissionService = permissionService ?? WebPermissionService(),
        _navigationGuard = navigationGuard ?? WebNavigationGuard(config: config),
        super(HybridWebViewState(
          status: 'Meminta izin camera dan location...',
          progress: 0,
          permissionState: StartupPermissionState.requesting,
          hasPermissionIssue: false,
          selectedEnvironment: config.normalizeEnvironment(initialEnvironment),
        ));

  final AppConfig _config;
  final WebPermissionService _permissionService;
  final WebNavigationGuard _navigationGuard;
  InAppWebViewController? webViewController;

  String get effectiveWebViewUrl {
    if (_config.isTargetUrlOverridden) {
      return _config.targetUrl;
    }
    return _config.urlForEnvironment(value.selectedEnvironment);
  }

  bool get isProdSelected => value.selectedEnvironment == _config.prodEnv;
  bool get isRequestingPermissions => value.permissionState == StartupPermissionState.requesting;
  bool get isPermanentlyDenied => value.permissionState == StartupPermissionState.permanentlyDenied;
  bool get showRetryPermissionButton =>
      value.permissionState == StartupPermissionState.ready && value.hasPermissionIssue;

  void updateProgress(double progress) {
    value = value.copyWith(progress: progress);
  }

  void updateStatus(String status) {
    value = value.copyWith(status: status);
  }

  Future<void> requestStartupPermissions() async {
    value = value.copyWith(
      permissionState: StartupPermissionState.requesting,
      status: 'Meminta izin camera dan location...',
      hasPermissionIssue: false,
    );

    try {
      final outcome = await _permissionService.requestStartupPermissions();

      if (outcome == StartupPermissionOutcome.permanentlyDenied) {
        value = value.copyWith(
          permissionState: StartupPermissionState.permanentlyDenied,
          hasPermissionIssue: true,
          status: 'Izin camera/location ditolak permanen. Aktifkan dari pengaturan perangkat.',
        );
        return;
      }

      if (outcome == StartupPermissionOutcome.denied) {
        value = value.copyWith(
          permissionState: StartupPermissionState.ready,
          hasPermissionIssue: true,
          status: 'Izin camera/location ditolak. Beberapa fitur web mungkin tidak berjalan.',
        );
        return;
      }

      if (outcome == StartupPermissionOutcome.failed) {
        value = value.copyWith(
          permissionState: StartupPermissionState.ready,
          hasPermissionIssue: true,
          status: 'Gagal meminta izin camera/location dari perangkat.',
        );
        return;
      }

      value = value.copyWith(
        permissionState: StartupPermissionState.ready,
        hasPermissionIssue: false,
        status: 'WebView aktif. Halaman payment akan dibuka di Custom Tabs.',
      );
    } catch (e) {
      value = value.copyWith(
        permissionState: StartupPermissionState.ready,
        hasPermissionIssue: true,
        status: 'Gagal meminta izin camera/location dari perangkat.',
      );
    }
  }

  Future<PermissionResponse> handleWebPermissionRequest(PermissionRequest request) async {
    try {
      final decision = await _permissionService.handleWebPermissionRequest(request);
      if (!decision.granted) {
        value = value.copyWith(hasPermissionIssue: true);
        if (decision.permanentlyDenied) {
          value = value.copyWith(permissionState: StartupPermissionState.permanentlyDenied);
        }
        updateStatus('Izin camera/microphone untuk web ditolak. Fitur media mungkin tidak berjalan.');
      }
      return decision.response;
    } catch (e) {
      return PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      );
    }
  }

  Future<GeolocationPermissionShowPromptResponse> handleGeolocationPrompt(String origin) async {
    try {
      final decision = await _permissionService.handleGeolocationPrompt(origin);
      if (!decision.response.allow) {
        value = value.copyWith(hasPermissionIssue: true);
        if (!decision.locationServiceEnabled) {
          updateStatus('Layanan lokasi perangkat mati. Aktifkan GPS untuk fitur lokasi di web.');
        } else {
          updateStatus('Izin camera/location ditolak. Beberapa fitur web mungkin tidak berjalan.');
        }
      }
      return decision.response;
    } catch (e) {
      return GeolocationPermissionShowPromptResponse(
        origin: origin,
        allow: false,
        retain: false,
      );
    }
  }

  Future<void> reloadBasePage() async {
    if (webViewController == null) {
      updateStatus('WebView belum siap. Memuat ulang dibatalkan.');
      return;
    }

    final uri = Uri.tryParse(effectiveWebViewUrl);
    if (uri == null) {
      updateStatus('URL tidak valid: $effectiveWebViewUrl');
      return;
    }

    await webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
    updateStatus('Memuat ulang halaman utama di WebView.');
  }

  Future<NavigationActionPolicy> handleNavigation(NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    final rawUrl = uri?.toString() ?? '';
    final handling = _navigationGuard.evaluate(rawUrl);

    if (handling == NavigationHandling.openInCustomTabs) {
      await _openInCustomTabs(rawUrl);
      return NavigationActionPolicy.CANCEL;
    }

    if (handling == NavigationHandling.block) {
      updateStatus('Navigasi diblokir karena URL tidak ada di allowlist.');
      return NavigationActionPolicy.CANCEL;
    }

    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _openInCustomTabs(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      updateStatus('URL payment tidak valid.');
      return;
    }

    bool opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (e) {
      opened = false;
    }

    if (!opened) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        opened = false;
      }
    }

    updateStatus(opened
        ? 'Halaman payment dibuka di Custom Tabs. Tutup tab untuk kembali ke WebView.'
        : 'Gagal membuka halaman payment di Custom Tabs.');
  }

  void switchEnvironment(bool useProd) {
    final nextEnvironment = useProd ? _config.prodEnv : _config.devEnv;
    value = value.copyWith(selectedEnvironment: nextEnvironment);

    if (webViewController == null) {
      updateStatus(
        'Environment diubah ke ${value.selectedEnvironment}. WebView akan memuat URL ini saat siap.',
      );
      return;
    }

    updateStatus(
      _config.isTargetUrlOverridden
          ? 'TARGET_URL override aktif, switcher tidak mengubah URL target.'
          : 'Environment diubah ke ${value.selectedEnvironment}. Memuat ulang WebView...',
    );
    reloadBasePage();
  }
}
