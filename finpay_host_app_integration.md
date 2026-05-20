# Finpay Host App Integration Guide

> **Versi:** 2026-05-20 (v5 — Stack WebView Strategy)
> **Target:** Developer Host App (Flutter/Android)
> **Dependencies:** `flutter_inappwebview`, `dio`, `url_launcher`, `app_links`

---

## 1. Arsitektur Integrasi

```
┌──────────────────────────────────────────────────────────┐
│                    HOST APP (Flutter)                     │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  HybridWebViewPage (Route Utama)                 │    │
│  │  ┌──────────────────────────────────────────┐    │    │
│  │  │  InAppWebView: Sambara PKB               │    │    │
│  │  │  • console.log listener                  │    │    │
│  │  │  • JS Bridge (SapawargaChannel)          │    │    │
│  │  │  • Navigation Guard (whitelist)          │    │    │
│  │  └──────────────────────────────────────────┘    │    │
│  │  HybridWebViewController:                        │    │
│  │  • Polling Dio (5 detik, max 15 menit)           │    │
│  │  • Push/Pop PaymentWebViewPage                   │    │
│  │  • Dispatch JS events ke Sambara                 │    │
│  └──────────────────────────────────────────────────┘    │
│                          │ Navigator.push()              │
│                          ▼                               │
│  ┌──────────────────────────────────────────────────┐    │
│  │  PaymentWebViewPage (Route Terpisah)             │    │
│  │  ┌──────────────────────────────────────────┐    │    │
│  │  │  InAppWebView: Payment Gateway           │    │    │
│  │  │  • ALLOW all HTTP/HTTPS navigation       │    │    │
│  │  │  • External scheme → launchUrl           │    │    │
│  │  │  • Custom user agent                     │    │    │
│  │  └──────────────────────────────────────────┘    │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

---

## 2. Tanggung Jawab Host App

### A. Menjalankan Sambara di WebView Utama
- Load URL Sambara dengan InAppWebView
- Inject JS bridge `SapawargaChannel` via UserScript (AT_DOCUMENT_START)
- Handle permission (kamera, lokasi)

### B. Mendengarkan Trigger dari Sambara
Sambara mengirim trigger pembayaran via `console.log`:

```json
{
    "type": "finpay_navigation",
    "url": "https://m.dana.id/n/cashier/...",
    "kodeBayar": "3222002005265231"
}
```

Host app menangkap via `onConsoleMessage` callback InAppWebView.

### C. Push Payment Page ke Navigator Stack
- **BUKAN** mengganti URL di WebView Sambara
- **BUKAN** membuka Chrome Custom Tab
- Push `PaymentWebViewPage` sebagai route baru di atas Sambara
- Sambara tetap hidup, state 100% preserved

### D. Polling Status Pembayaran
- **Library:** Dio (persistent connection pool)
- **Interval:** 5 detik
- **Batas:** 15 menit
- **Endpoint:** `POST /api/check-dummy-payment-status`
- **Kondisi paid:** `success == true && code == "0000"`

### E. Dispatch Events ke Sambara
Host app mengirim CustomEvent ke WebView Sambara:
- `paymentCompleted` → saat pembayaran lunas (API return paid)
- `paymentHold` → saat user cancel (back dari payment page)

### F. TIDAK Dilakukan oleh Host App
- ❌ Tidak menampilkan dialog konfirmasi pembatalan (Sambara yang handle)
- ❌ Tidak melakukan whitelist pada URL dari console.log (sudah difilter Sambara)
- ❌ Tidak menggunakan Chrome Custom Tab

---

## 3. Alur Lengkap

### Skenario 1: Pembayaran Berhasil
```
1. User klik "Bayar" di Sambara
2. Sambara console.log({ type:"finpay_navigation", url, kodeBayar })
3. Host: handleConsoleMessage() → detect finpay_navigation
4. Host: _openPaymentPage(url, kodeBayar)
   a. Set _isPaymentPageOpen = true
   b. Start polling (5 detik interval)
   c. Navigator.push(PaymentWebViewPage)
5. User melihat halaman DANA/QRIS di payment page
6. User bayar di DANA
7. Polling detect isPaid = true
8. Host: Navigator.pop() → payment page hilang
9. Sambara muncul kembali di last state ✅
10. Host: dispatch paymentCompleted ke Sambara (500ms delay)
11. Sambara update UI
```

### Skenario 2: User Cancel
```
1-5. (sama dengan skenario 1)
6. User tekan Back di payment page
7. Navigator.pop() otomatis
8. Sambara muncul kembali di last state ✅
9. Host: polling masih jalan → stop + dispatch paymentHold
10. Sambara tampilkan dialog konfirmasi pembatalan
```

### Skenario 3: Timeout (15 menit)
```
1-5. (sama dengan skenario 1)
6. 15 menit berlalu tanpa pembayaran
7. Polling auto-stop
8. Payment page masih terbuka — user bisa continue atau back
```

---

## 4. Kontrak Event JavaScript

### paymentCompleted (Host → Sambara)

```javascript
// Dispatched oleh Host saat API return isPaid = true
window.dispatchEvent(new CustomEvent('paymentCompleted', {
    detail: {
        ts: Date.now(),
        kodeBayar: '3222002005265231',
        status: 'success'
    }
}));
```

### paymentHold (Host → Sambara)

```javascript
// Dispatched oleh Host saat user back dari payment page
window.dispatchEvent(new CustomEvent('paymentHold', {
    detail: {
        ts: Date.now(),
        kodeBayar: '3222002005265231'
    }
}));
```

### Listener di Sambara:

```javascript
window.addEventListener('paymentCompleted', (e) => {
    // Update UI — pembayaran sukses
    console.log('Paid:', e.detail.kodeBayar);
});

window.addEventListener('paymentHold', (e) => {
    // Tampilkan dialog konfirmasi pembatalan
    console.log('Hold:', e.detail.kodeBayar);
});
```

---

## 5. API Backend (Dummy)

### Endpoint

```
POST http://192.168.99.46:8700/api/check-dummy-payment-status
Content-Type: application/json

{ "kodeBayar": "3222002005265231" }
```

### Response — Belum Bayar

```json
{
    "success": false,
    "code": "0003",
    "message": "Tagihan belum dibayar",
    "param": { "kodeBayar": "3222002005265231" }
}
```

### Response — Sudah Bayar

```json
{
    "success": true,
    "code": "0000",
    "message": "Tagihan sudah berhasil dibayar",
    "param": { "kodeBayar": "3222002005265231" }
}
```

### Logika isPaid:

```dart
final bool isPaid = body['success'] == true && body['code'] == '0000';
```

---

## 6. File Struktur

```
lib/
├── config/
│   ├── app_config.dart          # Whitelist domain, deep link config
│   └── logger.dart              # AppLogger utility
├── features/hybrid_webview/
│   ├── application/
│   │   ├── hybrid_webview_controller.dart  # Controller utama (polling, events)
│   │   └── web_permission_service.dart     # Permission handler
│   ├── domain/
│   │   └── web_navigation_guard.dart       # Whitelist navigation guard
│   └── presentation/
│       ├── hybrid_webview_page.dart         # Sambara WebView page
│       ├── payment_webview_page.dart        # Payment gateway page (BARU)
│       └── widgets/
│           ├── debug_tracker_overlay.dart
│           └── permission_chip.dart
└── app.dart / main.dart
```

---

## 7. Konfigurasi Penting

| Parameter | Nilai | Lokasi |
|-----------|-------|--------|
| Polling interval | 5 detik | `_pollingInterval` di controller |
| Polling max duration | 15 menit | `_pollingMaxDuration` di controller |
| API base URL | `http://192.168.99.46:8700` | Dio `BaseOptions.baseUrl` |
| API timeout | 5 detik (connect/receive/send) | Dio `BaseOptions` |
| Deep link scheme | `pocapp` | `AppConfig.deepLinkScheme` |
| Deep link host | `payment` | `AppConfig.deepLinkHost` |
| Bridge name | `SapawargaChannel` | `AppConfig.bridgeName` |
| Allowed hosts | `test-sambara.vercel.app`, `live.finpay.id` | `AppConfig._allowedHostsEnv` |
