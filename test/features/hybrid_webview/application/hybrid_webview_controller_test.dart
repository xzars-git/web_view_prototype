import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/config/app_config.dart';
import 'package:web_view_prototype/features/hybrid_webview/application/hybrid_webview_controller.dart';
import 'package:web_view_prototype/features/hybrid_webview/application/web_permission_service.dart';
import 'package:web_view_prototype/features/hybrid_webview/domain/web_navigation_guard.dart';

class MockWebPermissionService implements WebPermissionService {
  StartupPermissionOutcome startupOutcome = StartupPermissionOutcome.granted;

  @override
  Future<StartupPermissionOutcome> requestStartupPermissions() async => startupOutcome;

  @override
  Future<WebPermissionDecision> handleWebPermissionRequest(PermissionRequest request) async {
    return WebPermissionDecision(
      response: PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.GRANT,
      ),
      granted: true,
      permanentlyDenied: false,
    );
  }

  @override
  Future<GeolocationDecision> handleGeolocationPrompt(String origin) async {
    return GeolocationDecision(
      response: GeolocationPermissionShowPromptResponse(origin: origin, allow: true, retain: true),
      locationServiceEnabled: true,
    );
  }
}

class MockWebNavigationGuard implements WebNavigationGuard {
  @override
  NavigationHandling evaluate(String url) => NavigationHandling.allowWebView;
}

void main() {
  late HybridWebViewController controller;
  late MockWebPermissionService mockPermissionService;
  late MockWebNavigationGuard mockNavigationGuard;
  const config = DefaultAppConfig();

  setUp(() {
    mockPermissionService = MockWebPermissionService();
    mockNavigationGuard = MockWebNavigationGuard();
    controller = HybridWebViewController(
      config: config,
      initialEnvironment: config.devEnv,
      permissionService: mockPermissionService,
      navigationGuard: mockNavigationGuard,
    );
  });

  group('HybridWebViewController Tests', () {
    test('Initial state is correct', () {
      expect(controller.value.selectedEnvironment, config.devEnv);
      expect(controller.value.permissionState, StartupPermissionState.requesting);
      expect(controller.value.progress, 0);
    });

    test('updateProgress updates state correctly', () {
      controller.updateProgress(0.5);
      expect(controller.value.progress, 0.5);
    });

    test('switchEnvironment updates environment and status', () {
      controller.switchEnvironment(true); // Switch to PROD
      expect(controller.value.selectedEnvironment, config.prodEnv);
      expect(controller.isProdSelected, true);
      expect(controller.value.status, contains('Environment diubah ke prod'));
    });

    test('requestStartupPermissions success state', () async {
      mockPermissionService.startupOutcome = StartupPermissionOutcome.granted;
      await controller.requestStartupPermissions();

      expect(controller.value.permissionState, StartupPermissionState.ready);
      expect(controller.value.hasPermissionIssue, false);
      expect(controller.value.status, contains('WebView aktif'));
    });

    test('requestStartupPermissions permanentlyDenied state', () async {
      mockPermissionService.startupOutcome = StartupPermissionOutcome.permanentlyDenied;
      await controller.requestStartupPermissions();

      expect(controller.value.permissionState, StartupPermissionState.permanentlyDenied);
      expect(controller.value.hasPermissionIssue, true);
      expect(controller.value.status, contains('ditolak permanen'));
    });

    test('requestStartupPermissions failed state', () async {
      mockPermissionService.startupOutcome = StartupPermissionOutcome.failed;
      await controller.requestStartupPermissions();

      expect(controller.value.permissionState, StartupPermissionState.ready);
      expect(controller.value.hasPermissionIssue, true);
      expect(controller.value.status, contains('Gagal meminta izin'));
    });
  });
}
