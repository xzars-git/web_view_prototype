import 'logger.dart';

/// Abstraksi untuk konfigurasi aplikasi.
abstract class AppConfig {
  String get prodEnv;
  String get currentEnvironment;
  String get targetUrl;
  String get bridgeName;

  String get deepLinkScheme;
  String get deepLinkHost;
  String get paymentEventName;
  String get appBarTitle;
  bool get isTargetUrlOverridden;

  String normalizeEnvironment(String rawValue);
  String urlForEnvironment(String environment);

  /// Mengecek apakah sebuah URL diizinkan dibuka di dalam WebView utama.
  bool isWebViewNavigationAllowed(String rawUrl);

  /// Mengecek apakah URL adalah halaman hasil pembayaran Finpay (CC/VA).
  /// Digunakan di handleNavigation untuk trigger paymentCompleted saat
  /// Finpay redirect ke halaman sukses/gagal setelah proses bayar.
  bool isPaymentResultUrl(String rawUrl);
}

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

  static const String _prodBaseUrl = String.fromEnvironment(
    'PROD_BASE_URL',
    defaultValue:
        'https://test-sambara.vercel.app/beranda?data=pS9LkaUVso4Yv6eYOXzwR0-rwph4axBtM2vvcwBQ0Yu93rqVgUKh8zX_rQqqjh_gQTQiWqZeBbcyyNuj07T5tGBsLEkXf8mkRv3v5JfkTRzBKQJO4t_ZNQTjc7ZNWti1sTIMSuslp0sUuVzxs5fg6jZvXQYo1AFmySMk3OP_HYCZ35bIoDhnTwb_k5WaMiJvrIr_jhLhBcunr45uq94EJXMTeeah3LVcOQ7b1Z0SDTuusf9IfZwi6qxHqT_6m4crQ7s1ubJry7_bIPzPQ3XctmpupkQgUhxOqAAfuhVHwTY',
  );

  static const String _allowedHostsEnv = String.fromEnvironment(
    'WEBVIEW_ALLOWED_HOSTS',
    // live.finpay.id: halaman CC/VA Finpay yang dibuka via window.location.href (Jalur A)
    defaultValue: 'test-sambara.vercel.app,live.finpay.id',
  );

  List<String> get _webViewAllowedHosts =>
      _allowedHostsEnv.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  @override
  String normalizeEnvironment(String rawValue) => prodEnv;
  @override
  String get currentEnvironment => prodEnv;
  @override
  bool get isTargetUrlOverridden => false;

  @override
  String get targetUrl {
    AppLogger.d("CONFIG: Final Target URL is $_prodBaseUrl");
    return _prodBaseUrl;
  }

  @override
  String urlForEnvironment(String environment) => _prodBaseUrl;

  @override
  bool isWebViewNavigationAllowed(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;
    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) return false;

    // Izinkan domain utama dan subdomainnya
    return _webViewAllowedHosts.any((allowed) {
      final normalizedAllowed = allowed.trim().toLowerCase();
      return host == normalizedAllowed || host.endsWith('.$normalizedAllowed');
    });
  }

  /// Mendeteksi halaman hasil pembayaran Finpay berdasarkan pola path.
  /// Finpay redirect ke live.finpay.id/pg/payment/card/result/{status}
  /// setelah proses bayar CC/VA selesai (sukses maupun gagal).
  @override
  bool isPaymentResultUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    // Pola return URL Finpay yang terverifikasi dari actual redirect:
    // - /pg/payment/card/result/success
    // - /pg/payment/card/result/failed
    // - /pg/payment/card/result/pending
    return path.contains('/payment/card/result/') ||
        path.contains('/payment/result/') ||
        path.contains('/payment/return') ||
        path.contains('/payment/callback') ||
        path.contains('/payment/success') ||
        path.contains('/payment/failed');
  }
}
