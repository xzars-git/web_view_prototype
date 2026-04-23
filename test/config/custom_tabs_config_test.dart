import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/config/custom_tabs_config.dart';

void main() {
  group('CustomTabsConfig', () {
    test('normalizeEnvironment fallback ke dev untuk nilai tidak valid', () {
      expect(CustomTabsConfig.normalizeEnvironment('staging'), CustomTabsConfig.devEnv);
      expect(CustomTabsConfig.normalizeEnvironment(' PROD '), CustomTabsConfig.prodEnv);
    });

    test('shouldOpenInCustomTabs hanya true untuk host+path+https yang cocok', () {
      expect(
        CustomTabsConfig.shouldOpenInCustomTabs('https://m.dana.id/n/ipg/new/inputphone'),
        isTrue,
      );

      expect(
        CustomTabsConfig.shouldOpenInCustomTabs('http://m.dana.id/n/ipg/new/inputphone'),
        isFalse,
      );

      expect(
        CustomTabsConfig.shouldOpenInCustomTabs('https://example.com/n/ipg/new/inputphone'),
        isFalse,
      );
    });

    test('isWebViewNavigationAllowed hanya true untuk host allowlist', () {
      expect(
        CustomTabsConfig.isWebViewNavigationAllowed('https://sambarav2.vercel.app/beranda'),
        isTrue,
      );

      expect(
        CustomTabsConfig.isWebViewNavigationAllowed('https://evil.example.com/beranda'),
        isFalse,
      );

      expect(CustomTabsConfig.isWebViewNavigationAllowed('about:blank'), isTrue);
    });
  });
}
