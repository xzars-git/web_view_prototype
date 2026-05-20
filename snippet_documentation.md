# Snippet Code — Host App Payment Integration

> **Versi:** 2026-05-20
> **File sumber:** `hybrid_webview_controller.dart`
> **Package:** `flutter_inappwebview`, `http`, `url_launcher`

---

## 1. Menerima Data dari Console Log

PKB mengirim data pembayaran e-wallet via `console.log`. Host app menangkap melalui `onConsoleMessage`.

### Format JSON dari PKB:

```json
{
    "type": "finpay_navigation",
    "url": "https://m.dana.id/n/cashier/new/checkout?bizNo=20260520111212800110166257009864415&timestamp=1779243923129&originSourcePlatform=IPG&mid=216620000924815941781&did=216650001303284791789&sign=jSNPe6VJN5MOVogTk30zJDuS6D73zKzTFFITlyknQ%2FD7tzmFKf022Q7AatjJDJ7ceZ%2Fn7i%2FFAubrJTRY6L5QDqb0KtMJRLgKEjQKe36pmS%2FORnTJtoEqEhkBJwKKOKjno%2BiaxDIDn2Iba1aSfnhHMjL2MtGxvZqE53w93sT2VgWYGCML%2BVsKxdEDjFr1xuq5HPJqTEMu9IXYmnmzVrdr6qJndmII4GkQRiYfxbOfZ%2F%2B8ZZducZ6Yjmxm5DrTd5JioXjkkEI5EofmUc9ENdDUAC%2FABQC%2BdmjfPXpuV%2BQao%2BwU%2FdLz6sX8KizP%2Fc9rV%2FEIAe38LtoGime5ddeos6hckw%3D%3D&forceToH5=false&newRegistrationPage=true",
    "kodeBayar": "3222002005265231"
}
```

### Snippet — Presentation Layer (InAppWebView callback):

```dart
onConsoleMessage: (controller, consoleMessage) {
  _controller.handleConsoleMessage(consoleMessage.message);
},
```

### Snippet — Controller (parse JSON + buka Custom Tab):

```dart
// Field yang dibutuhkan:
String? _activeKodeBayar;
String? _lastCustomTabUrl;

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

---

## 2. Custom Tab + Payment Hold (Close → Dialog → Event)

Saat user tutup Custom Tab, muncul dialog konfirmasi. Jika user batalkan → kirim `paymentHold`. Jika lanjutkan → reopen Custom Tab.

### Snippet — ChromeSafariBrowser wrapper + onClosed:

```dart
class _PaymentChromeBrowser extends ChromeSafariBrowser {
  _PaymentChromeBrowser({required this.onClosedCallback});
  final VoidCallback onClosedCallback;
  @override
  void onClosed() => onClosedCallback();
}

// Inisialisasi browser:
late final ChromeSafariBrowser _browser;

void _initBrowser([ChromeSafariBrowser? browser]) {
  _browser = browser ?? _PaymentChromeBrowser(
    onClosedCallback: () {
      // User tutup Custom Tab → tampilkan dialog konfirmasi pembatalan.
      // Jangan langsung notify paymentCompleted; biarkan user memilih.
      AppLogger.d("[Browser] Custom Tab closed by user — showing hold dialog");
      _stopPaymentStatusPolling();
      _showPaymentHoldDialog();
    },
  );
}
```

### Snippet — Buka Custom Tab:

```dart
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
```

### Snippet — Dispatch paymentHold event:

```dart
void _notifyPaymentHold() {
  AppLogger.d("[Payment] Dispatching 'paymentHold' event to PKB");
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('paymentHold', "
            "{detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}'}}));",
  );
}
```

### Snippet — Dialog konfirmasi + Reopen Custom Tab:

```dart
// Field yang dibutuhkan:
BuildContext? _dialogContext;
set dialogContext(BuildContext? ctx) => _dialogContext = ctx;

void _showPaymentHoldDialog() {
  final ctx = _dialogContext;
  if (ctx == null || !ctx.mounted) {
    AppLogger.d("[Dialog] No valid context — sending paymentHold directly");
    _notifyPaymentHold();
    return;
  }

  showDialog(
    context: ctx,
    barrierDismissible: false,
    builder: (dialogCtx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Konfirmasi Pembatalan Transaksi',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1B5E20),
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Info kode bayar
          if (_activeKodeBayar != null && _activeKodeBayar!.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Kode Bayar',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _activeKodeBayar!,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            'Anda menutup halaman pembayaran. Apakah Anda ingin membatalkan transaksi ini atau melanjutkan pembayaran?',
            style: TextStyle(fontSize: 14),
          ),
        ],
      ),
      actions: [
        // Tombol "Lanjutkan Bayar" → reopen Custom Tab
        TextButton(
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            _reopenCustomTab();
          },
          child: const Text(
            'Lanjutkan Bayar',
            style: TextStyle(
              color: Color(0xFF1B5E20),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // Tombol "Batalkan Transaksi" → kirim paymentHold event
        ElevatedButton(
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            AppLogger.d("[Payment] User confirmed cancellation — sending paymentHold");
            _notifyPaymentHold();
            // Bersihkan state pembayaran
            _activeKodeBayar = null;
            _lastCustomTabUrl = null;
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red[700],
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text('Batalkan Transaksi'),
        ),
      ],
    ),
  );
}

/// Membuka kembali Custom Tab dengan URL terakhir.
/// Dipanggil saat user memilih "Lanjutkan Bayar" di dialog paymentHold.
void _reopenCustomTab() {
  if (_lastCustomTabUrl == null || _lastCustomTabUrl!.isEmpty) {
    AppLogger.d("[Payment] No stored URL to reopen Custom Tab");
    return;
  }
  AppLogger.d("[Payment] Reopening Custom Tab: ${_sanitizeUrl(_lastCustomTabUrl!)}");
  _openInCustomTabs(_lastCustomTabUrl!);
  // _openInCustomTabs() otomatis memanggil _startPaymentStatusPolling()
}
```

### PKB (Web) — Listener paymentHold:

```javascript
window.addEventListener('paymentHold', function(event) {
    console.log('Payment hold — kodeBayar:', event.detail.kodeBayar);
    console.log('Timestamp:', event.detail.ts);
    // Hit API pembatalan dari sisi PKB
});
```

---

## 3. Polling API Cek Status Pembayaran

Setelah Custom Tab terbuka, host app polling setiap 3 detik. Jika sudah bayar → auto-close Custom Tab + dispatch `paymentCompleted`.

### Endpoint:

```
POST http://192.168.99.46:8700/api/check-dummy-payment-status
Content-Type: application/json

{
    "kodeBayar": "3222002005265231"
}
```

### Snippet — Polling + Check Status:

```dart
// Field yang dibutuhkan:
Timer? _paymentStatusPoller;
bool _isPollingPayment = false;
String? _activeKodeBayar;
bool _paymentNotified = false;

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

### Snippet — Dispatch paymentCompleted (dipanggil saat isPaid=true):

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
  // Auto-reset flag setelah 3 detik agar bisa handle transaksi berikutnya
  Future.delayed(const Duration(seconds: 3), () => _paymentNotified = false);
}
```

### Kapan Polling Berhenti:

| Kondisi | Aksi |
|---------|------|
| API return `isPaid = true` | Stop polling → `paymentCompleted` → close Custom Tab |
| User tutup Custom Tab manual | Stop polling → dialog konfirmasi |
| Deep link `pocapp://` diterima | Stop polling → `paymentCompleted` → close Custom Tab |
| Controller `dispose()` | Stop polling (cleanup) |

### Jangan Lupa — dispose():

```dart
@override
void dispose() {
  _stopPaymentStatusPolling();
  _linkSubscription?.cancel();
  super.dispose();
}
```

---

## Ringkasan Alur

```
PKB console.log({ type:"finpay_navigation", url, kodeBayar })
  │
  ▼
Host: onConsoleMessage → handleConsoleMessage()
  │
  ├─ Parse JSON → simpan kodeBayar + URL
  │
  ▼
Host: _openInCustomTabs(url) → Custom Tab terbuka
Host: _startPaymentStatusPolling() → polling setiap 3 detik
  │
  ├─── isPaid=true ──────────► _notifyPaymentCompleted() → _browser.close()
  │                            → PKB terima 'paymentCompleted'
  │
  ├─── User tutup tab ──────► _showPaymentHoldDialog()
  │                            ├─ "Lanjutkan Bayar" → _reopenCustomTab()
  │                            └─ "Batalkan"        → _notifyPaymentHold()
  │                                                   → PKB terima 'paymentHold'
  │
  └─── Deep link pocapp:// ─► _notifyPaymentCompleted() → _browser.close()
                               → PKB terima 'paymentCompleted'
```

---

## Event Yang Dikirim ke PKB (Maks 1 per Transaksi)

| Event | Payload | Kapan |
|-------|---------|-------|
| `paymentCompleted` | `{detail: {ts: Date.now()}}` | API polling sukses / deep link |
| `paymentHold` | `{detail: {ts: Date.now(), kodeBayar: '...'}}` | User konfirmasi batalkan di dialog |
