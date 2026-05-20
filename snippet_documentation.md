# Snippet Code — Host App Payment Integration

> **Versi:** 2026-05-20 (v4 — InAppWebView overlay, Dio polling, tanpa Custom Tab)
> **File sumber:** `hybrid_webview_controller.dart`, `hybrid_webview_page.dart`

---

## 1. Parse Console Message dari Sambara

```dart
void handleConsoleMessage(String message) {
  final preview = message.length > 120 ? '${message.substring(0, 120)}...' : message;
  AppLogger.d("[JS] $preview");

  if (!message.contains('finpay_navigation')) return;

  try {
    final Map<String, dynamic> json = jsonDecode(message);
    if (json['type'] != 'finpay_navigation') return;

    final String? url = json['url']?.toString().trim();
    final String? kodeBayar = json['kodeBayar']?.toString().trim();

    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;

    _activeKodeBayar = kodeBayar;
    _webViewController?.stopLoading();
    _openPaymentWebView(url);
  } catch (e) {
    AppLogger.d("[Console] JSON parse error: $e");
  }
}
```

---

## 2. Buka / Tutup Payment Overlay

```dart
void _openPaymentWebView(String url) {
  value = value.copyWith(paymentUrl: url);  // Stack tampilkan overlay
  _notifyPaymentTabOpened();
  _startPaymentStatusPolling();
}

void onPaymentWebViewClosedByUser() {
  _stopPaymentStatusPolling();
  value = value.copyWith(paymentUrl: null); // Stack sembunyikan overlay
  _notifyPaymentHold();
  _activeKodeBayar = null;
}

void _closePaymentWebView() {
  value = value.copyWith(paymentUrl: null);
}
```

---

## 3. Payment Overlay Widget

```dart
// Di Stack (hybrid_webview_page.dart):
if (state.paymentUrl != null)
  _PaymentWebViewOverlay(
    url: state.paymentUrl!,
    onClose: _controller.onPaymentWebViewClosedByUser,
  ),
```

Overlay menggunakan UA tanpa `" wv"` agar tidak dideteksi sebagai WebView:

```dart
// Cache UA — hanya dibuat sekali per sesi app
String? _cachedUserAgent;

Future<String> _getCleanUserAgent() async {
  if (_cachedUserAgent != null) return _cachedUserAgent!;
  final webView = HeadlessInAppWebView(initialUrlRequest: URLRequest(url: WebUri('about:blank')));
  await webView.run();
  final ua = await webView.webViewController?.evaluateJavascript(source: 'navigator.userAgent') as String? ?? '';
  await webView.dispose();
  _cachedUserAgent = ua.replaceAll(' wv', '');
  return _cachedUserAgent!;
}
```

Deep link native app di dalam overlay:

```dart
shouldOverrideUrlLoading: (controller, navigationAction) async {
  final uri = navigationAction.request.url;
  if (uri == null) return NavigationActionPolicy.CANCEL;
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    // Shopee, DANA, dll. — catchError untuk handle app tidak terinstall
    await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    return NavigationActionPolicy.CANCEL;
  }
  return NavigationActionPolicy.ALLOW;
},
```

---

## 4. Polling Status Pembayaran (Dio)

```dart
static const Duration _pollingInterval = Duration(seconds: 10);
static const Duration _pollingMaxDuration = Duration(minutes: 15);

void _startPaymentStatusPolling() {
  if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) return;
  _stopPaymentStatusPolling();
  _dio.options.baseUrl = _config.paymentBaseUrl;

  _pollingTimer = Timer.periodic(_pollingInterval, (_) async {
    if (_activeKodeBayar == null) { _stopPaymentStatusPolling(); return; }
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/check-dummy-payment-status',
        data: {'kodeBayar': _activeKodeBayar},
      );
      if (response.statusCode == 200 && response.data != null) {
        final body = response.data!;
        final bool isPaid = body['success'] == true && body['code'] == '0000';
        if (isPaid) {
          _stopPaymentStatusPolling();
          _closePaymentWebView();
          _notifyPaymentSuccess();
          _activeKodeBayar = null;
        }
      }
    } catch (e) {
      AppLogger.d("[Polling] Error: $e");
    }
  });

  // Auto-stop setelah 15 menit
  _pollingMaxTimer = Timer(_pollingMaxDuration, () {
    _stopPaymentStatusPolling();
    _closePaymentWebView();
    _notifyPaymentHold();
    _activeKodeBayar = null;
  });
}
```

---

## 5. Dispatch Events ke Sambara

```dart
void _dispatchPaymentEvent(String eventName) {
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('$eventName', {detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}'}}));",
  );
}

void _notifyPaymentHold() => _dispatchPaymentEvent('paymentHold');
void _notifyPaymentTabOpened() => _dispatchPaymentEvent('paymentTabOpened');
void _notifyPaymentSuccess() => _dispatchPaymentEvent('paymentSuccess');
```

---

## 6. Deep Link Return dari Finpay

```dart
void _initDeepLinks() {
  _appLinks = AppLinks();
  _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
    if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
      if (uri.path.contains('return') || uri.path.contains('callback')) {
        _stopPaymentStatusPolling();
        _closePaymentWebView();
        _notifyPaymentSuccess();
        _activeKodeBayar = null;
      }
    }
  });
}
```

---

## Ringkasan Alur

```
Sambara: console.log({ type:"finpay_navigation", url, kodeBayar })
  │
  ▼
Host: handleConsoleMessage() → validasi HTTPS → _openPaymentWebView(url)
  │
  ├─ state.paymentUrl = url → Stack tampilkan overlay
  ├─ dispatch paymentTabOpened → Sambara stop timer
  └─ polling setiap 10 detik (max 15 menit)
       │
       ├── isPaid (code=0000) → tutup overlay + paymentSuccess
       ├── User tekan X/back  → tutup overlay + paymentHold
       ├── Deep link pocapp:// → tutup overlay + paymentSuccess
       └── 15 menit habis     → tutup overlay + paymentHold
```

---

## Events ke Sambara

| Event | Payload | Kapan |
|-------|---------|-------|
| `paymentTabOpened` | `{ts, kodeBayar}` | Overlay buka |
| `paymentHold` | `{ts, kodeBayar}` | User tutup / timeout |
| `paymentSuccess` | `{ts, kodeBayar}` | Lunas (API / deep link) |
