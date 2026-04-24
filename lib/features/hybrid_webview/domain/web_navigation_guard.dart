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

    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return NavigationHandling.block;

    // 1. IZINKAN jika host masuk dalam Whitelist resmi aplikasi.
    if (_config.isWebViewNavigationAllowed(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    // 2. TOLERANSI PEMBAYARAN: Izinkan jika URL mengandung pola umum sistem pembayaran.
    // Ini penting untuk Kartu Kredit karena sering ada redirect ke bank (3D Secure).
    final paymentKeywords = [
      'finpay', 
      '3dsecure', 
      'verifypass', 
      'callback', 
      'api.bni', 
      'mandiri.co.id',
      'klikbca'
    ];
    
    final lowerUrl = rawUrl.toLowerCase();
    if (paymentKeywords.any((keyword) => lowerUrl.contains(keyword))) {
       return NavigationHandling.allowWebView;
    }

    // 3. BLOKIR jika tidak memenuhi kriteria di atas.
    return NavigationHandling.block;
  }
}
