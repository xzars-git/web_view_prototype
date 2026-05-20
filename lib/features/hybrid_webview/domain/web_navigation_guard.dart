import '../../../config/app_config.dart';
import '../../../config/logger.dart';

/// Jenis penanganan untuk navigasi URL di WebView.
enum NavigationHandling {
  /// Mengizinkan pemuatan di dalam WebView Sambara.
  allowWebView,

  /// Membuka URL di PaymentWebViewPage (route terpisah di atas Sambara).
  openPaymentPage,

  /// Membuka URL di aplikasi eksternal (untuk deep link skema non-http).
  externalApp,

  /// Membatalkan navigasi (URL tidak diizinkan).
  cancel,
}

/// Domain Logic untuk keamanan navigasi WebView Sambara.
///
/// Guard ini hanya berlaku untuk navigasi di WebView Sambara.
/// PaymentWebViewPage memiliki policy sendiri (ALLOW semua HTTP/HTTPS).
class WebNavigationGuard {
  final AppConfig _config;

  const WebNavigationGuard({required AppConfig config}) : _config = config;

  /// Mengevaluasi URL untuk menentukan tindakan navigasi.
  NavigationHandling evaluate(String rawUrl) {
    if (rawUrl.isEmpty) {
      return NavigationHandling.allowWebView;
    }

    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return NavigationHandling.cancel;

    // 1. Non-http scheme (pocapp://, intent://, dsb.) → External App
    if (!uri.scheme.startsWith('http')) {
      return NavigationHandling.externalApp;
    }

    // 2. Deteksi halaman hasil Finpay (CC/VA) → Allow di WebView Sambara
    if (_config.isPaymentResultUrl(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    // 3. Whitelist: domain Sambara + live.finpay.id → Allow di WebView Sambara
    if (_config.isWebViewNavigationAllowed(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    // 4. URL di luar whitelist → Push ke PaymentWebViewPage
    AppLogger.d("GUARD: 🌐 External host → push payment page: ${uri.host}");
    return NavigationHandling.openPaymentPage;
  }
}
