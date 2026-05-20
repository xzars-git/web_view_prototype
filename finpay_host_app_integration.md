# Panduan Integrasi Host App — PKB WebView Payment
> **Untuk:** Tim pengembang host app (aplikasi native yang mem-wrap PKB sebagai WebView)
> **Versi:** 2026-05-20 (v2.1 — Enhanced Debug Logging + 5s Timeout + Error Suppression)
> **Kontak PKB:** *(isi nama/email tim PKB)*
> **Snippet siap copy-paste:** Lihat `snippet_documentation.md` untuk kode terbaru yang bisa langsung dipakai.

---


## Gambaran Umum

PKB (Pajak Kendaraan Bermotor) adalah **Flutter Web App** yang berjalan di dalam `InAppWebView` milik host app kamu. Kamu tidak perlu mengubah apapun di PKB — cukup implementasikan kontrak di dokumen ini di sisi host app.

```
Host App (Native Flutter)
└── InAppWebView
    └── PKB Flutter Web App  ← sudah jadi, tidak perlu diubah
```

Ketika user memilih metode pembayaran di PKB, ada **2 jalur** yang berbeda:

| Jalur | Metode | Cara Kerja |
|-------|--------|------------|
| **A** | Kartu Kredit, Virtual Account | PKB navigasi langsung di WebView → tetap di InAppWebView |
| **B** | DANA, ShopeePay, LinkAja | PKB kirim JSON via `console.log` → host buka **Chrome Custom Tab** |

---

## Domain yang Terlibat

| Metode | Domain | Dibuka di |
|--------|--------|-----------|
| Kartu Kredit | `live.finpay.id` | InAppWebView (Jalur A) |
| Virtual Account | `live.finpay.id` | InAppWebView (Jalur A) |
| DANA | `m.dana.id` | Chrome Custom Tab (Jalur B) |
| ShopeePay | `app.shopeepay.co.id` | Chrome Custom Tab (Jalur B) |
| LinkAja | `payment.linkaja.id` | Chrome Custom Tab (Jalur B) |

---

## Apa yang Harus Kamu Implementasikan

### ✅ Checklist Implementasi

- [ ] **Intercept `console.log`** — parse JSON `finpay_navigation` untuk dapatkan URL + kodeBayar
- [ ] **Buka URL di Custom Tab** — saat `finpay_navigation` terdeteksi
- [ ] **Polling API status pembayaran** — `POST /api/check-dummy-payment-status` setiap 3 detik
- [ ] **Auto-close Custom Tab** — saat API return status `true`
- [ ] **Dialog konfirmasi pembatalan** — muncul saat user tutup Custom Tab manual
- [ ] **Dispatch `paymentHold`** — saat user konfirmasi batalkan transaksi
- [ ] **Reopen Custom Tab** — saat user pilih lanjutkan bayar di dialog
- [ ] **Bridge `SapawargaChannel`** — inject ke WebView sebagai fallback
- [ ] **`handleNavigation`** — whitelist domain PKB + Finpay
- [ ] **Deep link `pocapp://`** — daftarkan di AndroidManifest & Info.plist

---

## 1. Intercept Console Message (PRIMARY — Menerima URL + kodeBayar)

PKB mengirim instruksi pembayaran e-wallet via `console.log(JSON.stringify({...}))`.
Host app menangkap via callback `onConsoleMessage`.

**Format JSON dari PKB:**
```json
{
    "type": "finpay_navigation",
    "url": "https://m.dana.id/n/cashier/new/checkout?bizNo=20260520111212800110166257009864415&...",
    "kodeBayar": "3222002005265231"
}
```

**Implementasi di Host App (Presentation Layer — onConsoleMessage):**

```dart
// Di InAppWebView widget:
onConsoleMessage: (controller, consoleMessage) {
  // Semua console.log dikirim ke controller untuk diproses
  _controller.handleConsoleMessage(consoleMessage.message);
},
```

**Implementasi di Controller — handleConsoleMessage():**

```dart
void handleConsoleMessage(String message) {
  // Log semua console message ke debug tracker
  AppLogger.d("[JS] $message");

  // Quick-check sebelum JSON parse (optimisasi performa)
  if (!message.contains('finpay_navigation')) return;

  try {
    final Map<String, dynamic> json = jsonDecode(message);
    if (json['type'] != 'finpay_navigation') return;

    final String? url = json['url']?.toString().trim();
    final String? kodeBayar = json['kodeBayar']?.toString().trim();

    if (url == null || url.isEmpty) {
      AppLogger.d("[Console] finpay_navigation received but URL is empty");
      return;
    }

    AppLogger.d("[Console] finpay_navigation detected");
    AppLogger.d("[Console] URL: ${_sanitizeUrl(url)}");
    AppLogger.d("[Console] kodeBayar: ${kodeBayar ?? 'null'}");

    // Simpan kodeBayar untuk polling status
    _activeKodeBayar = kodeBayar;

    // Validasi URL: hanya https://
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      AppLogger.d("[Console] Rejected: non-HTTPS URL");
      return;
    }

    // Simpan URL untuk kemungkinan reopen setelah paymentHold
    _lastCustomTabUrl = url;

    // Buka Custom Tab + mulai polling status
    _webViewController?.stopLoading();
    _openInCustomTabs(url);

  } catch (e) {
    // Bukan JSON valid atau bukan finpay_navigation — abaikan
  }
}
```

> **Kenapa console.log, bukan postMessage?** Console.log memungkinkan PKB mengirim data **terstruktur** (URL + kodeBayar) dalam satu payload JSON, tanpa perlu bridge tambahan. Host app cukup intercept `onConsoleMessage` yang sudah built-in di `InAppWebView`.

---

## 2. Buka URL di Chrome Custom Tab + Start Polling

Setelah `finpay_navigation` terdeteksi, host app membuka URL di Custom Tab **dan** mulai polling status pembayaran.

```dart
late final ChromeSafariBrowser _browser = _PaymentChromeBrowser(
  onClosedCallback: () {
    // User tutup Custom Tab → tampilkan dialog konfirmasi pembatalan
    AppLogger.d("[Browser] Custom Tab closed by user — showing hold dialog");
    _stopPaymentStatusPolling();
    _showPaymentHoldDialog();
  },
);

Future<void> _openInCustomTabs(String rawUrl) async {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null) return;
  try {
    if (!uri.scheme.startsWith('http')) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    await _browser.open(
      url: WebUri.uri(uri),
      settings: ChromeSafariBrowserSettings(
        shareState: CustomTabsShareState.SHARE_STATE_OFF,
        showTitle: true,
        noHistory: false,
      ),
    );
    AppLogger.d('[Nav] Custom Tab opened — polling payment status');

    // Mulai polling status pembayaran setelah Custom Tab terbuka
    _startPaymentStatusPolling();
  } catch (e, stack) {
    AppLogger.e("Custom Tab error", e, stack);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// ChromeSafariBrowser wrapper — callback saat user tutup Custom Tab
class _PaymentChromeBrowser extends ChromeSafariBrowser {
  _PaymentChromeBrowser({required this.onClosedCallback});
  final VoidCallback onClosedCallback;
  @override
  void onClosed() => onClosedCallback();
}
```

> **PENTING:** Saat `onClosed()` dipanggil (user tutup Custom Tab), host app **TIDAK** langsung dispatch `paymentCompleted`. Sebagai gantinya, tampilkan **dialog konfirmasi** agar user bisa memilih: lanjutkan bayar atau batalkan transaksi.

---

## 3. Polling API Status Pembayaran

Host app melakukan polling setiap 3 detik ke endpoint dummy payment server. Jika status pembayaran sudah `true`, Custom Tab ditutup otomatis dan event `paymentCompleted` di-dispatch ke PKB.

**Endpoint:**
```
POST http://192.168.99.46:8700/api/check-dummy-payment-status
Content-Type: application/json

{
    "kodeBayar": "3222002005265231"
}
```

**Implementasi:**

```dart
/// Timer polling status pembayaran via API.
Timer? _paymentStatusPoller;

/// Flag untuk mencegah polling concurrent.
bool _isPollingPayment = false;

/// Kode bayar aktif saat ini — diset dari console message finpay_navigation.
String? _activeKodeBayar;

void _startPaymentStatusPolling() {
  if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) {
    AppLogger.d("[Polling] No active kodeBayar — skip polling");
    return;
  }

  _stopPaymentStatusPolling();
  AppLogger.d("[Polling] Started — kodeBayar: $_activeKodeBayar (interval: 3s)");

  _paymentStatusPoller = Timer.periodic(const Duration(seconds: 3), (_) {
    _checkPaymentStatus();
  });
}

void _stopPaymentStatusPolling() {
  _paymentStatusPoller?.cancel();
  _paymentStatusPoller = null;
  _isPollingPayment = false;
}

Future<void> _checkPaymentStatus() async {
  if (_isPollingPayment) return; // guard concurrent
  if (_activeKodeBayar == null) {
    _stopPaymentStatusPolling();
    return;
  }

  _isPollingPayment = true;
  try {
    final url = Uri.parse('http://192.168.99.46:8700/api/check-dummy-payment-status');
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'kodeBayar': _activeKodeBayar}),
    );

    if (response.statusCode == 200) {
      final Map<String, dynamic> body = jsonDecode(response.body);
      // Cek apakah status pembayaran sudah true
      final bool isPaid = body['data']?['status'] == true ||
                          body['data']?['is_paid'] == true ||
                          body['success'] == true && body['data']?['status_payment'] == true;

      if (isPaid) {
        AppLogger.d("[Polling] Payment status: PAID ✅ — closing Custom Tab");
        _stopPaymentStatusPolling();

        // Reset flag agar bisa dispatch
        _paymentNotified = false;
        _notifyPaymentCompleted();

        // Tutup Custom Tab otomatis
        if (_browser.isOpened()) {
          await _browser.close();
        }

        // Bersihkan state
        _activeKodeBayar = null;
        _lastCustomTabUrl = null;
        return;
      }
    }
  } catch (e, stack) {
    // Silent fail — server mungkin tidak reachable
    AppLogger.e("[Polling] check-dummy-payment-status error", e, stack);
  } finally {
    _isPollingPayment = false;
  }
}
```

**Kapan polling berhenti:**

| Kondisi | Action |
|---------|--------|
| API return `isPaid = true` | `_stopPaymentStatusPolling()` + close Custom Tab + dispatch `paymentCompleted` |
| User tutup Custom Tab manual | `_stopPaymentStatusPolling()` + tampilkan dialog |
| Deep link `pocapp://` diterima | `_stopPaymentStatusPolling()` + dispatch `paymentCompleted` |
| Controller di-dispose | `_stopPaymentStatusPolling()` via `dispose()` |

---

## 4. Dialog Konfirmasi & Event paymentHold

Saat user menutup Custom Tab secara manual, muncul dialog konfirmasi dengan 2 opsi:

**Dialog UI:**

```
┌──────────────────────────────────────────────┐
│  Konfirmasi Pembatalan Transaksi             │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ Kode Bayar                             │  │
│  │ 3222002005265231                       │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  Anda menutup halaman pembayaran.            │
│  Apakah Anda ingin membatalkan transaksi     │
│  ini atau melanjutkan pembayaran?             │
│                                              │
│        [Lanjutkan Bayar]  [Batalkan Transaksi]│
└──────────────────────────────────────────────┘
```

**Implementasi — Dispatch paymentHold:**

```dart
/// Dispatch event 'paymentHold' ke PKB WebView.
/// Menginformasikan bahwa user menutup Custom Tab tanpa menyelesaikan pembayaran.
void _notifyPaymentHold() {
  AppLogger.d("[Payment] Dispatching 'paymentHold' event to PKB");
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('paymentHold', "
            "{detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}'}}));",
  );
}
```

**Event yang diterima PKB:**
```javascript
window.addEventListener('paymentHold', function(event) {
    console.log('kodeBayar:', event.detail.kodeBayar);
    console.log('timestamp:', event.detail.ts);
    // PKB menghit API pembatalan dari sisinya
});
```

**Implementasi — Dialog + Reopen:**

```dart
void _showPaymentHoldDialog() {
  final ctx = _dialogContext;
  if (ctx == null || !ctx.mounted) {
    _notifyPaymentHold();
    return;
  }

  showDialog(
    context: ctx,
    barrierDismissible: false,
    builder: (dialogCtx) => AlertDialog(
      // ... UI dialog ...
      actions: [
        // Tombol "Lanjutkan Bayar" → reopen Custom Tab
        TextButton(
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            _reopenCustomTab(); // buka kembali Custom Tab + restart polling
          },
          child: const Text('Lanjutkan Bayar'),
        ),
        // Tombol "Batalkan Transaksi" → kirim paymentHold event
        ElevatedButton(
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            _notifyPaymentHold();        // dispatch event ke PKB
            _activeKodeBayar = null;     // bersihkan state
            _lastCustomTabUrl = null;
          },
          child: const Text('Batalkan Transaksi'),
        ),
      ],
    ),
  );
}

/// Membuka kembali Custom Tab dengan URL terakhir.
void _reopenCustomTab() {
  if (_lastCustomTabUrl == null || _lastCustomTabUrl!.isEmpty) {
    AppLogger.d("[Payment] No stored URL to reopen Custom Tab");
    return;
  }
  AppLogger.d("[Payment] Reopening Custom Tab: ${_sanitizeUrl(_lastCustomTabUrl!)}");
  _openInCustomTabs(_lastCustomTabUrl!);
  // _openInCustomTabs akan otomatis memanggil _startPaymentStatusPolling()
}
```

---

## 5. Notifikasi ke PKB (paymentCompleted Event)

Event `paymentCompleted` di-dispatch ke PKB **hanya** saat pembayaran benar-benar terdeteksi selesai (bukan saat user tutup Custom Tab manual).

```dart
void _notifyPaymentCompleted() {
  if (_paymentNotified) {
    AppLogger.d("[Payment] Already notified — skipping duplicate dispatch");
    return;
  }
  _paymentNotified = true;
  AppLogger.d("[Payment] Dispatching 'paymentCompleted' event");
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('paymentCompleted', "
            "{detail:{ts:Date.now()}}));",
  );
  // Auto-reset flag setelah 3 detik
  Future.delayed(const Duration(seconds: 3), () => _paymentNotified = false);
}
```

**Event ini dipanggil dari 3 tempat:**

| Situasi | Trigger |
|---------|---------|
| API polling return `isPaid = true` | `_checkPaymentStatus()` → auto-close Custom Tab |
| Deep link `pocapp://payment/return` diterima | `_initDeepLinks()` → close Custom Tab |
| CC/VA result URL terdeteksi di WebView | `handleNavigation()` → Jalur A |

> **PENTING:** Saat user tutup Custom Tab manual, **BUKAN** `paymentCompleted` yang dikirim, melainkan dialog + kemungkinan `paymentHold`.

---

## 6. Pengaturan Navigasi WebView (shouldOverrideUrlLoading)

Tidak berubah dari versi sebelumnya:

```dart
Future<NavigationActionPolicy> handleNavigation(NavigationAction action) async {
  final uri = action.request.url;
  final rawUrl = uri?.toString() ?? '';
  if (rawUrl.isEmpty) return NavigationActionPolicy.ALLOW;

  final decision = _navigationGuard.evaluate(rawUrl);

  switch (decision) {
    case NavigationHandling.allowWebView:
      // Deteksi halaman hasil Finpay (CC/VA) → notifikasi ke PKB
      if (_config.isPaymentResultUrl(rawUrl)) {
        _stopPaymentStatusPolling();
        _paymentNotified = false;
        _notifyPaymentCompleted();
      }
      return NavigationActionPolicy.ALLOW;
      
    case NavigationHandling.openInCustomTab:
      if (!_browser.isOpened() && !_paymentNotified) {
        _openInCustomTabs(rawUrl);
      }
      return NavigationActionPolicy.CANCEL;

    case NavigationHandling.externalApp:
      if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
      return NavigationActionPolicy.CANCEL;

    case NavigationHandling.cancel:
      return NavigationActionPolicy.CANCEL;
  }
}
```

---

## 7. Deep Link Setup (pocapp://)

Tetap sama — deep link dari Finpay setelah pembayaran e-wallet.

### Android — `AndroidManifest.xml`
```xml
<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="pocapp" android:host="payment" />
</intent-filter>
```

### iOS — `Info.plist`
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>pocapp</string>
    </array>
  </dict>
</array>
```

### Listener di Dart
```dart
void _initDeepLinks() {
  _appLinks = AppLinks();
  _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
    AppLogger.d("[DeepLink] Received: ${uri.scheme}://${uri.host}${uri.path}");
    if (uri.scheme == _config.deepLinkScheme && uri.host == _config.deepLinkHost) {
      if (uri.path.contains('return') || uri.path.contains('callback')) {
        // Deep link = pembayaran selesai
        _stopPaymentStatusPolling();
        _paymentNotified = false;
        _notifyPaymentCompleted();
        if (_browser.isOpened()) await _browser.close();
        _activeKodeBayar = null;
        _lastCustomTabUrl = null;
      }
    }
  });
}
```

---

## 8. Alur Lengkap Per Jalur

### Jalur A — Kartu Kredit / Virtual Account

```
[PKB]  User pilih CC/VA → PKB navigasi langsung (window.location.href)
[Host] handleNavigation menerima URL live.finpay.id → ALLOW (whitelist)
[Host] WebView load halaman Finpay, user bayar
[Host] Finpay redirect ke live.finpay.id/pg/payment/card/result/success
[Host] handleNavigation deteksi result URL → _notifyPaymentCompleted()
[PKB]  Terima event 'paymentCompleted' → panggil API cek status → selesai
```

### Jalur B — E-Wallet (DANA, ShopeePay, LinkAja)

```
[PKB]  User pilih DANA → PKB kirim via console.log:
       { "type":"finpay_navigation", "url":"https://...", "kodeBayar":"..." }
[Host] onConsoleMessage → handleConsoleMessage() → parse JSON
[Host] _openInCustomTabs(url) + _startPaymentStatusPolling(kodeBayar)
[Host] Custom Tab terbuka → user bayar di DANA app

       Skenario 1 — Pembayaran berhasil (API polling):
         [Host] _checkPaymentStatus() return isPaid=true
         [Host] → _notifyPaymentCompleted() → _browser.close()
         [PKB]  Terima event 'paymentCompleted' → verifikasi → selesai ✅

       Skenario 2 — Deep link:
         Finpay kirim pocapp://payment/return
         [Host] _initDeepLinks → _notifyPaymentCompleted() → close browser
         [PKB]  Terima event 'paymentCompleted' → selesai ✅

       Skenario 3 — User tutup Custom Tab manual:
         [Host] onClosed() → _stopPaymentStatusPolling()
         [Host] _showPaymentHoldDialog()
         
         User pilih "Lanjutkan Bayar":
           [Host] _reopenCustomTab() → buka URL yang sama + restart polling
           → Kembali ke Skenario 1/2
         
         User pilih "Batalkan Transaksi":
           [Host] _notifyPaymentHold() → dispatch event ke PKB
           [PKB]  Terima event 'paymentHold' → hit API pembatalan
```

---

## 9. Troubleshooting

| Gejala | Kemungkinan Penyebab | Solusi |
|--------|---------------------|--------|
| Halaman Finpay CC/VA tidak muncul | Domain `live.finpay.id` tidak di whitelist | Tambahkan ke `allowedHosts` |
| E-wallet tidak terbuka | Console JSON tidak terdeteksi | Pastikan PKB mengirim format JSON yang benar via `console.log` |
| `paymentCompleted` tidak terpicu | API polling belum berjalan | Pastikan `kodeBayar` tersedia di JSON |
| Custom Tab tidak reopen setelah dialog | `_lastCustomTabUrl` null | Pastikan URL disimpan saat pertama kali buka |
| Deep link tidak tertangkap | AndroidManifest/Info.plist salah | Cek scheme `pocapp` dan host `payment` |
| `paymentHold` tidak terkirim | Dialog context tidak tersedia | Pastikan `dialogContext` di-set dari presentation layer |
| Polling tidak berhenti | Timer cancel gagal | Cek `_stopPaymentStatusPolling()` dipanggil di dispose |

---

## 10. Referensi Cepat

| Item | Nilai |
|------|-------|
| Console message type | `finpay_navigation` |
| Bridge name (fallback) | `SapawargaChannel` |
| Event: selesai bayar | `paymentCompleted` |
| Event: pembatalan | `paymentHold` |
| Deep link scheme | `pocapp` |
| Deep link host | `payment` |
| Finpay domain (whitelist) | `live.finpay.id` |
| Result URL pattern | `/pg/payment/card/result/` |
| Payment status API | `POST http://192.168.99.46:8700/api/check-dummy-payment-status` |
| Polling interval | `3 detik` |

### Apa yang PKB Sudah Jamin (Tidak Perlu Khawatir)

| Item PKB | Status |
|----------|--------|
| Listen `paymentCompleted` via `registerPaymentListener()` di `initState` | ✅ |
| Listen `paymentHold` → hit API pembatalan payment | ✅ (PKB tanggung jawab) |
| Reentrancy guard di `doVerifyPayment()` — hanya 1 API call sekaligus | ✅ |
| `handlePaymentCompletedFromHost()` → `stopTimer()` SEBELUM verify | ✅ |
| `showFinpayRedirectScreen` di-reset saat verify sukses | ✅ |
| `Timer?` nullable — aman dari crash `LateInitializationError` | ✅ |
| Listener dibersihkan di `dispose()` — tidak ada memory leak | ✅ |

### Yang Dikirim Host App ke PKB (Maksimal 1 Event Per Transaksi)

| Event | Kapan | Detail |
|-------|-------|--------|
| `paymentCompleted` | API polling sukses / deep link diterima / CC/VA result URL | `{ts: timestamp}` |
| `paymentHold` | User konfirmasi batalkan transaksi di dialog | `{ts: timestamp, kodeBayar: '...'}` |

> **Tidak ada lagi:** timer bypass, tombol simulasi, `PaymentInfoChannel`, atau `_forceDummyPayment()`.

---

## 📋 PROMPT SIAP KIRIM — untuk Tim Host App

> Salin dan kirimkan teks di bawah ini beserta file dokumentasi ini ke tim host app.

---

```
Halo, kami dari tim PKB.

Kami sudah mengupdate kontrak integrasi pembayaran. Perubahan utama:

1. KOMUNIKASI (console.log menggantikan postMessage):
   - PKB sekarang mengirim data pembayaran via console.log(JSON.stringify({...}))
   - Format: { "type":"finpay_navigation", "url":"...", "kodeBayar":"..." }
   - Host app intercept via onConsoleMessage → parse JSON → buka Custom Tab

2. POLLING STATUS PEMBAYARAN (menggantikan bypass timer):
   - Setelah Custom Tab terbuka, host app polling:
     POST http://192.168.99.46:8700/api/check-dummy-payment-status
     Body: { "kodeBayar": "..." }
   - Jika status true → auto-close Custom Tab + dispatch paymentCompleted

3. PAYMENT HOLD (event baru):
   - Saat user tutup Custom Tab manual → tampilkan dialog konfirmasi
   - "Lanjutkan Bayar" → reopen Custom Tab + restart polling
   - "Batalkan Transaksi" → dispatch event paymentHold ke PKB
   - PKB yang menghit API pembatalan dari sisinya

4. YANG DIHAPUS:
   - Timer bypass (_demoAutoCloseTimer)
   - Tombol simulasi (SimulationToolbar)
   - PaymentInfoChannel bridge
   - _forceDummyPayment()

Host app sekarang HANYA mengirim MAKSIMAL 1 event per transaksi:
   paymentCompleted (sukses) ATAU paymentHold (dibatalkan user)

Detail kode dan snippet ada di file finpay_host_app_integration.md terlampir.

Terima kasih.
```
