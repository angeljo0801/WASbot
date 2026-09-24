package com.whatsbot.whatsbot

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object WhatsBotBackupStorageBridge {
    private const val CHANNEL = "com.whatsbot.whatsbot/backups"
    private const val FOLDER = "WhatsBot"

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "writeBackup" -> {
                        val fileName =
                            call.argument<String>("fileName") ?: "WhatsBot-Backup.zip"
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        val overwrite = call.argument<Boolean>("overwrite") ?: false
                        result.success(write(context, fileName, bytes, overwrite))
                    }
                    "listBackups" -> result.success(list(context))
                    "readBackup" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        result.success(read(context, uri))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error(
                    "BACKUP_ERROR",
                    e.message ?: "Error de copia de seguridad.",
                    null
                )
            }
        }
    }

    private fun relativePath() =
        Environment.DIRECTORY_DOWNLOADS + "/" + FOLDER + "/"

    private fun write(
        context: Context,
        fileName: String,
        bytes: ByteArray,
        overwrite: Boolean
    ): Map<String, Any?> {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            var uri: Uri? = null

            if (overwrite) {
                resolver.query(
                    collection,
                    arrayOf(MediaStore.Downloads._ID),
                    MediaStore.Downloads.DISPLAY_NAME + "=? AND " +
                        MediaStore.Downloads.RELATIVE_PATH + "=?",
                    arrayOf(fileName, relativePath()),
                    null
                )?.use { c ->
                    if (c.moveToFirst()) {
                        uri = ContentUris.withAppendedId(collection, c.getLong(0))
                    }
                }
            }

            if (uri == null) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, "application/zip")
                    put(MediaStore.Downloads.RELATIVE_PATH, relativePath())
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                uri = resolver.insert(collection, values)
                    ?: throw IllegalStateException("No se pudo crear la salva.")
            }

            resolver.openOutputStream(uri!!, "wt")?.use { out ->
                out.write(bytes)
                out.flush()
            } ?: throw IllegalStateException("No se pudo escribir la salva.")

            resolver.update(
                uri!!,
                ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
                null,
                null
            )
            return mapOf(
                "name" to fileName,
                "uri" to uri.toString(),
                "folder" to "Downloads/$FOLDER"
            )
        }

        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            FOLDER
        )
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, fileName)
        if (file.exists() && !overwrite) {
            throw IllegalStateException("Ya existe una salva con ese nombre.")
        }
        file.writeBytes(bytes)
        return mapOf(
            "name" to file.name,
            "uri" to Uri.fromFile(file).toString(),
            "folder" to file.parent
        )
    }

    private fun list(context: Context): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val result = mutableListOf<Map<String, Any?>>()
            resolver.query(
                collection,
                arrayOf(
                    MediaStore.Downloads._ID,
                    MediaStore.Downloads.DISPLAY_NAME,
                    MediaStore.Downloads.DATE_MODIFIED,
                    MediaStore.Downloads.SIZE
                ),
                MediaStore.Downloads.RELATIVE_PATH + "=?",
                arrayOf(relativePath()),
                MediaStore.Downloads.DATE_MODIFIED + " DESC"
            )?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Downloads._ID)
                val nameCol = c.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)
                val dateCol = c.getColumnIndexOrThrow(MediaStore.Downloads.DATE_MODIFIED)
                val sizeCol = c.getColumnIndexOrThrow(MediaStore.Downloads.SIZE)
                while (c.moveToNext()) {
                    val name = c.getString(nameCol) ?: continue
                    if (!name.endsWith(".zip")) continue
                    result.add(
                        mapOf(
                            "name" to name,
                            "uri" to ContentUris.withAppendedId(
                                collection,
                                c.getLong(idCol)
                            ).toString(),
                            "modifiedMs" to c.getLong(dateCol) * 1000L,
                            "size" to c.getLong(sizeCol)
                        )
                    )
                }
            }
            return result
        }

        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            FOLDER
        )
        if (!dir.exists()) return emptyList()
        return (dir.listFiles() ?: emptyArray())
            .filter { it.isFile && it.name.endsWith(".zip") }
            .sortedByDescending { it.lastModified() }
            .map {
                mapOf(
                    "name" to it.name,
                    "uri" to Uri.fromFile(it).toString(),
                    "modifiedMs" to it.lastModified(),
                    "size" to it.length()
                )
            }
    }

    private fun read(context: Context, rawUri: String): ByteArray {
        val uri = Uri.parse(rawUri)
        return if (uri.scheme == "content") {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: throw IllegalStateException("No se pudo abrir la salva.")
        } else {
            File(uri.path ?: throw IllegalArgumentException("Ruta inválida.")).readBytes()
        }
    }
}
