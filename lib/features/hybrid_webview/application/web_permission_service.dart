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
  /// Meminta izin kamera dan lokasi dari sistem operasi secara sekuensial.
  Future<StartupPermissionOutcome> requestStartupPermissions() async {
    try {
      // Meminta izin satu per satu agar dialog sistem muncul secara berurutan.
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

  /// Mengecek apakah izin kamera saat ini diberikan.
  Future<bool> isCameraGranted() async {
    final status = await ph.Permission.camera.status;
    return status.isGranted;
  }

  /// Mengecek apakah izin lokasi saat ini diberikan.
  Future<bool> isLocationGranted() async {
    final status = await ph.Permission.locationWhenInUse.status;
    return status.isGranted;
  }

  /// Menangani callback izin dari WebView. 
  /// 
  /// Menggunakan pola POC: Langsung memberikan izin (GRANT) karena validasi 
  /// sudah dilakukan di level sistem saat startup.
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

  /// Menangani callback geolokasi dari WebView.
  /// 
  /// Langsung memberikan izin (ALLOW) karena validasi sistem sudah dilakukan.
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

  /// Helper untuk mengecek apakah status izin termasuk kategori 'Granted'.
  bool _isGranted(ph.PermissionStatus status) {
    return status.isGranted || status.isLimited;
  }

  /// Helper untuk mengecek apakah status izin termasuk kategori 'Permanently Denied'.
  bool _isPermanentOrRestricted(ph.PermissionStatus status) {
    return status.isPermanentlyDenied || status.isRestricted;
  }
}
