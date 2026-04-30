import '../../../config/app_config.dart';
import '../../../config/logger.dart';

/// Jenis penanganan untuk navigasi URL di WebView.
enum NavigationHandling {
  /// Mengizinkan pemuatan di dalam WebView utama.
  allowWebView,

  /// Mengalihkan navigasi ke Custom Tab (untuk host eksternal/pembayaran).
  openInCustomTab,
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
    if (uri == null) return NavigationHandling.openInCustomTab;

    // 1. Jika Host masuk dalam Whitelist (Domain utama/subdomain), izinkan di WebView.
    if (_config.isWebViewNavigationAllowed(rawUrl)) {
      AppLogger.d("GUARD: ✅ Whitelisted host, allowing in WebView");
      return NavigationHandling.allowWebView;
    }

    // 2. Jika Host di luar domain utama, otomatis anggap butuh Custom Tab (Anti-Stuck).
    // Ini menangani DANA, Shopee, atau link bank tanpa perlu hardcode namanya.
    AppLogger.d("GUARD: 📱 External host detected, diverting to Custom Tab");
    return NavigationHandling.openInCustomTab;
  }
}
