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

    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingKind: String? = null

    fun register(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                val kind = normalizeKind(call.argument<String>("kind"))
                when (call.method) {
                    "getFolder" -> result.success(currentFolder(kind))
                    "selectFolder" -> selectFolder(kind, result)
                    "clearFolder" -> {
                        clearFolder(kind)
                        result.success(true)
                    }
                    "writeImage" -> {
                        val fileName = call.argument<String>("fileName")
                            ?: throw IllegalArgumentException("Falta el nombre del archivo.")
                        val mimeType = call.argument<String>("mimeType") ?: "image/jpeg"
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        val overwrite = call.argument<Boolean>("overwrite") ?: true
                        result.success(
                            writeImage(kind, fileName, mimeType, bytes, overwrite)
                        )
                    }
                    "renameImage" -> {
                        val uri = call.argument<String>("uri")
                            ?: throw IllegalArgumentException("Falta la imagen que se va a renombrar.")
                        val fileName = call.argument<String>("fileName")
                            ?: throw IllegalArgumentException("Falta el nuevo nombre.")
                        result.success(renameImage(kind, uri, fileName))
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

    private fun normalizeKind(raw: String?): String {
        return when ((raw ?: "").lowercase()) {
            "remittances", "remesas" -> "remittances"
            else -> "purchases"
        }
    }

    private fun uriKey(kind: String) = "tree_uri_" + kind
    private fun labelKey(kind: String) = "tree_label_" + kind

    private fun currentFolder(kind: String): Map<String, Any?>? {
        val raw = prefs().getString(uriKey(kind), "") ?: ""
        if (raw.isBlank()) return null
        val uri = Uri.parse(raw)
        return mapOf(
            "kind" to kind,
            "uri" to raw,
            "label" to (
                prefs().getString(labelKey(kind), "")?.takeIf { it.isNotBlank() }
                    ?: queryName(uri)
                    ?: "Carpeta seleccionada"
            )
        )
    }

    private fun selectFolder(kind: String, result: MethodChannel.Result) {
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
        pendingKind = kind
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
        val kind = pendingKind ?: "purchases"
        pendingResult = null
        pendingKind = null

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
        }

        val old = prefs().getString(uriKey(kind), "") ?: ""
        val label = queryName(uri) ?: "Carpeta seleccionada"
        prefs().edit()
            .putString(uriKey(kind), uri.toString())
            .putString(labelKey(kind), label)
            .apply()

        if (old.isNotBlank() && old != uri.toString() && !isUriUsedByOtherKind(old, kind)) {
            releasePermission(old)
        }

        result.success(
            mapOf("kind" to kind, "uri" to uri.toString(), "label" to label)
        )
        return true
    }

    private fun clearFolder(kind: String) {
        val raw = prefs().getString(uriKey(kind), "") ?: ""
        prefs().edit().remove(uriKey(kind)).remove(labelKey(kind)).apply()
        if (raw.isNotBlank() && !isUriUsedByOtherKind(raw, kind)) {
            releasePermission(raw)
        }
    }

    private fun isUriUsedByOtherKind(rawUri: String, excludingKind: String): Boolean {
        for (kind in listOf("purchases", "remittances")) {
            if (kind == excludingKind) continue
            if ((prefs().getString(uriKey(kind), "") ?: "") == rawUri) return true
        }
        return false
    }

    private fun releasePermission(rawUri: String) {
        try {
            activity?.contentResolver?.releasePersistableUriPermission(
                Uri.parse(rawUri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Exception) {}
    }

    private fun writeImage(
        kind: String,
        fileName: String,
        mimeType: String,
        bytes: ByteArray,
        overwrite: Boolean
    ): Map<String, Any?> {
        if (bytes.isEmpty()) {
            throw IllegalArgumentException("La imagen está vacía.")
        }

        val raw = prefs().getString(uriKey(kind), "") ?: ""
        if (raw.isBlank()) {
            val label = if (kind == "remittances") "Remesas" else "Compras"
            throw IllegalStateException("Primero selecciona la carpeta de " + label + ".")
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
            "kind" to kind,
            "uri" to target.toString(),
            "name" to (queryName(target) ?: safeName),
            "folder" to (
                prefs().getString(labelKey(kind), "")?.takeIf { it.isNotBlank() }
                    ?: "Carpeta seleccionada"
            )
        )
    }

    private fun renameImage(
        kind: String,
        rawUri: String,
        requestedName: String
    ): Map<String, Any?> {
        val folderRaw = prefs().getString(uriKey(kind), "") ?: ""
        if (folderRaw.isBlank()) {
            throw IllegalStateException("No hay una carpeta configurada.")
        }

        val documentUri = Uri.parse(rawUri)
        val treeUri = Uri.parse(folderRaw)
        val currentName = queryName(documentUri) ?: ""
        val safeRequested = sanitizeName(requestedName)
        val finalName = uniqueNameExcluding(treeUri, safeRequested, documentUri)

        if (currentName == finalName) {
            return mapOf(
                "kind" to kind,
                "uri" to documentUri.toString(),
                "name" to currentName,
                "folder" to (
                    prefs().getString(labelKey(kind), "")?.takeIf { it.isNotBlank() }
                        ?: "Carpeta seleccionada"
                )
            )
        }

        val renamed = DocumentsContract.renameDocument(
            activity!!.contentResolver,
            documentUri,
            finalName
        ) ?: throw IllegalStateException("No se pudo cambiar el nombre de la imagen.")

        return mapOf(
            "kind" to kind,
            "uri" to renamed.toString(),
            "name" to (queryName(renamed) ?: finalName),
            "folder" to (
                prefs().getString(labelKey(kind), "")?.takeIf { it.isNotBlank() }
                    ?: "Carpeta seleccionada"
            )
        )
    }

    private fun uniqueNameExcluding(
        treeUri: Uri,
        original: String,
        excludedUri: Uri
    ): String {
        if (!nameExistsOtherThan(treeUri, original, excludedUri)) return original
        val dot = original.lastIndexOf('.')
        val stem = if (dot > 0) original.substring(0, dot) else original
        val ext = if (dot > 0) original.substring(dot) else ""
        var index = 2
        while (true) {
            val candidate = stem + "_" + index + ext
            if (!nameExistsOtherThan(treeUri, candidate, excludedUri)) return candidate
            index++
        }
    }

    private fun nameExistsOtherThan(
        treeUri: Uri,
        fileName: String,
        excludedUri: Uri
    ): Boolean {
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
                if (cursor.getString(nameIndex) != fileName) continue
                val candidateUri = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri,
                    cursor.getString(idIndex)
                )
                if (candidateUri != excludedUri) return true
            }
        }
        return false
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
            val candidate = stem + "_" + index + ext
            if (findChild(treeUri, candidate) == null) return candidate
            index++
        }
    }

    private fun sanitizeName(value: String): String {
        val clean = value
            .replace(Regex("[\\/:*?\"<>|]"), "_")
            .trim()
            .take(180)
        return if (clean.isBlank()) {
            "WhatsBot_" + System.currentTimeMillis() + ".jpg"
        } else {
            clean
        }
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
