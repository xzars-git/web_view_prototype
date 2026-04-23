import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/features/hybrid_webview/domain/web_navigation_guard.dart';

void main() {
  group('WebNavigationGuard', () {
    const guard = WebNavigationGuard();

    test('open custom tabs untuk URL payment yang valid', () {
      final decision = guard.evaluate('https://m.dana.id/n/ipg/new/inputphone');
      expect(decision, NavigationHandling.openInCustomTabs);
    });

    test('block untuk host non-allowlist', () {
      final decision = guard.evaluate('https://untrusted.example/path');
      expect(decision, NavigationHandling.block);
    });

    test('allow untuk host internal yang diizinkan', () {
      final decision = guard.evaluate('https://sambarav2.vercel.app/beranda');
      expect(decision, NavigationHandling.allowWebView);
    });
  });
}
