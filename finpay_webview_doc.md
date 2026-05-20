# Dokumentasi Alur Pembayaran Finpay — PKB WebView

> **Versi:** v5 (2026-05-20)
> **Arsitektur:** Stack WebView Strategy
> **Konteks:** Flutter PKB Web App berjalan di InAppWebView milik host app (`web_view_prototype`).
> Komunikasi PKB → Host via `console.log(JSON.stringify({type:"finpay_navigation", url, kodeBayar}))`.

---

## Domain Terverifikasi

| Metode | Domain | Jalur | Navigasi |
|--------|--------|-------|----------|
| Kartu Kredit | `live.finpay.id` | A — WebView Sambara | Whitelist ✅ |
| Virtual Account | `live.finpay.id` | A — WebView Sambara | Whitelist ✅ |
| DANA | `m.dana.id` | B — PaymentWebViewPage | Via console.log |
| ShopeePay | `app.shopeepay.co.id` | B — PaymentWebViewPage | Via console.log |
| LinkAja | `payment.linkaja.id` | B — PaymentWebViewPage | Via console.log |

> **Return URL CC/VA:** Finpay redirect ke `live.finpay.id/pg/payment/card/result/{success|failed|pending}`.
> Host detect pola path ini via `isPaymentResultUrl()`.

---

## Mengapa Ada Dua Jalur Pembayaran?

### Kelompok A — Kartu Kredit & Virtual Account
- Proses bayar terjadi **seluruhnya di halaman web** Finpay.
- PKB redirect via `window.location.href` → InAppWebView Sambara load halaman Finpay.
- Setelah selesai, Finpay redirect ke return URL → host detect → navigasi kembali.

### Kelompok B — E-Wallet (DANA, ShopeePay, LinkAja, dll.)
- Finpay generate **URL checkout** ke payment gateway.
- PKB kirim URL + kodeBayar ke host via `console.log(JSON.stringify({...}))`.
- Host push `PaymentWebViewPage` → halaman payment terbuka di atas Sambara.
- Sambara tetap hidup di background, state 100% preserved.

---

## Arsitektur Stack WebView

```
┌──────────────────────────────────────────────────────────────┐
│          HOST APP: web_view_prototype (Flutter Native)         │
│                                                                │
│  HybridWebViewController                                       │
│    handleConsoleMessage()  ← parse finpay_navigation JSON     │
│    _openPaymentPage()     ← Navigator.push(PaymentWebViewPage)│
│    _checkPaymentStatus()  ← Dio polling setiap 5 detik       │
│    _notifyPaymentCompleted() / _notifyPaymentHold()           │
│    _initDeepLinks()       ← listen pocapp:// via app_links   │
│    handleNavigation()     ← whitelist + result detection      │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │          InAppWebView Sambara (Flutter PKB Web App)       │  │
│  │                                                           │  │
│  │  User pilih metode bayar                                  │  │
│  │    ┌──────────────────────┐                               │  │
│  │    ▼ CC/VA          ▼ E-Wallet                            │  │
│  │  isCcOrVa=true    isCcOrVa=false                          │  │
│  │  window.location   console.log(JSON.stringify({           │  │
│  │  .href=urlFinpay     type:"finpay_navigation",            │  │
│  │                      url:"https://...",                   │  │
│  │                      kodeBayar:"..."                      │  │
│  │                    }))                                     │  │
│  └────┼───────────────────┼──────────────────────────────────┘  │
│       │                   │                                      │
│  handleNavigation()   onConsoleMessage                          │
│  → whitelist check    → handleConsoleMessage()                  │
│  WebView load URL     → _openPaymentPage(url, kodeBayar)       │
│       │                   │                                      │
│  User bayar di        Navigator.push(PaymentWebViewPage)        │
│  WebView Sambara      Sambara tetap hidup di bawah ✅           │
│       │                   │                                      │
│  Finpay redirect ke   ┌───┴──────────────────────────────┐     │
│  return URL           │ Skenario 1: API isPaid=true       │     │
│       │               │ → Navigator.pop()                 │     │
│  handleNavigation():  │ → paymentCompleted ke Sambara     │     │
│  result URL detected  ├──────────────────────────────────┤     │
│       │               │ Skenario 2: User tekan Back       │     │
│       │               │ → Navigator.pop()                 │     │
│       │               │ → paymentHold ke Sambara          │     │
│       │               ├──────────────────────────────────┤     │
│       │               │ Skenario 3: Deep link return      │     │
│       │               │ → Navigator.pop()                 │     │
│       │               └──────────────────────────────────┘     │
│       └───────────────────┘                                      │
│                  ▼                                                │
│  evaluateJavascript:                                              │
│  paymentCompleted → PKB verifikasi → sukses                      │
│  paymentHold      → PKB tampilkan dialog pembatalan              │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Flutter PKB: Event Listener                              │  │
│  │  'paymentCompleted' → doVerifyPayment() → sukses         │  │
│  │  'paymentHold'      → dialog konfirmasi pembatalan       │  │
│  └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Kode Aktual — PKB Side

### finpay_navigation_web.dart

```dart
void navigateToFinpayImpl(String urlFinpay, {String? methodType}) {
  if (urlFinpay.isEmpty) return;
  final String method = (methodType ?? "").toUpperCase();

  // JALUR A: CC/VA → window.location.href
  final bool isCcOrVa = method.contains('CC') ||
      method.contains('CREDIT') ||
      method.contains('VA') || method.contains('VIRTUAL') ||
      method.contains('ACCOUNT')|| method.contains('BJB') ||
      method.contains('BCA')    || method.contains('BRI') ||
      method.contains('BNI')    || method.contains('MANDIRI');

  if (isCcOrVa) {
    _navigateWindowLocation(urlFinpay);
    return;
  }

  // JALUR B: E-Wallet → kirim ke host via console.log JSON
  final jsonPayload = jsonEncode({
    'type': 'finpay_navigation',
    'url': urlFinpay,
    'kodeBayar': currentKodeBayar,
  });
  print(jsonPayload);  // console.log ke host app
}
```

### detail_pembayaran_controller.dart

```dart
// initState: daftarkan listener segera
if (kIsWeb) registerPaymentListener(() => doVerifyPayment());

// dispose: bersihkan listener
if (kIsWeb) unregisterPaymentListener();
stopTimer();
super.dispose();

// doVerifyPayment: reentrancy-safe
doVerifyPayment({bool fromTimer = false}) async {
  if (isChecking) return;
  isChecking = true;
  try {
    final result = await api.paymentVerification(kodeBayar: kodeBayar);
    if (result['data']['status_payment'] == true) {
      isPaymentSuccess = true;
      showFinpayRedirectScreen = false;
      stopTimer();
    }
  } finally {
    isChecking = false;
    update();
  }
}
```

---

## Kode Aktual — Host App Side (hybrid_webview_controller.dart)

### 1. Console Message Handler

```dart
void handleConsoleMessage(String message) {
  if (!message.contains('finpay_navigation')) return;
  final Map<String, dynamic> json = jsonDecode(message);
  if (json['type'] != 'finpay_navigation') return;

  final String? url = json['url']?.toString().trim();
  final String? kodeBayar = json['kodeBayar']?.toString().trim();
  if (url == null || url.isEmpty) return;

  _openPaymentPage(url, kodeBayar);
}
```

### 2. Push Payment Page (Stack Navigator)

```dart
Future<void> _openPaymentPage(String url, String? kodeBayar) async {
  if (_isPaymentPageOpen) return;

  _activeKodeBayar = kodeBayar;
  _isPaymentPageOpen = true;
  _startPaymentStatusPolling();

  await Navigator.of(ctx).push(
    MaterialPageRoute(
      builder: (_) => PaymentWebViewPage(paymentUrl: url, kodeBayar: kodeBayar ?? ''),
    ),
  );

  // Setelah pop: cleanup
  _isPaymentPageOpen = false;
  if (_paymentStatusPoller != null) {
    _stopPaymentStatusPolling();
    _notifyPaymentHold();
  }
  _activeKodeBayar = null;
}
```

### 3. API Polling (Dio, 5 detik, max 15 menit)

```dart
final Dio _dio = Dio(BaseOptions(
  baseUrl: 'http://192.168.99.46:8700',
  connectTimeout: Duration(seconds: 5),
  receiveTimeout: Duration(seconds: 5),
));

Future<void> _checkPaymentStatus() async {
  final response = await _dio.post<Map<String, dynamic>>(
    '/api/check-dummy-payment-status',
    data: {'kodeBayar': _activeKodeBayar},
  );
  final body = response.data!;
  final bool isPaid = body['success'] == true && body['code'] == '0000';

  if (isPaid) {
    _stopPaymentStatusPolling();
    Navigator.of(ctx).pop();  // Payment page hilang → Sambara muncul
    Future.delayed(Duration(milliseconds: 500), () {
      _notifyPaymentCompleted();
    });
  }
}
```

### 4. Events ke Sambara

```dart
// paymentCompleted — pembayaran lunas
_webViewController?.evaluateJavascript(
  source: "window.dispatchEvent(new CustomEvent('paymentCompleted', "
          "{detail:{ts:Date.now(), kodeBayar:'...', status:'success'}}));",
);

// paymentHold — user cancel
_webViewController?.evaluateJavascript(
  source: "window.dispatchEvent(new CustomEvent('paymentHold', "
          "{detail:{ts:Date.now(), kodeBayar:'...'}}));",
);
```

---

## Alur Lengkap Per Jalur

### Jalur A — CC / Virtual Account

```
[1] PKB: navigateToFinpay(url, methodType: 'VA')
[2] isCcOrVa=true → _navigateWindowLocation(urlFinpay)
[3] InAppWebView: shouldOverrideUrlLoading dipanggil
[4] handleNavigation: host='live.finpay.id'
    → isWebViewNavigationAllowed() = true → ALLOW ✅
[5] WebView Sambara load halaman Finpay
[6] User bayar di halaman Finpay
[7] Finpay redirect ke result page:
    → live.finpay.id/pg/payment/card/result/success
    → isPaymentResultUrl() = true → ALLOW
[8] PKB terima event → doVerifyPayment() → sukses
```

### Jalur B — E-Wallet (DANA, ShopeePay, LinkAja)

```
[1] PKB: navigateToFinpay(url, methodType: 'DANA')
[2] isCcOrVa=false → console.log(JSON.stringify({type:"finpay_navigation", url, kodeBayar}))
[3] onConsoleMessage → handleConsoleMessage() → parse JSON
[4] _openPaymentPage(url, kodeBayar):
    a. Start Dio polling (5 detik, max 15 menit)
    b. Navigator.push(PaymentWebViewPage) — Sambara tetap hidup

    Skenario 1 — Polling detect paid:
      [5a] _checkPaymentStatus() → isPaid=true (code: "0000")
      [6a] Navigator.pop() → Sambara muncul di last state ✅
      [7a] Dispatch paymentCompleted ke Sambara (500ms delay)
      [8a] PKB: doVerifyPayment() → sukses

    Skenario 2 — User tekan Back:
      [5b] Navigator.pop() → Sambara muncul di last state ✅
      [6b] Polling stop + dispatch paymentHold
      [7b] Sambara tampilkan dialog pembatalan

    Skenario 3 — Deep link return:
      [5c] pocapp://payment/return → app_links stream
      [6c] Navigator.pop() → Sambara muncul di last state ✅

    Skenario 4 — Timeout 15 menit:
      [5d] Polling auto-stop
      [6d] Payment page masih terbuka — user bisa back manual
```

---

## Sistem Verifikasi (2 Lapis)

```
Lapis 1 — EVENT (langsung, dari host app):
  paymentCompleted → handlePaymentCompletedFromHost()
    → stopTimer() segera (sebelum verify)
    → doVerifyPayment(fromTimer: false)
    → reentrancy guard (if isChecking return)

Lapis 2 — TIMER (setiap 5 detik, dari PKB):
  waitingStatusPembayaran() timer sejak initState()
  Otomatis berhenti saat:
    - isPaymentSuccess=true → stopTimer() di doVerifyPayment
    - handlePaymentCompletedFromHost() → stopTimer() langsung
  Reentrancy guard mencegah tick timer yang terlanjur terjadwal
```

---

## Status Verifikasi Final ✅

### PKB Side

| Item | Status |
|------|--------|
| Routing CC/VA → `window.location.href` via `_navigateWindowLocation()` | ✅ |
| Routing e-wallet → `console.log(JSON.stringify({...}))` | ✅ |
| Fallback: `SapawargaChannel.postMessage(url)` jika di luar host app | ✅ |
| `registerPaymentListener` di `initState` dengan guard `kIsWeb` | ✅ |
| `unregisterPaymentListener` di `dispose` sebelum `super.dispose()` | ✅ |
| `stopTimer()` setelah `isPaymentSuccess = true` | ✅ |
| `doVerifyPayment()` reentrancy guard (`if (isChecking) return`) | ✅ |
| Listener `paymentCompleted` → `doVerifyPayment()` | ✅ |
| Listener `paymentHold` → dialog konfirmasi pembatalan | ✅ |

### Host App Side

| Item | Status |
|------|--------|
| `onConsoleMessage` → `handleConsoleMessage()` parse finpay_navigation | ✅ |
| Bridge `SapawargaChannel` inject `AT_DOCUMENT_START` (fallback) | ✅ |
| `handleNavigation`: whitelist (Sambara + `live.finpay.id`) | ✅ |
| `handleNavigation`: CC/VA result page → ALLOW di Sambara WebView | ✅ |
| `_openPaymentPage()` → `Navigator.push(PaymentWebViewPage)` | ✅ |
| Dio polling: 5 detik interval, 15 menit max | ✅ |
| isPaid → `Navigator.pop()` + `paymentCompleted` | ✅ |
| User Back → `Navigator.pop()` + `paymentHold` | ✅ |
| Deep link `pocapp://` → `Navigator.pop()` | ✅ |
| `dispose()` → stop polling + close Dio + cancel deep link | ✅ |
| ~~Custom Tab / ChromeSafariBrowser~~ | ❌ **DIHAPUS** |
| ~~Dialog konfirmasi host-side~~ | ❌ **DIHAPUS** (Sambara handle) |
| ~~Timer bypass / simulasi~~ | ❌ **DIHAPUS** |
| ~~PaymentInfoChannel~~ | ❌ **DIHAPUS** |

---

## Kontrak Integrasi (v5 — Production-Ready)

```
ARSITEKTUR:
- PKB   : Flutter Web App — console.log(JSON) untuk e-wallet, window.location untuk CC/VA
- Host  : Flutter native — InAppWebView Sambara + PaymentWebViewPage (stack) + Dio Polling
- CC/VA : PKB → _navigateWindowLocation() → WebView Sambara load live.finpay.id
- E-wallet: PKB → console.log({type:"finpay_navigation",...}) → host push PaymentWebViewPage

=== 1. CONSOLE MESSAGE HANDLER ===
onConsoleMessage → handleConsoleMessage(message)
  → parse JSON: { type:"finpay_navigation", url, kodeBayar }
  → _openPaymentPage(url, kodeBayar)

=== 2. STACK NAVIGATOR ===
Navigator.push(PaymentWebViewPage) → halaman payment terbuka di atas
Sambara tetap hidup di bawah stack → state 100% preserved
Payment page: ALLOW semua HTTP/HTTPS, non-http → launchUrl external

=== 3. DIO POLLING STATUS PEMBAYARAN ===
Endpoint: POST /api/check-dummy-payment-status
Body: { "kodeBayar": "..." }
Interval: 5 detik (Timer.periodic)
Max: 15 menit
Guard: _isPollingPayment flag mencegah concurrent call
isPaid: success == true && code == "0000"
→ Navigator.pop() + paymentCompleted (500ms delay)

=== 4. WHITELIST & handleNavigation ===
Logika (urutan):
  1. non-http scheme → launchUrl external → CANCEL
  2. isPaymentResultUrl() → ALLOW (CC/VA selesai)
  3. isWebViewNavigationAllowed() → ALLOW (Sambara + Finpay)
  4. else → openPaymentPage → Navigator.push(PaymentWebViewPage)

=== 5. EVENTS KE SAMBARA ===
paymentCompleted: { ts, kodeBayar, status:'success' }
  Trigger: Dio polling isPaid=true
paymentHold: { ts, kodeBayar }
  Trigger: User back dari payment page

=== 6. DEEP LINK (pocapp://) ===
AndroidManifest: intent-filter scheme="pocapp" host="payment"
app_links package untuk listen deep link stream.
→ Navigator.pop() + cleanup
```
