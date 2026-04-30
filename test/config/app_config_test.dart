import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/config/app_config.dart';

/// Unit test untuk memverifikasi logika konfigurasi aplikasi.
/// 
/// Memastikan pemrosesan environment variable, normalisasi teks,
/// dan aturan allowlist host berjalan sesuai spesifikasi.
void main() {
  group('AppConfig Tests', () {
    const config = DefaultAppConfig();

    test('normalizeEnvironment always returns prod', () {
      // Skenario: Memastikan aplikasi hanya mengenal lingkungan produksi.
      expect(config.normalizeEnvironment('anything'), config.prodEnv);
    });

    test('isWebViewNavigationAllowed handles valid domains', () {
      // Skenario: Host yang ada di allowlist default harus diizinkan.
      expect(config.isWebViewNavigationAllowed('https://test-sambara-i16sl1wq1-xzars-projects.vercel.app'), true);
    });

    test('isWebViewNavigationAllowed blocks external domains', () {
      // Skenario: Host luar (misal: DANA) harus diblokir di WebView Utama demi keamanan.
      // (DANA harus dibuka melalui Bridge ke Custom Tabs, bukan navigasi langsung).
      expect(config.isWebViewNavigationAllowed('https://m.dana.id'), false);
    });
  });
}
