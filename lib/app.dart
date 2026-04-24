import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'features/hybrid_webview/presentation/hybrid_webview_page.dart';

/// Root Widget aplikasi.
/// 
/// Class ini bertanggung jawab untuk konfigurasi global seperti tema,
/// navigasi dasar, dan bertindak sebagai 'Composition Root' yang
/// menyuntikkan dependensi [AppConfig] ke fitur-fitur di bawahnya.
class App extends StatelessWidget {
  /// Membutuhkan [config] untuk pengaturan perilaku aplikasi.
  const App({super.key, required this.config});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Mematikan label debug di pojok kanan atas.
      debugShowCheckedModeBanner: false,
      title: 'Hybrid WebView Prototype',
      theme: ThemeData(
        // Skema warna berbasis Material 3 dengan warna dasar ungu.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // Menampilkan halaman WebView utama sebagai halaman home.
      home: HybridWebViewPage(
        config: config,
        initialEnvironment: config.currentEnvironment,
      ),
    );
  }
}
