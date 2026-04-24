import '../../../config/app_config.dart';

enum NavigationHandling { allowWebView, block }

class WebNavigationGuard {
  final AppConfig _config;

  const WebNavigationGuard({required AppConfig config}) : _config = config;

  NavigationHandling evaluate(String rawUrl) {
    if (rawUrl.isEmpty) {
      return NavigationHandling.allowWebView;
    }

    if (!_config.isWebViewNavigationAllowed(rawUrl)) {
      return NavigationHandling.block;
    }

    return NavigationHandling.allowWebView;
  }
}
