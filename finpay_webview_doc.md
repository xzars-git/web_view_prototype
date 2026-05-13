# Dokumentasi Alur Pembayaran Finpay — PKB WebView
> **Terakhir diverifikasi:** 2026-05-11
> **Konteks:** Flutter PKB berjalan sebagai Flutter Web App di dalam InAppWebView milik host app (`web_view_prototype`).
> Komunikasi dari PKB ke host via JS bridge `window.SapawargaChannel.postMessage(url)`.

## Domain Terverifikasi

| Metode | Domain | Jalur | Whitelist? |
|--------|--------|-------|------------|
| Kartu Kredit | `live.finpay.id` | A — WebView | ✅ |
| Virtual Account | `live.finpay.id` | A — WebView | ✅ |
| DANA | `m.dana.id` | B — Custom Tab | ❌ (via bridge) |
| ShopeePay | `app.shopeepay.co.id` | B — Custom Tab | ❌ (via bridge) |
| LinkAja | `payment.linkaja.id` | B — Custom Tab | ❌ (via bridge) |

> **Return URL CC/VA:** Finpay redirect ke `live.finpay.id/pg/payment/card/result/{success\|failed\|pending}`
> setelah proses pembayaran selesai. Host app mendeteksi pola path ini untuk trigger `paymentCompleted`.

---

## Mengapa Ada Dua Jalur Pembayaran?

### Kelompok A — Kartu Kredit & Virtual Account
- Proses bayar terjadi **seluruhnya di halaman web** Finpay.
- Tidak perlu berpindah ke aplikasi lain.
- PKB cukup redirect via `window.location.href` → InAppWebView load halaman Finpay.
- Setelah selesai, Finpay redirect ke return URL → host detect → notifikasi PKB.

### Kelompok B — E-Wallet (DANA, ShopeePay, LinkAja, dll.)
- Finpay generate **deep link** ke aplikasi e-wallet (`dana://pay?...`).
- Deep link tidak bisa dibuka dari InAppWebView secara langsung.
- Harus dibuka di **Chrome Custom Tab** agar OS bisa handle intent ke aplikasi e-wallet.
- PKB kirim URL ke host via `SapawargaChannel.postMessage` → host buka Custom Tab.

---

## Arsitektur Aktual

```
┌─────────────────────────────────────────────────────────────┐
│          HOST APP: web_view_prototype (Flutter Native)       │
│                                                              │
│  HybridWebViewController                                     │
│    _PaymentChromeBrowser   ← onClosed() → notifyPayment     │
│    bridgeUserScript        ← inject SapawargaChannel ke JS  │
│    _setupJsHandlers()      ← terima postMessage dari PKB    │
│    _initDeepLinks()        ← listen pocapp:// via app_links  │
│    handleNavigation()      ← whitelist + result detection   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │          InAppWebView (Flutter PKB Web App)           │    │
│  │                                                       │    │
│  │  User pilih metode bayar                              │    │
│  │    ┌────────────────────────────┐                     │    │
│  │    ▼ CC/VA             ▼ E-Wallet                     │    │
│  │  isCcOrVa=true      isCcOrVa=false                   │    │
│  │  window.location    SapawargaChannel                  │    │
│  │  .href=urlFinpay    .postMessage(url)                 │    │
│  └────┼────────────────────┼──────────────────────────┘    │
│       │                    │                                  │
│  handleNavigation()    handler terima                        │
│  → whitelist check     → _processIncomingMessage             │
│  InAppWebView load URL → _openInCustomTabs(url)              │
│       │                    │                                  │
│  User bayar di WebView  ChromeSafariBrowser.open()           │
│       │                 User bayar di Custom Tab              │
│       │                    │                                  │
│  Finpay redirect ke     Finpay redirect pocapp://            │
│  return URL             → app_links stream                    │
│       │                    │  atau                            │
│  handleNavigation():    onClosed() callback                   │
│  non-http → external   _notifyPaymentCompleted()              │
│  OR return URL det.         │                                  │
│  _notifyPaymentCompleted()  │                                  │
│       └────────────────────┘                                  │
│                  ▼                                            │
│  evaluateJavascript:                                          │
│  "window.dispatchEvent(new CustomEvent('paymentCompleted'))" │
│                  │                                            │
│  ┌───────────────▼──────────────────────────────────────┐    │
│  │  Flutter PKB: registerPaymentListener aktif           │    │
│  │  → doVerifyPayment() langsung (tanpa tunggu timer)    │    │
│  │  → api.paymentVerification(kodeBayar)                 │    │
│  │  → sukses: isPaymentSuccess=true                      │    │
│  │  → gagal: timer polling 5 detik lanjut               │    │
│  └──────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## Kode Aktual — PKB Side

### finpay_navigation_web.dart

```dart
void navigateToFinpayImpl(String urlFinpay, {String? methodType}) {
  if (urlFinpay.isEmpty) return;
  final String method = (methodType ?? "").toUpperCase();

  // JALUR A: CC/VA → _navigateWindowLocation() (safe, tanpa eval injection)
  final bool isCcOrVa = method.contains('CC') ||
      method.contains('CREDIT') ||
      method.contains('VA')     || method.contains('VIRTUAL') ||
      method.contains('ACCOUNT')|| method.contains('BJB') ||
      method.contains('BCA')    || method.contains('BRI') ||
      method.contains('BNI')    || method.contains('MANDIRI');

  if (isCcOrVa) {
    _navigateWindowLocation(urlFinpay); // DOM property assignment, bukan eval
    return;
  }

  // JALUR B: E-Wallet → kirim ke host via SapawargaChannel
  if (js.context.hasProperty('SapawargaChannel')) {
    js.context['SapawargaChannel'].callMethod('postMessage', [urlFinpay]);
  } else {
    _navigateWindowLocation(urlFinpay); // fallback: bukan di host app
  }
}
```

### detail_pembayaran_controller.dart

```dart
// Dev mode: random 70% sukses
static const bool fakePayment = bool.fromEnvironment('FAKE_PAYMENT');

// initState: daftarkan listener segera
if (kIsWeb) registerPaymentListener(() => doVerifyPayment());

// dispose: bersihkan listener
if (kIsWeb) unregisterPaymentListener();
stopTimer(); // safe karena ada guard isTimerActive && timer.isActive
super.dispose();

// doVerifyPayment: fake payment
if (fakePayment) {
  await Future.delayed(const Duration(milliseconds: 800));
  final isSuccess = DateTime.now().millisecondsSinceEpoch % 10 < 7;
  result = {'data': {'status_payment': isSuccess}};
}
```

---

## Kode Aktual — Host App Side (hybrid_webview_controller.dart)

### handleNavigation — Whitelist + Result Detection

```dart
Future<NavigationActionPolicy> handleNavigation(NavigationAction action) async {
  final uri = action.request.url;
  final rawUrl = uri?.toString() ?? '';
  if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

  // 1. Non-http scheme (pocapp://) → handle external & CANCEL
  if (uri != null && !uri.scheme.startsWith('http')) {
    launchUrl(uri, mode: LaunchMode.externalApplication);
    return NavigationActionPolicy.CANCEL;
  }

  // 2. Deteksi halaman hasil CC/VA (live.finpay.id/pg/payment/card/result/*)
  //    → trigger paymentCompleted, tetap ALLOW agar user lihat halaman hasil
  if (_config.isPaymentResultUrl(rawUrl)) {
    _notifyPaymentCompleted();
    return NavigationActionPolicy.ALLOW;
  }

  // 3. Whitelist: PKB domain + live.finpay.id → ALLOW
  if (_config.isWebViewNavigationAllowed(rawUrl)) {
    return NavigationActionPolicy.ALLOW;
  }

  // 4. Di luar whitelist → CANCEL (security guard)
  return NavigationActionPolicy.CANCEL;
}
```

> **Kenapa e-wallet tidak masuk sini:** E-wallet dihandle `SapawargaChannel.postMessage` → `_processIncomingMessage` → `_openInCustomTabs` **sebelum** menyentuh WebView navigation. Jadi apapun yang masuk `shouldOverrideUrlLoading` adalah URL CC/VA → di-whitelist → ALLOW.

### Bridge & Notifikasi

```dart
// Bridge injection (AT_DOCUMENT_START — sebelum PKB load)
window['SapawargaChannel'] = { postMessage: fn → callHandler('SapawargaChannel', url) }

// Terima postMessage dari PKB — validasi hanya https://
addJavaScriptHandler('SapawargaChannel', (args) {
  final uri = Uri.tryParse(args[0]);
  if (uri?.scheme == 'https') _openInCustomTabs(args[0]);
})

// Notifikasi ke PKB — double-fire guard (flag + 3 detik auto-reset)
void _notifyPaymentCompleted() {
  if (_paymentNotified) return; // skip jika sudah dispatch
  _paymentNotified = true;
  evaluateJavascript("window.dispatchEvent(new CustomEvent('paymentCompleted',{detail:{ts:Date.now()}}));");
  Future.delayed(Duration(seconds: 3), () => _paymentNotified = false);
}

// Tempat 1: Custom Tab ditutup user
_PaymentChromeBrowser(onClosedCallback: () { _notifyPaymentCompleted(); smartGoBack(); })

// Tempat 2: Deep link pocapp:// diterima
//   URUTAN PENTING: notify DULU, baru close (cegah double-fire via onClosed)
_appLinks.uriLinkStream.listen((uri) {
  if (uri.scheme == 'pocapp' && uri.host == 'payment') {
    _notifyPaymentCompleted(); // flag=true
    _browser.close();          // onClosed() akan skip karena flag sudah true
  }
})

// Tempat 3: CC/VA result page terdeteksi di handleNavigation
// → isPaymentResultUrl() → _notifyPaymentCompleted()
```

---

## Alur Lengkap Per Jalur

### Jalur A — CC / Virtual Account

```
[1] PKB: navigateToFinpay(url, methodType: 'VA')
[2] isCcOrVa=true → _navigateWindowLocation(urlFinpay) [safe, no eval injection]
[3] InAppWebView: shouldOverrideUrlLoading dipanggil
[4] handleNavigation: uri.scheme='https', host='live.finpay.id'
    → isWebViewNavigationAllowed() = true → ALLOW ✅
[5] InAppWebView load halaman Finpay (live.finpay.id)
[6] User bayar di halaman Finpay
[7] Finpay redirect ke result page:
    → https://live.finpay.id/pg/payment/card/result/success
      isPaymentResultUrl() = true → _notifyPaymentCompleted() + ALLOW
    → pocapp://payment/return (alternatif)
      handleNavigation → launchUrl external → _initDeepLinks pick up
[8] PKB terima event → doVerifyPayment() → api.paymentVerification() → sukses
    Timer polling berhenti (stopTimer() setelah isPaymentSuccess=true)
```

### Jalur B — E-Wallet (DANA, ShopeePay, LinkAja)

```
[1] PKB: navigateToFinpay(url, methodType: 'DANA')
[2] isCcOrVa=false → SapawargaChannel.postMessage(url)
[3] bridge forward ke flutter_inappwebview.callHandler
[4] _processIncomingMessage(url) → _openInCustomTabs(url)
    (WebView TIDAK navigate — shouldOverrideUrlLoading TIDAK dipanggil)
[5] ChromeSafariBrowser.open() → Custom Tab buka Finpay
[6] User pilih DANA → Custom Tab buka aplikasi DANA
[7] Konfirmasi di DANA → Finpay redirect ke pocapp://
[8] app_links stream terima → _notifyPaymentCompleted() → browser.close()
    ATAU: user tutup manual → onClosed() → _notifyPaymentCompleted()
[9] PKB terima event → doVerifyPayment() → sukses
```

---

## Sistem Fallback (3 Lapis)

```
Lapis 1 — EVENT (0 detik):
  Host dispatch 'paymentCompleted'
  → handlePaymentCompletedFromHost()
  → stopTimer() segera  ← timer dihentikan SEBELUM verify
  → doVerifyPayment(fromTimer: false)
  → reentrancy guard (if isChecking return)

Lapis 2 — onClosed (segera setelah Custom Tab ditutup):
  _PaymentChromeBrowser.onClosed() → _notifyPaymentCompleted()
  Covers: user tutup manual, deep link tidak terdeteksi
  Double-fire guard: _paymentNotified flag mencegah duplikat dari deep link + onClosed

Lapis 3 — TIMER (setiap 5 detik, nullable Timer?):
  waitingStatusPembayaran() timer sejak initState()
  Otomatis berhenti saat:
    - isPaymentSuccess=true → stopTimer() di doVerifyPayment
    - handlePaymentCompletedFromHost() → stopTimer() langsung
  Reentrancy guard mencegah tick timer yang terlanjur terjadwal dari menjalankan API call paralel
```

---

## Status Verifikasi Final ✅

### PKB Side

| Item | Status |
|------|--------|
| Routing CC/VA → `window.location.href` via `_navigateWindowLocation()` (safe, no eval injection) | ✅ **FIXED** |
| Routing e-wallet → `SapawargaChannel.postMessage` | ✅ |
| Fallback jika SapawargaChannel tidak ada (debug mode) | ✅ |
| `registerPaymentListener` di `initState` dengan guard `kIsWeb` | ✅ |
| `unregisterPaymentListener` di `dispose` sebelum `super.dispose()` — semicolon fix | ✅ **FIXED** |
| `stopTimer()` setelah `isPaymentSuccess = true` | ✅ **FIXED** |
| `stopTimer()` safe guard nullable `Timer?` (no `LateInitializationError`) | ✅ **FIXED** |
| `doVerifyPayment()` reentrancy guard (`if (isChecking) return`) | ✅ **FIXED** |
| `handlePaymentCompletedFromHost()` → `stopTimer()` sebelum verify | ✅ **FIXED** |
| `showFinpayRedirectScreen` di-reset saat verify sukses | ✅ **FIXED** |
| Listener `paymentCompleted` log `event.detail.ts` | ✅ **FIXED** |
| `webview_finpay.dart` + `base_webview.dart` → marked LEGACY, `CustomEvent` | ✅ **FIXED** |
| Notify-before-close order di standalone deep link handler | ✅ **FIXED** |
| Platform detection `kIsWeb` (bukan try/catch) | ✅ |
| Mock payment di API layer (`api_service_pkb.dart`) — controller bersih | ✅ **UPDATED** |

### Host App Side

| Item | Status |
|------|--------|
| Bridge `SapawargaChannel` inject `AT_DOCUMENT_START` | ✅ |
| Handler terima postMessage → Custom Tab | ✅ |
| Bridge validation: hanya terima `https://` URL | ✅ **FIXED** |
| `handleNavigation`: non-http → external, http/https → ALLOW | ✅ **FIXED** |
| `handleNavigation`: whitelist aktif (PKB + `live.finpay.id`) | ✅ **FIXED** |
| `handleNavigation`: CC/VA result page → trigger notify | ✅ **FIXED** |
| `_notifyPaymentCompleted`: double-fire guard (flag + 3s reset) | ✅ **FIXED** |
| Log sanitasi URL (tanpa query params) | ✅ **FIXED** |
| `_initDeepLinks`: notify DULU sebelum close browser | ✅ **FIXED** |
| Deep link log dengan scheme+host+path (tanpa query) | ✅ **FIXED** |

---

## 🗑️ PROMPT: Aktifkan Production Mode

```
Aktifkan API sungguhan untuk payment verification.
Jangan ubah alur kode yang lain.

File target:
  packages/core/lib/service/api_service_pkb.dart

Yang harus dilakukan:

1. Di method paymentVerification(), hapus blok DEMO MODE (baris return + delay + random):
     await Future.delayed(const Duration(milliseconds: 600));
     final bool isSuccess = Random().nextBool();
     debugPrint(...);
     return { ... status_payment: isSuccess ... };

2. Hapus komentar "// ignore: dead_code" di atas blok try.

3. Hapus import 'dart:math'; jika tidak dipakai di tempat lain.

4. Hapus import 'package:flutter/foundation.dart'; jika tidak dipakai di tempat lain.

Hasil akhir: method paymentVerification() langsung memanggil API
  client.apiCall(url: Endpoints.paymentVerification, ...).

Syarat: jangan ubah method lain, jangan ubah file lain.
```

---

## 🏗️ KONTRAK INTEGRASI HOST APP (Production-Ready)

```
ARSITEKTUR:
- PKB   : Flutter Web App — bridge via window.SapawargaChannel.postMessage(url)
- Host  : Flutter native — InAppWebView + ChromeSafariBrowser
- CC/VA : PKB → _navigateWindowLocation() → WebView load live.finpay.id
- E-wallet: PKB → SapawargaChannel → host buka Custom Tab

=== 1. BRIDGE (SapawargaChannel) ===
Inject UserScript AT_DOCUMENT_START:
  window['SapawargaChannel'] = {
    postMessage: function(url) {
      flutter_inappwebview.callHandler('SapawargaChannel', url);
    }
  }
addJavaScriptHandler('SapawargaChannel', (args) {
  // Validasi: hanya https:// yang diizinkan dari bridge
  if (Uri.parse(args[0]).scheme == 'https') openCustomTab(args[0]);
})

=== 2. WHITELIST & handleNavigation ===
Logika (urutan penting):
  1. non-http scheme → launchUrl external → CANCEL
  2. isPaymentResultUrl()  → _notifyPaymentCompleted() + ALLOW  ← CC/VA selesai
  3. isWebViewNavigationAllowed() → ALLOW  ← PKB domain + live.finpay.id
  4. else → CANCEL  ← security guard

Default whitelist (WEBVIEW_ALLOWED_HOSTS):
  test-sambara.vercel.app, live.finpay.id

Payment result patterns (isPaymentResultUrl):
  /payment/card/result/, /payment/result/, /payment/return,
  /payment/callback, /payment/success, /payment/failed

=== 3. NOTIFIKASI KE PKB ===
Dispatch CustomEvent (bukan Event biasa):
  window.dispatchEvent(new CustomEvent('paymentCompleted', {detail:{ts:Date.now()}}))

Double-fire guard: _paymentNotified flag (auto-reset 3 detik)
Dipanggil dari 3 tempat:
  - isPaymentResultUrl detected (CC/VA selesai)
  - _initDeepLinks: pocapp://payment/return diterima  [notify DULU, baru close]
  - ChromeSafariBrowser.onClosed()                   [E-wallet tutup manual]

=== 4. DEEP LINK (pocapp://) ===
AndroidManifest: intent-filter scheme="pocapp" host="payment"
Info.plist: CFBundleURLSchemes = ["pocapp"]
app_links package untuk listen deep link stream.

=== 5. VERIFIKASI PEMBAYARAN (PKB) ===
Semua trigger berujung ke satu method:
  doVerifyPayment() → api.paymentVerification(kodeBayar)
  → result["data"]["status_payment"] true/false
  → isPaymentSuccess=true → showFinpayRedirectScreen=false → stopTimer()
  → finally { isChecking=false; update(); }

Keamanan:
  - Reentrancy guard: if (isChecking) return — hanya 1 API call sekaligus
  - Timer? nullable — aman dari LateInitializationError
  - handlePaymentCompletedFromHost() panggil stopTimer() SEBELUM verify
  - finally block memastikan isChecking selalu di-reset

Controller TIDAK tahu apakah API mock atau real.
Mock/real dikontrol HANYA di api_service_pkb.dart.

=== 6. DEMO MODE ===
Mock ada di: packages/core/lib/service/api_service_pkb.dart
  → paymentVerification() return random 50% sukses (Random().nextBool())
  → Delay 600ms simulasi latency
  → Kode production ada di bawahnya (dead code sementara)

Untuk aktifkan production: hapus blok mock, uncomment blok API.
Controller tidak perlu diubah.
```
