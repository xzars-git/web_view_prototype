# Audit & Kontrak: PKB Web App ↔ Host App — Pembayaran Finpay

> **Versi:** v5 (2026-05-20) — Stack WebView Strategy
> **Status:** Semua temuan v1-v2 telah ditangani. Arsitektur v5 aktif.

---

## Riwayat Perubahan Arsitektur

| Versi | Arsitektur | Status |
|-------|-----------|--------|
| v1 | Custom Tab + manual bypass | ❌ Deprecated |
| v2 | Custom Tab + API polling + dialog | ❌ Deprecated |
| v3 | Single WebView replace URL | ❌ Deprecated (state hilang) |
| **v5** | **Stack Navigator (PaymentWebViewPage)** | **✅ Aktif** |

### Kenapa v5?
- Custom Tab → app background → OS throttle network → polling gagal
- Replace URL → state Sambara hilang (kembali ke beranda)
- Stack Navigator → kedua WebView hidup, app tetap foreground ✅

---

## Kontrak Yang Berlaku (v5 — Production)

```
HOST APP menjamin:
  ✅ Console message handler: parse finpay_navigation JSON
  ✅ Navigator.push(PaymentWebViewPage) — Sambara tetap hidup di bawah
  ✅ PaymentWebViewPage: ALLOW semua HTTP/HTTPS, non-http → launchUrl external
  ✅ Dio polling: check-dummy-payment-status setiap 5 detik (max 15 menit)
  ✅ isPaid (code:"0000") → Navigator.pop() + dispatch paymentCompleted
  ✅ User Back → Navigator.pop() + dispatch paymentHold
  ✅ Bridge SapawargaChannel inject AT_DOCUMENT_START (fallback)
  ✅ Deep link pocapp:// → Navigator.pop() + cleanup
  ✅ dispose(): stop polling + close Dio + cancel deep link

  TIDAK ADA LAGI:
  ❌ ChromeSafariBrowser / Custom Tab
  ❌ Dialog konfirmasi host-side (Sambara yang handle)
  ❌ Timer bypass, simulasi, PaymentInfoChannel, _forceDummyPayment
  ❌ Double-fire guard (tidak perlu — stack pop hanya 1x)

PKB menjamin:
  ✅ Kirim finpay_navigation via console.log(JSON.stringify({type, url, kodeBayar}))
  ✅ Listen event paymentCompleted → doVerifyPayment()
  ✅ Listen event paymentHold → tampilkan dialog konfirmasi pembatalan
  ✅ doVerifyPayment() reentrancy-safe (if isChecking return)
  ✅ finally { isChecking=false; update(); }
  ✅ isPaymentSuccess=true → stopTimer()
  ✅ unregisterPaymentListener() di dispose()
  ✅ Timer? nullable-safe
```

---

## Ringkasan Kebutuhan (Tim Host App → Tim PKB)

### Yang Dijamin Host App (v5)

1. **Console message handler** — `onConsoleMessage` parse JSON `finpay_navigation` untuk dapatkan URL + kodeBayar.
2. **Stack Navigator** — `Navigator.push(PaymentWebViewPage)` membuka halaman payment di atas Sambara. State Sambara 100% preserved.
3. **Dio polling** — `POST /api/check-dummy-payment-status` setiap 5 detik (max 15 menit). Jika `code:"0000"`, auto-pop + dispatch `paymentCompleted`.
4. **User Back handling** — Saat user tekan Back di payment page, pop + dispatch `paymentHold` ke Sambara.
5. **Bridge `SapawargaChannel`** — tetap di-inject sebagai fallback.
6. **Host app HANYA mengirim 1 event** per transaksi: `paymentCompleted` ATAU `paymentHold`.

### Yang Diharapkan dari PKB

1. PKB **listen event `paymentCompleted`** dan langsung panggil `doVerifyPayment()`.
2. PKB **listen event `paymentHold`** dan tampilkan dialog konfirmasi pembatalan.
3. Setelah `doVerifyPayment()` sukses, PKB **navigasi sendiri** ke halaman sukses.
4. PKB mengirim data via `console.log(JSON.stringify({type:"finpay_navigation", url, kodeBayar}))`.

---

## Status Temuan v1 (Referensi Historis)

| # | Severity | Masalah | Status |
|---|----------|---------|--------|
| 1 | 🔴 | Duplikasi logika dispatch | ✅ Ditangani |
| 2 | 🔴 | `unregisterPaymentListenerImpl` fragile | ✅ Fixed |
| 3 | 🟡 | `doVerifyPayment` tanpa reentrancy guard | ✅ Fixed |
| 4 | 🟡 | `handlePaymentCompletedFromHost` tidak stop timer | ✅ Fixed |
| 5 | 🟡 | Listener tidak baca `event.detail` | ✅ Fixed |
| 6 | 🟡 | `showFinpayRedirectScreen` tidak di-reset | ✅ Fixed |
| 7 | 🔵 | Duplikasi bridge inject | ✅ Ditangani |
| 8 | 🔵 | Duplikasi `pocapp://` handling | ✅ Ditangani |
| 9 | 🔵 | `late Timer` tanpa null-safety | ✅ Fixed |

---

## 🗑️ PROMPT: Aktifkan Production Mode

```
Aktifkan API sungguhan untuk payment verification.
Jangan ubah alur kode yang lain.

File target:
  packages/core/lib/service/api_service_pkb.dart

Yang harus dilakukan:

1. Di method paymentVerification(), hapus blok DEMO MODE:
     await Future.delayed(const Duration(milliseconds: 600));
     final bool isSuccess = Random().nextBool();
     return { ... status_payment: isSuccess ... };

2. Hapus komentar "// ignore: dead_code" di atas blok try.

3. Hapus import 'dart:math'; jika tidak dipakai di tempat lain.

4. Hapus import 'package:flutter/foundation.dart'; jika tidak dipakai di tempat lain.

Hasil akhir: method paymentVerification() langsung memanggil API
  client.apiCall(url: Endpoints.paymentVerification, ...).

Syarat: jangan ubah method lain, jangan ubah file lain.
```
