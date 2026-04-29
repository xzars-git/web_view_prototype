# Dokumentasi Teknis - Web View Prototype (Hybrid)

Proyek ini adalah prototipe aplikasi Flutter yang mengintegrasikan WebView secara mendalam dengan fitur native Android/iOS. Fokus utamanya adalah menangani flow pembayaran yang kompleks, perizinan hardware, dan komunikasi bridge yang aman.

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

### 1. JavaScript Bridge (SapawargaChannel)

Aplikasi menyediakan objek `SapawargaChannel` ke sisi Web.

- **Trigger:** Web memanggil `window.SapawargaChannel.postMessage(url)`.
- **Action:** App mendeteksi instruksi ini dan **WAJIB** membukanya di **Custom Tab** (Chrome Custom Tabs di Android / SFSafariViewController di iOS).
- **Kegunaan:** Sangat direkomendasikan untuk flow DANA, ShopeePay, atau link eksternal yang butuh integrasi aplikasi lain.

### 2. Smart Navigation Guard (Anti-Stuck)

Menyelesaikan masalah klasik di mana user terjebak di halaman redirect pembayaran (VA/CC).

- **Teknik:** *Double-Buffer Host Tracking*.
- **Cara Kerja:** App selalu mencatat domain internal terakhir. Jika user masuk ke domain bank (External Host) dan menekan tombol Back, App akan mendeteksi perbedaan host dan langsung memuat ulang halaman internal terakhir, melompati halaman redirector yang menjebak.

### 3. Unified Startup Permissions

App meminta izin Kamera dan Lokasi di awal (startup).

- **Proses:** WebView tidak akan dimuat sampai status perizinan jelas (Granted/Denied).
- **Fallback:** Jika izin diberikan, WebView secara otomatis memberikan akses ke hardware saat diminta oleh JavaScript tanpa dialog tambahan yang mengganggu.

### 4. Centralized Debug Tracker

Panel log visual yang bisa muncul di layar HP.

- **Teknis:** Menggunakan `ValueNotifier` statis di `AppLogger`.
- **Kelebihan:** Log dari konsol JavaScript, Deep Link, dan sistem Native muncul di satu tempat yang sama. Tetap berfungsi di mode Release untuk mempermudah debugging lapangan.

---

## 🛠 Hal-Hal Penting untuk Developer (Clone)

### Cara Menjalankan

Pastikan menggunakan `--dart-define` jika ingin mengubah URL tujuan:

```bash
flutter run --dart-define=PROD_BASE_URL=https://alamat-web-kamu.com
```

### Konfigurasi Bridge

Semua detail teknis dikelola di `lib/config/app_config.dart`. Kamu bisa mengubah:

- `bridgeName`: Nama objek window di JavaScript.
- `deepLinkScheme`: Skema untuk kembali dari pembayaran (`pocapp://`).
- `paymentEventName`: Nama event yang dikirim balik ke Web (`paymentCompleted`).

### Keamanan

Daftar domain yang diizinkan untuk dibuka di dalam WebView utama diatur via `WEBVIEW_ALLOWED_HOSTS` di `app_config.dart`. Domain di luar ini akan otomatis diblokir atau dialihkan.

---

## 📝 Catatan Integrasi Tim Web

Untuk berkomunikasi dengan App, gunakan kode berikut di sisi Web:

```javascript
// Membuka Custom Tab (DANA/Shopee)
window.SapawargaChannel.postMessage("https://link-pembayaran.com");

// Mendengarkan status pembayaran selesai (setelah Custom Tab ditutup)
window.addEventListener('paymentCompleted', function() {
    console.log("Pembayaran selesai, silakan refresh status!");
});
```
