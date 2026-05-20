import '../../../config/app_config.dart';

/// Jenis penanganan untuk navigasi URL di WebView Sambara.
enum NavigationHandling {
  /// Izinkan dimuat di WebView Sambara (domain dalam whitelist).
  allowWebView,

  /// Buka di [PaymentWebViewPage] (domain di luar whitelist).
  openPaymentPage,

  /// Buka di aplikasi eksternal (deep link non-http).
  externalApp,

  /// Tolak navigasi.
  cancel,
}

/// Domain logic untuk keamanan navigasi WebView Sambara.
///
/// Guard ini mengevaluasi setiap URL yang dimuat di WebView Sambara
/// dan menentukan cara penangannya berdasarkan whitelist dan pola URL.
///
/// Catatan: [PaymentWebViewPage] memiliki policy sendiri — ALLOW semua HTTP/HTTPS.
/// Guard ini HANYA berlaku untuk navigasi di WebView utama Sambara.
class WebNavigationGuard {
  final AppConfig _config;

  const WebNavigationGuard({required AppConfig config}) : _config = config;

  /// Evaluasi [rawUrl] dan tentukan [NavigationHandling] yang sesuai.
  ///
  /// Urutan pengecekan (penting):
  /// 1. Non-http scheme → [externalApp]
  /// 2. Payment result URL (Finpay CC/VA) → [allowWebView]
  /// 3. Whitelist domain (Sambara + Finpay) → [allowWebView]
  /// 4. Domain lainnya → [openPaymentPage]
  NavigationHandling evaluate(String rawUrl) {
    if (rawUrl.isEmpty) return NavigationHandling.allowWebView;

    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return NavigationHandling.cancel;

    // Non-http scheme (pocapp://, intent://, dsb.) → External App
    if (!uri.scheme.startsWith('http')) {
      return NavigationHandling.externalApp;
    }

    // Halaman hasil pembayaran Finpay (CC/VA return URL)
    if (_config.isPaymentResultUrl(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    // Domain dalam whitelist (Sambara + live.finpay.id)
    if (_config.isWebViewNavigationAllowed(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    // Domain di luar whitelist → Push ke PaymentWebViewPage
    return NavigationHandling.openPaymentPage;
  }
}
