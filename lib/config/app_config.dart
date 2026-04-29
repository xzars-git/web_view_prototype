import 'logger.dart';

/// Abstraksi untuk konfigurasi aplikasi.
///
/// Digunakan untuk memisahkan detail implementasi konfigurasi (seperti
/// environment variables) dari logika bisnis agar kode mudah ditest (mockable).
abstract class AppConfig {
  /// Nama environment produksi.
  String get prodEnv;

  /// Environment yang sedang aktif saat ini.
  String get currentEnvironment;

  /// URL tujuan utama yang sudah diformat dengan token.
  String get targetUrl;

  /// Nama bridge untuk komunikasi JS-Flutter.
  String get bridgeName;

  /// Skema deep link untuk aplikasi ini.
  String get deepLinkScheme;

  /// Host deep link untuk memproses kembalinya pembayaran.
  String get deepLinkHost;

  /// Nama event JavaScript yang dikirim ke Web saat pembayaran selesai.
  String get paymentEventName;

  /// Judul halaman utama WebView.
  String get appBarTitle;

  /// Status apakah URL ditimpa secara manual via environment variable.
  bool get isTargetUrlOverridden;

  /// Menstandarisasi string environment.
  String normalizeEnvironment(String rawValue);

  /// Mendapatkan URL untuk environment tertentu.
  String urlForEnvironment(String environment);

  /// Menentukan apakah URL tertentu harus dibuka di Custom Tabs.
  bool isWebViewNavigationAllowed(String rawUrl);
}

/// Implementasi konkret dari [AppConfig].
///
/// Membaca data dari 'dart-define' yang disuntikkan saat proses build.
class DefaultAppConfig implements AppConfig {
  const DefaultAppConfig();

  @override
  String get prodEnv => 'prod';

  @override
  String get bridgeName => 'SapawargaChannel';

  @override
  String get deepLinkScheme => 'pocapp';

  @override
  String get deepLinkHost => 'payment';

  @override
  String get paymentEventName => 'paymentCompleted';

  @override
  String get appBarTitle => 'Hybrid WebView';

  // URL dasar produksi, disuntikkan via PROD_BASE_URL.
  static const String _prodBaseUrl = String.fromEnvironment(
    'PROD_BASE_URL',
    defaultValue:
        'https://test-sambara-i16sl1wq1-xzars-projects.vercel.app/beranda?data=pS9LkaUVso4Yv6eYOXzwR0-rwph4axBtM2vvcwBQ0Yu93rqVgUKh8zX_rQqqjh_gQTQiWqZeBbcyyNuj07T5tGBsLEkXf8mkRv3v5JfkTRzBKQJO4t_ZNQTjc7ZNWti1sTIMSuslp0sUuVzxs5fg6jZvXQYo1AFmySMk3OP_HYCZ35bIoDhnTwb_k5WaMiJvrIr_jhLhBcunr45uq94EJXMTeeah3LVcOQ7b1Z0SDTuusf9IfZwi6qxHqT_6m4crQ7s1ubJry7_bIPzPQ3XctmpupkQgUhxOqAAfuhVHwTY',
  );

  /// Daftar host yang diizinkan untuk dibuka langsung di WebView utama.
  /// Disuntikkan via WEBVIEW_ALLOWED_HOSTS (comma separated).
  static const String _allowedHostsEnv = String.fromEnvironment(
    'WEBVIEW_ALLOWED_HOSTS',
    defaultValue: 'test-sambara-i16sl1wq1-xzars-projects.vercel.app',
  );

  List<String> get _webViewAllowedHosts =>
      _allowedHostsEnv.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static const String _targetUrlOverride = String.fromEnvironment('TARGET_URL', defaultValue: '');

  @override
  String normalizeEnvironment(String rawValue) => prodEnv;

  @override
  String get currentEnvironment => prodEnv;

  @override
  bool get isTargetUrlOverridden => _targetUrlOverride.trim().isNotEmpty;

  @override
  String get targetUrl {
    final url = isTargetUrlOverridden
        ? _targetUrlOverride.trim()
        : urlForEnvironment(currentEnvironment);
    AppLogger.d("CONFIG: Final Target URL is $url");
    return url;
  }

  @override
  String urlForEnvironment(String environment) => _prodBaseUrl;

  @override
  bool isWebViewNavigationAllowed(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;

    final scheme = uri.scheme.toLowerCase();
    // Mengizinkan skema internal browser.
    if (scheme == 'about') return uri.toString().toLowerCase() == 'about:blank';
    if (scheme != 'http' && scheme != 'https') return false;

    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) return false;

    // Memeriksa apakah host URL masuk dalam daftar yang diizinkan (allowlist).
    return _webViewAllowedHosts.any((allowed) {
      final normalizedAllowed = allowed.trim().toLowerCase();
      return host == normalizedAllowed || host.endsWith('.$normalizedAllowed');
    });
  }
}
