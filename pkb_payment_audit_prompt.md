# Audit & Fix: PKB Web App — Sisi Pembayaran Finpay

> **Konteks:** Dokumen ini adalah komunikasi dua arah antara Tim Host App dan Tim PKB.
> Kolom **[PKB Response]** ditambahkan sebagai jawaban resmi dari Tim PKB atas setiap temuan.
> **Status terakhir:** Semua temuan telah ditangani. ✅

---

## Ringkasan Kebutuhan Kami (Tim Host App → Tim PKB)

### Apa yang Sudah Dijamin Host App

1. **Bridge `SapawargaChannel`** — diinjeksi via `UserScript` di `AT_DOCUMENT_START`, sebelum PKB load.
2. **`paymentCompleted` event** — di-dispatch sebagai `CustomEvent` ke `window` setelah:
   - Jalur A (CC/VA): `handleNavigation` deteksi result URL (`/payment/card/result/...`)
   - Jalur B (E-Wallet): Deep link `pocapp://payment/return` diterima, ATAU user tutup Custom Tab manual
3. **Guard double-fire** — Flag `_paymentNotified` mencegah event duplikat (auto-reset 3 detik).
4. **Host app TIDAK memanggil `reloadBasePage()`** setelah `paymentCompleted` — PKB yang mengontrol navigasi sendiri.

### Apa yang Kami Harapkan dari PKB

1. PKB **listen event `paymentCompleted`** dan langsung panggil `doVerifyPayment()`.
2. Setelah `doVerifyPayment()` sukses, PKB **navigasi sendiri** ke halaman sukses / kembali ke daftar kendaraan.
3. Timer polling **berhenti** setelah `isPaymentSuccess = true`.
4. Listener `paymentCompleted` dibersihkan di `dispose()`.
5. `showFinpayRedirectScreen` di-reset saat event diterima agar user langsung lihat UI verifikasi.

> **[PKB Response — Kebutuhan]** ✅ Semua poin di atas sudah terpenuhi dan telah diverifikasi.
> Lihat respons per temuan di bawah untuk detail implementasinya.

---

## Audit Kode PKB — Kondisi Tidak Ideal

Setelah review kode PKB (`detail_pembayaran_controller.dart`, `finpay_navigation_web.dart`, `webview_finpay.dart`, `api_service_pkb.dart`), berikut temuan kami:

---

### 🔴 #1 — `webview_finpay.dart` dispatch `Event` biasa, bukan `CustomEvent`

**File:** `packages/pkb/lib/pages/detail_pembayaran/widget/webview_finpay.dart` line 58
**File:** `packages/core/lib/widgets/webview/base_webview.dart` line 50

```dart
// PKB (webview_finpay.dart L58):
window.dispatchEvent(new Event('paymentCompleted'));

// Host App dispatch:
window.dispatchEvent(new CustomEvent('paymentCompleted', {detail:{ts:Date.now()}}));
```

**Masalah:** PKB di `webview_finpay.dart` memiliki kode sendiri yang dispatch `Event` (bukan `CustomEvent`). Ini **tidak dipakai saat berjalan di dalam host app** — karena host app yang dispatch, bukan PKB. Tapi file ini juga punya `_notifyPaymentCompleted()` method sendiri dan `shouldOverrideUrlLoading` yang handle `pocapp://` — ini **duplikasi logika** yang seharusnya ada di host app saja.

**Risiko:** Jika PKB build di-deploy di luar host app (standalone InAppWebView), logika ini akan berjalan tapi tidak konsisten dengan host app.

**Rekomendasi:** Klarifikasi — apakah `webview_finpay.dart` masih dipakai? Kalau PKB sudah berjalan di dalam host app (WebView milik `web_view_prototype`), file ini seharusnya **tidak aktif** atau hanya fallback. Pastikan tidak ada dua tempat yang melakukan hal yang sama.

> **[PKB Response]** ✅ **FIXED**
> `webview_finpay.dart` dan `base_webview.dart` adalah **legacy/standalone mode** — dipakai hanya jika PKB
> di-build sebagai mobile app mandiri (bukan di dalam host app). Ketika PKB berjalan di dalam host app,
> file ini tidak aktif karena host app menyediakan bridge dan dispatch sendiri.
>
> Yang sudah dilakukan:
> - Ditambahkan komentar `LEGACY / STANDALONE MODE ONLY` yang jelas di kedua file
> - `_notifyPaymentCompleted()` diupdate dari `Event` biasa → `CustomEvent` agar konsisten jika file ini dipakai di standalone mode
> - Semua section yang duplikasi (bridge inject, `pocapp://` handler) sudah diberi komentar eksplisit bahwa ini hanya aktif di standalone
>
> **File PKB yang benar-benar aktif saat dalam host app:** `finpay_navigation_web.dart` (listener) dan `detail_pembayaran_controller.dart` (verifikasi).

---

### 🔴 #2 — `unregisterPaymentListenerImpl()` ada bug: missing semicolon

**File:** `packages/pkb/lib/utils/finpay_navigation/finpay_navigation_web.dart` line 117-122

```dart
js.context.callMethod('eval', [
  "if(window.__sambPaymentFn){"
      "window.removeEventListener('paymentCompleted',window.__sambPaymentFn);"
      "window.__sambPaymentFn=null;"
      "}"
      "window._flutterOnPaymentCompleted=null;",  // ← INI
]);
```

**Masalah:** Baris `window._flutterOnPaymentCompleted=null;` ada di LUAR blok `if`. Tapi di line sebelumnya, closing brace `}` dan baris ini digabung tanpa semicolon pemisah setelah `}`:

```javascript
// Hasil setelah concat Dart string:
if(window.__sambPaymentFn){window.removeEventListener('paymentCompleted',window.__sambPaymentFn);window.__sambPaymentFn=null;}window._flutterOnPaymentCompleted=null;
```

Sebenarnya ini **secara kebetulan benar** karena JavaScript ASI (Automatic Semicolon Insertion) menanganinya. Tapi ini fragile — satu perubahan kecil bisa merusak.

**Rekomendasi:** Tambahkan semicolon eksplisit setelah closing brace `}`:
```dart
"window.__sambPaymentFn=null;"
"}"   // ← tambah ; sebelum statement berikutnya
"; window._flutterOnPaymentCompleted=null;",
```

> **[PKB Response]** ✅ **FIXED**
> Semicolon eksplisit sudah ditambahkan. String JS sekarang menjadi:
> ```
> if(window.__sambPaymentFn){...window.__sambPaymentFn=null;};window._flutterOnPaymentCompleted=null;
> ```
> Tidak lagi bergantung pada ASI.

---

### 🟡 #3 — `doVerifyPayment` tidak punya guard reentrancy

**File:** `packages/pkb/lib/pages/detail_pembayaran/controller/detail_pembayaran_controller.dart` line 243-288

```dart
doVerifyPayment({bool fromTimer = false}) async {
  if (!fromTimer) {
    isChecking = true;
    update();
  }
  // ... API call ...
}
```

**Masalah:** Jika `doVerifyPayment()` dipanggil bersamaan dari 3 sumber:
1. Timer polling (setiap 5 detik)
2. `handlePaymentCompletedFromHost()` (event dari host)
3. User tekan tombol "Cek Status" manual

Ketiga panggilan bisa berjalan **paralel** — 3 API call sekaligus. Tidak ada guard `if (isChecking) return;`.

**Dampak:** 3× API call redundan, `countChecking` terhitung salah, `isPaymentSuccess` bisa di-set multiple kali.

**Rekomendasi:**
```dart
doVerifyPayment({bool fromTimer = false}) async {
  if (isChecking) return;  // ← tambahkan guard
  // ... sisanya sama
}
```

> **[PKB Response]** ✅ **FIXED**
> Guard reentrancy sudah ditambahkan dengan pattern bersih:
> ```dart
> doVerifyPayment({bool fromTimer = false}) async {
>   if (isChecking) return; // guard semua sumber
>   isChecking = true;
>   if (!fromTimer) countChecking++;
>   update();
>   try {
>     final result = await api.paymentVerification(...);
>     if (result['data']['status_payment'] == true) {
>       isPaymentSuccess = true;
>       showFinpayRedirectScreen = false;
>       stopTimer();
>     }
>   } catch (e, stackTrace) { ... }
>   finally {
>     isChecking = false; // selalu reset
>     update();
>   }
> }
> ```
> `finally` block memastikan `isChecking` selalu di-reset (tidak pernah stuck `true`).

---

### 🟡 #4 — `handlePaymentCompletedFromHost()` tidak menghentikan timer

**File:** line 311-323

```dart
void handlePaymentCompletedFromHost() {
  showFinpayRedirectScreen = false;
  update();
  doVerifyPayment(fromTimer: false);  // ← async, tapi tidak di-await
}
```

**Masalah:** Saat host app kirim `paymentCompleted`:
1. `handlePaymentCompletedFromHost()` dipanggil → `doVerifyPayment(fromTimer: false)`
2. Timer masih jalan → 5 detik kemudian → `doVerifyPayment(fromTimer: true)` lagi
3. Jika API verify sukses di step 1, `stopTimer()` dipanggil di `doVerifyPayment`
4. Tapi timer tick mungkin sudah terjadwal sebelum `stopTimer()` dipanggil

Timer **tidak di-cancel** saat event diterima. Seharusnya:
```dart
void handlePaymentCompletedFromHost() {
  showFinpayRedirectScreen = false;
  stopTimer();  // ← hentikan timer segera, verifikasi sekarang lebih prioritas
  update();
  doVerifyPayment(fromTimer: false);
}
```

> **[PKB Response]** ✅ **FIXED**
> `stopTimer()` sekarang dipanggil di `handlePaymentCompletedFromHost()` **sebelum** `doVerifyPayment()`.
> Saat event dari host diterima, timer polling langsung berhenti — verifikasi via event lebih prioritas.
> Reentrancy guard di #3 juga memastikan bahwa tick timer yang terlanjur terjadwal pun tidak akan
> memulai API call baru.

---

### 🟡 #5 — Listener `paymentCompleted` menggunakan `addEventListener` biasa — tidak handle `CustomEvent`

**File:** `finpay_navigation_web.dart` line 105-109

```javascript
window.__sambPaymentFn=function(){
  if(window._flutterOnPaymentCompleted) window._flutterOnPaymentCompleted();
};
window.addEventListener('paymentCompleted', window.__sambPaymentFn);
```

**Fakta:** Host app dispatch `CustomEvent` dengan `{detail:{ts:Date.now()}}`.
PKB listener tidak membaca `event.detail` — langsung panggil callback tanpa argument.

**Dampak saat ini:** Tidak masalah secara fungsional — `CustomEvent` tetap trigger `addEventListener`. Tapi:
- PKB tidak bisa tracing timestamp dari host app
- Tidak bisa bedakan mana event asli vs event lama yang tertinggal

**Rekomendasi (nice-to-have):** Ubah callback untuk menerima `event` parameter:
```javascript
window.__sambPaymentFn = function(event) {
  console.log('[PKB] paymentCompleted received, ts=' + (event.detail?.ts || 'unknown'));
  if(window._flutterOnPaymentCompleted) window._flutterOnPaymentCompleted();
};
```

> **[PKB Response]** ✅ **FIXED**
> Listener sudah diupdate untuk menerima parameter `event` dan log `event.detail.ts`.
> Ini memudahkan debugging — saat Custom Tab ditutup, log di browser console PKB akan menampilkan
> timestamp event yang dikirim host app, sehingga mudah memverifikasi apakah event diterima
> dan kapan tepatnya.

---

### 🟡 #6 — `showFinpayRedirectScreen` tidak di-reset saat timer verify sukses

**File:** line 266-270

```dart
if (result['data']['status_payment'] == true) {
  isPaymentSuccess = true;
  stopTimer();
  update();
}
```

Jika timer polling berhasil verify (tanpa event dari host), `showFinpayRedirectScreen` masih `true`. User bisa terjebak di layar redirect Finpay padahal pembayaran sudah sukses.

**Rekomendasi:** Tambahkan reset:
```dart
if (result['data']['status_payment'] == true) {
  isPaymentSuccess = true;
  showFinpayRedirectScreen = false;  // ← tambahkan
  stopTimer();
  update();
}
```

> **[PKB Response]** ✅ **FIXED**
> `showFinpayRedirectScreen = false` sudah ditambahkan di dalam blok sukses di `doVerifyPayment()`.
> Berlaku untuk semua trigger: timer polling maupun event dari host app — keduanya melewati
> method yang sama sehingga behavior konsisten.

---

### 🔵 #7 — `webview_finpay.dart` duplikasi bridge inject dengan host app

**File:** `webview_finpay.dart` line 191-209

PKB punya inject `SapawargaChannel` sendiri di `initialUserScripts`, PLUS host app juga inject bridge-nya sendiri. Saat berjalan di dalam host app, ada **dua** `SapawargaChannel` di-inject — yang terakhir menang. Yang mana yang terakhir tergantung timing.

**Rekomendasi:** Jika PKB **selalu** berjalan di dalam host app untuk flow Finpay, hapus inject bridge di `webview_finpay.dart`. Bridge sudah disediakan host app via `bridgeUserScript` di `HybridWebViewController`.

> **[PKB Response]** ✅ **DITANGANI**
> File ini adalah **legacy/standalone mode** (lihat #1). Saat PKB berjalan di dalam host app,
> `webview_finpay.dart` **tidak aktif** — host app menyediakan WebView-nya sendiri beserta bridge.
>
> Bridge inject di `webview_finpay.dart` sudah diberi komentar eksplisit:
> ```dart
> // CATATAN: Di production (host app), bridge inject ini TIDAK dipakai.
> // Host app sudah inject SapawargaChannel sendiri via bridgeUserScript.
> // Ini hanya fallback saat PKB berjalan standalone.
> ```
> Tidak dihapus karena masih diperlukan untuk skenario standalone/testing di luar host app.

---

### 🔵 #8 — `webview_finpay.dart` handle `pocapp://` scheme sendiri

**File:** `webview_finpay.dart` line 251-266

PKB punya `shouldOverrideUrlLoading` yang intercept `pocapp://payment/return`. Tapi host app juga sudah handle ini via `_initDeepLinks` listener.

**Risiko:** Double handling — PKB close browser + dispatch event, host app juga close browser + dispatch event. Flag `_paymentNotified` di host app mencegah double-fire, tapi PKB sisi tidak punya guard serupa.

> **[PKB Response]** ✅ **DITANGANI**
> Sama dengan #7 — ini adalah standalone mode code. Saat PKB berjalan di dalam host app,
> `webview_finpay.dart` tidak dipakai, sehingga tidak ada konflik.
>
> Sebagai tambahan, urutan di standalone handler sudah difix untuk konsistensi:
> ```dart
> // Notify DULU sebelum close (konsisten dengan host app pattern)
> _notifyPaymentCompleted();
> if (browser != null && browser!.isOpened()) await browser!.close();
> ```
> Handler sudah diberi komentar `STANDALONE MODE ONLY` agar jelas batasannya.

---

### 🔵 #9 — `late Timer timer` tanpa initialization guard

**File:** line 52

```dart
late Timer timer;
bool isTimerActive = false;
```

Jika `stopTimer()` dipanggil sebelum `waitingStatusPembayaran()` (misal di dispose karena navigate away cepat), `timer` belum di-assign → `LateInitializationError` crash.

**Rekomendasi:** Ubah ke nullable:
```dart
Timer? timer;
```
Dan update `stopTimer()`:
```dart
void stopTimer() {
  if (isTimerActive && (timer?.isActive ?? false)) {
    timer?.cancel();
    isTimerActive = false;
  }
}
```

> **[PKB Response]** ✅ **FIXED**
> `late Timer timer` sudah diubah menjadi `Timer? timer`.
> `stopTimer()` sudah diupdate menggunakan nullable-safe access:
> ```dart
> void stopTimer() {
>   if (isTimerActive && (timer?.isActive ?? false)) {
>     timer?.cancel();
>     isTimerActive = false;
>   }
> }
> ```
> Tidak ada lagi risiko `LateInitializationError` crash.

---

## Ringkasan Temuan & Status

| # | Severity | Masalah | File | Status PKB |
|---|----------|---------|------|------------|
| 1 | 🔴 | Duplikasi logika dispatch + deep link handling di `webview_finpay.dart` | webview_finpay.dart | ✅ Ditangani — marked LEGACY, CustomEvent |
| 2 | 🔴 | `unregisterPaymentListenerImpl` semicolon fragile | finpay_navigation_web.dart | ✅ Fixed |
| 3 | 🟡 | `doVerifyPayment` tanpa reentrancy guard | detail_pembayaran_controller.dart | ✅ Fixed |
| 4 | 🟡 | `handlePaymentCompletedFromHost` tidak stop timer | detail_pembayaran_controller.dart | ✅ Fixed |
| 5 | 🟡 | Listener tidak baca `event.detail` dari `CustomEvent` | finpay_navigation_web.dart | ✅ Fixed |
| 6 | 🟡 | `showFinpayRedirectScreen` tidak di-reset saat timer verify | detail_pembayaran_controller.dart | ✅ Fixed |
| 7 | 🔵 | Duplikasi bridge inject antara PKB dan host app | webview_finpay.dart | ✅ Ditangani — komentar LEGACY |
| 8 | 🔵 | Duplikasi `pocapp://` handling antara PKB dan host app | webview_finpay.dart | ✅ Ditangani — komentar LEGACY |
| 9 | 🔵 | `late Timer` tanpa null-safety bisa crash | detail_pembayaran_controller.dart | ✅ Fixed |

---

## Kontrak Yang Berlaku (Production)

```
HOST APP menjamin:
  ✅ Bridge SapawargaChannel di-inject AT_DOCUMENT_START
  ✅ paymentCompleted CustomEvent di-dispatch setelah:
     * CC/VA result URL terdeteksi (Jalur A)
     * Deep link pocapp://payment/return (Jalur B)
     * User tutup Custom Tab manual (Jalur B)
  ✅ Double-fire guard: max 1 dispatch per 3 detik
  ✅ Host TIDAK memanggil reloadBasePage() — PKB handle navigasi sendiri

PKB menjamin:
  ✅ Listen event paymentCompleted via registerPaymentListener() di initState
  ✅ handlePaymentCompletedFromHost() → stopTimer() → doVerifyPayment()
  ✅ doVerifyPayment() reentrancy-safe (if isChecking return)
  ✅ finally { isChecking=false; update(); } — selalu reset, tidak pernah stuck
  ✅ isPaymentSuccess=true → showFinpayRedirectScreen=false → stopTimer()
  ✅ unregisterPaymentListener() di dispose()
  ✅ Timer? nullable-safe, tidak crash di edge case
  ✅ Listener log event.detail.ts untuk debugging
  ✅ webview_finpay.dart hanya aktif di standalone mode
```
