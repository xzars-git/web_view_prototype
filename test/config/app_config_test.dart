import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/config/app_config.dart';

void main() {
  group('AppConfig Tests', () {
    const config = DefaultAppConfig();

    test('normalizeEnvironment always returns prod', () {
      expect(config.normalizeEnvironment('anything'), config.prodEnv);
    });

    test('isWebViewNavigationAllowed handles valid domains', () {
      expect(config.isWebViewNavigationAllowed('https://sambarav2.vercel.app'), true);
      expect(config.isWebViewNavigationAllowed('https://10.44.121.12'), true);
    });

    test('isWebViewNavigationAllowed blocks external domains', () {
      expect(config.isWebViewNavigationAllowed('https://m.dana.id'), false);
    });
  });
}
