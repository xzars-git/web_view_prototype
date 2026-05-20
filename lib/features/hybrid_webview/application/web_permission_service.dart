import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Hasil dari proses permintaan izin startup.
enum StartupPermissionOutcome { granted, denied, permanentlyDenied, failed }

/// Wrapper untuk keputusan izin WebView.
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

/// Wrapper untuk keputusan izin geolokasi WebView.
class GeolocationDecision {
  const GeolocationDecision({required this.response, required this.locationServiceEnabled});

  final GeolocationPermissionShowPromptResponse response;
  final bool locationServiceEnabled;
}

/// Service untuk menangani interaksi dengan API perizinan native (Android/iOS).
class WebPermissionService {
  final ph.Permission _locationPermission;
  final ph.Permission _cameraPermission;

  WebPermissionService({
    ph.Permission? locationPermission,
    ph.Permission? cameraPermission,
  })  : _locationPermission = locationPermission ?? ph.Permission.locationWhenInUse,
        _cameraPermission = cameraPermission ?? ph.Permission.camera;

  /// Requests camera and location permissions sequentially so system dialogs
  /// appear one at a time instead of stacking on top of each other.
  Future<StartupPermissionOutcome> requestStartupPermissions() async {
    try {
      final locationStatus = await _locationPermission.request();
      final cameraStatus = await _cameraPermission.request();

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

  /// Mengecek apakah izin kamera saat ini diberikan.
  Future<bool> isCameraGranted() async {
    final status = await _cameraPermission.status;
    return status.isGranted;
  }

  /// Mengecek apakah izin lokasi saat ini diberikan.
  Future<bool> isLocationGranted() async {
    final status = await _locationPermission.status;
    return status.isGranted;
  }

  /// Grants any WebView permission request unconditionally. System-level
  /// validation already happened at startup, so no second prompt is needed.
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

  /// Grants geolocation to any origin. Same rationale as [handleWebPermissionRequest].
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

  bool _isGranted(ph.PermissionStatus status) => status.isGranted || status.isLimited;

  bool _isPermanentOrRestricted(ph.PermissionStatus status) =>
      status.isPermanentlyDenied || status.isRestricted;
}
