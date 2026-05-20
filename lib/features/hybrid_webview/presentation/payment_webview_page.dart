import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/logger.dart';

/// Halaman payment terpisah yang di-push di atas Sambara.
/// Sambara tetap hidup di background — state tidak hilang.
/// Saat pop, Sambara langsung terlihat kembali di kondisi terakhir.
class PaymentWebViewPage extends StatefulWidget {
  const PaymentWebViewPage({
    super.key,
    required this.paymentUrl,
    required this.kodeBayar,
  });

  final String paymentUrl;
  final String kodeBayar;

  @override
  State<PaymentWebViewPage> createState() => _PaymentWebViewPageState();
}

class _PaymentWebViewPageState extends State<PaymentWebViewPage> {
  double _progress = 0;

  /// Coba buka deep link di external app.
  /// Jika app terinstall → buka app. Jika tidak → return false.
  /// TIDAK redirect ke store karena payment gateway punya web checkout fallback.
  Future<bool> _tryLaunchDeepLink(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    AppLogger.d("[PaymentPage] 🔗 Deep link: $scheme");

    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched) {
        AppLogger.d("[PaymentPage] ✅ App $scheme terbuka");
        return true;
      }
    } catch (e) {
      AppLogger.d("[PaymentPage] ⚠️ App $scheme tidak terinstall — web fallback aktif");
    }

    // App tidak terinstall → biarkan web checkout page yang handle
    AppLogger.d("[PaymentPage] 🌐 Fallback ke web checkout (app tidak ada)");
    return false;
  }

  /// Parse `intent://` URI → extract scheme asli.
  /// Format: intent://...#Intent;scheme=shopeepayid;package=com.shopee.pay;end
  Uri? _parseIntentUri(String rawUrl) {
    try {
      final schemeMatch = RegExp(r'scheme=([^;]+)').firstMatch(rawUrl);
      if (schemeMatch != null) {
        final targetScheme = schemeMatch.group(1)!;
        final intentPath = rawUrl.replaceFirst('intent://', '$targetScheme://').split('#Intent').first;
        return Uri.tryParse(intentPath);
      }
    } catch (e) {
      AppLogger.d("[PaymentPage] ⚠️ Intent URI parse error: $e");
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        AppLogger.d("[PaymentPage] 🔙 User back — returning to Sambara");
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pembayaran'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              AppLogger.d("[PaymentPage] 🔙 Back button — returning to Sambara");
              Navigator.of(context).pop();
            },
          ),
        ),
        body: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(widget.paymentUrl),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
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
                userAgent:
                    'Mozilla/5.0 (Linux; Android 10; Mobile) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/120.0.0.0 Mobile Safari/537.36',
              ),
              onLoadStart: (controller, url) {
                AppLogger.d("[PaymentPage] ▶️ Load: ${url?.host}${url?.path}");
              },
              onLoadStop: (controller, url) {
                AppLogger.d("[PaymentPage] ✅ Done: ${url?.host}${url?.path}");
              },
              onProgressChanged: (controller, progress) {
                setState(() => _progress = progress / 100.0);
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url;
                final rawUrl = uri?.toString() ?? '';

                if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

                // ═══ intent:// scheme ═══
                // Parse intent URI → extract scheme asli → coba launch app.
                if (rawUrl.startsWith('intent://')) {
                  AppLogger.d("[PaymentPage] 🔗 Intent URI detected");
                  final targetUri = _parseIntentUri(rawUrl);
                  if (targetUri != null) {
                    await _tryLaunchDeepLink(targetUri);
                  }
                  return NavigationActionPolicy.CANCEL;
                }

                // ═══ Non-http scheme (shopeepayid://, dana://, linkaja://, dll) ═══
                // Coba buka app. Kalau gagal, CANCEL saja — web checkout tetap aktif.
                if (!rawUrl.startsWith('http')) {
                  if (uri != null) {
                    await _tryLaunchDeepLink(uri);
                  }
                  return NavigationActionPolicy.CANCEL;
                }

                // ═══ HTTP/HTTPS — ALLOW semua di payment WebView ═══
                AppLogger.d("[PaymentPage] 🌐 ALLOW: ${uri?.host}${uri?.path}");
                return NavigationActionPolicy.ALLOW;
              },
              onReceivedError: (controller, request, error) {
                final errorUrl = request.url.toString();
                final description = error.description;
                AppLogger.d("[PaymentPage] ❌ Error: $description");

                // ERR_UNKNOWN_URL_SCHEME — deep link via JS window.location
                // yang menembus shouldOverrideUrlLoading.
                // Solusi: goBack() ke halaman HTTPS sebelumnya.
                // Web checkout page punya fallback sendiri.
                if (description.contains('ERR_UNKNOWN_URL_SCHEME')) {
                  AppLogger.d("[PaymentPage] 🔧 Unknown scheme → goBack ke web checkout");
                  // Coba launch app dulu (kalau terinstall)
                  final failedUri = Uri.tryParse(errorUrl);
                  if (failedUri != null && !errorUrl.startsWith('http')) {
                    _tryLaunchDeepLink(failedUri);
                  }
                  // Kembali ke halaman HTTPS sebelumnya (web checkout fallback)
                  controller.goBack();
                }
              },
              onCreateWindow: (controller, createWindowAction) async {
                final url = createWindowAction.request.url;
                if (url != null) {
                  AppLogger.d("[PaymentPage] 🪟 New window → redirect in-page: $url");
                  await controller.loadUrl(urlRequest: URLRequest(url: url));
                }
                return false;
              },
            ),
            if (_progress < 1)
              Align(
                alignment: Alignment.topCenter,
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
