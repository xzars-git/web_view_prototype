# Panduan Integrasi Host App — PKB WebView Payment
> **Untuk:** Tim pengembang host app (aplikasi native yang mem-wrap PKB sebagai WebView)
> **Versi:** 2026-05-11
> **Kontak PKB:** *(isi nama/email tim PKB)*

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
| **B** | DANA, ShopeePay, LinkAja | PKB kirim URL ke host app → host buka **Chrome Custom Tab** |

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

### ✅ Checklist Implementasi (Production)

- [ ] **Bridge `SapawargaChannel`** — inject ke WebView sebelum PKB load
- [ ] **Handler terima postMessage** → buka URL di Custom Tab
- [ ] **`handleNavigation` / `shouldOverrideUrlLoading`** — whitelist domain
- [ ] **Notifikasi ke PKB** — dispatch event `paymentCompleted` setelah bayar
- [ ] **Deep link `pocapp://`** — daftarkan di AndroidManifest & Info.plist

### ✅ Checklist Tambahan (Demo Mode)

- [ ] **`_demoAutoCloseTimer`** — timer native yang auto-close Custom Tab setelah N detik
- [ ] **Auto-trigger Jalur A** — timer yang balik ke PKB setelah WebView navigasi ke Finpay

---

## 1. Bridge JavaScript (SapawargaChannel)

PKB berkomunikasi ke host app menggunakan `window.SapawargaChannel.postMessage(url)`.
Kamu harus menyuntikkan object ini ke WebView **sebelum** halaman PKB dimuat.

**Cara inject (flutter_inappwebview):**

```dart
// Buat UserScript yang diinjeksi AT_DOCUMENT_START
UserScript(
  groupName: 'sapawarga_bridge',
  source: """
    (function() {
      window['SapawargaChannel'] = {
        postMessage: function(message) {
          if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('SapawargaChannel', message);
          } else {
            window.addEventListener('flutterInAppWebViewPlatformReady', function() {
              window.flutter_inappwebview.callHandler('SapawargaChannel', message);
            });
          }
        }
      };
    })();
  """,
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
)
```

**Daftarkan handler Flutter-nya:**

```dart
webViewController.addJavaScriptHandler(
  handlerName: 'SapawargaChannel',
  callback: (args) {
    if (args.isEmpty) return;
    final String url = args[0].toString().trim();

    // Validasi: hanya terima URL https://
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;

    _openInCustomTab(url); // lihat bagian 3
  },
);
```

> **Catatan:** PKB hanya mengirim URL e-wallet (DANA, ShopeePay, LinkAja) melalui bridge ini. URL CC/VA **tidak** dikirim via bridge — PKB langsung navigasi WebView.

---

## 2. Pengaturan Navigasi WebView (shouldOverrideUrlLoading)

Kamu **wajib** mengizinkan domain berikut di dalam WebView:

```dart
// Domain yang harus di-ALLOW di WebView:
// - Domain PKB kamu sendiri (misal: sambara.vercel.app)
// - live.finpay.id (halaman pembayaran CC/VA)
final List<String> allowedHosts = [
  'sambara.vercel.app',   // ganti dengan domain PKB production
  'live.finpay.id',       // halaman Finpay CC/VA
];

Future<NavigationActionPolicy> handleNavigation(NavigationAction action) async {
  final uri = action.request.url;
  if (uri == null) return NavigationActionPolicy.ALLOW;

  // 1. Non-http (pocapp://, dll.) → handle external
  if (!uri.scheme.startsWith('http')) {
    launchUrl(uri, mode: LaunchMode.externalApplication);
    return NavigationActionPolicy.CANCEL;
  }

  // 2. Deteksi halaman hasil pembayaran CC/VA
  //    Finpay redirect ke live.finpay.id/pg/payment/card/result/{success|failed}
  //    Trigger notifikasi ke PKB agar langsung verifikasi
  final path = uri.path.toLowerCase();
  if (path.contains('/payment/card/result/') ||
      path.contains('/payment/result/') ||
      path.contains('/payment/success') ||
      path.contains('/payment/failed')) {
    _notifyPaymentCompleted(); // lihat bagian 4
    return NavigationActionPolicy.ALLOW; // tetap tampilkan halaman hasil
  }

  // 3. Domain whitelist → ALLOW
  final host = uri.host.toLowerCase();
  if (allowedHosts.any((h) => host == h || host.endsWith('.$h'))) {
    return NavigationActionPolicy.ALLOW;
  }

  // 4. Di luar whitelist → CANCEL
  return NavigationActionPolicy.CANCEL;
}
```

> **PENTING:** Jangan redirect URL `https://` ke Custom Tab! URL CC/VA masuk via `shouldOverrideUrlLoading` dan harus di-ALLOW agar tetap di WebView.

---

## 3. Buka URL di Chrome Custom Tab

```dart
late final ChromeSafariBrowser _browser = _PaymentChromeBrowser(
  onClosedCallback: () {
    // User tutup Custom Tab → beritahu PKB untuk cek status
    _notifyPaymentCompleted();
  },
);

Future<void> _openInCustomTab(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await _browser.open(
      url: WebUri.uri(uri),
      settings: ChromeSafariBrowserSettings(
        shareState: CustomTabsShareState.SHARE_STATE_OFF,
        showTitle: true,
      ),
    );
  } catch (e) {
    // Fallback jika Custom Tab gagal
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// ChromeSafariBrowser wrapper
class _PaymentChromeBrowser extends ChromeSafariBrowser {
  _PaymentChromeBrowser({required this.onClosedCallback});
  final VoidCallback onClosedCallback;

  @override
  void onClosed() => onClosedCallback();
}
```

---

## 4. Notifikasi ke PKB (paymentCompleted Event)

Setelah pembayaran selesai (dari jalur manapun), kamu **wajib** mengirim event ini ke PKB:

```dart
// Simpan referensi webViewController
InAppWebViewController? _webViewController;

void _notifyPaymentCompleted() {
  _webViewController?.evaluateJavascript(
    source: "window.dispatchEvent(new CustomEvent('paymentCompleted', {detail:{ts:Date.now()}}));",
  );
}
```

**Event ini dipanggil dari 3 tempat:**

| Situasi | Dipanggil dari |
|---------|---------------|
| Finpay redirect ke halaman sukses/gagal (CC/VA) | `handleNavigation` saat deteksi result URL |
| Deep link `pocapp://payment/return` diterima | `app_links` stream listener |
| User tutup Custom Tab secara manual (E-wallet) | `ChromeSafariBrowser.onClosed()` |

> **PENTING — Urutan untuk deep link:** Panggil `_notifyPaymentCompleted()` **sebelum** menutup browser. Jika dibalik, `onClosed()` akan memicu notifikasi kedua.
>
> ```dart
> // ✅ Benar:
> _notifyPaymentCompleted(); // notify dulu
> await _browser.close();    // baru close
>
> // ❌ Salah (double-fire):
> await _browser.close();    // close dulu → onClosed() fire → notify #1
> _notifyPaymentCompleted(); // notify #2 → duplicate!
> ```

---

## 5. Deep Link Setup (pocapp://)

Deep link `pocapp://payment/return` dikirim oleh Finpay setelah pembayaran e-wallet selesai.

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

### Listener di Dart (package `app_links`)

```dart
import 'package:app_links/app_links.dart';

final _appLinks = AppLinks();

void _initDeepLinks() {
  _appLinks.uriLinkStream.listen((uri) async {
    if (uri.scheme == 'pocapp' && uri.host == 'payment') {
      if (uri.path.contains('return') || uri.path.contains('callback')) {
        // Notify DULU, baru close browser
        _notifyPaymentCompleted();
        if (_browser.isOpened()) await _browser.close();
      }
    }
  });
}
```

---

## 6. Alur Lengkap Per Jalur

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
[PKB]  User pilih DANA → PKB kirim URL ke bridge: SapawargaChannel.postMessage(url)
[Host] Handler terima URL → validasi https:// → buka Custom Tab
[Host] User bayar di DANA app
       Skenario 1 — Deep link:
         Finpay kirim pocapp://payment/return
         [Host] app_links terima → _notifyPaymentCompleted() → close browser
       Skenario 2 — Manual close:
         User tutup Custom Tab
         [Host] onClosed() → _notifyPaymentCompleted()
[PKB]  Terima event 'paymentCompleted' → panggil API cek status → selesai
```

---

## 7. Troubleshooting

| Gejala | Kemungkinan Penyebab | Solusi |
|--------|---------------------|--------|
| Halaman Finpay CC/VA tidak muncul | Domain `live.finpay.id` tidak di whitelist | Tambahkan ke `allowedHosts` |
| E-wallet tidak terbuka (stuck di WebView) | Bridge `SapawargaChannel` tidak ter-inject | Pastikan UserScript diinjeksi `AT_DOCUMENT_START` |
| `paymentCompleted` dipanggil 2x | Urutan notify/close salah | Panggil notify **sebelum** `_browser.close()` |
| PKB tidak update setelah bayar | Event `paymentCompleted` tidak sampai | Pastikan `evaluateJavascript` dipanggil ke webViewController yang aktif |
| Deep link tidak tertangkap | AndroidManifest/Info.plist salah | Cek scheme `pocapp` dan host `payment` |
| Demo timer tidak jalan | `_startDemoAutoClose` tidak dipanggil | Pastikan dipanggil setelah `_browser.open()` dan saat navigasi ke Finpay |

---

## 8. Demo Mode — Auto Trigger Tanpa Aksi User

> **Konteks:** Saat Custom Tab terbuka, WebView di-pause Android. Timer/JS di PKB ikut berhenti.
> Namun **host app TIDAK di-pause** — timer native di sini tetap berjalan.
> Skema ini memanfaatkan hal tersebut untuk simulasi pembayaran otomatis tanpa perlu user menutup Custom Tab secara manual.

### Cara Kerja

```
Jalur B (E-Wallet — Custom Tab):
  _openInCustomTabs() dipanggil
    → Custom Tab buka URL Finpay
    → _startDemoAutoClose(isCustomTab: true) dipanggil
    → Timer 5 detik berjalan di host app (tidak di-pause!)
    → [5s] Timer fired:
        → _notifyPaymentCompleted()  ← event dikirim ke PKB
        → _browser.close()           ← Custom Tab tertutup otomatis
    → PKB terima event → verifikasi → UI sukses ✅

Jalur A (CC/VA — InAppWebView):
  handleNavigation() mendeteksi navigasi ke URL Finpay (live.finpay.id)
    → _startDemoAutoClose(isCustomTab: false) dipanggil
    → Timer 5 detik berjalan
    → [5s] Timer fired:
        → _notifyPaymentCompleted()
        → reloadBasePage()  ← WebView kembali ke PKB
    → PKB reload → timer PKB lanjut → mock sukses ✅
```

### Implementasi

```dart
// Field yang dibutuhkan di controller:
static const Duration _demoAutoCloseDelay = Duration(seconds: 5); // sesuaikan
Timer? _demoAutoCloseTimer;

// Helper:
void _startDemoAutoClose({bool isCustomTab = false}) {
  _demoAutoCloseTimer?.cancel();
  _demoAutoCloseTimer = Timer(_demoAutoCloseDelay, () async {
    if (isCustomTab) {
      // Jalur B: notify dulu, baru close (cegah double-fire via onClosed)
      _notifyPaymentCompleted();
      if (_browser.isOpened()) await _browser.close();
    } else {
      // Jalur A: notify, lalu reload PKB
      _notifyPaymentCompleted();
      await reloadBasePage(); // atau loadUrl ke URL PKB production
    }
  });
}

// Panggil setelah Custom Tab berhasil dibuka (Jalur B):
await _browser.open(url: ..., settings: ...);
_startDemoAutoClose(isCustomTab: true); // ← tambahkan ini

// Panggil saat WebView navigasi ke Finpay CC/VA (Jalur A):
// Di dalam handleNavigation(), case allowWebView:
if (_config.isWebViewNavigationAllowed(rawUrl) && rawUrl.contains('finpay')) {
  _startDemoAutoClose(isCustomTab: false); // ← tambahkan ini
}

// WAJIB: batalkan timer di dispose():
@override
void dispose() {
  _demoAutoCloseTimer?.cancel();
  ...
}
```

### Yang Dibutuhkan untuk Menjalankan Skema Ini

| Kebutuhan | Detail |
|-----------|--------|
| **Package** | Tidak ada package tambahan — hanya `dart:async` (`Timer`) |
| **Perubahan PKB** | **Tidak ada** — PKB sudah siap menerima event `paymentCompleted` |
| **Perubahan host app** | Tambahkan `_demoAutoCloseTimer`, `_startDemoAutoClose()`, dan 2 pemanggilan di atas |
| **Mock API PKB** | Aktif di `api_service_pkb.dart` → `paymentVerification()` random 50% sukses |
| **Waktu delay** | Default 5 detik — ubah `_demoAutoCloseDelay` sesuai kebutuhan demo |
| **Untuk production** | Comment/hapus 2 baris `_startDemoAutoClose(...)` di host app |

> **PENTING:** `_notifyPaymentCompleted()` menggunakan `evaluateJavascript` yang hanya berhasil
> saat WebView aktif (tidak di-pause). Untuk Jalur B, ini aman karena setelah `_browser.close()`
> WebView akan resume dan event sudah dikirim. Untuk Jalur A, `_notifyPaymentCompleted()` dipanggil
> sebelum `reloadBasePage()` agar event terkirim ke halaman Finpay yang masih aktif —
> tapi PKB belum ada di sana, jadi yang menyelamatkan adalah **timer PKB** setelah reload.

---

## 9. Testing

### Test Bridge (tanpa bayar sungguhan)
1. Buka PKB di WebView
2. Buka DevTools → Console
3. Jalankan:
   ```js
   // Simulasi PKB kirim URL ke bridge (Jalur B)
   SapawargaChannel.postMessage('https://m.dana.id/test')

   // Simulasi pembayaran selesai (trigger verifikasi di PKB)
   window.dispatchEvent(new CustomEvent('paymentCompleted'))
   ```

### Test Demo Auto-Trigger (di device fisik)
1. Buka host app → WebView load PKB
2. Pilih metode bayar apapun
3. Tunggu 5 detik — Custom Tab/WebView harus auto-close dan PKB menampilkan status sukses
4. Tidak perlu aksi manual apapun dari user

### Test Deep Link (Android)
```bash
adb shell am start -W -a android.intent.action.VIEW \
  -d "pocapp://payment/return" com.your.app.package
```

---

## 10. Referensi Cepat

| Item | Nilai |
|------|-------|
| Bridge name | `SapawargaChannel` |
| Event name | `paymentCompleted` |
| Deep link scheme | `pocapp` |
| Deep link host | `payment` |
| Finpay domain (whitelist) | `live.finpay.id` |
| Result URL pattern | `/pg/payment/card/result/` |
| Demo timer delay | `5 detik` (ubah `_demoAutoCloseDelay`) |
| Mock API | `api_service_pkb.dart → paymentVerification()` |

---

## 📋 PROMPT SIAP KIRIM — untuk Tim Host App

> Salin dan kirimkan teks di bawah ini beserta file dokumentasi ini ke tim host app.
> Lampirkan juga file `finpay_host_app_integration.md` sebagai referensi lengkapnya.

---

```
Halo, kami dari tim PKB.

Kami butuh bantuan untuk mengimplementasikan integrasi pembayaran Finpay
ke dalam host app yang sudah berjalan. Kami sudah menyiapkan PKB sebagai
Flutter Web App — kalian tidak perlu mengubah apapun di PKB.

Silakan baca file `finpay_host_app_integration.md` yang kami lampirkan.
Dokumen tersebut berisi spesifikasi lengkap dan siap implementasi.

Yang perlu diimplementasikan di sisi host app:

1. PRODUCTION (wajib):
   - Bridge SapawargaChannel (inject JS ke WebView sebelum PKB load)
   - shouldOverrideUrlLoading: whitelist live.finpay.id + domain PKB
   - Buka e-wallet URL via ChromeSafariBrowser (Custom Tab)
   - Dispatch event paymentCompleted ke WebView setelah bayar
   - Setup deep link pocapp:// di AndroidManifest & Info.plist

2. DEMO MODE (opsional, untuk simulasi tanpa bayar sungguhan):
   Tambahkan timer native di host app yang auto-close Custom Tab
   setelah beberapa detik, lalu dispatch event paymentCompleted ke PKB.
   Detail kode ada di bagian "8. Demo Mode" di dokumen terlampir.

   Kebutuhan:
   - Tidak ada package tambahan (hanya dart:async Timer)
   - Tidak ada perubahan di PKB
   - Hanya 3 penambahan kecil di controller host app:
     a. Field: static const _demoAutoCloseDelay = Duration(seconds: 5)
     b. Method: _startDemoAutoClose({bool isCustomTab})
     c. Panggil _startDemoAutoClose() setelah Custom Tab terbuka
        dan saat WebView navigasi ke halaman Finpay

   Untuk production: comment/hapus 2 baris pemanggilan _startDemoAutoClose()

Kontrak integrasi lengkap (bridge name, event name, deep link scheme, dll.)
ada di section "Referensi Cepat" di akhir dokumen.

Terima kasih.
```
