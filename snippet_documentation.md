# Snippet Code — Host App Payment Integration (Single WebView Strategy)

> **Versi:** 2026-05-20 (v4 — Single WebView, Foreground Polling, Dio)
> **File sumber:** `hybrid_webview_controller.dart`
> **Package:** `flutter_inappwebview`, `dio`, `url_launcher`, `app_links`
> **Strategi:** Tidak pakai Custom Tab — payment page di-load langsung di WebView yang sama.

---

## Mengapa Single WebView?

Custom Tab menyebabkan app masuk background → OS Android throttle network → polling gagal.
Dengan load payment URL di WebView yang sama, app tetap foreground dan polling stabil.

---

## 1. Menerima Trigger dari Console Log

```json
{ "type": "finpay_navigation", "url": "https://m.dana.id/...", "kodeBayar": "3222002005265231" }
```

```dart
void handleConsoleMessage(String message) {
  if (!message.contains('finpay_navigation')) return;

  final Map<String, dynamic> json = jsonDecode(message);
  if (json['type'] != 'finpay_navigation') return;

  final String? url = json['url']?.toString().trim();
  final String? kodeBayar = json['kodeBayar']?.toString().trim();

  if (url == null || url.isEmpty) return;

  _activeKodeBayar = kodeBayar;
  _isOnPaymentPage = true;

  // Load payment page di WebView yang SAMA (bukan Custom Tab)
  _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  _startPaymentStatusPolling();
}
```

---

## 2. Foreground Polling (Dio, 5 detik, max 15 menit)

```dart
final Dio _dio = Dio(BaseOptions(
  baseUrl: 'http://192.168.99.46:8700',
  connectTimeout: const Duration(seconds: 5),
  receiveTimeout: const Duration(seconds: 5),
  contentType: 'application/json',
));

static const Duration _pollingInterval = Duration(seconds: 5);
static const Duration _pollingMaxDuration = Duration(minutes: 15);

Future<void> _checkPaymentStatus() async {
  final response = await _dio.post<Map<String, dynamic>>(
    '/api/check-dummy-payment-status',
    data: {'kodeBayar': _activeKodeBayar},
  );

  if (response.statusCode == 200 && response.data != null) {
    final body = response.data!;
    final bool isPaid = body['success'] == true && body['code'] == '0000';

    if (isPaid) {
      _stopPaymentStatusPolling();
      await _returnToSambara();  // Kembali ke halaman Sambara
      Future.delayed(Duration(milliseconds: 1500), () {
        _notifyPaymentCompleted();  // Dispatch event setelah halaman loaded
      });
    }
  }
}
```

### API Response (contoh sukses):

```json
{
    "success": true,
    "code": "0000",
    "message": "Tagihan dengan kode bayar 3222002005265231 sudah berhasil dibayar",
    "param": { "kodeBayar": "3222002005265231" }
}
```

---

## 3. Back Button → paymentHold

```dart
Future<void> smartGoBack() async {
  if (_isOnPaymentPage) {
    _stopPaymentStatusPolling();
    _notifyPaymentHold();       // Beritahu PKB user membatalkan
    await _returnToSambara();   // Kembali ke halaman Sambara
    return;
  }
  // Navigasi back biasa di Sambara
  if (await _webViewController!.canGoBack()) {
    await _webViewController!.goBack();
  }
}
```

---

## 4. Navigation Guard Bypass

Saat `_isOnPaymentPage == true`, SEMUA navigasi diizinkan di WebView (payment redirect, etc):

```dart
Future<NavigationActionPolicy> handleNavigation(NavigationAction action) async {
  if (_isOnPaymentPage) {
    return NavigationActionPolicy.ALLOW;  // Bypass guard
  }
  // Normal guard logic...
}
```

---

## Alur Lengkap

```
PKB console.log({ type:"finpay_navigation", url, kodeBayar })
  │
  ▼
Host: handleConsoleMessage() → _isOnPaymentPage = true
  │
  ├─ loadUrl(paymentUrl) → WebView menampilkan halaman pembayaran
  ├─ _startPaymentStatusPolling() → tiap 5 detik, max 15 menit
  │
  ├─── isPaid (code=0000) ─► _returnToSambara() → dispatch paymentCompleted
  │
  ├─── User tekan Back ────► _notifyPaymentHold() → _returnToSambara()
  │
  └─── 15 menit habis ─────► _stopPaymentStatusPolling()
```

---

## Events ke PKB

| Event | Payload | Kapan |
|-------|---------|-------|
| `paymentCompleted` | `{ts, kodeBayar, status:'success'}` | API polling return `code:"0000"` |
| `paymentHold` | `{ts, kodeBayar}` | User tekan Back di halaman pembayaran |
