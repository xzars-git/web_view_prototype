import 'package:flutter/material.dart';

import 'app.dart';
import 'config/app_config.dart';

/// Titik masuk utama (Entry Point) aplikasi Flutter.
/// 
/// Fungsi ini menginisialisasi konfigurasi aplikasi dan menjalankan
/// root widget [App] dengan injeksi dependensi konfigurasi.
void main() {
  // Membuat instance konfigurasi default yang membaca environment variables.
  const config = DefaultAppConfig();
  
  // Menjalankan aplikasi.
  runApp(const App(config: config));
}
