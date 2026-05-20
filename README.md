# Spesifikasi Teknis Integrasi: Sambara Web × Aplikasi Sapawarga

## Pendahuluan

Dokumen ini menyajikan spesifikasi teknis dan panduan integrasi antara Sambara Web dengan Aplikasi Sapawarga. Panduan ini ditujukan bagi tim pengembang Aplikasi Sapawarga untuk memastikan interoperabilitas sistem, pengalaman pengguna yang mulus (_seamless_), dan keandalan proses pembayaran Finpay.

---

## Spesifikasi Tech Stack

### Persyaratan Sistem Operasi

| Platform | Versi Minimum | Catatan                        |
| -------- | ------------- | ------------------------------ |
| Android  | API 21+       | Target API: 35+                |
| iOS      | 12.0+         | Minimum Deployment Target: 12+ |
| Windows  | 10+           | Build Tools sesuai dokumentasi |
| macOS    | 10.13+        | Untuk development iOS & macOS  |
| Linux    | Ubuntu 20.04+ | Untuk development              |

### Persyaratan Development

| Komponen        | Versi Minimum | Catatan                        |
| --------------- | ------------- | ------------------------------ |
| **Flutter SDK** | 3.9.2+        | Gunakan `flutter --version`    |
| **Dart SDK**    | 3.5.0+        | Disertakan dengan Flutter SDK  |
| **Java / JDK**  | 11+           | Untuk build Android            |
| **Android SDK** | API 35        | Target SDK untuk build optimal |
| **Xcode**       | 14.0+         | Untuk build iOS (macOS only)   |
| **CocoaPods**   | 1.11+         | Dependency manager iOS         |

### Dependencies Utama

| Package                | Versi   | Fungsi                                |
| ---------------------- | ------- | ------------------------------------- |
| `flutter`              | ^3.9.2  | Framework utama aplikasi              |
| `flutter_inappwebview` | ^6.1.5  | WebView untuk menampilkan Sambara Web |
| `geolocator`           | ^13.0.2 | Akses lokasi pengguna                 |
| `permission_handler`   | ^11.3.1 | Manajemen perizinan sistem            |
| `url_launcher`         | ^6.3.1  | Membuka URL eksternal                 |
| `app_links`            | ^6.3.2  | Handling deep links & App Links       |

### Dev Dependencies

| Package         | Versi  | Fungsi            |
| --------------- | ------ | ----------------- |
| `flutter_test`  | SDK    | Testing framework |
| `flutter_lints` | ^5.0.0 | Code quality      |
| `mocktail`      | ^1.0.4 | Mocking untuk tes |

### Tools Opsional

- **Android Studio** atau **VS Code**: IDE untuk development
- **GitHub Desktop** / **Git CLI**: Version control
- **Postman** / **Insomnia**: Testing API (jika diperlukan)

---

## Ruang Lingkup Integrasi

Ruang lingkup integrasi ini mencakup:

- Mekanisme komunikasi searah (pengiriman pesan) dari Sambara Web ke Aplikasi Sapawarga melalui _console log_.
- Intersepsi dan ekstraksi URL pembayaran dari _event_ `webview_navigation` oleh Aplikasi Sapawarga.
- Pembukaan antarmuka pembayaran pada halaman _Payment WebView_ yang tumpuk (_stack_) di atas Sambara Web berdasarkan _event_ `webview_navigation`.
- Penutupan halaman _Payment WebView_ secara terprogram berdasarkan _event_ `close_webview` dari Sambara Web.
- Pengembalian fokus pengguna ke Sambara Web secara otomatis.

---

## Alur Kerja (_Workflow_) Integrasi Sistem

Proses integrasi ini dirancang agar Aplikasi Sapawarga dapat mengambil alih tampilan pembayaran tanpa merusak sesi (_state_) Sambara Web. Berikut adalah urutan alur kerjanya:

### 1. Inisiasi Pembayaran

Pengguna memicu proses pembayaran melalui antarmuka Sambara Web yang sedang dimuat di dalam komponen _WebView_ Aplikasi Sapawarga.

### 2. Transmisi Data

Sambara Web mentransmisikan pesan berformat JSON yang memuat parameter `url` (tautan pembayaran Finpay) melalui metode `console.log` standar JavaScript.

### 3. Intersepsi Data

Aplikasi Sapawarga secara aktif mengintersepsi pesan konsol tersebut, kemudian memvalidasi dan mengekstraksi URL pembayaran.

### 4. Pembukaan Halaman Pembayaran

Aplikasi Sapawarga membuka URL yang diterima menggunakan `PaymentWebViewPage` — halaman _WebView_ terpisah yang di-_push_ ke atas _stack_ navigasi. Sambara Web tetap hidup di latar belakang, sehingga _state_-nya tidak hilang.

### 5. Penanganan Penutupan (Event `close_webview`)

Saat proses pembayaran selesai (baik sukses maupun dibatalkan oleh sistem), Sambara Web mengirimkan _event_ `close_webview` melalui `console.log`. Aplikasi Sapawarga merespons dengan menutup `PaymentWebViewPage` secara terprogram, sehingga tampilan otomatis kembali ke Sambara Web.

### 6. Notifikasi ke Sambara Web (`paymentHold`)

Setelah `PaymentWebViewPage` tertutup — baik karena `close_webview` maupun karena pengguna menekan tombol kembali secara manual — Aplikasi Sapawarga mengirimkan _event_ `paymentHold` ke Sambara Web. Sambara Web bertanggung jawab penuh untuk mendeteksi _event_ ini dan menyajikan halaman resi/sukses kepada pengguna.

---

## Spesifikasi Implementasi Teknis

### Pengiriman Data dari Sambara Web

Sambara Web akan menembakkan _event log_ menggunakan metode standar JavaScript `console.log`. Perintah yang dieksekusi adalah sebagai berikut:

```javascript
console.log(
  JSON.stringify({
    url: "https://m.dana.id/n/cashier/...",
  }),
);
```

#### Struktur Payload — `webview_navigation`

```json
{
  "url": "https://m.dana.id/n/cashier/new/checkout?bizNo=..."
}
```

**Keterangan Atribut:**

| Atribut | Tipe   | Keterangan                                                                       |
| ------- | ------ | -------------------------------------------------------------------------------- |
| `url`   | String | Tautan halaman tagihan Finpay yang harus dimuat dan ditampilkan kepada pengguna. |

> **Catatan:** Payload `webview_navigation` **hanya berisi `url`**. Tidak ada field `type` maupun `kodeBayar` di dalam body JSON. Aplikasi Sapawarga mengidentifikasi _event_ ini dari konteks konsol yang telah dikonfigurasi sebelumnya.

---

### Penutupan Halaman Pembayaran dari Sambara Web

Ketika Sambara Web mendeteksi bahwa sesi pembayaran harus diakhiri (baik karena sukses maupun dibatalkan oleh sistem), Sambara Web akan mengirimkan _event_ berikut:

```javascript
console.log(
  JSON.stringify({
    type: "close_webview",
    reason: "payment_success", // opsional
  }),
);
```

#### Struktur Payload — `close_webview`

```json
{
  "type": "close_webview",
  "reason": "payment_success"
}
```

**Keterangan Atribut:**

| Atribut  | Tipe   | Keterangan                                                                   |
| -------- | ------ | ---------------------------------------------------------------------------- |
| `type`   | String | Identifier wajib dengan nilai mutlak `"close_webview"`.                      |
| `reason` | String | Opsional. Informasi tambahan penyebab penutupan. Contoh:`"payment_success"`. |

---

### Penerimaan Data oleh Aplikasi Sapawarga

Aplikasi Sapawarga wajib mengonfigurasi komponen _WebView_-nya untuk mendengarkan (_listen_) aktivitas log konsol dari Sambara Web. Ketika log masuk, Aplikasi Sapawarga perlu melakukan langkah berikut:

1. Tangkap _event_ konsol melalui `onConsoleMessage` pada _controller WebView_.
2. Lakukan _parsing_ (Try-Catch) nilai string dari konsol ke dalam bentuk objek JSON.
3. Lakukan pengondisian berdasarkan nilai `type`:
   - Jika `type == "webview_navigation"` → ekstrak `url` dan buka `PaymentWebViewPage`.
   - Jika `type == "close_webview"` → tutup `PaymentWebViewPage` yang sedang aktif secara terprogram.

**Contoh logika pseudocode:**

```
onConsoleMessage(message):
  try:
    json = JSON.parse(message)

    if json.type == "webview_navigation":
      url = json.url
      if url is not empty:
        push PaymentWebViewPage(url)

    if json.type == "close_webview":
      pop current page (PaymentWebViewPage)
  catch:
    // abaikan pesan non-JSON
```

---

### Penanganan Halaman Pembayaran (`PaymentWebViewPage`)

Setelah `url` dari `webview_navigation` divalidasi, Aplikasi Sapawarga **dilarang** memuat tautan tersebut di dalam _WebView_ utama Sambara Web. Hal ini untuk menghindari ter-_reset_-nya sesi (_state_) Sambara Web.

Aplikasi Sapawarga **diwajibkan** untuk membuka `PaymentWebViewPage` — sebuah halaman Flutter terpisah yang memuat _WebView_ baru — menggunakan `Navigator.push`. Halaman ini akan muncul sebagai _overlay_ menutupi Sambara Web.

**Keuntungan strategi ini:**

- Sambara Web tetap hidup di latar belakang (_background_) tanpa kehilangan _state_.
- Saat `PaymentWebViewPage` di-_pop_, Sambara Web langsung kembali terlihat dalam kondisi terakhirnya.
- Tidak ada reloading halaman Sambara Web.

---

### Notifikasi `paymentHold` ke Sambara Web

Setelah `PaymentWebViewPage` tertutup — melalui kondisi apapun — Aplikasi Sapawarga wajib mengirimkan _Custom Event_ `paymentHold` ke Sambara Web menggunakan `evaluateJavascript`.

**Event yang di-_dispatch_:**

```javascript
window.dispatchEvent(
  new CustomEvent("paymentHold", {
    detail: { ts: Date.now() },
  }),
);
```

Sambara Web memiliki tanggung jawab penuh untuk mendengarkan _event_ `paymentHold` dan menyajikan tampilan yang sesuai (halaman resi, notifikasi sukses, atau pengecekan status mandiri).

---

## Diagram Alur Integrasi

```
Pengguna                Sambara Web             Sapawarga App           PaymentWebViewPage
   │                       │                         │                          │
   │── Klik Bayar ─────────▶│                         │                          │
   │                       │── console.log ──────────▶│                          │
   │                       │   {type:"webview_nav",   │                          │
   │                       │    url: "..."}           │                          │
   │                       │                         │── Navigator.push ────────▶│
   │                       │                         │                          │
   │                       │                         │     [User menyelesaikan / │
   │                       │                         │      membatalkan pembayaran]
   │                       │                         │                          │
   │                       │── console.log ──────────▶│                          │
   │                       │   {type:"close_webview"}│                          │
   │                       │                         │── Navigator.pop ──────────│
   │                       │                         │                          │
   │                       │◀── evaluateJavascript ──│                          │
   │                       │    dispatchEvent('paymentHold')                    │
   │                       │                         │                          │
   │◀── Tampilkan Resi ────│                         │                          │
```

---

## Ringkasan Perubahan dari Versi Sebelumnya

| Aspek                                | Versi Lama                     | Versi Saat Ini                                     |
| ------------------------------------ | ------------------------------ | -------------------------------------------------- |
| Mekanisme pembukaan pembayaran       | Custom Tab / Browser Native    | `PaymentWebViewPage` (Flutter Navigator Stack)     |
| Nama*event* buka pembayaran          | `finpay_navigation`            | `webview_navigation`                               |
| Payload*event* buka pembayaran       | `type`, `url`, `kodeBayar`     | `url` saja                                         |
| Verifikasi status pembayaran         | API Polling oleh Sapawarga     | Tidak ada (tanggung jawab Sambara Web)             |
| Nama*event* tutup halaman            | `close_tab`                    | `close_webview`                                    |
| Trigger penutupan halaman pembayaran | API Polling sukses / deep link | _Console message_ `close_webview` dari Sambara Web |
| _Event_ ke Sambara setelah tutup     | `paymentCompleted`             | `paymentHold`                                      |
