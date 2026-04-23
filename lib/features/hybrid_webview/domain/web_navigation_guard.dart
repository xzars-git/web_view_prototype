import '../../../config/custom_tabs_config.dart';

enum NavigationHandling { allowWebView, openInCustomTabs, block }

class WebNavigationGuard {
  const WebNavigationGuard();

  NavigationHandling evaluate(String rawUrl) {
    if (rawUrl.isEmpty) {
      return NavigationHandling.allowWebView;
    }

    if (CustomTabsConfig.shouldOpenInCustomTabs(rawUrl)) {
      return NavigationHandling.openInCustomTabs;
    }

    if (!CustomTabsConfig.isWebViewNavigationAllowed(rawUrl)) {
      return NavigationHandling.block;
    }

    return NavigationHandling.allowWebView;
  }
}
