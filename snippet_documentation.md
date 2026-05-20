# Snippet Code — Host App Payment Integration

> **Versi:** 2026-05-20 (v2 — enhanced debug logging)
> **File sumber:** `hybrid_webview_controller.dart`
> **Package:** `flutter_inappwebview`, `http`, `url_launcher`, `app_links`

---

## 1. Menerima Data dari Console Log

PKB mengirim data pembayaran e-wallet via `console.log`. Host app menangkap melalui `onConsoleMessage`.

### Format JSON dari PKB:

```json
{
    "type": "finpay_navigation",
    "url": "https://m.dana.id/n/cashier/new/checkout?bizNo=...",
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
int _pollingErrorCount = 0;

void handleConsoleMessage(String message) {
  // Log console message (truncate kalau terlalu panjang)
  final preview = message.length > 120 ? '${message.substring(0, 120)}...' : message;
  AppLogger.d("[JS] $preview");

  // Quick-check sebelum JSON parse
  if (!message.contains('finpay_navigation')) return;

  AppLogger.d("[Console] ════════════════════════════════");
  AppLogger.d("[Console] 📨 Mendeteksi finpay_navigation di console message");

  try {
    final Map<String, dynamic> json = jsonDecode(message);
    if (json['type'] != 'finpay_navigation') {
      AppLogger.d("[Console] ⚠️ JSON valid tapi type='${json['type']}' — bukan finpay_navigation, skip");
      return;
    }

    final String? url = json['url']?.toString().trim();
    final String? kodeBayar = json['kodeBayar']?.toString().trim();

    AppLogger.d("[Console] ✅ type: finpay_navigation");
    AppLogger.d("[Console] 🔑 kodeBayar: ${kodeBayar ?? '⚠️ NULL — polling tidak akan berjalan!'}");
    AppLogger.d("[Console] 🔗 url host: ${url != null ? Uri.tryParse(url)?.host ?? 'parse error' : 'null'}");

    if (url == null || url.isEmpty) {
      AppLogger.d("[Console] ❌ URL kosong — batalkan proses");
      AppLogger.d("[Console] ════════════════════════════════");
      return;
    }

    // Validasi scheme
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      AppLogger.d("[Console] ❌ URL ditolak — scheme='${uri?.scheme}', harus https://");
      AppLogger.d("[Console] ════════════════════════════════");
      return;
    }

    // Simpan state
    _activeKodeBayar = kodeBayar;
    _lastCustomTabUrl = url;
    _pollingErrorCount = 0; // reset error counter untuk transaksi baru

    AppLogger.d("[Console] → Membuka Custom Tab + memulai polling");
    AppLogger.d("[Console] ════════════════════════════════");

    _webViewController?.stopLoading();
    _openInCustomTabs(url);

  } catch (e) {
    AppLogger.d("[Console] ❌ JSON parse error: $e");
    AppLogger.d("[Console] Raw message: $message");
    AppLogger.d("[Console] ════════════════════════════════");
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
      AppLogger.d("[Browser] ════════════════════════════════");
      AppLogger.d("[Browser] 🔴 Custom Tab DITUTUP oleh user");
      AppLogger.d("[Browser] kodeBayar aktif: ${_activeKodeBayar ?? 'null'}");
      AppLogger.d("[Browser] → Stop polling + tampilkan dialog konfirmasi");
      AppLogger.d("[Browser] ════════════════════════════════");
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
  if (uri == null) {
    AppLogger.d("[CustomTab] ❌ URL tidak valid — batal buka Custom Tab");
    return;
  }
  AppLogger.d("[CustomTab] ════════════════════════════════");
  AppLogger.d("[CustomTab] 🌐 Membuka Custom Tab");
  AppLogger.d("[CustomTab] host : ${uri.host}");
  AppLogger.d("[CustomTab] path : ${uri.path}");
  try {
    if (!uri.scheme.startsWith('http')) {
      AppLogger.d("[CustomTab] scheme non-http ('${uri.scheme}') → launchUrl external");
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
    AppLogger.d("[CustomTab] ✅ Custom Tab berhasil dibuka");
    AppLogger.d("[CustomTab] ════════════════════════════════");
    _startPaymentStatusPolling();
  } catch (e, stack) {
    AppLogger.e("[CustomTab] ❌ Gagal buka Custom Tab — fallback ke launchUrl", e, stack);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
```

### Snippet — Dispatch paymentHold event:

```dart
void _notifyPaymentHold() {
  AppLogger.d("[Payment] ════════════════════════════════");
  AppLogger.d("[Payment] 🔴 DISPATCH event 'paymentHold' ke PKB");
  AppLogger.d("[Payment] kodeBayar: ${_activeKodeBayar ?? 'null'}");
  AppLogger.d("[Payment] PKB diharapkan hit API pembatalan setelah ini");
  AppLogger.d("[Payment] ════════════════════════════════");
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
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                  const Text('Kode Bayar', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text(_activeKodeBayar!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
        TextButton(
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            _reopenCustomTab();
          },
          child: const Text('Lanjutkan Bayar',
            style: TextStyle(color: Color(0xFF1B5E20), fontWeight: FontWeight.w600)),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            AppLogger.d("[Payment] User confirmed cancellation — sending paymentHold");
            _notifyPaymentHold();
            _activeKodeBayar = null;
            _lastCustomTabUrl = null;
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red[700], foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('Batalkan Transaksi'),
        ),
      ],
    ),
  );
}

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

### Snippet — Polling + Check Status (dengan debug log):

```dart
// Field yang dibutuhkan:
Timer? _paymentStatusPoller;
bool _isPollingPayment = false;
String? _activeKodeBayar;
bool _paymentNotified = false;
int _pollingErrorCount = 0;
static const int _maxPollingErrorLog = 3;

void _startPaymentStatusPolling() {
  if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) {
    AppLogger.d("[Polling] ⚠️ Tidak ada kodeBayar — polling tidak dimulai");
    return;
  }

  _stopPaymentStatusPolling();
  _pollingErrorCount = 0;
  AppLogger.d("[Polling] ▶️ Polling DIMULAI");
  AppLogger.d("[Polling] kodeBayar : $_activeKodeBayar");
  AppLogger.d("[Polling] interval  : 3 detik");
  AppLogger.d("[Polling] endpoint  : http://192.168.99.46:8700/api/check-dummy-payment-status");

  _paymentStatusPoller = Timer.periodic(const Duration(seconds: 3), (_) {
    _checkPaymentStatus();
  });
}

void _stopPaymentStatusPolling() {
  if (_paymentStatusPoller != null) {
    AppLogger.d("[Polling] ⏹️ Polling DIHENTIKAN");
  }
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
    final endpoint = Uri.parse('http://192.168.99.46:8700/api/check-dummy-payment-status');
    final requestBody = jsonEncode({'kodeBayar': _activeKodeBayar});

    AppLogger.d("[Polling] 🔄 POST $endpoint");
    AppLogger.d("[Polling] Request body: $requestBody");

    final response = await http
        .post(
          endpoint,
          headers: {'Content-Type': 'application/json'},
          body: requestBody,
        )
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw Exception(
            'Request timeout setelah 5 detik — pastikan device dan server di WiFi yang sama'),
        );

    AppLogger.d("[Polling] Response status : ${response.statusCode}");
    AppLogger.d("[Polling] Response body   : ${response.body}");

    if (response.statusCode == 200) {
      final Map<String, dynamic> body = jsonDecode(response.body);
      final bool isPaid = body['data']?['status'] == true ||
                          body['data']?['is_paid'] == true ||
                          (body['success'] == true && body['data']?['status_payment'] == true);

      AppLogger.d("[Polling] isPaid: $isPaid");
      _pollingErrorCount = 0; // reset karena request berhasil

      if (isPaid) {
        AppLogger.d("[Polling] ════════════════════════════════");
        AppLogger.d("[Polling] 💰 Status LUNAS — menutup Custom Tab otomatis");
        AppLogger.d("[Polling] ════════════════════════════════");
        _stopPaymentStatusPolling();
        _paymentNotified = false;
        _notifyPaymentCompleted();
        if (_browser.isOpened()) {
          AppLogger.d("[Polling] 🔒 Menutup Custom Tab...");
          await _browser.close();
        }
        _activeKodeBayar = null;
        _lastCustomTabUrl = null;
        return;
      } else {
        AppLogger.d("[Polling] ⏳ Status belum lunas — lanjut polling");
      }
    } else {
      AppLogger.d("[Polling] ⚠️ HTTP ${response.statusCode} — response tidak 200");
    }
  } catch (e) {
    _pollingErrorCount++;
    // Log error hanya N kali pertama — agar tidak spam log
    if (_pollingErrorCount <= _maxPollingErrorLog) {
      AppLogger.d("[Polling] Error ke-$_pollingErrorCount/$_maxPollingErrorLog: $e");
      if (_pollingErrorCount == 1) {
        AppLogger.d("[Polling] 💡 Cek: device & PC di WiFi yang sama? Server jalan di 192.168.99.46:8700?");
      }
      if (_pollingErrorCount == _maxPollingErrorLog) {
        AppLogger.d("[Polling] 🔕 Error log disuppress — server tidak reachable. Polling tetap berjalan.");
      }
    }
  } finally {
    _isPollingPayment = false;
  }
}
```

### Snippet — Dispatch paymentCompleted (dipanggil saat isPaid=true):

```dart
void _notifyPaymentCompleted() {
  if (_paymentNotified) {
    AppLogger.d("[Payment] ⚠️ Duplicate dispatch dicegah — sudah dikirim dalam 3 detik terakhir");
    return;
  }
  _paymentNotified = true;
  AppLogger.d("[Payment] ════════════════════════════════");
  AppLogger.d("[Payment] ✅ DISPATCH event 'paymentCompleted' ke PKB");
  AppLogger.d("[Payment] ════════════════════════════════");
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('paymentCompleted', "
            "{detail:{ts:Date.now()}}));",
  );
  Future.delayed(const Duration(seconds: 3), () => _paymentNotified = false);
}
```

### Contoh Output Debug saat Polling:

```
[Polling] ▶️ Polling DIMULAI
[Polling] kodeBayar : 3222002005265231
[Polling] interval  : 3 detik
[Polling] endpoint  : http://192.168.99.46:8700/api/check-dummy-payment-status
[Polling] 🔄 POST http://192.168.99.46:8700/api/check-dummy-payment-status
[Polling] Request body: {"kodeBayar":"3222002005265231"}
[Polling] Response status : 200
[Polling] Response body   : {"success":true,"data":{"status_payment":false}}
[Polling] isPaid: false
[Polling] ⏳ Status belum lunas — lanjut polling
...
[Polling] 🔄 POST http://192.168.99.46:8700/api/check-dummy-payment-status
[Polling] Request body: {"kodeBayar":"3222002005265231"}
[Polling] Response status : 200
[Polling] Response body   : {"success":true,"data":{"status_payment":true}}
[Polling] isPaid: true
[Polling] ════════════════════════════════
[Polling] 💰 Status LUNAS — menutup Custom Tab otomatis
[Polling] ════════════════════════════════
[Polling] ⏹️ Polling DIHENTIKAN
[Payment] ════════════════════════════════
[Payment] ✅ DISPATCH event 'paymentCompleted' ke PKB
[Payment] ════════════════════════════════
[Polling] 🔒 Menutup Custom Tab...
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
