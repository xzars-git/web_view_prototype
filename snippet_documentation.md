# Snippet Code — Host App Payment Integration

> **Versi:** 2026-05-20 (v3 — Tanpa dialog, tanpa paymentCompleted, polling 5s/15min)
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

### Snippet — Presentation Layer:

```dart
onConsoleMessage: (controller, consoleMessage) {
  _controller.handleConsoleMessage(consoleMessage.message);
},
```

### Snippet — Controller:

```dart
String? _activeKodeBayar;
int _pollingErrorCount = 0;

void handleConsoleMessage(String message) {
  final preview = message.length > 120 ? '${message.substring(0, 120)}...' : message;
  AppLogger.d("[JS] $preview");

  if (!message.contains('finpay_navigation')) return;

  AppLogger.d("[Console] ════════════════════════════════");
  AppLogger.d("[Console] 📨 Mendeteksi finpay_navigation");

  try {
    final Map<String, dynamic> json = jsonDecode(message);
    if (json['type'] != 'finpay_navigation') return;

    final String? url = json['url']?.toString().trim();
    final String? kodeBayar = json['kodeBayar']?.toString().trim();

    AppLogger.d("[Console] ✅ type: finpay_navigation");
    AppLogger.d("[Console] 🔑 kodeBayar: ${kodeBayar ?? 'NULL'}");
    AppLogger.d("[Console] 🔗 url host: ${url != null ? Uri.tryParse(url)?.host : 'null'}");

    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;

    _activeKodeBayar = kodeBayar;
    _pollingErrorCount = 0;

    AppLogger.d("[Console] → Membuka Custom Tab + polling (max 15 menit)");
    AppLogger.d("[Console] ════════════════════════════════");

    _webViewController?.stopLoading();
    _openInCustomTabs(url);
  } catch (e) {
    AppLogger.d("[Console] ❌ JSON parse error: $e");
  }
}
```

---

## 2. Custom Tab Close → paymentHold (Tanpa Dialog)

Saat user tutup Custom Tab, host app **langsung kirim `paymentHold`** ke PKB.
Dialog konfirmasi pembatalan ditampilkan oleh **Sambara (WebView)**, BUKAN host app.

### Snippet — Browser onClosed:

```dart
class _PaymentChromeBrowser extends ChromeSafariBrowser {
  _PaymentChromeBrowser({required this.onClosedCallback});
  final VoidCallback onClosedCallback;
  @override
  void onClosed() => onClosedCallback();
}

void _initBrowser([ChromeSafariBrowser? browser]) {
  _browser = browser ?? _PaymentChromeBrowser(
    onClosedCallback: () {
      AppLogger.d("[Browser] ════════════════════════════════");
      AppLogger.d("[Browser] 🔴 Custom Tab DITUTUP oleh user");
      AppLogger.d("[Browser] kodeBayar: ${_activeKodeBayar ?? 'null'}");
      AppLogger.d("[Browser] → Stop polling + kirim paymentHold ke PKB");
      AppLogger.d("[Browser] ════════════════════════════════");
      _stopPaymentStatusPolling();
      _notifyPaymentHold();
      _activeKodeBayar = null;
    },
  );
}
```

### Snippet — Dispatch paymentHold:

```dart
void _notifyPaymentHold() {
  AppLogger.d("[Payment] ════════════════════════════════");
  AppLogger.d("[Payment] 🔴 DISPATCH event 'paymentHold' ke PKB");
  AppLogger.d("[Payment] kodeBayar: ${_activeKodeBayar ?? 'null'}");
  AppLogger.d("[Payment] Sambara akan menampilkan dialog konfirmasi");
  AppLogger.d("[Payment] ════════════════════════════════");
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('paymentHold', "
            "{detail:{ts:Date.now(), kodeBayar:'${_activeKodeBayar ?? ''}'}}));",
  );
}
```

### PKB (Web) — Listener paymentHold:

```javascript
window.addEventListener('paymentHold', function(event) {
    console.log('Payment hold — kodeBayar:', event.detail.kodeBayar);
    // Sambara menampilkan dialog konfirmasi pembatalan sendiri
});
```

---

## 3. Polling API Cek Status Pembayaran

Setelah Custom Tab terbuka:
- Polling setiap **5 detik**
- Batas waktu **15 menit**
- Jika paid → **tutup Custom Tab saja** (TIDAK kirim event ke PKB)

### Endpoint:

```
POST http://192.168.99.46:8700/api/check-dummy-payment-status
Content-Type: application/json

{ "kodeBayar": "3222002005265231" }
```

### Response dari API (contoh sukses):

```json
{
    "success": true,
    "code": "0000",
    "message": "Tagihan dengan kode bayar 3222002005265231 sudah berhasil dibayar",
    "param": {
        "kodeBayar": "3222002005265231"
    }
}
```

### Logika isPaid:

```dart
final bool isPaid = body['success'] == true && body['code'] == '0000';
```

### Snippet — Polling + Check Status:

```dart
Timer? _paymentStatusPoller;
Timer? _pollingMaxTimer;
bool _isPollingPayment = false;
int _pollingErrorCount = 0;
static const int _maxPollingErrorLog = 3;
static const Duration _pollingInterval = Duration(seconds: 5);
static const Duration _pollingMaxDuration = Duration(minutes: 15);

void _startPaymentStatusPolling() {
  if (_activeKodeBayar == null || _activeKodeBayar!.isEmpty) return;

  _stopPaymentStatusPolling();
  _pollingErrorCount = 0;

  AppLogger.d("[Polling] ▶️ Polling DIMULAI");
  AppLogger.d("[Polling] kodeBayar  : $_activeKodeBayar");
  AppLogger.d("[Polling] interval   : ${_pollingInterval.inSeconds} detik");
  AppLogger.d("[Polling] max durasi : ${_pollingMaxDuration.inMinutes} menit");

  _paymentStatusPoller = Timer.periodic(_pollingInterval, (_) {
    _checkPaymentStatus();
  });

  // Auto-stop setelah 15 menit
  _pollingMaxTimer = Timer(_pollingMaxDuration, () {
    AppLogger.d("[Polling] ⏰ Batas ${_pollingMaxDuration.inMinutes} menit tercapai — stop");
    _stopPaymentStatusPolling();
  });
}

void _stopPaymentStatusPolling() {
  if (_paymentStatusPoller != null) {
    AppLogger.d("[Polling] ⏹️ Polling DIHENTIKAN");
  }
  _paymentStatusPoller?.cancel();
  _paymentStatusPoller = null;
  _pollingMaxTimer?.cancel();
  _pollingMaxTimer = null;
  _isPollingPayment = false;
}

Future<void> _checkPaymentStatus() async {
  if (_isPollingPayment) return;
  if (_activeKodeBayar == null) { _stopPaymentStatusPolling(); return; }

  _isPollingPayment = true;
  try {
    final endpoint = Uri.parse('http://192.168.99.46:8700/api/check-dummy-payment-status');
    final requestBody = jsonEncode({'kodeBayar': _activeKodeBayar});

    AppLogger.d("[Polling] 🔄 POST $endpoint");
    AppLogger.d("[Polling] Request body: $requestBody");

    final response = await http
        .post(endpoint, headers: {'Content-Type': 'application/json'}, body: requestBody)
        .timeout(const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Timeout 5s — cek WiFi'));

    AppLogger.d("[Polling] Response status : ${response.statusCode}");
    AppLogger.d("[Polling] Response body   : ${response.body}");

    if (response.statusCode == 200) {
      final Map<String, dynamic> body = jsonDecode(response.body);

      // Debug: tampilkan semua field response
      AppLogger.d("[Polling] ── Parsed Response ──");
      AppLogger.d("[Polling]   success : ${body['success']}");
      AppLogger.d("[Polling]   code    : ${body['code']}");
      AppLogger.d("[Polling]   message : ${body['message']}");
      AppLogger.d("[Polling]   param   : ${body['param']}");

      final bool isPaid = body['success'] == true && body['code'] == '0000';
      AppLogger.d("[Polling]   isPaid  : $isPaid");
      AppLogger.d("[Polling] ────────────────────");

      _pollingErrorCount = 0;

      if (isPaid) {
        AppLogger.d("[Polling] ════════════════════════════════");
        AppLogger.d("[Polling] 💰 LUNAS — kodeBayar: $_activeKodeBayar");
        AppLogger.d("[Polling] → Menutup Custom Tab (TIDAK kirim event)");
        AppLogger.d("[Polling] ════════════════════════════════");
        _stopPaymentStatusPolling();
        if (_browser.isOpened()) await _browser.close();
        _activeKodeBayar = null;
        return;
      }
    }
  } catch (e) {
    _pollingErrorCount++;
    if (_pollingErrorCount <= _maxPollingErrorLog) {
      AppLogger.d("[Polling] Error ke-$_pollingErrorCount/$_maxPollingErrorLog: $e");
      if (_pollingErrorCount == _maxPollingErrorLog) {
        AppLogger.d("[Polling] 🔕 Log disuppress — polling tetap berjalan");
      }
    }
  } finally {
    _isPollingPayment = false;
  }
}
```

### Contoh Output Debug:

```
[Polling] ▶️ Polling DIMULAI
[Polling] kodeBayar  : 3222002005265231
[Polling] interval   : 5 detik
[Polling] max durasi : 15 menit
[Polling] 🔄 POST http://192.168.99.46:8700/api/check-dummy-payment-status
[Polling] Request body: {"kodeBayar":"3222002005265231"}
[Polling] Response status : 200
[Polling] Response body   : {"success":true,"code":"0000","message":"Tagihan dengan kode bayar 3222002005265231 sudah berhasil dibayar","param":{"kodeBayar":"3222002005265231"}}
[Polling] ── Parsed Response ──
[Polling]   success : true
[Polling]   code    : 0000
[Polling]   message : Tagihan dengan kode bayar 3222002005265231 sudah berhasil dibayar
[Polling]   param   : {kodeBayar: 3222002005265231}
[Polling]   isPaid  : true
[Polling] ────────────────────
[Polling] ════════════════════════════════
[Polling] 💰 LUNAS — kodeBayar: 3222002005265231
[Polling] → Menutup Custom Tab (TIDAK kirim event)
[Polling] ════════════════════════════════
[Polling] ⏹️ Polling DIHENTIKAN
[Polling] 🔒 Menutup Custom Tab...
```

---

## Ringkasan Alur

```
PKB console.log({ type:"finpay_navigation", url, kodeBayar })
  │
  ▼
Host: onConsoleMessage → handleConsoleMessage()
  │
  ├─ Parse JSON → simpan kodeBayar
  │
  ▼
Host: _openInCustomTabs(url) → Custom Tab terbuka
Host: _startPaymentStatusPolling() → polling setiap 5 detik (max 15 menit)
  │
  ├─── isPaid (code=0000) ──► TUTUP Custom Tab saja (tanpa event)
  │
  ├─── User tutup tab ─────► kirim paymentHold ke PKB
  │                           → Sambara tampilkan dialog konfirmasi
  │
  ├─── Deep link pocapp:// ─► TUTUP Custom Tab saja (tanpa event)
  │
  └─── 15 menit habis ─────► Stop polling otomatis
```

---

## Event Yang Dikirim ke PKB

| Event | Payload | Kapan |
|-------|---------|-------|
| `paymentHold` | `{detail: {ts, kodeBayar}}` | User tutup Custom Tab |

> **PENTING:** Host app TIDAK mengirim `paymentCompleted`. Saat pembayaran sukses, host app hanya menutup Custom Tab. Sambara mendeteksi sendiri status pembayaran via API internal.
