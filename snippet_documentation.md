# Snippet Code — Host App Payment Integration (Stack WebView Strategy)

> **Versi:** 2026-05-20 (v5 — Stack Navigator, Foreground Polling, Dio)
> **File sumber:** `hybrid_webview_controller.dart`, `payment_webview_page.dart`
> **Package:** `flutter_inappwebview`, `dio`, `url_launcher`, `app_links`
> **Strategi:** PaymentWebViewPage di-push di atas Sambara via Navigator stack.

---

## Arsitektur: Stack WebView Strategy

```
Flutter Navigator Stack:
┌─────────────────────────────────┐  ← PaymentWebViewPage (ROUTE BARU)
│  WebView: https://m.dana.id/... │    - Menampilkan halaman payment gateway
│  ↕ Back → pop() ke Sambara     │    - Semua redirect ALLOW di dalam
│  ↕ isPaid → auto pop()         │    - Non-http scheme → launchUrl external
└─────────────────────────────────┘
┌─────────────────────────────────┐  ← HybridWebViewPage (TETAP HIDUP)
│  WebView: Sambara               │    - State 100% dipertahankan
│  (tidak di-dispose/reload)      │    - Menerima event JS setelah pop
│  Polling Dio tetap jalan ✅     │    - Controller milik layer ini
└─────────────────────────────────┘
```

### Kenapa Stack, Bukan Replace URL?

| Replace URL (lama) | Stack Navigator (sekarang) |
|---|---|
| Load payment di WebView yang sama | Push route baru di atas Sambara |
| Sambara ter-reload saat kembali | Sambara **100% preserved** |
| State hilang (kembali ke beranda) | State tetap di halaman terakhir |
| JS event mungkin hilang | JS event diterima karena WebView masih hidup |

---

## 1. Menerima Trigger dari Console Log

Sambara mengirim JSON via `console.log`:

```json
{
    "type": "finpay_navigation",
    "url": "https://m.dana.id/n/cashier/new/checkout?bizNo=...",
    "kodeBayar": "3222002005265231"
}
```

### Snippet — Controller (handleConsoleMessage):

```dart
void handleConsoleMessage(String message) {
  if (!message.contains('finpay_navigation')) return;

  final Map<String, dynamic> json = jsonDecode(message);
  if (json['type'] != 'finpay_navigation') return;

  final String? url = json['url']?.toString().trim();
  final String? kodeBayar = json['kodeBayar']?.toString().trim();

  if (url == null || url.isEmpty) return;

  // Push payment page ke atas Sambara
  _openPaymentPage(url, kodeBayar);
}
```

---

## 2. Push Payment Page ke Stack

```dart
Future<void> _openPaymentPage(String url, String? kodeBayar) async {
  if (_isPaymentPageOpen) return; // Guard: cegah double push

  _activeKodeBayar = kodeBayar;
  _isPaymentPageOpen = true;

  // Start polling SEBELUM push
  _startPaymentStatusPolling();

  // Push → Sambara tetap hidup di bawah
  await Navigator.of(ctx).push(
    MaterialPageRoute(
      builder: (_) => PaymentWebViewPage(paymentUrl: url, kodeBayar: kodeBayar ?? ''),
    ),
  );

  // ↓ Kode di bawah ini jalan setelah payment page di-pop ↓
  _isPaymentPageOpen = false;
  if (_paymentStatusPoller != null) {
    _stopPaymentStatusPolling();
    _notifyPaymentHold();  // User cancel — beritahu Sambara
  }
  _activeKodeBayar = null;
}
```

---

## 3. Payment WebView Page (Halaman Terpisah)

```dart
class PaymentWebViewPage extends StatefulWidget {
  final String paymentUrl;
  final String kodeBayar;
  // ...
}
```

### Fitur:
- **ALLOW semua navigasi HTTP/HTTPS** — tanpa whitelist (sudah difilter Sambara)
- **Non-http scheme** (`intent://`, `dana://`) → `launchUrl` external
- **Custom User Agent** → agar payment gateway tidak block WebView
- **Back button** → `Navigator.pop()` → kembali ke Sambara

---

## 4. Foreground Polling (Dio, 5 detik, max 15 menit)

Polling berjalan di controller (milik HybridWebViewPage) — **tidak bergantung** pada PaymentWebViewPage.

```dart
final Dio _dio = Dio(BaseOptions(
  baseUrl: 'http://192.168.99.46:8700',
  connectTimeout: Duration(seconds: 5),
  receiveTimeout: Duration(seconds: 5),
  contentType: 'application/json',
));

// Cek status pembayaran
final response = await _dio.post<Map<String, dynamic>>(
  '/api/check-dummy-payment-status',
  data: {'kodeBayar': _activeKodeBayar},
);

final bool isPaid = body['success'] == true && body['code'] == '0000';

if (isPaid) {
  _stopPaymentStatusPolling();
  Navigator.of(ctx).pop();              // Pop payment page
  _notifyPaymentCompleted();            // Beritahu Sambara (setelah delay 500ms)
}
```

### API Response (sukses):

```json
{
    "success": true,
    "code": "0000",
    "message": "Tagihan sudah berhasil dibayar",
    "param": { "kodeBayar": "3222002005265231" }
}
```

---

## 5. Events ke Sambara (PKB)

| Event | Payload | Kapan Dispatch |
|-------|---------|----------------|
| `paymentHold` | `{ts, kodeBayar}` | User tekan Back di payment page |
| `paymentCompleted` | `{ts, kodeBayar, status:'success'}` | API return `code: "0000"` (paid) |

### Listener di Sambara:

```javascript
window.addEventListener('paymentHold', function(event) {
    console.log('Payment dibatalkan:', event.detail.kodeBayar);
    // Sambara tampilkan dialog konfirmasi pembatalan
});

window.addEventListener('paymentCompleted', function(event) {
    console.log('Pembayaran sukses:', event.detail.kodeBayar);
    // Sambara update UI status pembayaran
});
```

---

## Alur Lengkap

```
Sambara: console.log({ type:"finpay_navigation", url, kodeBayar })
  │
  ▼
Controller: handleConsoleMessage() → _openPaymentPage()
  │
  ├─ Set _activeKodeBayar, _isPaymentPageOpen = true
  ├─ _startPaymentStatusPolling() → tiap 5 detik, max 15 menit
  ├─ Navigator.push(PaymentWebViewPage)
  │     │
  │     │  ← User melihat halaman payment (DANA/QRIS/dll)
  │     │  ← Sambara tetap hidup di background
  │     │
  │     ├─── isPaid (code=0000) ──► Navigator.pop() + paymentCompleted
  │     │                           Sambara muncul di last state ✅
  │     │
  │     ├─── User Back ────────────► Navigator.pop() + paymentHold
  │     │                           Sambara muncul di last state ✅
  │     │
  │     ├─── Deep link pocapp:// ──► Navigator.pop()
  │     │
  │     └─── 15 menit habis ───────► Polling stop otomatis
  │
  ▼
Controller: (setelah pop) → cleanup _activeKodeBayar
```

---

## Yang Dilakukan Host App (Ringkasan)

### 1. Menjalankan Sambara di WebView utama
- Load URL Sambara di `InAppWebView` dengan JS bridge (`SapawargaChannel`)

### 2. Mendengarkan console.log dari Sambara
- Intercept `finpay_navigation` JSON → extract `url` dan `kodeBayar`

### 3. Push Payment Page ke Navigator Stack
- `PaymentWebViewPage` terbuka di atas Sambara
- Semua navigasi di payment page diizinkan (tanpa whitelist)

### 4. Polling Status Pembayaran (Foreground)
- Dio POST ke backend setiap 5 detik
- Cek `success == true && code == '0000'`

### 5. Auto-Return saat Paid
- Pop payment page → Sambara muncul di last state
- Dispatch `paymentCompleted` ke Sambara via JS

### 6. Handle User Cancel
- User tekan Back → Pop payment page
- Dispatch `paymentHold` ke Sambara
- Sambara tampilkan dialog konfirmasi pembatalan sendiri
