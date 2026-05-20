# Dokumen Spesifikasi Teknis: Integrasi Modul Pembayaran Web via WebView

## 1. Pendahuluan

Dokumen ini menyajikan spesifikasi teknis dan panduan integrasi antara Aplikasi Web (berbasis Flutter Web) dengan Aplikasi Host (Hosted App). Panduan ini ditujukan bagi tim pengembang Aplikasi Host dari instansi terkait untuk memastikan interoperabilitas sistem, pengalaman pengguna yang mulus (_seamless_), dan keandalan proses verifikasi transaksi pembayaran Finpay.

## 2. Ruang Lingkup Integrasi

Ruang lingkup integrasi ini mencakup:

- Mekanisme komunikasi searah (pengiriman pesan) dari Aplikasi Web ke Aplikasi Host.
- Ekstraksi parameter transaksi (URL pembayaran dan Kode Bayar) oleh Aplikasi Host.
- Pembukaan antarmuka pembayaran pada _Custom Tab_ atau _In-App Browser_.
- Pengecekan status transaksi pembayaran secara mandiri (_polling_) oleh Aplikasi Host.
- Terminasi sesi pembayaran secara otomatis dan pengembalian fokus pengguna ke Aplikasi Web.

---

## 3. Alur Kerja (Workflow) Integrasi Sistem

Proses integrasi ini dirancang agar Aplikasi Host dapat mengambil alih proses _checkout_ dan memverifikasinya di latar belakang, tanpa mengganggu _state_ dari Aplikasi Web. Berikut adalah urutan alur kerjanya:

1.**Inisiasi Pembayaran:** Pengguna memicu proses pembayaran melalui antarmuka Aplikasi Web yang sedang dimuat di dalam komponen WebView Aplikasi Host.

2.**Transmisi Data:** Aplikasi Web mentransmisikan pesan berformat JSON yang memuat parameter `url` (tautan Finpay) dan `kodeBayar` melalui metode keluaran konsol (_console log_).

3.**Intersepsi Data:** Aplikasi Host secara aktif mengintersepsi pesan konsol tersebut, kemudian memvalidasi dan mengekstraksi URL beserta Kode Bayar.

4.**Pembukaan Sesi Pembayaran:** Aplikasi Host membuka tautan URL yang diterima menggunakan antarmuka _Custom Tab_ (misalnya: Chrome Custom Tabs untuk Android atau SFSafariViewController untuk iOS) di atas antarmuka WebView.

5.**Verifikasi Latar Belakang (API Polling):** Selama _Custom Tab_ aktif di layar, Aplikasi Host wajib menjalankan proses di latar belakang (_background task_) untuk melakukan pengecekan status pembayaran secara periodik (_polling_) ke Endpoint API Backend menggunakan parameter Kode Bayar.

6.**Penanganan Sukses (Auto-close):** Apabila sistem mendapatkan respon bahwa pembayaran telah **berhasil**, Aplikasi Host secara terprogram akan menutup _Custom Tab_, sehingga tampilan secara otomatis kembali ke Aplikasi Web yang ada di WebView.

---

## 4. Spesifikasi Implementasi Teknis

### 4.1. Pengiriman Data dari Aplikasi Web

Aplikasi Web akan menembakkan sebuah _event_ log menggunakan metode standar JavaScript. Dalam lingkungan Flutter Web, perintah yang dieksekusi adalah sebagai berikut:

```javascript
// Contoh representasi di dalam eksekusi aplikasi web

console.log(
  '{"type":"finpay_navigation","url":"https://url-pembayaran-finpay.com/...","kodeBayar":"1234567890"}',
);
```

**Struktur _Payload_ (JSON):**

```json
{
  "type": "finpay_navigation",

  "url": "https://...",

  "kodeBayar": "1234567890"
}
```

**Keterangan Atribut:**

-`type` (String): _Identifier_ wajib dengan nilai mutlak `"finpay_navigation"`. Parameter ini digunakan oleh Aplikasi Host untuk membedakan _event_ navigasi pembayaran dari log sistem lainnya.

-`url` (String): Tautan halaman tagihan Finpay yang harus dimuat dan ditampilkan kepada pengguna.

-`kodeBayar` (String): Nomor referensi unik transaksi. Parameter ini wajib disimpan oleh Aplikasi Host sebagai kunci (_key_) untuk mengecek status pembayaran ke API.

### 4.2. Penerimaan Data oleh Aplikasi Host

Aplikasi Host wajib mengonfigurasi komponen WebView-nya untuk mendengarkan (_listen_) aktivitas log konsol dari Aplikasi Web. Ketika log masuk, Aplikasi Host perlu melakukan langkah berikut:

1. Tangkap _event_ konsol (misalnya melalui `onConsoleMessage` pada _controller_ WebView).
2. Lakukan _parsing_ (_Try-Catch_) nilai string dari konsol ke dalam bentuk objek JSON.
3. Lakukan pengondisian: Apabila _key_ `type` bernilai `"finpay_navigation"`, maka lanjutkan ke tahap ekstraksi parameter `url` dan `kodeBayar`.

### 4.3. Penanganan Tautan Pembayaran (Custom Tab)

Setelah `url` divalidasi, Aplikasi Host dilarang memuat tautan tersebut di dalam WebView yang sama untuk menghindari teresetnya sesi (_state_) Aplikasi Web.

Aplikasi Host **diwajibkan** untuk meluncurkan komponen browser _native_ yang terintegrasi di dalam aplikasi (seperti _Chrome Custom Tabs_ atau mode _in-app browser_ bawaan sistem operasi). Antarmuka ini akan muncul sebagai _overlay_ menutupi WebView.

### 4.4. Pengecekan Status Pembayaran (API Polling)

Langkah kritikal dalam integrasi ini adalah verifikasi transaksi. Segera setelah _Custom Tab_ dimuat, Aplikasi Host harus menginisiasi proses pengecekan status (_API Polling_).

**Spesifikasi Proses Polling:**

-**Trigger Awal:** Dimulai bersamaan atau beberapa saat setelah perintah buka _Custom Tab_ dieksekusi.

-**Interval:** Proses penembakan API dilakukan secara periodik, misalnya setiap 3 hingga 5 detik (bergantung pada spesifikasi _rate-limit_ server backend instansi).

-**Parameter Request:** Menggunakan `kodeBayar` yang telah di-ekstrak pada langkah 4.2.

-**Terminasi Polling (Pemberhentian Siklus):** Proses ini wajib dihentikan (_cancel/dispose_) apabila terjadi salah satu kondisi berikut:

1. API mengembalikan status pembayaran **SUKSES**.
2. Pengguna membatalkan pembayaran dengan menekan tombol kembali/silang (_close_) pada _Custom Tab_ secara manual.
3. Mencapai batas waktu maksimal transaksi (_Timeout_) yang ditentukan oleh sistem (misalnya: 15 menit).

### 4.5. Terminasi Sesi Pembayaran (_Callback_ Keberhasilan)

Sistem Aplikasi Host harus merespons secara otomatis (_programmatically_) ketika kondisi terminasi nomor 1 (Pembayaran Sukses) pada poin 4.4 terpenuhi.

Aplikasi Host **wajib memerintahkan penutupan layar Custom Tab secara terprogram** (_dismiss/close programmatic_). Saat layar tertutup, pengguna akan melihat kembali antarmuka Aplikasi Web secara utuh. Aplikasi Web selanjutnya memiliki tanggung jawab penuh untuk mendeteksi perubahan state dan menyajikan halaman resi/sukses kepada pengguna.
