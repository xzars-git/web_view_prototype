import '../../../config/app_config.dart';
import '../../../config/logger.dart';

/// Jenis penanganan untuk navigasi URL di WebView.
enum NavigationHandling {
  /// Mengizinkan pemuatan di dalam WebView utama.
  allowWebView,

  /// Membuka URL di dalam WebView utama (Single WebView Strategy — dulunya Custom Tab).
  openInCustomTab,

  /// Membuka URL di aplikasi eksternal (untuk deep link skema lain).
  externalApp,

  /// Membatalkan navigasi (untuk host eksternal/non-whitelist).
  cancel,
}

/// Domain Logic untuk keamanan navigasi WebView.
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

    // 1. Non-http scheme (pocapp://, dsb.) -> External App
    if (!uri.scheme.startsWith('http')) {
      return NavigationHandling.externalApp;
    }

    // 2. Deteksi Halaman Hasil Finpay (Jalur A) -> Allow di WebView
    if (_config.isPaymentResultUrl(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    // 3. Whitelist check: PKB domain + live.finpay.id -> Allow di WebView
    if (_config.isWebViewNavigationAllowed(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    // 4. URL http/https di luar whitelist -> Buka di Custom Tab (Fallback)
    AppLogger.d("GUARD: 🌐 External host detected → akan di-load in-app: ${uri.host}");
    return NavigationHandling.openInCustomTab;
  }
}
