import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/logger.dart';

/// Halaman WebView untuk payment gateway (DANA, ShopeePay, LinkAja, dll).
///
/// Di-push di atas Sambara via [Navigator.push] sehingga Sambara tetap
/// hidup di background dengan state 100% preserved.
///
/// Menangani 3 jenis navigasi:
/// - HTTP/HTTPS: ALLOW semua (payment gateway internal)
/// - intent://: Parse scheme asli → coba buka app via [launchUrl]
/// - Custom scheme (shopeepayid://, dana://): Coba buka app, fallback ke web
class PaymentWebViewPage extends StatefulWidget {
  const PaymentWebViewPage({super.key, required this.paymentUrl});

  /// URL halaman checkout payment gateway.
  final String paymentUrl;

  @override
  State<PaymentWebViewPage> createState() => _PaymentWebViewPageState();
}

class _PaymentWebViewPageState extends State<PaymentWebViewPage> {
  double _progress = 0;

  /// Mencoba membuka deep link di aplikasi eksternal.
  ///
  /// Jika app terinstall → [launchUrl] berhasil → return true.
  /// Jika tidak terinstall → return false → web checkout fallback
  /// yang disediakan payment gateway akan tetap berfungsi.
  Future<bool> _tryLaunchDeepLink(Uri uri) async {
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched) return true;
    } catch (_) {
      // App tidak terinstall — web checkout akan handle
    }
    return false;
  }

  /// Parse Android `intent://` URI untuk mengekstrak scheme asli.
  ///
  /// Contoh input:
  /// `intent://...#Intent;scheme=shopeepayid;package=com.shopee.pay;end`
  ///
  /// Mengekstrak `scheme=shopeepayid` dan merekonstruksi URI
  /// menjadi `shopeepayid://...` agar bisa di-launch.
  Uri? _parseIntentUri(String rawUrl) {
    try {
      final schemeMatch = RegExp(r'scheme=([^;]+)').firstMatch(rawUrl);
      if (schemeMatch != null) {
        final targetScheme = schemeMatch.group(1)!;
        final intentPath = rawUrl
            .replaceFirst('intent://', '$targetScheme://')
            .split('#Intent')
            .first;
        return Uri.tryParse(intentPath);
      }
    } catch (e) {
      AppLogger.e("Intent URI parse failed", e);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Intercept back gesture — pop secara manual
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pembayaran'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.paymentUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
                // Izinkan mixed content (HTTP di dalam HTTPS payment page)
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                supportZoom: true,
                builtInZoomControls: true,
                displayZoomControls: false,
                domStorageEnabled: true,
                databaseEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                supportMultipleWindows: false,
                javaScriptCanOpenWindowsAutomatically: true,
                // User agent standar agar payment gateway tidak block WebView
                userAgent:
                    'Mozilla/5.0 (Linux; Android 10; Mobile) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/120.0.0.0 Mobile Safari/537.36',
              ),
              onProgressChanged: (controller, progress) {
                setState(() => _progress = progress / 100.0);
              },

              /// Intercept semua navigasi URL di payment WebView.
              ///
              /// - intent:// → parse scheme asli → coba buka app
              /// - Non-http (shopeepayid://, dana://) → coba buka app
              /// - HTTP/HTTPS → ALLOW (payment gateway internal)
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url;
                final rawUrl = uri?.toString() ?? '';
                if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

                // Intent URI: extract scheme asli → coba launch app
                if (rawUrl.startsWith('intent://')) {
                  final targetUri = _parseIntentUri(rawUrl);
                  if (targetUri != null) await _tryLaunchDeepLink(targetUri);
                  return NavigationActionPolicy.CANCEL;
                }

                // Deep link scheme: coba buka app, CANCEL navigasi WebView
                if (!rawUrl.startsWith('http')) {
                  if (uri != null) await _tryLaunchDeepLink(uri);
                  return NavigationActionPolicy.CANCEL;
                }

                // HTTP/HTTPS: izinkan semua di payment WebView
                return NavigationActionPolicy.ALLOW;
              },

              /// Handle error loading — terutama ERR_UNKNOWN_URL_SCHEME.
              ///
              /// Terjadi saat deep link dipicu via JavaScript (window.location)
              /// yang menembus shouldOverrideUrlLoading pada beberapa device.
              /// Solusi: goBack() ke halaman HTTPS sebelumnya.
              onReceivedError: (controller, request, error) {
                final errorUrl = request.url.toString();
                final description = error.description;

                if (description.contains('ERR_UNKNOWN_URL_SCHEME')) {
                  AppLogger.d("[Payment] ERR_UNKNOWN_URL_SCHEME → goBack to web checkout");
                  final failedUri = Uri.tryParse(errorUrl);
                  if (failedUri != null && !errorUrl.startsWith('http')) {
                    _tryLaunchDeepLink(failedUri);
                  }
                  controller.goBack();
                }
              },

              /// Handle popup/window baru dari payment page.
              /// Redirect ke WebView yang sama (single window mode).
              onCreateWindow: (controller, createWindowAction) async {
                final url = createWindowAction.request.url;
                if (url != null) {
                  await controller.loadUrl(urlRequest: URLRequest(url: url));
                }
                return false;
              },
            ),

            // Progress bar di bagian atas
            if (_progress < 1)
              Align(
                alignment: Alignment.topCenter,
                child: LinearProgressIndicator(value: _progress, minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }
}
