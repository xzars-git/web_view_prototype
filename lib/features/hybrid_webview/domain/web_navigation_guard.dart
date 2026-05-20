import '../../../config/app_config.dart';
import '../../../config/logger.dart';

/// Describes how the controller should handle a navigation request.
enum NavigationHandling {
  /// Load the URL inside the main Sambara WebView.
  allowWebView,

  /// Open the URL in the in-app payment overlay (e-wallet pages).
  openInCustomTab,

  /// Hand off to the OS to open in an external application (deep links).
  externalApp,

  /// Block the navigation entirely.
  cancel,
}

/// Evaluates navigation URLs against config-driven rules and returns the
/// appropriate [NavigationHandling] decision.
///
/// Rule priority (first match wins):
/// 1. Non-HTTP scheme → [externalApp]
/// 2. Finpay result page → [allowWebView] (CC/VA payment return)
/// 3. Whitelisted host → [allowWebView]
/// 4. Everything else → [openInCustomTab] (payment overlay fallback)
class WebNavigationGuard {
  final AppConfig _config;

  const WebNavigationGuard({required AppConfig config}) : _config = config;

  NavigationHandling evaluate(String rawUrl) {
    if (rawUrl.isEmpty) return NavigationHandling.allowWebView;

    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return NavigationHandling.cancel;

    if (!uri.scheme.startsWith('http')) {
      return NavigationHandling.externalApp;
    }

    if (_config.isPaymentResultUrl(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    if (_config.isWebViewNavigationAllowed(rawUrl)) {
      return NavigationHandling.allowWebView;
    }

    AppLogger.d('[Guard] External host — routing to payment overlay: ${uri.host}');
    return NavigationHandling.openInCustomTab;
  }
}
