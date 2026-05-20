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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Kembali ke Sambara — pop route ini
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
                // Izinkan semua mixed content (HTTP di dalam HTTPS payment page)
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                supportZoom: true,
                builtInZoomControls: true,
                displayZoomControls: false,
                domStorageEnabled: true,
                databaseEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                // Izinkan popup dari payment gateway
                supportMultipleWindows: false,
                javaScriptCanOpenWindowsAutomatically: true,
                // Custom user agent agar payment gateway tidak block WebView
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

                // Non-http scheme (intent://, dana://, dll) → buka external app
                if (!rawUrl.startsWith('http')) {
                  AppLogger.d("[PaymentPage] 🔗 External scheme: ${uri?.scheme} → launchUrl");
                  if (uri != null) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                  return NavigationActionPolicy.CANCEL;
                }

                // Semua URL http/https diizinkan di dalam WebView payment
                AppLogger.d("[PaymentPage] 🌐 ALLOW: ${uri?.host}${uri?.path}");
                return NavigationActionPolicy.ALLOW;
              },
              onReceivedError: (controller, request, error) {
                AppLogger.d("[PaymentPage] ❌ Error: ${error.description}");
              },
              onCreateWindow: (controller, createWindowAction) async {
                // Handle popup/window baru di payment page — load di WebView yang sama
                final url = createWindowAction.request.url;
                if (url != null) {
                  AppLogger.d("[PaymentPage] 🪟 New window → redirect in-page: $url");
                  await controller.loadUrl(urlRequest: URLRequest(url: url));
                }
                return false;
              },
            ),
            // Progress bar
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
