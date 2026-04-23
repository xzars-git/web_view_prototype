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
      final results = await Future.wait([
        ph.Permission.camera.request(),
        ph.Permission.locationWhenInUse.request(),
      ]);
      final cameraStatus = results[0];
      final locationStatus = results[1];

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

  Future<WebPermissionDecision> handleWebPermissionRequest(PermissionRequest request) async {
    var isGranted = true;
    var hasPermanentDenial = false;

    if (_requestNeedsCamera(request.resources)) {
      final cameraStatus = await ph.Permission.camera.request();
      isGranted = isGranted && _isGranted(cameraStatus);
      hasPermanentDenial = hasPermanentDenial || _isPermanentOrRestricted(cameraStatus);
    }

    if (_requestNeedsMicrophone(request.resources)) {
      final microphoneStatus = await ph.Permission.microphone.request();
      isGranted = isGranted && _isGranted(microphoneStatus);
      hasPermanentDenial = hasPermanentDenial || _isPermanentOrRestricted(microphoneStatus);
    }

    return WebPermissionDecision(
      granted: isGranted,
      permanentlyDenied: hasPermanentDenial,
      response: PermissionResponse(
        resources: request.resources,
        action: isGranted ? PermissionResponseAction.GRANT : PermissionResponseAction.DENY,
      ),
    );
  }

  Future<GeolocationDecision> handleGeolocationPrompt(String origin) async {
    var isReady = await _isLocationReadyForWeb();

    if (!isReady) {
      final requestStatus = await ph.Permission.locationWhenInUse.request();
      isReady = requestStatus.isGranted && await _isLocationReadyForWeb();
    }

    final serviceStatus = await ph.Permission.locationWhenInUse.serviceStatus;
    final serviceEnabled = serviceStatus == ph.ServiceStatus.enabled;

    return GeolocationDecision(
      locationServiceEnabled: serviceEnabled,
      response: GeolocationPermissionShowPromptResponse(
        origin: origin,
        allow: isReady,
        retain: true,
      ),
    );
  }

  Future<bool> _isLocationReadyForWeb() async {
    final permission = await ph.Permission.locationWhenInUse.status;
    if (!_isGranted(permission)) {
      return false;
    }

    final serviceStatus = await ph.Permission.locationWhenInUse.serviceStatus;
    return serviceStatus == ph.ServiceStatus.enabled;
  }

  bool _requestNeedsCamera(List<PermissionResourceType> resources) {
    return resources.any((resource) {
      final value = resource.toString().toLowerCase();
      return value.contains('video') || value.contains('camera');
    });
  }

  bool _requestNeedsMicrophone(List<PermissionResourceType> resources) {
    return resources.any((resource) => resource.toString().toLowerCase().contains('audio'));
  }

  bool _isGranted(ph.PermissionStatus status) {
    return status.isGranted || status.isLimited;
  }

  bool _isPermanentOrRestricted(ph.PermissionStatus status) {
    return status.isPermanentlyDenied || status.isRestricted;
  }
}
