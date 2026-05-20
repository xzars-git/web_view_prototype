# web_view_prototype

Host app Flutter yang mem-wrap **Sambara** (Flutter Web App) di dalam `InAppWebView`. Menangani alur pembayaran Finpay end-to-end: membuka halaman pembayaran e-wallet di overlay InAppWebView, melakukan polling status via API, dan mengirim notifikasi hasil ke Sambara.

## Arsitektur Singkat

```
Host App (Flutter Native)
└── Stack
    ├── InAppWebView — Sambara (selalu hidup, tidak di-destroy)
    └── _PaymentWebViewOverlay — Finpay/e-wallet (muncul di atas saat diperlukan)
```

App selalu tetap di **foreground** → `Timer.periodic` polling berjalan tanpa throttling di Android maupun iOS.

## Cara Menjalankan

```bash
# Default (dev)
flutter run

# Override URL target
flutter run --dart-define=TARGET_URL=https://example.com

# Override URL payment server
flutter run --dart-define=PAYMENT_BASE_URL=http://192.168.1.1:8700
```

## Trigger Pembayaran

Ada dua jalur masuk, keduanya berujung ke `_openPaymentWebView()`:

### Primary — console.log (aktif digunakan)

Sambara mengirim payload JSON via `console.log`:

```javascript
console.log(JSON.stringify({
  type: "finpay_navigation",
  url: "https://app.shopeepay.co.id/...",
  kodeBayar: "3222002005265231"
}));
```

Host menangkap via `onConsoleMessage` → `handleConsoleMessage()` → buka overlay + mulai polling.

### Fallback — JS Bridge `SapawargaChannel.postMessage`

```javascript
window.SapawargaChannel.postMessage("https://...");
```

Digunakan sebagai fallback jika Sambara tidak mengirim format `finpay_navigation`. Karena payload-nya hanya URL (tanpa `kodeBayar`), **polling status tidak berjalan** via jalur ini.

## Alur Pembayaran

```
Sambara: console.log({ type:"finpay_navigation", url, kodeBayar })
  │
  ▼
Host: handleConsoleMessage() → validasi HTTPS → _openPaymentWebView()
  │
  ├─ state.paymentUrl = url → Stack tampilkan overlay di atas Sambara
  ├─ dispatch paymentTabOpened → Sambara stop timer internal
  └─ polling POST /api/check-dummy-payment-status setiap 10 detik
       │
       ├─ isPaid=true        → tutup overlay + dispatch paymentSuccess
       ├─ User tutup overlay → tutup overlay + dispatch paymentHold
       └─ 15 menit habis    → tutup overlay + dispatch paymentHold
```

## Events Host → Sambara

| Event | Kapan | Payload |
|-------|-------|---------|
| `paymentTabOpened` | Overlay payment dibuka | `{ts, kodeBayar}` |
| `paymentHold` | User menutup overlay / timeout | `{ts, kodeBayar}` |
| `paymentSuccess` | API konfirmasi lunas / deep link | `{ts, kodeBayar}` |

## Konfigurasi

Semua konstanta ada di `lib/config/app_config.dart`:

| Key (`--dart-define`) | Default | Keterangan |
|-----------------------|---------|-----------|
| `TARGET_URL` | Sambara dev URL | URL WebView utama |
| `PAYMENT_BASE_URL` | `http://192.168.99.46:8700` | Server polling status |
| `bridgeName` | `SapawargaChannel` | Nama JS bridge fallback |
| `deepLinkScheme` | `pocapp` | Scheme deep link return |
| `deepLinkHost` | `payment` | Host deep link return |

## Deep Link (Android & iOS)

Finpay akan redirect ke `pocapp://payment/return` atau `pocapp://payment/callback` setelah pembayaran selesai. Host menangkap via `app_links`, menutup overlay, dan men-dispatch `paymentSuccess` ke Sambara.

- **Android:** `AndroidManifest.xml` — intent-filter scheme `pocapp`, host `payment`
- **iOS:** `Info.plist` — `CFBundleURLSchemes = ["pocapp"]`

## Debug Panel

Ketuk ikon bug di AppBar untuk toggle panel log. Semua log dari `[WebView]`, `[Console]`, `[Polling]`, `[DeepLink]`, dan `[Event]` muncul di satu tempat — bisa digunakan di device fisik tanpa perlu USB.
