import 'dart:io';

import 'package:flutter_background/flutter_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WhatsBotBackgroundService {
  static const _enabledKey = 'background_execution_enabled';

  static Future<bool> preferenceEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  static bool get isRunning =>
      Platform.isAndroid && FlutterBackground.isBackgroundExecutionEnabled;

  static Future<bool> restore() async {
    if (!Platform.isAndroid) return false;
    final enabled = await preferenceEnabled();
    if (!enabled) return false;

    final started = await _enable();
    if (!started) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, false);
    }
    return started;
  }

  static Future<bool> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();

    if (!enabled) {
      await prefs.setBool(_enabledKey, false);
      if (Platform.isAndroid && FlutterBackground.isBackgroundExecutionEnabled) {
        try {
          await FlutterBackground.disableBackgroundExecution();
        } catch (_) {}
      }
      return true;
    }

    if (!Platform.isAndroid) {
      await prefs.setBool(_enabledKey, false);
      return false;
    }

    final started = await _enable();
    await prefs.setBool(_enabledKey, started);
    return started;
  }

  static Future<bool> _enable() async {
    final config = FlutterBackgroundAndroidConfig(
      notificationTitle: 'WhatsBot activo',
      notificationText:
          'Recibiendo, sincronizando y procesando mensajes en segundo plano.',
      notificationImportance: AndroidNotificationImportance.normal,
      enableWifiLock: true,
    );

    try {
      final initialized =
          await FlutterBackground.initialize(androidConfig: config);
      if (!initialized) return false;
      if (FlutterBackground.isBackgroundExecutionEnabled) return true;
      return await FlutterBackground.enableBackgroundExecution();
    } catch (_) {
      return false;
    }
  }
}
