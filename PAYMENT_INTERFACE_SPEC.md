# Payment Interface Specification: Web-to-App Bridge

Dokumen ini mendefinisikan protokol komunikasi antara aplikasi Web (Front-End) dan aplikasi Induk (Flutter) untuk menangani alur pembayaran secara mulus.

---

## 1. Mekanisme Komunikasi (Bridge)

Aplikasi Induk menyediakan bridge bernama `SapawargaChannel`. Setiap pesan yang dikirim melalui bridge ini akan dianggap sebagai instruksi untuk membuka **Custom Tab** (Browser In-App).

### Metode Pemanggilan (Web Side)
```javascript
// Mengirimkan string URL langsung
window.SapawargaChannel.postMessage("https://m.dana.id/checkout/...");
```

---

## 2. Aturan Navigasi Berdasarkan Metode Pembayaran

| Metode Pembayaran | Target Navigasi | Aksi Front-End |
| :--- | :--- | :--- |
| **DANA** | Custom Tab | Kirim URL via `SapawargaChannel.postMessage(url)` |
| **ShopeePay** | Custom Tab | Kirim URL via `SapawargaChannel.postMessage(url)` |
| **LinkAja** | Custom Tab | Kirim URL via `SapawargaChannel.postMessage(url)` |
| **Virtual Account (VA)** | Internal WebView | Navigasi normal atau Tampilkan Widget WebView di Web |
| **Kartu Kredit (CC)** | Internal WebView | Navigasi normal atau Tampilkan Widget WebView di Web |

---

## 3. Integrasi Callback (Deep Link)

Untuk semua jenis pembayaran, parameter `return_url` atau `callback_url` yang dikirim ke Payment Gateway **WAJIB** menggunakan skema berikut:

**Return URL:** `pocapp://payment/return`

### Perilaku Aplikasi Induk saat menerima Deep Link:
1.  **Cleanup:** Menutup otomatis jendela Custom Tab (jika sedang terbuka).
2.  **Signal:** Mengirimkan event JavaScript ke WebView Utama:
    ```javascript
    window.dispatchEvent(new Event('paymentCompleted'));
    ```

---

## 4. Implementasi Referensi (Dart Web)

```dart
void handlePayment(String url, String method) {
  bool needsCustomTab = ['DANA', 'SHOPEEPAY', 'LINKAJA'].contains(method.toUpperCase());

  if (needsCustomTab && js.context.hasProperty('SapawargaChannel')) {
    // Membuka Custom Tab di Aplikasi Induk
    js.context['SapawargaChannel'].callMethod('postMessage', [url]);
  } else {
    // Navigasi internal di dalam WebView Utama
    html.window.location.href = url;
  }
}
```

---
*Dibuat: 24 April 2026*
*Status: Final - Selective Bridging Logic*
