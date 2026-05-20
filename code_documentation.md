# Code Documentation — Hybrid WebView + Payment Integration

> **Versi:** 2026-05-20 (v5 — Stack WebView Strategy)
> **Strategi:** PaymentWebViewPage di-push di atas Sambara via Navigator stack.

---

## Arsitektur

Aplikasi menggunakan **Stack WebView Strategy**:
- **HybridWebViewPage**: Menampilkan Sambara PKB di InAppWebView. Tetap hidup selama app berjalan.
- **PaymentWebViewPage**: Halaman payment gateway (DANA, QRIS, dll). Di-push sebagai route baru di atas Sambara. Saat di-pop, Sambara muncul kembali di kondisi terakhir.

### Kenapa Stack?
Chrome Custom Tab menyebabkan app masuk background → OS Android throttle network → polling gagal.
Replace URL di WebView yang sama menyebabkan state Sambara hilang (kembali ke beranda).
Stack Navigator mempertahankan kedua WebView dan app tetap foreground.

---

## File Utama

### `hybrid_webview_controller.dart`
Controller utama yang mengelola:
- **Console Message Handler**: Intercept `finpay_navigation` JSON dari Sambara
- **Payment Page Push**: `Navigator.push(PaymentWebViewPage)` ke atas Sambara
- **Polling Dio**: Cek status pembayaran setiap 5 detik (max 15 menit)
- **Event Dispatch**: `paymentCompleted` dan `paymentHold` ke Sambara via JS
- **Deep Link Handler**: Tangani return dari external app (pocapp://)
- **Navigation Guard**: Whitelist domain yang boleh di WebView Sambara

### `payment_webview_page.dart`
Halaman payment terpisah:
- InAppWebView dedicated untuk payment gateway
- ALLOW semua navigasi HTTP/HTTPS (tanpa whitelist)
- Non-http scheme → launchUrl external
- Custom User-Agent agar payment gateway tidak block
- Back → Navigator.pop() → kembali ke Sambara

### `hybrid_webview_page.dart`
Halaman utama Sambara:
- InAppWebView untuk Sambara PKB
- Set `controller.navigatorContext` agar controller bisa push
- Debug tracker overlay
- Permission chips (Camera, Location)

### `web_navigation_guard.dart`
Domain guard untuk navigasi Sambara:
- `allowWebView` → domain internal (Sambara, Finpay)
- `openInCustomTab` → sekarang di-remap ke push PaymentWebViewPage
- `externalApp` → scheme non-http
- `cancel` → ditolak

### `app_config.dart`
Konfigurasi:
- `targetUrl` → URL Sambara PKB
- `bridgeName` → "SapawargaChannel"
- `deepLinkScheme/Host` → "pocapp://payment"
- `_webViewAllowedHosts` → whitelist domain di Sambara WebView
- `isPaymentResultUrl()` → deteksi halaman hasil Finpay

---

## Events JavaScript

| Event | Direction | Payload | Trigger |
|-------|-----------|---------|---------|
| `paymentCompleted` | Host → Sambara | `{ts, kodeBayar, status}` | API return paid |
| `paymentHold` | Host → Sambara | `{ts, kodeBayar}` | User back dari payment |

---

## Polling Configuration

| Parameter | Nilai |
|-----------|-------|
| Library | Dio 5.x |
| Interval | 5 detik |
| Max Duration | 15 menit |
| Endpoint | `POST /api/check-dummy-payment-status` |
| isPaid Condition | `success == true && code == "0000"` |
| Error Suppression | Setelah 3 error berturut-turut |

---

## Dependencies

```yaml
dependencies:
  flutter_inappwebview: ^6.1.5
  dio: ^5.7.0
  geolocator: ^13.0.2
  permission_handler: ^11.3.1
  url_launcher: ^6.3.1
  app_links: ^6.3.2
```
