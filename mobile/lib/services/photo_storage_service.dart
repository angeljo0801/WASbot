import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';
import 'api_service.dart';

class PhotoFolderInfo {
  final String uri;
  final String label;

  const PhotoFolderInfo({
    required this.uri,
    required this.label,
  });

  factory PhotoFolderInfo.fromMap(Map<dynamic, dynamic> map) {
    return PhotoFolderInfo(
      uri: (map['uri'] ?? '').toString(),
      label: (map['label'] ?? 'Carpeta seleccionada').toString(),
    );
  }
}

class PhotoSaveResult {
  final String uri;
  final String name;
  final String folder;

  const PhotoSaveResult({
    required this.uri,
    required this.name,
    required this.folder,
  });

  factory PhotoSaveResult.fromMap(Map<dynamic, dynamic> map) {
    return PhotoSaveResult(
      uri: (map['uri'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      folder: (map['folder'] ?? '').toString(),
    );
  }
}

class PhotoStorageService {
  PhotoStorageService._();

  static final PhotoStorageService instance = PhotoStorageService._();

  static const MethodChannel _channel =
      MethodChannel('com.whatsbot.whatsbot/photo_storage');

  static const String _archivePrefix = 'photo_storage_archived_note_';

  Future<PhotoFolderInfo?> selectedFolder() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getFolder');
      if (raw is Map) return PhotoFolderInfo.fromMap(raw);
    } catch (_) {}
    return null;
  }

  Future<PhotoFolderInfo?> selectFolder() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('selectFolder');
      if (raw is Map) return PhotoFolderInfo.fromMap(raw);
    } catch (_) {}
    return null;
  }

  Future<void> clearFolder() async {
    try {
      await _channel.invokeMethod<void>('clearFolder');
    } catch (_) {}
  }

  String _extension(String raw) {
    final lower = raw.toLowerCase().split('?').first;
    if (lower.endsWith('.png')) return '.png';
    if (lower.endsWith('.webp')) return '.webp';
    if (lower.endsWith('.gif')) return '.gif';
    if (lower.endsWith('.heic')) return '.heic';
    if (lower.endsWith('.heif')) return '.heif';
    if (lower.endsWith('.jpeg')) return '.jpeg';
    return '.jpg';
  }

  String _mimeForExtension(String ext) => switch (ext.toLowerCase()) {
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        '.heic' => 'image/heic',
        '.heif' => 'image/heif',
        _ => 'image/jpeg',
      };

  String _dateStamp(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}${two(local.month)}${two(local.day)}_'
        '${two(local.hour)}${two(local.minute)}${two(local.second)}';
  }

  Future<PhotoSaveResult?> saveBytes(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
    bool overwrite = true,
  }) async {
    if (bytes.isEmpty || await selectedFolder() == null) return null;
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        'writeImage',
        <String, dynamic>{
          'fileName': fileName,
          'mimeType': mimeType,
          'bytes': bytes,
          'overwrite': overwrite,
        },
      );
      if (raw is Map) return PhotoSaveResult.fromMap(raw);
    } catch (_) {}
    return null;
  }

  Future<PhotoSaveResult?> saveLocalFile(
    String path, {
    String prefix = 'WhatsBot',
    bool overwrite = false,
  }) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final ext = _extension(path);
    final original = file.uri.pathSegments.isEmpty
        ? ''
        : file.uri.pathSegments.last.trim();
    final name = original.isEmpty
        ? '${prefix}_${DateTime.now().microsecondsSinceEpoch}$ext'
        : original;
    return saveBytes(
      bytes,
      fileName: name,
      mimeType: _mimeForExtension(ext),
      overwrite: overwrite,
    );
  }

  Future<Uint8List?> _bytesForNote(Note note, ApiService api) async {
    final raw = (note.mediaPath ?? '').trim();
    if (raw.isEmpty) {
      for (final path in note.photoPaths) {
        final file = File(path);
        if (await file.exists()) return file.readAsBytes();
      }
      return null;
    }

    final local = File(raw);
    if (await local.exists()) return local.readAsBytes();

    return api.fetchMediaBytes(raw);
  }

  String _incomingFileName(Note note) {
    final raw = (note.mediaPath ?? '').trim();
    final ext = _extension(raw);
    final identity = note.messageSid.trim().isNotEmpty
        ? note.messageSid
        : note.id.toString();
    final safeIdentity =
        identity.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_').take(48);
    return 'WhatsApp_${_dateStamp(note.createdAt)}_$safeIdentity$ext';
  }

  Future<bool> archiveIncomingNote(Note note, ApiService api) async {
    if (note.messageType != 'image') return false;
    if (await selectedFolder() == null) return false;

    final prefs = await SharedPreferences.getInstance();
    final identity = note.messageSid.trim().isNotEmpty
        ? note.messageSid
        : note.id.toString();
    final key = '$_archivePrefix$identity';
    if ((prefs.getString(key) ?? '').isNotEmpty) return false;

    final bytes = await _bytesForNote(note, api);
    if (bytes == null || bytes.isEmpty) return false;

    final ext = _extension((note.mediaPath ?? '').trim());
    final saved = await saveBytes(
      bytes,
      fileName: _incomingFileName(note),
      mimeType: _mimeForExtension(ext),
      overwrite: true,
    );
    if (saved == null || saved.uri.isEmpty) return false;

    await prefs.setString(key, saved.uri);
    return true;
  }

  Future<int> archiveIncomingNotes(
    Iterable<Note> notes,
    ApiService api, {
    int limit = 20,
  }) async {
    if (await selectedFolder() == null) return 0;

    var saved = 0;
    for (final note in notes) {
      if (saved >= limit) break;
      try {
        if (await archiveIncomingNote(note, api)) saved++;
      } catch (_) {
        // A later refresh retries the same photo.
      }
    }
    return saved;
  }
}

extension on String {
  String take(int count) =>
      length <= count ? this : substring(0, count);
}
