# Panduan Integrasi Host App — PKB WebView Payment

> **Untuk:** Tim pengembang host app yang mem-wrap Sambara/PKB sebagai InAppWebView
> **Versi:** 2026-05-20 (v3 — InAppWebView overlay, tanpa Custom Tab)

---

## Gambaran Umum

Sambara berjalan di dalam `InAppWebView`. Saat user memilih metode pembayaran e-wallet, Sambara mengirim sinyal ke host via `console.log`. Host membuka **InAppWebView overlay** di atas Sambara (bukan Custom Tab), sehingga app tetap foreground dan polling tidak ter-throttle.

```
Host App (Flutter Native)
└── Stack
    ├── InAppWebView ← Sambara (selalu hidup)
    └── _PaymentWebViewOverlay ← Finpay/e-wallet (overlay saat paymentUrl != null)
```

---

## Jalur Pembayaran

| Jalur | Metode | Cara Kerja |
|-------|--------|------------|
| **A** | Kartu Kredit, Virtual Account | Sambara navigasi langsung → tetap di Sambara WebView |
| **B** | DANA, ShopeePay, LinkAja | Sambara kirim JSON → host buka InAppWebView overlay |

---

## 1. Sinyal dari Sambara (console.log)

Sambara mengirim instruksi pembayaran via `console.log(JSON.stringify({...}))`.

**Format JSON:**
```json
{
    "type": "finpay_navigation",
    "url": "https://app.shopeepay.co.id/...",
    "kodeBayar": "3222002005265231"
}
```

**Implementasi:**
```dart
// Di widget InAppWebView:
onConsoleMessage: (controller, consoleMessage) {
  _controller.handleConsoleMessage(consoleMessage.message);
},
```

Host parse JSON, validasi `https://`, lalu buka overlay:

```dart
void handleConsoleMessage(String message) {
  if (!message.contains('finpay_navigation')) return;
  try {
    final json = jsonDecode(message) as Map<String, dynamic>;
    if (json['type'] != 'finpay_navigation') return;
    final url = json['url']?.toString().trim();
    final kodeBayar = json['kodeBayar']?.toString().trim();
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;
    _activeKodeBayar = kodeBayar;
    _openPaymentWebView(url);
  } catch (_) {}
}
```

---

## 2. InAppWebView Overlay (Payment Page)

Overlay ditampilkan dengan menambahkan `_PaymentWebViewOverlay` ke Stack via state:

```dart
// Di state:
final String? paymentUrl; // null = overlay tidak tampil

// Di UI (Stack):
if (state.paymentUrl != null)
  _PaymentWebViewOverlay(
    url: state.paymentUrl!,
    onClose: _controller.onPaymentWebViewClosedByUser,
  ),
```

Overlay menggunakan User Agent yang sudah di-strip dari `" wv"` (tanda WebView di Chrome Android) agar tidak diblokir oleh payment provider seperti Shopee Pay.

---

## 3. Events Host → Sambara

Semua event dikirim via `evaluateJavascript`:

| Event | Kapan | Payload |
|-------|-------|---------|
| `paymentTabOpened` | Overlay dibuka | `{ts, kodeBayar}` |
| `paymentHold` | User tutup overlay / timeout | `{ts, kodeBayar}` |
| `paymentSuccess` | API konfirmasi lunas / deep link | `{ts, kodeBayar}` |

**Sambara perlu listen:**
```javascript
window.addEventListener('paymentTabOpened', (e) => {
    // Hentikan timer internal Sambara, host yang polling
});
window.addEventListener('paymentHold', (e) => {
    // Resume timer, tampilkan dialog konfirmasi di Sambara
    console.log('kodeBayar:', e.detail.kodeBayar);
});
window.addEventListener('paymentSuccess', (e) => {
    // Tandai sukses
});
```

---

## 4. Polling Status Pembayaran

Host polling endpoint setiap **10 detik** menggunakan Dio. Batas waktu **15 menit**.

```
POST {PAYMENT_BASE_URL}/api/check-dummy-payment-status
Content-Type: application/json

{ "kodeBayar": "3222002005265231" }
```

**Response sukses:**
```json
{ "success": true, "code": "0000", "message": "..." }
```

**Logika isPaid:**
```dart
final bool isPaid = body['success'] == true && body['code'] == '0000';
```

Saat `isPaid = true`:
1. Stop polling
2. Tutup overlay (`paymentUrl = null`)
3. Dispatch `paymentSuccess` ke Sambara

---

## 5. User Tutup Overlay

Saat user tekan tombol X atau back saat overlay aktif:

```dart
void onPaymentWebViewClosedByUser() {
  _stopPaymentStatusPolling();
  value = value.copyWith(paymentUrl: null); // sembunyikan overlay
  _notifyPaymentHold();                     // beri tahu Sambara
  _activeKodeBayar = null;
}
```

Sambara yang menampilkan dialog konfirmasi pembatalan dari sisinya — host tidak perlu dialog.

---

## 6. Deep Link (pocapp://)

Saat Finpay redirect ke `pocapp://payment/return` atau `pocapp://payment/callback`:

1. `app_links` menangkap URI
2. Stop polling
3. Tutup overlay
4. Dispatch `paymentSuccess`

**Android — `AndroidManifest.xml`:**
```xml
<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="pocapp" android:host="payment" />
</intent-filter>
```

**iOS — `Info.plist`:**
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>pocapp</string></array>
  </dict>
</array>
```

---

## 7. Deep Link Native App (Shopee, DANA, dll.)

Saat halaman Finpay di dalam overlay mencoba buka `shopee://`, `dana://`, dsb., overlay handle via `shouldOverrideUrlLoading`:

```dart
if (uri.scheme != 'http' && uri.scheme != 'https') {
  // Coba buka native app; jika tidak terinstall, WebView tetap di halaman saat ini
  await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
  return NavigationActionPolicy.CANCEL;
}
```

---

## 8. Checklist Implementasi

- [x] `onConsoleMessage` → `handleConsoleMessage()` parse `finpay_navigation`
- [x] Buka InAppWebView overlay via state `paymentUrl`
- [x] User Agent strip `" wv"` untuk payment provider compatibility
- [x] Polling `POST /api/check-dummy-payment-status` setiap 10 detik
- [x] Dispatch `paymentTabOpened` saat overlay buka
- [x] Dispatch `paymentHold` saat overlay ditutup user / timeout
- [x] Dispatch `paymentSuccess` saat isPaid / deep link
- [x] Deep link `pocapp://` di AndroidManifest + Info.plist
- [x] Native app deep link (shopee://, dll.) via `launchUrl` + catchError

---

## Referensi Cepat

| Item | Nilai |
|------|-------|
| Console message type | `finpay_navigation` |
| JS Bridge (fallback) | `SapawargaChannel` |
| Event: overlay buka | `paymentTabOpened` |
| Event: batal | `paymentHold` |
| Event: sukses | `paymentSuccess` |
| Deep link scheme | `pocapp` |
| Deep link host | `payment` |
| Polling endpoint | `POST /api/check-dummy-payment-status` |
| Polling interval | 10 detik |
| Polling max | 15 menit |
