import 'package:flutter/material.dart';
import 'config/custom_tabs_config.dart';
import 'features/hybrid_webview/presentation/hybrid_webview_page.dart';

class WebViewPrototypeApp extends StatelessWidget {
  const WebViewPrototypeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: HybridWebViewPage(initialEnvironment: CustomTabsConfig.environment),
    );
  }
}
