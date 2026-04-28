import '../../../config/app_config.dart';

/// Jenis penanganan untuk navigasi URL di WebView.
enum NavigationHandling {
  /// Mengizinkan pemuatan di dalam WebView utama.
  allowWebView,

  /// Memblokir pemuatan URL (untuk host eksternal yang tidak dikenal).
  block,
}

/// Domain Logic untuk keamanan navigasi WebView.
///
/// Evaluasi URL berdasarkan:
/// 1. Whitelist domain resmi (dari AppConfig)
/// 2. Payment tolerance keywords (untuk 3D Secure bank redirects)
/// 3. Block semuanya yang tidak memenuhi kriteria di atas
class WebNavigationGuard {
  final AppConfig _config;

  const WebNavigationGuard({required AppConfig config}) : _config = config;

  /// Mengevaluasi URL untuk navigasi yang aman.
  NavigationHandling evaluate(String rawUrl) {
    if (rawUrl.isEmpty) {
      return NavigationHandling.allowWebView;
    }

    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return NavigationHandling.block;

    // 1. WHITELIST: Izinkan jika domain ada di allow list
    if (_config.isWebViewNavigationAllowed(rawUrl)) {
      print("DEBUG_GUARD: ✅ URL passed whitelist check");
      return NavigationHandling.allowWebView;
    }

    // 2. PAYMENT TOLERANCE: Izinkan payment gateway & 3D Secure redirects
    final paymentKeywords = [
      'finpay',
      '3dsecure',
      'verifypass',
      'callback',
      'api.bni',
      'mandiri.co.id',
      'klikbca',
    ];

    final lowerUrl = rawUrl.toLowerCase();
    if (paymentKeywords.any((keyword) => lowerUrl.contains(keyword))) {
      print("DEBUG_GUARD: ✅ URL passed payment tolerance check");
      return NavigationHandling.allowWebView;
    }

    // 3. BLOCK: Semua URL lain yang tidak masuk kategori di atas
    print("DEBUG_GUARD: 🛑 URL BLOCKED - not in whitelist or payment keywords");
    return NavigationHandling.block;
  }
}
