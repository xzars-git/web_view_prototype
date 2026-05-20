import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../../config/logger.dart';

/// Hasil dari proses permintaan izin startup.
enum StartupPermissionOutcome { granted, denied, permanentlyDenied, failed }


/// Service untuk menangani interaksi dengan API perizinan native (Android/iOS).
class WebPermissionService {
  final ph.Permission _locationPermission;
  final ph.Permission _cameraPermission;

  WebPermissionService({
    ph.Permission? locationPermission,
    ph.Permission? cameraPermission,
  })  : _locationPermission = locationPermission ?? ph.Permission.locationWhenInUse,
        _cameraPermission = cameraPermission ?? ph.Permission.camera;

  /// Meminta izin kamera dan lokasi dari sistem operasi secara sekuensial.
  Future<StartupPermissionOutcome> requestStartupPermissions() async {
    try {
      // Meminta izin satu per satu agar dialog sistem muncul secara berurutan.
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
      AppLogger.e('requestStartupPermissions failed', error, stackTrace);
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

  /// Menangani callback izin dari WebView. 
  /// 
  /// Menggunakan pola POC: Langsung memberikan izin (GRANT) karena validasi 
  /// sudah dilakukan di level sistem saat startup.
  Future<PermissionResponse> handleWebPermissionRequest(PermissionRequest request) async {
    return PermissionResponse(
      resources: request.resources,
      action: PermissionResponseAction.GRANT,
    );
  }

  /// Menangani callback geolokasi dari WebView.
  ///
  /// Langsung memberikan izin (ALLOW) karena validasi sistem sudah dilakukan.
  Future<GeolocationPermissionShowPromptResponse> handleGeolocationPrompt(String origin) async {
    return GeolocationPermissionShowPromptResponse(
      origin: origin,
      allow: true,
      retain: true,
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
