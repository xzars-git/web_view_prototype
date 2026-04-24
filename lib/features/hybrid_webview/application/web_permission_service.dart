import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

enum StartupPermissionOutcome { granted, denied, permanentlyDenied, failed }

class WebPermissionDecision {
  const WebPermissionDecision({
    required this.response,
    required this.granted,
    required this.permanentlyDenied,
  });

  final PermissionResponse response;
  final bool granted;
  final bool permanentlyDenied;
}

class GeolocationDecision {
  const GeolocationDecision({required this.response, required this.locationServiceEnabled});

  final GeolocationPermissionShowPromptResponse response;
  final bool locationServiceEnabled;
}

class WebPermissionService {
  Future<StartupPermissionOutcome> requestStartupPermissions() async {
    try {
      // Minta izin secara sekuensial (satu per satu) agar dialog muncul berurutan
      final locationStatus = await ph.Permission.locationWhenInUse.request();
      final cameraStatus = await ph.Permission.camera.request();

      if (_isPermanentOrRestricted(cameraStatus) || _isPermanentOrRestricted(locationStatus)) {
        return StartupPermissionOutcome.permanentlyDenied;
      }

      if (!_isGranted(cameraStatus) || !_isGranted(locationStatus)) {
        return StartupPermissionOutcome.denied;
      }

      return StartupPermissionOutcome.granted;
    } catch (error, stackTrace) {
      debugPrint('requestStartupPermissions failed: $error');
      debugPrint('$stackTrace');
      return StartupPermissionOutcome.failed;
    }
  }

  Future<bool> isCameraGranted() async {
    final status = await ph.Permission.camera.status;
    return status.isGranted;
  }

  Future<bool> isLocationGranted() async {
    final status = await ph.Permission.locationWhenInUse.status;
    return status.isGranted;
  }

  Future<WebPermissionDecision> handleWebPermissionRequest(PermissionRequest request) async {
    return WebPermissionDecision(
      granted: true,
      permanentlyDenied: false,
      response: PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.GRANT,
      ),
    );
  }

  Future<GeolocationDecision> handleGeolocationPrompt(String origin) async {
    return GeolocationDecision(
      locationServiceEnabled: true,
      response: GeolocationPermissionShowPromptResponse(
        origin: origin,
        allow: true,
        retain: true,
      ),
    );
  }

  bool _isGranted(ph.PermissionStatus status) {
    return status.isGranted || status.isLimited;
  }

  bool _isPermanentOrRestricted(ph.PermissionStatus status) {
    return status.isPermanentlyDenied || status.isRestricted;
  }
}
