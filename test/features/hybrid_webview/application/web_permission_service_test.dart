import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:web_view_prototype/features/hybrid_webview/application/web_permission_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  
  late WebPermissionService service;
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUp(() {
    service = WebPermissionService();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('WebPermissionService Tests (MethodChannel)', () {
    test('requestStartupPermissions returns granted when both are granted', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
        if (methodCall.method == 'requestPermissions') {
          final List<dynamic> permissions = methodCall.arguments;
          return {for (var p in permissions) p: 1}; // 1 = granted
        }
        return null;
      });

      final result = await service.requestStartupPermissions();
      expect(result, StartupPermissionOutcome.granted);
    });

    test('requestStartupPermissions returns denied when one is denied', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
        if (methodCall.method == 'requestPermissions') {
          final List<dynamic> permissions = methodCall.arguments;
          return {for (var p in permissions) p: 0}; // 0 = denied
        }
        return null;
      });

      final result = await service.requestStartupPermissions();
      expect(result, StartupPermissionOutcome.denied);
    });

    test('requestStartupPermissions returns permanentlyDenied when one is permanentlyDenied', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
        if (methodCall.method == 'requestPermissions') {
          final List<dynamic> permissions = methodCall.arguments;
          return {for (var p in permissions) p: 4}; // 4 = permanentlyDenied
        }
        return null;
      });

      final result = await service.requestStartupPermissions();
      expect(result, StartupPermissionOutcome.permanentlyDenied);
    });

    test('handleWebPermissionRequest returns GRANT action', () async {
      final request = PermissionRequest(
        origin: WebUri('https://example.com'),
        resources: [PermissionResourceType.CAMERA],
      );
      final result = await service.handleWebPermissionRequest(request);

      expect(result.granted, isTrue);
      expect(result.response.action, PermissionResponseAction.GRANT);
    });

    test('handleGeolocationPrompt returns allow true', () async {
      final result = await service.handleGeolocationPrompt('https://example.com');

      expect(result.locationServiceEnabled, isTrue);
      expect(result.response.allow, isTrue);
    });
  });
}
