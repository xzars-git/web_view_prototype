import '../../../config/app_config.dart';

/// Jenis penanganan untuk navigasi URL di WebView.
enum NavigationHandling { 
  /// Mengizinkan pemuatan di dalam WebView utama.
  allowWebView, 
  
  /// Memblokir pemuatan URL (untuk host eksternal yang tidak dikenal).
  block 
}

/// Domain Logic untuk keamanan navigasi WebView.
/// 
/// Class ini murni berisi aturan bisnis untuk mengevaluasi apakah sebuah URL
/// aman atau berbahaya bagi aplikasi.
class WebNavigationGuard {
  final AppConfig _config;

  const WebNavigationGuard({required AppConfig config}) : _config = config;

  /// Mengevaluasi URL dan menentukan tindakan yang harus diambil.
  NavigationHandling evaluate(String rawUrl) {
    // Mengizinkan URL kosong (biasanya terjadi saat inisialisasi).
    if (rawUrl.isEmpty) {
      return NavigationHandling.allowWebView;
    }

    // Memeriksa apakah URL termasuk dalam host aplikasi yang diizinkan.
    if (!_config.isWebViewNavigationAllowed(rawUrl)) {
      return NavigationHandling.block;
    }

    return NavigationHandling.allowWebView;
  }
}
