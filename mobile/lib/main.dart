import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/home_page.dart';
import 'services/backup_service.dart';
import 'services/background_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await WhatsBotBackupService.autoBackupIfDue();
  } catch (_) {}
  runApp(const WhatsBotApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(WhatsBotBackgroundService.restore());
  });
}

class WhatsBotApp extends StatelessWidget {
  const WhatsBotApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'WhatsBot',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const HomePage(),
      );
}
