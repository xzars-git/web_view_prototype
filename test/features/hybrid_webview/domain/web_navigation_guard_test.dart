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

    test('evaluate handles custom tabs URLs', () {
      expect(
        guard.evaluate('https://m.dana.id/n/ipg/new/inputphone'),
        NavigationHandling.openInCustomTabs,
      );
    });

    test('evaluate handles blocked URLs', () {
      expect(
        guard.evaluate('https://unknown-domain.com'),
        NavigationHandling.block,
      );
    });
  });
}
