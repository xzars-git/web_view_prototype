import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/config/app_config.dart';

void main() {
  group('AppConfig Tests', () {
    const config = DefaultAppConfig();

    test('normalizeEnvironment handles various inputs', () {
      expect(config.normalizeEnvironment('PROD'), config.prodEnv);
      expect(config.normalizeEnvironment('  dev  '), config.devEnv);
    });

    test('isWebViewNavigationAllowed handles valid domains', () {
      expect(config.isWebViewNavigationAllowed('https://sambarav2.vercel.app'), true);
      expect(config.isWebViewNavigationAllowed('https://test.sambarav2.vercel.app'), true);
      expect(config.isWebViewNavigationAllowed('https://m.dana.id'), true);
    });

    test('isWebViewNavigationAllowed blocks invalid domains', () {
      expect(config.isWebViewNavigationAllowed('https://evil.com'), false);
      expect(config.isWebViewNavigationAllowed('http://sambarav2.vercel.app'), true); // Allowed in config
    });

    test('shouldOpenInCustomTabs detects payment URLs', () {
      expect(
        config.shouldOpenInCustomTabs('https://m.dana.id/n/ipg/new/inputphone'),
        true,
      );
      expect(
        config.shouldOpenInCustomTabs('https://m.dana.id/other'),
        false,
      );
    });
  });
}
