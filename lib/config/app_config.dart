import 'logger.dart';

/// Abstraksi untuk konfigurasi aplikasi.
abstract class AppConfig {
  String get prodEnv;
  String get currentEnvironment;
  String get targetUrl;

  String get appBarTitle;
  bool get isTargetUrlOverridden;

  String normalizeEnvironment(String rawValue);
  String urlForEnvironment(String environment);

  /// Mengecek apakah sebuah URL diizinkan dibuka di dalam WebView utama.
  bool isWebViewNavigationAllowed(String rawUrl);

  /// Mengecek apakah URL adalah halaman hasil pembayaran Finpay (CC/VA).
  /// Digunakan di WebNavigationGuard untuk mengizinkan redirect result page di WebView utama.
  bool isPaymentResultUrl(String rawUrl);
}

class DefaultAppConfig implements AppConfig {
  const DefaultAppConfig();

  @override
  String get prodEnv => 'prod';

  @override
  String get appBarTitle => 'Hybrid WebView';

  /// URL base produksi untuk WebView utama.
  ///
  /// PENTING: Ganti defaultValue dengan URL produksi yang sebenarnya sebelum
  /// melakukan build untuk production. URL di bawah ini hanya untuk testing.
  ///
  /// Alternatif: Gunakan build parameter --dart-define=PROD_BASE_URL=<url_actual>
  /// untuk mengganti URL tanpa memodifikasi kode source.
  ///
  /// Contoh:
  /// flutter build apk --dart-define=PROD_BASE_URL=https://sambara.vercel.app/beranda
  static const String _prodBaseUrl = String.fromEnvironment(
    'PROD_BASE_URL',
    defaultValue:
        'https://test-sambara.vercel.app/beranda?data=fq2c1H5HSzl7bRDkuNxs-egYQwtgLJLS9l5VHRQZb7D1YmUSxaxow--P0WVfPH7Z0sDueotDmnuVr_Awc49DL7W_teRSVOxpbTy1HnWuFWuhv-uNYg09ccbNW0vYNaUkm2PQ6IpJxFFHGyYGtwDBQSY8H2LbRSNA1dnPRqw6_6cfPIsrfsjL4xfy0pL84Vhfsu3-mnS5OPNVrjwHhXQow_VVMjTTSx2hte-stLsn5cTG56oN7sXlt_pJf69fnGpsoE2k_BvdyprzdLN50a7Fun_2V7GuGjT_9bii7H02AT7XjkwpyJTdJCb82mtmA_7M',
  );

  static const String _allowedHostsEnv = String.fromEnvironment(
    'WEBVIEW_ALLOWED_HOSTS',
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
