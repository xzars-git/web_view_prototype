# Audit & Fix: PKB Web App — Sisi Pembayaran Finpay

> **Konteks:** Dokumen ini adalah komunikasi dua arah antara Tim Host App dan Tim PKB.
> **Status terakhir:** Semua temuan v1 telah ditangani. ✅
> **Update v2 (2026-05-20):** Refactor besar — console handler, API polling, paymentHold.

---

## Perubahan Arsitektur v2 (2026-05-20)

### Yang Berubah dari v1

| Area | v1 (Lama) | v2 (Sekarang) |
|------|-----------|---------------|
| **Komunikasi E-Wallet** | `SapawargaChannel.postMessage(url)` — hanya URL | `console.log(JSON.stringify({type, url, kodeBayar}))` — URL + kodeBayar |
| **Verifikasi Pembayaran** | Timer bypass + manual button | API polling `check-dummy-payment-status` setiap 3s |
| **Custom Tab Close** | Langsung dispatch `paymentCompleted` | Dialog konfirmasi → `paymentHold` atau reopen |
| **Event Baru** | — | `paymentHold` (user batalkan transaksi) |
| **Bridge** | `SapawargaChannel` (primary) + `PaymentInfoChannel` | `console.log` (primary) + `SapawargaChannel` (fallback) |
| **Demo/Bypass** | `_demoAutoCloseTimer`, 3 tombol simulasi | **DIHAPUS SEMUA** |

---

## Ringkasan Kebutuhan (Tim Host App → Tim PKB)

### Apa yang Sudah Dijamin Host App (v2)

1. **Console message handler** — `onConsoleMessage` parse JSON `finpay_navigation` untuk dapatkan URL + kodeBayar.
2. **API polling** — `POST /api/check-dummy-payment-status` setiap 3 detik. Jika `isPaid=true`, Custom Tab auto-close + dispatch `paymentCompleted`.
3. **Dialog konfirmasi** — Saat user tutup Custom Tab manual, muncul dialog:
   - "Lanjutkan Bayar" → reopen Custom Tab + restart polling.
   - "Batalkan Transaksi" → dispatch `paymentHold` ke PKB.
4. **Bridge `SapawargaChannel`** — tetap di-inject sebagai fallback.
5. **Guard double-fire** — Flag `_paymentNotified` mencegah event duplikat (auto-reset 3 detik).
6. **Host app HANYA mengirim maksimal 1 event** per transaksi: `paymentCompleted` ATAU `paymentHold`.

### Apa yang Kami Harapkan dari PKB

1. PKB **listen event `paymentCompleted`** dan langsung panggil `doVerifyPayment()`.
2. PKB **listen event `paymentHold`** dan hit API pembatalan payment dari sisinya.
3. Setelah `doVerifyPayment()` sukses, PKB **navigasi sendiri** ke halaman sukses.
4. Timer polling **berhenti** setelah `isPaymentSuccess = true`.
5. PKB **siap menerima reopen Custom Tab** (user pilih "Lanjutkan Bayar" di dialog).
6. PKB mengirim data via `console.log(JSON.stringify({type:"finpay_navigation", url, kodeBayar}))`.

---

## Status Temuan v1 (Untuk Referensi)

Semua temuan dari audit v1 telah ditangani:

| # | Severity | Masalah | Status |
|---|----------|---------|--------|
| 1 | 🔴 | Duplikasi logika dispatch di `webview_finpay.dart` | ✅ Ditangani — marked LEGACY |
| 2 | 🔴 | `unregisterPaymentListenerImpl` semicolon fragile | ✅ Fixed |
| 3 | 🟡 | `doVerifyPayment` tanpa reentrancy guard | ✅ Fixed |
| 4 | 🟡 | `handlePaymentCompletedFromHost` tidak stop timer | ✅ Fixed |
| 5 | 🟡 | Listener tidak baca `event.detail` dari `CustomEvent` | ✅ Fixed |
| 6 | 🟡 | `showFinpayRedirectScreen` tidak di-reset saat timer verify | ✅ Fixed |
| 7 | 🔵 | Duplikasi bridge inject antara PKB dan host app | ✅ Ditangani |
| 8 | 🔵 | Duplikasi `pocapp://` handling | ✅ Ditangani |
| 9 | 🔵 | `late Timer` tanpa null-safety bisa crash | ✅ Fixed |

---

## Kontrak Yang Berlaku (v2 — Production)

```
HOST APP menjamin:
  ✅ Console message handler: parse finpay_navigation JSON → buka Custom Tab
  ✅ API polling: check-dummy-payment-status setiap 3 detik
  ✅ Auto-close Custom Tab saat isPaid=true + dispatch paymentCompleted
  ✅ Dialog konfirmasi saat user tutup Custom Tab:
     - "Lanjutkan Bayar" → reopen Custom Tab + restart polling
     - "Batalkan Transaksi" → dispatch paymentHold
  ✅ Bridge SapawargaChannel di-inject AT_DOCUMENT_START (fallback)
  ✅ Deep link pocapp:// → _notifyPaymentCompleted() + close browser
  ✅ CC/VA result URL → _notifyPaymentCompleted()
  ✅ Double-fire guard: max 1 dispatch per 3 detik
  ✅ Host HANYA mengirim maks 1 event: paymentCompleted ATAU paymentHold
  ✅ DIHAPUS: timer bypass, simulasi, PaymentInfoChannel, _forceDummyPayment

PKB menjamin:
  ✅ Kirim finpay_navigation via console.log(JSON.stringify({...}))
  ✅ Listen event paymentCompleted via registerPaymentListener() di initState
  ✅ Listen event paymentHold → hit API pembatalan payment
  ✅ handlePaymentCompletedFromHost() → stopTimer() → doVerifyPayment()
  ✅ doVerifyPayment() reentrancy-safe (if isChecking return)
  ✅ finally { isChecking=false; update(); } — selalu reset, tidak pernah stuck
  ✅ isPaymentSuccess=true → showFinpayRedirectScreen=false → stopTimer()
  ✅ unregisterPaymentListener() di dispose()
  ✅ Timer? nullable-safe, tidak crash di edge case
  ✅ Listener log event.detail.ts untuk debugging
  ✅ webview_finpay.dart hanya aktif di standalone mode
```

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
