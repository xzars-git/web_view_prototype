# Dokumentasi Teknis — web_view_prototype

> **Versi:** 2026-05-20 (InAppWebView overlay — tanpa Custom Tab, tanpa Foreground Service)

---

## Struktur Proyek

```
lib/
├── config/
│   ├── app_config.dart       — konstanta URL, bridge name, deep link scheme
│   └── logger.dart           — AppLogger dengan ValueNotifier untuk debug panel
├── features/hybrid_webview/
│   ├── application/
│   │   ├── hybrid_webview_controller.dart  — orkestrasi utama
│   │   └── web_permission_service.dart     — wrapper permission_handler
│   ├── domain/
│   │   └── web_navigation_guard.dart       — evaluasi URL → NavigationHandling
│   └── presentation/
│       ├── hybrid_webview_page.dart         — UI: Stack Sambara + payment overlay
│       └── widgets/
│           ├── debug_tracker_overlay.dart
│           └── permission_chip.dart
```

---

## Komponen Utama

### HybridWebViewState

State immutable yang di-hold oleh `ValueNotifier`. Field `paymentUrl` menggunakan sentinel pattern agar `null` bisa di-set secara eksplisit via `copyWith`.

```
paymentUrl == null  → overlay tersembunyi, hanya Sambara yang tampil
paymentUrl != null  → overlay payment tampil di atas Sambara
```

### HybridWebViewController

Controller utama sekaligus `ValueNotifier<HybridWebViewState>`. Bertanggung jawab atas:

- **JS Bridge** — inject `SapawargaChannel` via `UserScript AT_DOCUMENT_START` (fallback jika Sambara pakai `postMessage`)
- **Console handler** — parse `finpay_navigation` JSON dari Sambara
- **Payment overlay** — buka/tutup via `paymentUrl` di state
- **Polling** — `Timer.periodic` (10 detik) + `Timer` max 15 menit, keduanya via Dio
- **Deep link** — `app_links` stream, cocok scheme `pocapp` + host `payment`
- **Navigation guard** — delegasi ke `WebNavigationGuard`

### _PaymentWebViewOverlay

`StatefulWidget` yang ditampilkan di atas Sambara WebView saat `paymentUrl != null`.

- Fetch user agent sekali via `HeadlessInAppWebView`, di-cache di variabel modul-level `_cachedUserAgent`
- UA di-strip dari `" wv"` agar tidak terdeteksi sebagai WebView oleh Shopee Pay, DANA, dll.
- Non-HTTP scheme (shopee://, dana://, dll.) dibuka via `launchUrl` dengan `.catchError` untuk handle app tidak terinstall

---

## Alur Pembayaran

### Trigger dari Sambara

Sambara mengirim data pembayaran via `console.log`:

```json
{ "type": "finpay_navigation", "url": "https://...", "kodeBayar": "3222..." }
```

Host intercept via `onConsoleMessage` → `handleConsoleMessage()` → validasi HTTPS → `_openPaymentWebView()`.

### Pembayaran Berjalan

1. `value.paymentUrl` di-set → Flutter rebuild → overlay muncul
2. `paymentTabOpened` di-dispatch ke Sambara (Sambara stop timer internal)
3. Polling mulai: `POST /api/check-dummy-payment-status` setiap 10 detik

### Selesai / Dibatalkan

| Kondisi | Action |
|---------|--------|
| API return `success=true && code="0000"` | Stop polling, tutup overlay, dispatch `paymentSuccess` |
| User tekan tombol X / back | Stop polling, tutup overlay, dispatch `paymentHold` |
| Deep link `pocapp://payment/return` | Stop polling, tutup overlay, dispatch `paymentSuccess` |
| 15 menit habis | Stop polling, tutup overlay, dispatch `paymentHold` |

---

## JS Events (Host → Sambara)

Semua event dikirim via `evaluateJavascript`:

```dart
window.dispatchEvent(new CustomEvent('paymentTabOpened', {detail:{ts:Date.now(), kodeBayar:'...'}}))
window.dispatchEvent(new CustomEvent('paymentHold',      {detail:{ts:Date.now(), kodeBayar:'...'}}))
window.dispatchEvent(new CustomEvent('paymentSuccess',   {detail:{ts:Date.now(), kodeBayar:'...'}}))
```

Sambara listen:

```javascript
window.addEventListener('paymentTabOpened', (e) => { /* stop internal timer */ });
window.addEventListener('paymentHold',      (e) => { /* resume timer, show dialog */ });
window.addEventListener('paymentSuccess',   (e) => { /* mark sukses */ });
```

---

## Navigation Guard

`WebNavigationGuard.evaluate(url)` mengembalikan `NavigationHandling`:

| Hasil | Action di controller |
|-------|---------------------|
| `allowWebView` | `ALLOW` — buka di Sambara WebView |
| `openInCustomTab` | `CANCEL` + buka payment overlay |
| `externalApp` | `CANCEL` + `launchUrl` external |
| `cancel` | `CANCEL` |

---

## Permissions

Diminta saat startup via `requestStartupPermissions()`. WebView tidak load sampai status izin jelas. Saat JS minta akses kamera/lokasi, host langsung grant tanpa dialog tambahan karena sudah dicek di startup.

---

## Packages

| Package | Kegunaan |
|---------|---------|
| `flutter_inappwebview` | WebView utama + HeadlessWebView untuk UA |
| `dio` | HTTP polling status pembayaran |
| `app_links` | Listen deep link return dari Finpay |
| `url_launcher` | Buka deep link native app (shopee://, dll.) |
| `permission_handler` | Request izin kamera & lokasi |
