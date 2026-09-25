package com.whatsbot.whatsbot

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

class WhatsBotPayPalNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName != "com.google.android.gm") return

        val extras = sbn.notification.extras ?: return
        val values = listOfNotNull(
            extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
            extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
            extras.getCharSequence(Notification.EXTRA_INFO_TEXT)?.toString(),
        ).map { it.trim() }.filter { it.isNotEmpty() }
        if (values.isEmpty()) return

        val payment = Regex(
            "^.+?\\s+sent\\s+you\\s+\\\$[\\d,]+(?:\\.\\d{1,2})?\\s+USD\\b",
            RegexOption.IGNORE_CASE,
        )
        val subject = values.firstOrNull { payment.containsMatchIn(it) } ?: return
        val body = values.distinct().joinToString("\n")
        val id = sbn.key ?: (sbn.postTime.toString() + "-" + subject.hashCode())

        val prefs = getSharedPreferences("whatsbot_paypal_queue", MODE_PRIVATE)
        synchronized(WhatsBotPayPalNotificationListener::class.java) {
            val current = try {
                JSONArray(prefs.getString("pending", "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }
            for (i in 0 until current.length()) {
                val item = current.optJSONObject(i) ?: continue
                if (item.optString("id") == id) return
            }
            current.put(
                JSONObject()
                    .put("id", id)
                    .put("subject", subject)
                    .put("body", body)
                    .put("timestamp", sbn.postTime)
            )
            prefs.edit().putString("pending", current.toString()).apply()
        }
    }
}
