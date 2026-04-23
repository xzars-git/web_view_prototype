class CustomTabsConfig {
  const CustomTabsConfig._();

  static const String devEnv = 'dev';
  static const String prodEnv = 'prod';

  static const String _devUrl =
      'http://10.44.121.12:4001/beranda?data=pS9LkaUVso4Yv6eYOXzwR0-rwph4axBtM2vvcwBQ0Yu93rqVgUKh8zX_rQqqjh_gQTQiWqZeBbcyyNuj07T5tGBsLEkXf8mkRv3v5JfkTRzBKQJO4t_ZNQTjc7ZNWti1sTIMSuslp0sUuVzxs5fg6jZvXQYo1AFmySMk3OP_HYCZ35bIoDhnTwb_k5WaMiJvrIr_jhLhBcunr45uq94EJXMTeeah3LVcOQ7b1Z0SDTuusf9IfZwi6qxHqT_6m4crQ7s1ubJry7_bIPzPQ3XctmpupkQgUhxOqAAfuhVHwTY';

  static const String _prodUrl =
      'https://sambarav2.vercel.app/beranda?data=pS9LkaUVso4Yv6eYOXzwR0-rwph4axBtM2vvcwBQ0Yu93rqVgUKh8zX_rQqqjh_gQTQiWqZeBbcyyNuj07T5tGBsLEkXf8mkRv3v5JfkTRzBKQJO4t_ZNQTjc7ZNWti1sTIMSuslp0sUuVzxs5fg6jZvXQYo1AFmySMk3OP_HYCZ35bIoDhnTwb_k5WaMiJvrIr_jhLhBcunr45uq94EJXMTeeah3LVcOQ7b1Z0SDTuusf9IfZwi6qxHqT_6m4crQ7s1ubJry7_bIPzPQ3XctmpupkQgUhxOqAAfuhVHwTY';

  // If this list is empty, any host is allowed.
  static const List<String> _customTabAllowedHosts = ['m.dana.id'];

  // Keywords used to decide which WebView pages must open in Custom Tabs.
  static const List<String> _customTabPathKeywords = ['/n/ipg/new/inputphone'];

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
        return _prodUrl;
      case devEnv:
      default:
        return _devUrl;
    }
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
}
