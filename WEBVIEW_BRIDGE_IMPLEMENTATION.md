# Dokumentasi Integrasi WebView Bridge & Selective Navigation (v2)

Dokumen ini menjelaskan implementasi sinkronisasi alur pembayaran antara aplikasi Mobile (Flutter) dan Front-End (Web). Logika navigasi sekarang sepenuhnya dikendalikan oleh sisi Web (**Selective Navigation**).

## 1. Strategi Navigasi (Web-Side Logic)
Aplikasi mobile bertindak sebagai eksekutor pasif. Keputusan navigasi dilakukan oleh FE:
- **Metode E-Wallet (DANA, ShopeePay, LinkAja):** 
  FE mengirim link ke Bridge -> Mobile membuka **Custom Tab** (Browser Luar). Ini wajib agar *App Switching* ke aplikasi native e-wallet berjalan lancar.
- **Metode Non E-Wallet (VA, Kartu Kredit):** 
  FE melakukan navigasi internal (`window.location`) -> Mobile tetap diam, navigasi berjalan di **WebView Utama**.

## 2. Arsitektur Komunikasi Bridge

### Mobile Side (Flutter)
Meyediakan handler bernama `SapawargaChannel`. Flutter secara otomatis menyuntikkan script berikut agar FE bisa memanggil bridge dengan mudah:
```javascript
window.SapawargaChannel.postMessage(url);
```

### Protocol Bridge
Bridge mendukung dua format pesan untuk fleksibilitas:
1.  **String URL (Standar Baru):** Cukup kirim URL mentah. Flutter akan otomatis membukanya di **Custom Tab**.
    ```javascript
    window.SapawargaChannel.postMessage("https://link-pembayaran-ewallet.com");
    ```
2.  **JSON Object (Advanced):** Jika ingin mengontrol target navigasi secara spesifik.
    ```json
    {
      "url": "https://link-internal.com",
      "target": "webview" 
    }
    ```

## 3. Deep Link & Closing Tab
Aplikasi mobile mendengarkan scheme khusus untuk menutup Custom Tab:
- **URL Return:** `pocapp://payment/return`
- **Alur:** 
    1. User menyelesaikan pembayaran di Custom Tab.
    2. Gateway mengarahkan ke `pocapp://payment/return`.
    3. Mobile menangkap link tersebut -> Menutup Custom Tab secara otomatis.
    4. Mobile mengirimkan event `paymentCompleted` ke WebView utama.

## 4. Cara Menggunakan di Sisi Web (FE)

### Menangkap Sinyal Kembali dari Pembayaran
Gunakan Event Listener untuk me-refresh data transaksi setelah user kembali dari Custom Tab:
```javascript
window.addEventListener('paymentCompleted', function() {
    console.log("Sinyal kembali diterima. Refreshing data...");
    // Panggil fungsi refresh status transaksi Anda
});
```

## 5. File Terkait
- `webview_finpay.dart`: Handler bridge, injeksi script, dan deep link interception.
- `finpay_navigation_web.dart`: Logika pemilihan (E-Wallet via Bridge, VA via Web).
- `AndroidManifest.xml`: Registrasi scheme `pocapp://`.

---
*Dokumentasi ini disinkronkan dengan pembaruan Selective Navigation v2.*
