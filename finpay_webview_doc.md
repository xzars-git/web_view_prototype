# Dokumentasi Alur Pembayaran Finpay — PKB WebView
> **Terakhir diverifikasi:** 2026-05-20
> **Konteks:** Flutter PKB berjalan sebagai Flutter Web App di dalam InAppWebView milik host app (`web_view_prototype`).
> Komunikasi dari PKB ke host via `console.log(JSON.stringify({type:"finpay_navigation", url, kodeBayar}))`.

## Domain Terverifikasi

| Metode | Domain | Jalur | Whitelist? |
|--------|--------|-------|------------|
| Kartu Kredit | `live.finpay.id` | A — WebView | ✅ |
| Virtual Account | `live.finpay.id` | A — WebView | ✅ |
| DANA | `m.dana.id` | B — Custom Tab | ❌ (via console.log) |
| ShopeePay | `app.shopeepay.co.id` | B — Custom Tab | ❌ (via console.log) |
| LinkAja | `payment.linkaja.id` | B — Custom Tab | ❌ (via console.log) |

> **Return URL CC/VA:** Finpay redirect ke `live.finpay.id/pg/payment/card/result/{success|failed|pending}`
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
- PKB kirim URL + kodeBayar ke host via `console.log(JSON.stringify({...}))` → host buka Custom Tab.

---

## Arsitektur Aktual

```
┌─────────────────────────────────────────────────────────────┐
│          HOST APP: web_view_prototype (Flutter Native)       │
│                                                              │
│  HybridWebViewController                                     │
│    _PaymentChromeBrowser   ← onClosed() → showPaymentHold   │
│    bridgeUserScript        ← inject SapawargaChannel (fb)   │
│    handleConsoleMessage()  ← PRIMARY: parse finpay JSON     │
│    _checkPaymentStatus()   ← polling API setiap 3 detik    │
│    _showPaymentHoldDialog()← dialog konfirmasi saat close   │
│    _initDeepLinks()        ← listen pocapp:// via app_links│
│    handleNavigation()      ← whitelist + result detection   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │          InAppWebView (Flutter PKB Web App)           │    │
│  │                                                       │    │
│  │  User pilih metode bayar                              │    │
│  │    ┌────────────────────────────┐                     │    │
│  │    ▼ CC/VA             ▼ E-Wallet                     │    │
│  │  isCcOrVa=true      isCcOrVa=false                   │    │
│  │  window.location    console.log(JSON.stringify({      │    │
│  │  .href=urlFinpay      type:"finpay_navigation",      │    │
│  │                       url:"https://...",              │    │
│  │                       kodeBayar:"..."                 │    │
│  │                     }))                               │    │
│  └────┼────────────────────┼──────────────────────────┘    │
│       │                    │                                  │
│  handleNavigation()    onConsoleMessage                      │
│  → whitelist check     → handleConsoleMessage()              │
│  InAppWebView load URL → parse JSON → _openInCustomTabs()   │
│       │                    │                                  │
│  User bayar di WebView  Custom Tab buka + polling start      │
│       │                    │                                  │
│  Finpay redirect ke     ┌──┴──────────────────────────┐     │
│  return URL             │ Skenario 1: API paid=true    │     │
│       │                 │ → _notifyPaymentCompleted()  │     │
│  handleNavigation():    │ → _browser.close()           │     │
│  result URL detected    ├──────────────────────────────┤     │
│  _notifyPaymentCompleted│ Skenario 2: Deep link        │     │
│       │                 │ → _notifyPaymentCompleted()  │     │
│       │                 │ → _browser.close()           │     │
│       │                 ├──────────────────────────────┤     │
│       │                 │ Skenario 3: User close tab   │     │
│       │                 │ → dialog konfirmasi          │     │
│       │                 │   "Lanjutkan" → reopenTab    │     │
│       │                 │   "Batalkan" → paymentHold   │     │
│       │                 └──────────────────────────────┘     │
│       └────────────────────┘                                  │
│                  ▼                                            │
│  evaluateJavascript:                                          │
│  paymentCompleted → PKB verifikasi → sukses                  │
│  paymentHold      → PKB hit API batal                        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Flutter PKB: Event Listener                          │    │
│  │  'paymentCompleted' → doVerifyPayment() → sukses     │    │
│  │  'paymentHold'      → hit API pembatalan             │    │
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

  // JALUR B: E-Wallet → kirim ke host via console.log JSON
  // Host app intercept via onConsoleMessage → handleConsoleMessage()
  final jsonPayload = jsonEncode({
    'type': 'finpay_navigation',
    'url': urlFinpay,
    'kodeBayar': currentKodeBayar,  // kode bayar dari controller
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
  if (isChecking) return; // guard
  isChecking = true;
  if (!fromTimer) countChecking++;
  update();
  try {
    final result = await api.paymentVerification(kodeBayar: kodeBayar);
    if (result['data']['status_payment'] == true) {
      isPaymentSuccess = true;
      showFinpayRedirectScreen = false;
      stopTimer();
    }
  } catch (e, stackTrace) { ... }
  finally {
    isChecking = false;
    update();
  }
}
```

---

## Kode Aktual — Host App Side (hybrid_webview_controller.dart)

### 1. Console Message Handler (PRIMARY)

```dart
// Presentation layer — onConsoleMessage callback:
onConsoleMessage: (controller, consoleMessage) {
  _controller.handleConsoleMessage(consoleMessage.message);
},

// Controller — handleConsoleMessage():
void handleConsoleMessage(String message) {
  AppLogger.d("[JS] $message");
  if (!message.contains('finpay_navigation')) return;
  try {
    final Map<String, dynamic> json = jsonDecode(message);
    if (json['type'] != 'finpay_navigation') return;
    final String? url = json['url']?.toString().trim();
    final String? kodeBayar = json['kodeBayar']?.toString().trim();
    if (url == null || url.isEmpty) return;

    _activeKodeBayar = kodeBayar;
    _lastCustomTabUrl = url;

    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;

    _webViewController?.stopLoading();
    _openInCustomTabs(url); // buka Custom Tab + mulai polling
  } catch (e) { /* bukan JSON valid — abaikan */ }
}
```

### 2. API Polling Status Pembayaran

```dart
void _startPaymentStatusPolling() {
  if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) return;
  _stopPaymentStatusPolling();
  _paymentStatusPoller = Timer.periodic(const Duration(seconds: 3), (_) {
    _checkPaymentStatus();
  });
}

Future<void> _checkPaymentStatus() async {
  if (_isPollingPayment) return;
  _isPollingPayment = true;
  try {
    final response = await http.post(
      Uri.parse('http://192.168.99.46:8700/api/check-dummy-payment-status'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'kodeBayar': _activeKodeBayar}),
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      final isPaid = body['data']?['status'] == true || ...;
      if (isPaid) {
        _stopPaymentStatusPolling();
        _paymentNotified = false;
        _notifyPaymentCompleted();
        if (_browser.isOpened()) await _browser.close();
        _activeKodeBayar = null;
        _lastCustomTabUrl = null;
      }
    }
  } catch (e, stack) {
    AppLogger.e("[Polling] error", e, stack);
  } finally {
    _isPollingPayment = false;
  }
}
```

### 3. Payment Hold (onClosed + Dialog)

```dart
// Browser onClosed callback:
_PaymentChromeBrowser(
  onClosedCallback: () {
    AppLogger.d("[Browser] Custom Tab closed by user");
    _stopPaymentStatusPolling();
    _showPaymentHoldDialog();  // dialog, bukan langsung notify
  },
);

// Dispatch paymentHold:
void _notifyPaymentHold() {
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('paymentHold', "
            "{detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}'}}));",
  );
}
```

### 4. Notifikasi paymentCompleted

```dart
void _notifyPaymentCompleted() {
  if (_paymentNotified) return;
  _paymentNotified = true;
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('paymentCompleted', "
            "{detail:{ts:Date.now()}}));",
  );
  Future.delayed(const Duration(seconds: 3), () => _paymentNotified = false);
}
```

---

## Alur Lengkap Per Jalur

### Jalur A — CC / Virtual Account

```
[1] PKB: navigateToFinpay(url, methodType: 'VA')
[2] isCcOrVa=true → _navigateWindowLocation(urlFinpay)
[3] InAppWebView: shouldOverrideUrlLoading dipanggil
[4] handleNavigation: uri.scheme='https', host='live.finpay.id'
    → isWebViewNavigationAllowed() = true → ALLOW ✅
[5] InAppWebView load halaman Finpay (live.finpay.id)
[6] User bayar di halaman Finpay
[7] Finpay redirect ke result page:
    → https://live.finpay.id/pg/payment/card/result/success
      isPaymentResultUrl() = true → _notifyPaymentCompleted() + ALLOW
[8] PKB terima event → doVerifyPayment() → api.paymentVerification() → sukses
```

### Jalur B — E-Wallet (DANA, ShopeePay, LinkAja)

```
[1] PKB: navigateToFinpay(url, methodType: 'DANA')
[2] isCcOrVa=false → console.log(JSON.stringify({type:"finpay_navigation", url, kodeBayar}))
[3] onConsoleMessage → handleConsoleMessage() → parse JSON
[4] _openInCustomTabs(url) → Custom Tab buka + _startPaymentStatusPolling()
[5] User pilih DANA → Custom Tab buka aplikasi DANA
[6] Polling berjalan setiap 3 detik...

    Skenario 1 — API polling sukses:
      [7a] _checkPaymentStatus() → isPaid=true
      [8a] _notifyPaymentCompleted() → _browser.close()
      [9a] PKB terima paymentCompleted → doVerifyPayment() → sukses ✅

    Skenario 2 — Deep link diterima:
      [7b] pocapp://payment/return → app_links stream
      [8b] _notifyPaymentCompleted() → _browser.close()
      [9b] PKB terima paymentCompleted → sukses ✅

    Skenario 3 — User tutup Custom Tab:
      [7c] onClosed() → _stopPaymentStatusPolling()
      [8c] _showPaymentHoldDialog()
      [9c] User pilih "Lanjutkan Bayar" → _reopenCustomTab() → kembali ke [4]
           User pilih "Batalkan" → _notifyPaymentHold() → PKB hit API batal
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
| Routing e-wallet → `console.log(JSON.stringify({...}))` | ✅ **UPDATED** |
| Fallback: `SapawargaChannel.postMessage(url)` jika di luar host app | ✅ |
| `registerPaymentListener` di `initState` dengan guard `kIsWeb` | ✅ |
| `unregisterPaymentListener` di `dispose` sebelum `super.dispose()` | ✅ |
| `stopTimer()` setelah `isPaymentSuccess = true` | ✅ |
| `doVerifyPayment()` reentrancy guard (`if (isChecking) return`) | ✅ |
| `handlePaymentCompletedFromHost()` → `stopTimer()` sebelum verify | ✅ |
| `showFinpayRedirectScreen` di-reset saat verify sukses | ✅ |
| Listener `paymentCompleted` log `event.detail.ts` | ✅ |
| Listener `paymentHold` → hit API pembatalan | ✅ **NEW** |
| Mock payment di API layer (`api_service_pkb.dart`) — controller bersih | ✅ |

### Host App Side

| Item | Status |
|------|--------|
| `onConsoleMessage` → `handleConsoleMessage()` parse finpay_navigation JSON | ✅ **NEW** |
| Bridge `SapawargaChannel` inject `AT_DOCUMENT_START` (fallback) | ✅ |
| Handler terima postMessage → Custom Tab (fallback) | ✅ |
| Bridge validation: hanya terima `https://` URL | ✅ |
| `handleNavigation`: whitelist aktif (PKB + `live.finpay.id`) | ✅ |
| `handleNavigation`: CC/VA result page → trigger notify | ✅ |
| `_notifyPaymentCompleted`: double-fire guard (flag + 3s reset) | ✅ |
| API polling: `_startPaymentStatusPolling()` / `_checkPaymentStatus()` | ✅ **NEW** |
| Auto-close Custom Tab saat isPaid=true | ✅ **NEW** |
| `onClosed` → dialog konfirmasi (bukan langsung notify) | ✅ **CHANGED** |
| `_notifyPaymentHold()` dispatch event ke PKB | ✅ **NEW** |
| `_reopenCustomTab()` buka kembali URL terakhir | ✅ **NEW** |
| `_initDeepLinks`: notify DULU sebelum close browser | ✅ |
| Bypass timer (`_demoAutoCloseTimer`) | ❌ **DIHAPUS** |
| Simulation toolbar (3 tombol) | ❌ **DIHAPUS** |
| `PaymentInfoChannel` bridge | ❌ **DIHAPUS** |
| `_forceDummyPayment()` | ❌ **DIHAPUS** |

---

## 🏗️ KONTRAK INTEGRASI HOST APP (v2 — Production-Ready)

```
ARSITEKTUR:
- PKB   : Flutter Web App — console.log(JSON) untuk e-wallet, window.location untuk CC/VA
- Host  : Flutter native — InAppWebView + ChromeSafariBrowser + API Polling
- CC/VA : PKB → _navigateWindowLocation() → WebView load live.finpay.id
- E-wallet: PKB → console.log({type:"finpay_navigation",...}) → host buka Custom Tab

=== 1. CONSOLE MESSAGE HANDLER (PRIMARY) ===
onConsoleMessage → handleConsoleMessage(message)
  → parse JSON: { type:"finpay_navigation", url, kodeBayar }
  → _openInCustomTabs(url) + _startPaymentStatusPolling()
Validasi: hanya https:// URL yang diterima

=== 2. API POLLING STATUS PEMBAYARAN ===
Endpoint: POST http://192.168.99.46:8700/api/check-dummy-payment-status
Body: { "kodeBayar": "..." }
Interval: 3 detik (Timer.periodic)
Guard: _isPollingPayment flag mencegah concurrent call
Hasil isPaid=true → _notifyPaymentCompleted() + _browser.close() + cleanup

=== 3. WHITELIST & handleNavigation ===
Logika (urutan penting):
  1. non-http scheme → launchUrl external → CANCEL
  2. isPaymentResultUrl()  → _notifyPaymentCompleted() + ALLOW  ← CC/VA selesai
  3. isWebViewNavigationAllowed() → ALLOW  ← PKB domain + live.finpay.id
  4. else → CANCEL / openInCustomTab

=== 4. NOTIFIKASI KE PKB ===
paymentCompleted (sukses):
  window.dispatchEvent(new CustomEvent('paymentCompleted', {detail:{ts:Date.now()}}))
  Double-fire guard: _paymentNotified flag (auto-reset 3 detik)
  Dipanggil dari:
    - API polling isPaid=true
    - Deep link pocapp://payment/return
    - CC/VA result URL terdeteksi di handleNavigation

paymentHold (user batalkan):
  window.dispatchEvent(new CustomEvent('paymentHold', {detail:{ts:Date.now(), kodeBayar:'...'}}))
  Dipanggil dari:
    - Dialog konfirmasi → tombol "Batalkan Transaksi"

=== 5. PAYMENT HOLD FLOW ===
onClosed() → _stopPolling() → _showPaymentHoldDialog()
  "Lanjutkan Bayar" → _reopenCustomTab() → _openInCustomTabs() + restart polling
  "Batalkan Transaksi" → _notifyPaymentHold() + cleanup state

=== 6. DEEP LINK (pocapp://) ===
AndroidManifest: intent-filter scheme="pocapp" host="payment"
Info.plist: CFBundleURLSchemes = ["pocapp"]
app_links package untuk listen deep link stream.

=== 7. HOST APP MENGIRIM MAKSIMAL 1 EVENT PER TRANSAKSI ===
  paymentCompleted (jika pembayaran berhasil)
  ATAU
  paymentHold (jika user membatalkan)
  
  TIDAK ADA LAGI: timer bypass, simulasi manual, force-dummy-payment
```
