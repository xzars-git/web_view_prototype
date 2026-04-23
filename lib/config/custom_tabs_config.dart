class CustomTabsConfig {
  const CustomTabsConfig._();

  static const String devEnv = 'dev';
  static const String prodEnv = 'prod';

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

  // If this list is empty, any host is allowed.
  static const List<String> _customTabAllowedHosts = ['m.dana.id'];

  // Keywords used to decide which WebView pages must open in Custom Tabs.
  static const List<String> _customTabPathKeywords = ['/n/ipg/new/inputphone'];

  static const List<String> _webViewAllowedHosts = [
    '10.44.121.12',
    'sambarav2.vercel.app',
    'm.dana.id',
  ];

  // Supported values: dev, prod
  static const String _rawEnv = String.fromEnvironment('APP_ENV', defaultValue: devEnv);
  static const String _targetUrlOverride = String.fromEnvironment('TARGET_URL', defaultValue: '');

  static String normalizeEnvironment(String rawValue) {
    final normalized = rawValue.trim().toLowerCase();
    if (normalized == prodEnv) {
      return prodEnv;
    }
    return devEnv;
  }

  static String get _resolvedEnv {
    return normalizeEnvironment(_rawEnv);
  }

  static String urlForEnvironment(String environment) {
    switch (normalizeEnvironment(environment)) {
      case prodEnv:
        return _buildUrlWithOptionalToken(_prodBaseUrl);
      case devEnv:
      default:
        return _buildUrlWithOptionalToken(_devBaseUrl);
    }
  }

  static String _buildUrlWithOptionalToken(String rawUrl) {
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

  static String get targetUrl {
    if (isTargetUrlOverridden) {
      return _targetUrlOverride.trim();
    }

    return urlForEnvironment(_resolvedEnv);
  }

  static String get environment => _resolvedEnv;

  static bool get isTargetUrlOverridden => _targetUrlOverride.trim().isNotEmpty;

  static bool shouldOpenInCustomTabs(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      return false;
    }

    if (uri.scheme.toLowerCase() != 'https') {
      return false;
    }

    if (_customTabAllowedHosts.isNotEmpty) {
      final currentHost = uri.host.toLowerCase();
      final hostMatched = _customTabAllowedHosts.any(
        (allowed) => allowed.trim().toLowerCase() == currentHost,
      );
      if (!hostMatched) {
        return false;
      }
    }

    final fingerprint = '${uri.path.toLowerCase()}?${uri.query.toLowerCase()}';
    return _customTabPathKeywords.any(
      (keyword) => fingerprint.contains(keyword.trim().toLowerCase()),
    );
  }

  static bool isWebViewNavigationAllowed(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      return false;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'about') {
      return uri.toString().toLowerCase() == 'about:blank';
    }

    if (scheme != 'http' && scheme != 'https') {
      return false;
    }

    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) {
      return false;
    }

    return _webViewAllowedHosts.any((allowed) {
      final normalizedAllowed = allowed.trim().toLowerCase();
      return host == normalizedAllowed || host.endsWith('.$normalizedAllowed');
    });
  }
}
