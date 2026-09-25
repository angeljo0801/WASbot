package com.whatsbot.whatsbot

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

object WhatsBotSmsBridge {
    private const val CHANNEL = "whatsbot/sms"
    private const val REQUEST_SMS_PERMISSION = 8421

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    result.success(
                        activity.checkSelfPermission(Manifest.permission.RECEIVE_SMS) ==
                            PackageManager.PERMISSION_GRANTED
                    )
                }
                "requestPermission" -> {
                    if (activity.checkSelfPermission(Manifest.permission.RECEIVE_SMS) ==
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(true)
                    } else {
                        activity.requestPermissions(
                            arrayOf(Manifest.permission.RECEIVE_SMS),
                            REQUEST_SMS_PERMISSION,
                        )
                        result.success(true)
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

    private fun readPending(context: Context): List<Map<String, Any>> {
        val prefs = context.getSharedPreferences("whatsbot_sms_queue", Context.MODE_PRIVATE)
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
                    "body" to item.optString("body"),
                    "address" to item.optString("address"),
                    "timestamp" to item.optLong("timestamp"),
                )
            )
        }
        return out
    }

    private fun removePending(context: Context, ids: Set<String>) {
        if (ids.isEmpty()) return
        val prefs = context.getSharedPreferences("whatsbot_sms_queue", Context.MODE_PRIVATE)
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
