# Dokumentasi Alur Pembayaran Finpay — PKB WebView

> **Versi:** 2026-05-20
> **Konteks:** Sambara berjalan sebagai Flutter Web App di dalam `InAppWebView` milik host app (`web_view_prototype`).

---

## Domain yang Terlibat

| Metode | Domain | Jalur |
|--------|--------|-------|
| Kartu Kredit | `live.finpay.id` | A — Sambara WebView langsung |
| Virtual Account | `live.finpay.id` | A — Sambara WebView langsung |
| DANA | `m.dana.id` | B — InAppWebView overlay |
| ShopeePay | `app.shopeepay.co.id` | B — InAppWebView overlay |
| LinkAja | `payment.linkaja.id` | B — InAppWebView overlay |

---

## Mengapa Ada Dua Jalur?

**Jalur A (CC/VA):** Proses terjadi sepenuhnya di halaman web Finpay. Sambara cukup `window.location.href = urlFinpay` → InAppWebView load halaman Finpay → user bayar → Finpay redirect ke return URL.

**Jalur B (E-Wallet):** Finpay generate deep link ke app e-wallet (`shopee://`, `dana://`, dll.). Deep link tidak bisa dihandle langsung dari InAppWebView. Sambara kirim URL + kodeBayar ke host, host buka InAppWebView overlay terpisah dengan User Agent yang sudah di-strip dari tanda WebView.

---

## Arsitektur

```
┌───────────────────────────────────────────────────────────┐
│                HOST APP (Flutter Native)                   │
│                                                            │
│  HybridWebViewController                                   │
│    handleConsoleMessage()  ← parse finpay_navigation JSON  │
│    _openPaymentWebView()   ← set paymentUrl di state       │
│    _startPolling()         ← Dio POST setiap 10 detik      │
│    _initDeepLinks()        ← listen pocapp:// via app_links│
│    handleNavigation()      ← whitelist + CC/VA jalur A     │
│                                                            │
│  ┌─── Stack ──────────────────────────────────────────┐   │
│  │ InAppWebView (Sambara) — selalu hidup               │   │
│  │                                                     │   │
│  │  User pilih metode bayar                            │   │
│  │    Jalur A: window.location.href → live.finpay.id  │   │
│  │    Jalur B: console.log({ type:"finpay_navigation" │   │
│  │             url, kodeBayar })                       │   │
│  ├─────────────────────────────────────────────────── │   │
│  │ _PaymentWebViewOverlay (muncul saat paymentUrl!=null│   │
│  │   InAppWebView dengan clean UA (tanpa " wv")        │   │
│  │   shouldOverrideUrlLoading: buka shopee:// dll.     │   │
│  │   via launchUrl + catchError                        │   │
│  └─────────────────────────────────────────────────── ┘   │
│                                                            │
│  Events ke Sambara (evaluateJavascript):                   │
│    paymentTabOpened — overlay buka                         │
│    paymentHold      — user tutup / timeout                 │
│    paymentSuccess   — lunas via API / deep link            │
└───────────────────────────────────────────────────────────┘
```

---

## Alur Per Jalur

### Jalur A — Kartu Kredit / Virtual Account

```
[1] Sambara: window.location.href = 'https://live.finpay.id/...'
[2] handleNavigation: host=live.finpay.id → allowWebView → ALLOW
[3] Sambara WebView load halaman Finpay, user bayar
[4] Finpay redirect ke return URL (live.finpay.id/pg/payment/card/result/...)
    → host detect via NavigationGuard → paymentSuccess tidak diperlukan dari host
    → Sambara sendiri cek status via timer internal
```

### Jalur B — E-Wallet (DANA, ShopeePay, LinkAja)

```
[1] Sambara: console.log(JSON.stringify({
      type:"finpay_navigation",
      url:"https://app.shopeepay.co.id/...",
      kodeBayar:"3222..."
    }))
[2] Host: onConsoleMessage → handleConsoleMessage() → parse JSON
[3] _openPaymentWebView(url):
    - state.paymentUrl = url → Stack tampilkan overlay
    - dispatch paymentTabOpened → Sambara stop timer internal
    - mulai polling Dio setiap 10 detik
[4] Overlay InAppWebView load URL Finpay/e-wallet
    - Finpay detect clean UA (bukan WebView) → tampilkan QR/deeplink yang benar
    - Jika shopee:// terdeteksi → launchUrl(externalApp) → buka Shopee app

Skenario 1 — Polling sukses:
  [5a] Dio POST → isPaid=true → stop polling → tutup overlay → paymentSuccess
  [6a] Sambara: addEventListener('paymentSuccess') → mark sukses ✅

Skenario 2 — Deep link:
  [5b] Finpay kirim pocapp://payment/return
  [6b] app_links → stop polling → tutup overlay → paymentSuccess ✅

Skenario 3 — User tutup overlay (X / back):
  [5c] onPaymentWebViewClosedByUser() → stop polling → tutup overlay → paymentHold
  [6c] Sambara: addEventListener('paymentHold') → resume timer + tampilkan dialog ✅

Skenario 4 — Timeout 15 menit:
  [5d] _pollingMaxTimer → stop polling → tutup overlay → paymentHold
  [6d] Sambara: paymentHold ✅
```

---

## Kenapa InAppWebView Overlay (Bukan Custom Tab)?

| | Custom Tab | InAppWebView Overlay |
|--|-----------|---------------------|
| App status saat payment | Background | Foreground |
| Timer.periodic Android | Dimatikan Doze Mode | Berjalan normal |
| iOS | Perlu SFSafariViewController | Sama, app foreground |
| Kompleksitas | Tinggi (2 implementasi) | Satu kode untuk semua |
| User Agent | Bisa set | Bisa set |

InAppWebView overlay = satu solusi yang berfungsi identik di Android dan iOS.

---

## Status Implementasi ✅

### Host App

| Item | Status |
|------|--------|
| `onConsoleMessage` → parse `finpay_navigation` | ✅ |
| InAppWebView overlay via Stack + `paymentUrl` state | ✅ |
| User Agent clean (strip `" wv"`, di-cache) | ✅ |
| Polling Dio 10 detik / max 15 menit | ✅ |
| `paymentTabOpened` dispatch | ✅ |
| `paymentHold` dispatch (user close / timeout) | ✅ |
| `paymentSuccess` dispatch (polling / deep link) | ✅ |
| Deep link `pocapp://` via `app_links` | ✅ |
| Native deep link (shopee://, dll.) + catchError | ✅ |
| JS bridge `SapawargaChannel` (fallback postMessage) | ✅ |
| Foreground Service | ❌ Dihapus — tidak diperlukan |
| Chrome Custom Tab | ❌ Dihapus — diganti overlay |
| Dialog konfirmasi di host | ❌ Dihapus — Sambara yang handle |

### Sambara

| Item | Status |
|------|--------|
| `paymentTabOpened` → stop timer internal | ✅ |
| `paymentHold` → resume timer + tampilkan dialog | ✅ |
| `paymentSuccess` → mark sukses | ✅ |
