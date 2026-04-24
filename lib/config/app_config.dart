abstract class AppConfig {
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
  String get prodEnv => 'prod';

  static const String _prodBaseUrl = String.fromEnvironment(
    'PROD_BASE_URL',
    defaultValue: 'https://sambarav2.vercel.app/beranda',
  );

  static const String _targetDataToken = String.fromEnvironment(
    'TARGET_DATA_TOKEN',
    defaultValue:
        'pS9LkaUVso4Yv6eYOXzwR0-rwph4axBtM2vvcwBQ0Yu93rqVgUKh8zX_rQqqjh_gQTQiWqZeBbcyyNuj07T5tGBsLEkXf8mkRv3v5JfkTRzBKQJO4t_ZNQTjc7ZNWti1sTIMSuslp0sUuVzxs5fg6jZvXQYo1AFmySMk3OP_HYCZ35bIoDhnTwb_k5WaMiJvrIr_jhLhBcunr45uq94EJXMTeeah3LVcOQ7b1Z0SDTuusf9IfZwi6qxHqT_6m4crQ7s1ubJry7_bIPzPQ3XctmpupkQgUhxOqAAfuhVHwTY',
  );

  static const List<String> _customTabAllowedHosts = [
    'm.dana.id',
    'api-hk.m.dana.id',
    'm.dana.id.link'
  ];
  static const List<String> _customTabPathKeywords = [
    '/n/cashier/new/checkout',
    '/n/ipg/new/inputphone',
    '/n/ipg/new/payment'
  ];
  static const List<String> _webViewAllowedHosts = [
    '10.44.121.12',
    'sambarav2.vercel.app',
    'm.dana.id',
    'api-hk.m.dana.id'
  ];

  static const String _rawEnv = String.fromEnvironment('APP_ENV', defaultValue: 'prod');
  static const String _targetUrlOverride = String.fromEnvironment('TARGET_URL', defaultValue: '');

  @override
  String normalizeEnvironment(String rawValue) {
    return prodEnv; // Always return prod
  }

  @override
  String get currentEnvironment => prodEnv;

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
    return _buildUrlWithOptionalToken(_prodBaseUrl);
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
    if (uri == null) return false;
    
    final host = uri.host.toLowerCase();
    
    // Jika host adalah DANA, langsung buka di Custom Tabs
    if (host.contains('dana.id')) {
      return true;
    }

    if (uri.scheme.toLowerCase() != 'https') return false;

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
