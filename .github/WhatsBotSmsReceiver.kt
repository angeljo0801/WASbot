package com.whatsbot.whatsbot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import org.json.JSONArray
import org.json.JSONObject

class WhatsBotSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) return

        val body = messages.joinToString(separator = "") { it.messageBody ?: "" }.trim()
        if (!body.startsWith("BofA:", ignoreCase = true)) return
        if (!body.contains("le ha enviado a usted $", ignoreCase = true)) return

        val timestamp = messages.minOfOrNull { it.timestampMillis } ?: System.currentTimeMillis()
        val address = messages.firstOrNull()?.originatingAddress ?: ""
        val id = timestamp.toString() + "-" + body.hashCode().toUInt().toString(16)

        val prefs = context.getSharedPreferences("whatsbot_sms_queue", Context.MODE_PRIVATE)
        synchronized(WhatsBotSmsReceiver::class.java) {
            val current = try {
                JSONArray(prefs.getString("pending", "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }

            for (i in 0 until current.length()) {
                val item = current.optJSONObject(i) ?: continue
                if (item.optString("id") == id) return
            }

            val item = JSONObject()
                .put("id", id)
                .put("body", body)
                .put("address", address)
                .put("timestamp", timestamp)
            current.put(item)
            prefs.edit().putString("pending", current.toString()).apply()
        }
    }
}
