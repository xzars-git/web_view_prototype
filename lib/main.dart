import 'package:flutter/material.dart';

import 'app.dart';
import 'config/app_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  const config = DefaultAppConfig();
  runApp(const App(config: config));
}
