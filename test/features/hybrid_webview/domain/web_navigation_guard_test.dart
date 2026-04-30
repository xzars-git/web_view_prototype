import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/config/app_config.dart';
import 'package:web_view_prototype/features/hybrid_webview/domain/web_navigation_guard.dart';

/// Unit test untuk memverifikasi kebijakan navigasi (Guard) aplikasi.
/// 
/// Memastikan bahwa sistem keamanan memblokir akses ke host luar dan
/// mengizinkan navigasi internal secara konsisten.
void main() {
  group('WebNavigationGuard Tests', () {
    const config = DefaultAppConfig();
    const guard = WebNavigationGuard(config: config);

    test('evaluate handles allowed URLs', () {
      // Skenario: Navigasi ke sub-halaman di dalam host aplikasi harus diperbolehkan.
      expect(
        guard.evaluate('https://test-sambara-i16sl1wq1-xzars-projects.vercel.app/home'),
        NavigationHandling.allowWebView,
      );
    });

    test('evaluate blocks external URLs', () {
      // Skenario: Link luar (DANA) harus diblokir agar tidak dimuat di WebView utama.
      // Catatan: Ini memaksa komunikasi via bridge postMessage untuk Custom Tabs.
      expect(
        guard.evaluate('https://m.dana.id'),
        NavigationHandling.openInCustomTab,
      );
    });
  });
}
