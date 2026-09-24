package com.whatsbot.whatsbot

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WhatsBotBackupStorageBridge.register(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger
        )
        LocalAiManagerBridge.register(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger
        )
    }
}
