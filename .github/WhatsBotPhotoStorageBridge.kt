package com.whatsbot.whatsbot

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object WhatsBotPhotoStorageBridge {
    private const val CHANNEL = "com.whatsbot.whatsbot/photo_storage"
    private const val REQUEST_FOLDER = 48321
    private const val PREFS = "whatsbot_photo_storage"
    private const val KEY_URI = "tree_uri"
    private const val KEY_LABEL = "tree_label"

    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null

    fun register(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getFolder" -> result.success(currentFolder())
                    "selectFolder" -> selectFolder(result)
                    "clearFolder" -> {
                        clearFolder()
                        result.success(true)
                    }
                    "writeImage" -> {
                        val fileName = call.argument<String>("fileName")
                            ?: throw IllegalArgumentException("Falta el nombre del archivo.")
                        val mimeType = call.argument<String>("mimeType") ?: "image/jpeg"
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        val overwrite = call.argument<Boolean>("overwrite") ?: true
                        result.success(writeImage(fileName, mimeType, bytes, overwrite))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error(
                    "PHOTO_STORAGE_ERROR",
                    e.message ?: "No se pudo acceder a la carpeta de fotos.",
                    null
                )
            }
        }
    }

    private fun prefs() = activity!!.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun currentFolder(): Map<String, Any?>? {
        val raw = prefs().getString(KEY_URI, "") ?: ""
        if (raw.isBlank()) return null
        val uri = Uri.parse(raw)
        return mapOf(
            "uri" to raw,
            "label" to (
                prefs().getString(KEY_LABEL, "")?.takeIf { it.isNotBlank() }
                    ?: queryName(uri)
                    ?: "Carpeta seleccionada"
            )
        )
    }

    private fun selectFolder(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error(
                "PHOTO_STORAGE_BUSY",
                "Ya hay un selector de carpeta abierto.",
                null
            )
            return
        }
        val host = activity
            ?: throw IllegalStateException("WhatsBot no tiene una actividad disponible.")
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
        }
        host.startActivityForResult(intent, REQUEST_FOLDER)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_FOLDER) return false
        val result = pendingResult ?: return true
        pendingResult = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }

        val returnedIntent = data
        val uri = returnedIntent?.data
        if (uri == null) {
            result.success(null)
            return true
        }

        val flags = returnedIntent.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        try {
            activity?.contentResolver?.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
            // Some document providers grant usable access without persistence.
        }

        val label = queryName(uri) ?: "Carpeta seleccionada"
        prefs().edit()
            .putString(KEY_URI, uri.toString())
            .putString(KEY_LABEL, label)
            .apply()

        result.success(mapOf("uri" to uri.toString(), "label" to label))
        return true
    }

    private fun clearFolder() {
        val raw = prefs().getString(KEY_URI, "") ?: ""
        if (raw.isNotBlank()) {
            try {
                activity?.contentResolver?.releasePersistableUriPermission(
                    Uri.parse(raw),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (_: Exception) {}
        }
        prefs().edit().remove(KEY_URI).remove(KEY_LABEL).apply()
    }

    private fun writeImage(
        fileName: String,
        mimeType: String,
        bytes: ByteArray,
        overwrite: Boolean
    ): Map<String, Any?> {
        if (bytes.isEmpty()) {
            throw IllegalArgumentException("La imagen está vacía.")
        }

        val raw = prefs().getString(KEY_URI, "") ?: ""
        if (raw.isBlank()) {
            throw IllegalStateException("Primero selecciona una carpeta para las fotos.")
        }

        val treeUri = Uri.parse(raw)
        val resolver = activity!!.contentResolver
        val safeName = sanitizeName(fileName)
        var target = findChild(treeUri, safeName)

        if (target == null || !overwrite) {
            val finalName = if (target == null) safeName else uniqueName(treeUri, safeName)
            val parent = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri)
            )
            target = DocumentsContract.createDocument(
                resolver,
                parent,
                mimeType,
                finalName
            ) ?: throw IllegalStateException("No se pudo crear la imagen en la carpeta elegida.")
        }

        resolver.openOutputStream(target, "rwt")?.use { out ->
            out.write(bytes)
            out.flush()
        } ?: throw IllegalStateException("No se pudo escribir la imagen.")

        return mapOf(
            "uri" to target.toString(),
            "name" to (queryName(target) ?: safeName),
            "folder" to (
                prefs().getString(KEY_LABEL, "")?.takeIf { it.isNotBlank() }
                    ?: "Carpeta seleccionada"
            )
        )
    }

    private fun findChild(treeUri: Uri, fileName: String): Uri? {
        val resolver = activity!!.contentResolver
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri)
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME
        )
        resolver.query(children, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID
            )
            val nameIndex = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME
            )
            while (cursor.moveToNext()) {
                if (cursor.getString(nameIndex) == fileName) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        cursor.getString(idIndex)
                    )
                }
            }
        }
        return null
    }

    private fun uniqueName(treeUri: Uri, original: String): String {
        val dot = original.lastIndexOf('.')
        val stem = if (dot > 0) original.substring(0, dot) else original
        val ext = if (dot > 0) original.substring(dot) else ""
        var index = 2
        while (true) {
            val candidate = "${stem}_${index}${ext}"
            if (findChild(treeUri, candidate) == null) return candidate
            index++
        }
    }

    private fun sanitizeName(value: String): String {
        val clean = value
            .replace(Regex("[\\/:*?\"<>|]"), "_")
            .trim()
            .take(180)
        return if (clean.isBlank()) "WhatsBot_${System.currentTimeMillis()}.jpg" else clean
    }

    private fun queryName(uri: Uri): String? {
        val resolver = activity?.contentResolver ?: return null
        var cursor: Cursor? = null
        try {
            cursor = resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        } catch (_: Exception) {
        } finally {
            cursor?.close()
        }
        return null
    }
}
