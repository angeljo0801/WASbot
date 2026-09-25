package com.whatsbot.whatsbot

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

object WhatsBotPayPalEmailBridge {
    private const val CHANNEL = "whatsbot/paypal_email"

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAccess" -> result.success(hasAccess(activity))
                "openSettings" -> {
                    try {
                        activity.startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("settings", e.message, null)
                    }
                }
                "pending" -> result.success(readPending(activity))
                "ack" -> {
                    val ids = (call.arguments as? List<*>)
                        ?.mapNotNull { it?.toString() }
                        ?.toSet()
                        ?: emptySet()
                    removePending(activity, ids)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasAccess(context: Context): Boolean {
        val component = ComponentName(
            context,
            WhatsBotPayPalNotificationListener::class.java,
        ).flattenToString()
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        return enabled.split(':').any { it.equals(component, ignoreCase = true) }
    }

    private fun readPending(context: Context): List<Map<String, Any>> {
        val prefs = context.getSharedPreferences("whatsbot_paypal_queue", Context.MODE_PRIVATE)
        val array = try {
            JSONArray(prefs.getString("pending", "[]") ?: "[]")
        } catch (_: Exception) {
            JSONArray()
        }
        val out = mutableListOf<Map<String, Any>>()
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            out.add(
                mapOf(
                    "id" to item.optString("id"),
                    "subject" to item.optString("subject"),
                    "body" to item.optString("body"),
                    "timestamp" to item.optLong("timestamp"),
                )
            )
        }
        return out
    }

    private fun removePending(context: Context, ids: Set<String>) {
        if (ids.isEmpty()) return
        val prefs = context.getSharedPreferences("whatsbot_paypal_queue", Context.MODE_PRIVATE)
        val source = try {
            JSONArray(prefs.getString("pending", "[]") ?: "[]")
        } catch (_: Exception) {
            JSONArray()
        }
        val kept = JSONArray()
        for (i in 0 until source.length()) {
            val item = source.optJSONObject(i) ?: continue
            if (!ids.contains(item.optString("id"))) kept.put(item)
        }
        prefs.edit().putString("pending", kept.toString()).apply()
    }
}
