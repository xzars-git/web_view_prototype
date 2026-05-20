import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:web_view_prototype/features/hybrid_webview/application/web_permission_service.dart';

class MockPermission extends Mock implements ph.Permission {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WebPermissionService service;
  late MockPermission locationPermission;
  late MockPermission cameraPermission;

  setUp(() {
    locationPermission = MockPermission();
    cameraPermission = MockPermission();
    service = WebPermissionService(
      locationPermission: locationPermission,
      cameraPermission: cameraPermission,
    );
  });

  group('WebPermissionService Tests (MethodChannel)', () {
    test('requestStartupPermissions returns granted when both are granted', () async {
      when(() => locationPermission.request()).thenAnswer((_) async => ph.PermissionStatus.granted);
      when(() => cameraPermission.request()).thenAnswer((_) async => ph.PermissionStatus.granted);

      final result = await service.requestStartupPermissions();
      expect(result, StartupPermissionOutcome.granted);
    });

    test('requestStartupPermissions returns denied when one is denied', () async {
      when(() => locationPermission.request()).thenAnswer((_) async => ph.PermissionStatus.granted);
      when(() => cameraPermission.request()).thenAnswer((_) async => ph.PermissionStatus.denied);

      final result = await service.requestStartupPermissions();
      expect(result, StartupPermissionOutcome.denied);
    });

    test(
      'requestStartupPermissions returns permanentlyDenied when one is permanentlyDenied',
      () async {
        when(
          () => locationPermission.request(),
        ).thenAnswer((_) async => ph.PermissionStatus.permanentlyDenied);
        when(() => cameraPermission.request()).thenAnswer((_) async => ph.PermissionStatus.granted);

        final result = await service.requestStartupPermissions();
        expect(result, StartupPermissionOutcome.permanentlyDenied);
      },
    );

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
