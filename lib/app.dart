import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'features/hybrid_webview/presentation/hybrid_webview_page.dart';

class App extends StatelessWidget {
  const App({super.key, required this.config});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hybrid WebView Prototype',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: HybridWebViewPage(
        config: config,
        initialEnvironment: config.currentEnvironment,
      ),
    );
  }
}
