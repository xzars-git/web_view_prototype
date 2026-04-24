import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/config/app_config.dart';
import 'package:web_view_prototype/features/hybrid_webview/domain/web_navigation_guard.dart';

void main() {
  group('WebNavigationGuard Tests', () {
    const config = DefaultAppConfig();
    const guard = WebNavigationGuard(config: config);

    test('evaluate handles allowed URLs', () {
      expect(
        guard.evaluate('https://sambarav2.vercel.app/home'),
        NavigationHandling.allowWebView,
      );
    });

    test('evaluate blocks external URLs', () {
      expect(
        guard.evaluate('https://m.dana.id'),
        NavigationHandling.block,
      );
    });
  });
}
