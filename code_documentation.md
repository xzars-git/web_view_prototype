# Dokumentasi Teknis - Web View Prototype (Hybrid)

Proyek ini adalah prototipe aplikasi Flutter yang mengintegrasikan WebView secara mendalam dengan fitur native Android/iOS. Fokus utamanya adalah menangani flow pembayaran yang kompleks, perizinan hardware, dan komunikasi bridge yang aman.

> **Versi:** 2026-05-20 (Refactored — Console-based handler + API polling)

---

## 🏗 Arsitektur Proyek

Aplikasi mengikuti pola **Feature-First Architecture** sederhana:

- `lib/config/`: Konfigurasi global, logging, dan env variables.
- `lib/features/hybrid_webview/`: Fitur inti yang terdiri dari:
  - `application/`: Controller (logika bisnis & koordinasi).
  - `domain/`: Logika validasi dan guard navigasi.
  - `presentation/`: UI Widget dan WebView.

---

## 🚀 Flow Utama & Fitur Unggulan

### 1. Console Message Handler (Primary — finpay_navigation)

Aplikasi mendeteksi instruksi pembayaran dari PKB melalui **`console.log`** (bukan `postMessage`).

- **Trigger:** PKB Web App memanggil `console.log(JSON.stringify({...}))`.
- **Format JSON:**
  ```json
  {
      "type": "finpay_navigation",
      "url": "https://m.dana.id/n/cashier/new/checkout?...",
      "kodeBayar": "3222002005265231"
  }
  ```
- **Action:** Host app mendeteksi JSON ini via `onConsoleMessage`, lalu:
  1. Buka URL di **Custom Tab** (Chrome Custom Tabs / SFSafariViewController).
  2. Mulai **polling API** `check-dummy-payment-status` setiap 3 detik.
  3. Jika status `true` → tutup Custom Tab otomatis + dispatch `paymentCompleted`.

### 2. JavaScript Bridge (SapawargaChannel — Fallback)

Bridge `SapawargaChannel` tetap tersedia sebagai **fallback** jika PKB belum update ke console.log.

- **Trigger:** Web memanggil `window.SapawargaChannel.postMessage(url)`.
- **Action:** App mendeteksi URL dan membuka di Custom Tab.
- **Keterbatasan:** Hanya menerima URL, tanpa `kodeBayar`. Polling status tidak tersedia via jalur ini.

### 3. Smart Navigation Guard (Anti-Stuck)

Menyelesaikan masalah klasik di mana user terjebak di halaman redirect pembayaran (VA/CC).

- **Teknik:** *Double-Buffer Host Tracking*.
- **Cara Kerja:** App selalu mencatat domain internal terakhir. Jika user masuk ke domain bank (External Host) dan menekan tombol Back, App akan mendeteksi perbedaan host dan langsung memuat ulang halaman internal terakhir, melompati halaman redirector yang menjebak.

### 4. Unified Startup Permissions

App meminta izin Kamera dan Lokasi di awal (startup).

- **Proses:** WebView tidak akan dimuat sampai status perizinan jelas (Granted/Denied).
- **Fallback:** Jika izin diberikan, WebView secara otomatis memberikan akses ke hardware saat diminta oleh JavaScript tanpa dialog tambahan yang mengganggu.

### 5. Centralized Debug Tracker

Panel log visual yang bisa muncul di layar HP.

- **Teknis:** Menggunakan `ValueNotifier` statis di `AppLogger`.
- **Kelebihan:** Log dari konsol JavaScript, Deep Link, dan sistem Native muncul di satu tempat yang sama. Tetap berfungsi di mode Release untuk mempermudah debugging lapangan.

### 6. Payment Hold & Cancellation Dialog

Saat user menutup Custom Tab pembayaran secara manual:

- **Action:** Muncul dialog **Konfirmasi Pembatalan Transaksi** dengan info kode bayar.
- **Opsi 1:** "Lanjutkan Bayar" → Reopen Custom Tab dengan URL yang sama.
- **Opsi 2:** "Batalkan Transaksi" → Dispatch event `paymentHold` ke PKB.
- **Tanggung Jawab PKB:** Mendengarkan event `paymentHold` dan menghit API pembatalan dari sisi web.

---

## 🛠 Hal-Hal Penting untuk Developer (Clone)

### Cara Menjalankan

Pastikan menggunakan `--dart-define` jika ingin mengubah URL tujuan:

```bash
flutter run --dart-define=PROD_BASE_URL=https://alamat-web-kamu.com
```

### Konfigurasi Bridge

Semua detail teknis dikelola di `lib/config/app_config.dart`. Kamu bisa mengubah:

- `bridgeName`: Nama objek window di JavaScript (fallback).
- `deepLinkScheme`: Skema untuk kembali dari pembayaran (`pocapp://`).
- `paymentEventName`: Nama event yang dikirim balik ke Web (`paymentCompleted`).

### Keamanan

Daftar domain yang diizinkan untuk dibuka di dalam WebView utama diatur via `WEBVIEW_ALLOWED_HOSTS` di `app_config.dart`. Domain di luar ini akan otomatis diblokir atau dialihkan.

---

## 📝 Catatan Integrasi Tim Web (PKB)

Untuk berkomunikasi dengan Host App, gunakan kode berikut di sisi Web:

```javascript
// Mengirim URL pembayaran e-wallet + kodeBayar ke Host App (PRIMARY)
console.log(JSON.stringify({
    type: "finpay_navigation",
    url: "https://link-pembayaran-ewallet.com",
    kodeBayar: "3222002005265231"
}));

// Mendengarkan status pembayaran selesai (setelah Custom Tab ditutup & status API true)
window.addEventListener('paymentCompleted', function(event) {
    console.log("Pembayaran selesai, silakan refresh status!");
    console.log("Timestamp:", event.detail?.ts);
});

// Mendengarkan pembatalan transaksi (user tutup Custom Tab + konfirmasi batal)
window.addEventListener('paymentHold', function(event) {
    console.log("User membatalkan — kodeBayar:", event.detail?.kodeBayar);
    // Hit API pembatalan dari sisi PKB
});
```

---

## 📊 Referensi Cepat

| Item | Nilai |
|------|-------|
| Console message type | `finpay_navigation` |
| Bridge name (fallback) | `SapawargaChannel` |
| Event: pembayaran selesai | `paymentCompleted` |
| Event: pembayaran hold | `paymentHold` |
| Deep link scheme | `pocapp` |
| Deep link host | `payment` |
| Finpay domain (whitelist) | `live.finpay.id` |
| Result URL pattern | `/pg/payment/card/result/` |
| Payment status API | `POST /api/check-dummy-payment-status` |
| Polling interval | `3 detik` |
