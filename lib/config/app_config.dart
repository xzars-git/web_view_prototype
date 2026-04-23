abstract class AppConfig {
  String get devEnv;
  String get prodEnv;
  String get currentEnvironment;
  String get targetUrl;
  bool get isTargetUrlOverridden;

  String normalizeEnvironment(String rawValue);
  String urlForEnvironment(String environment);
  bool shouldOpenInCustomTabs(String rawUrl);
  bool isWebViewNavigationAllowed(String rawUrl);
}

class DefaultAppConfig implements AppConfig {
  const DefaultAppConfig();

  @override
  String get devEnv => 'dev';
  @override
  String get prodEnv => 'prod';

  static const String _devBaseUrl = String.fromEnvironment(
    'DEV_BASE_URL',
    defaultValue: 'https://example.invalid/beranda',
  );

  static const String _prodBaseUrl = String.fromEnvironment(
    'PROD_BASE_URL',
    defaultValue: 'https://sambarav2.vercel.app/beranda',
  );

  static const String _targetDataToken = String.fromEnvironment(
    'TARGET_DATA_TOKEN',
    defaultValue: '',
  );

  static const List<String> _customTabAllowedHosts = ['m.dana.id'];
  static const List<String> _customTabPathKeywords = ['/n/ipg/new/inputphone'];
  static const List<String> _webViewAllowedHosts = [
    '10.44.121.12',
    'sambarav2.vercel.app',
    'm.dana.id',
  ];

  static const String _rawEnv = String.fromEnvironment('APP_ENV', defaultValue: 'dev');
  static const String _targetUrlOverride = String.fromEnvironment('TARGET_URL', defaultValue: '');

  @override
  String normalizeEnvironment(String rawValue) {
    final normalized = rawValue.trim().toLowerCase();
    return (normalized == prodEnv) ? prodEnv : devEnv;
  }

  @override
  String get currentEnvironment => normalizeEnvironment(_rawEnv);

  @override
  bool get isTargetUrlOverridden => _targetUrlOverride.trim().isNotEmpty;

  @override
  String get targetUrl {
    if (isTargetUrlOverridden) {
      return _targetUrlOverride.trim();
    }
    return urlForEnvironment(currentEnvironment);
  }

  @override
  String urlForEnvironment(String environment) {
    final normalized = normalizeEnvironment(environment);
    final baseUrl = (normalized == prodEnv) ? _prodBaseUrl : _devBaseUrl;
    return _buildUrlWithOptionalToken(baseUrl);
  }

  String _buildUrlWithOptionalToken(String rawUrl) {
    final trimmed = rawUrl.trim();
    final token = _targetDataToken.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || token.isEmpty) {
      return trimmed;
    }

    final nextQuery = Map<String, String>.from(uri.queryParameters);
    nextQuery['data'] = token;
    return uri.replace(queryParameters: nextQuery).toString();
  }

  @override
  bool shouldOpenInCustomTabs(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;

    if (_customTabAllowedHosts.isNotEmpty) {
      final currentHost = uri.host.toLowerCase();
      if (!_customTabAllowedHosts.any((allowed) => allowed.toLowerCase() == currentHost)) {
        return false;
      }
    }

    final fingerprint = '${uri.path.toLowerCase()}?${uri.query.toLowerCase()}';
    return _customTabPathKeywords.any((keyword) => fingerprint.contains(keyword.toLowerCase()));
  }

  @override
  bool isWebViewNavigationAllowed(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;

    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'about') return uri.toString().toLowerCase() == 'about:blank';
    if (scheme != 'http' && scheme != 'https') return false;

    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) return false;

    return _webViewAllowedHosts.any((allowed) {
      final normalizedAllowed = allowed.trim().toLowerCase();
      return host == normalizedAllowed || host.endsWith('.$normalizedAllowed');
    });
  }
}
