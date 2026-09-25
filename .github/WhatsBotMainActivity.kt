package com.whatsbot.whatsbot

import android.content.Intent
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
        WhatsBotSmsBridge.register(
            this,
            flutterEngine.dartExecutor.binaryMessenger
        )
        WhatsBotPayPalEmailBridge.register(
            this,
            flutterEngine.dartExecutor.binaryMessenger
        )
        WhatsBotPhotoStorageBridge.register(
            this,
            flutterEngine.dartExecutor.binaryMessenger
        )
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        if (WhatsBotPhotoStorageBridge.onActivityResult(requestCode, resultCode, data)) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (WhatsBotSmsBridge.onRequestPermissionsResult(requestCode, grantResults)) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
