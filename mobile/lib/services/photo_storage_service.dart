import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';
import 'api_service.dart';

enum PhotoFolderKind {
  purchases('purchases', 'Compras'),
  remittances('remittances', 'Remesas');

  final String wireValue;
  final String label;

  const PhotoFolderKind(this.wireValue, this.label);
}

class PhotoFolderInfo {
  final String kind;
  final String uri;
  final String label;

  const PhotoFolderInfo({
    required this.kind,
    required this.uri,
    required this.label,
  });

  factory PhotoFolderInfo.fromMap(Map<dynamic, dynamic> map) {
    return PhotoFolderInfo(
      kind: (map['kind'] ?? '').toString(),
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

  Future<PhotoFolderInfo?> selectedFolder(PhotoFolderKind kind) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        'getFolder',
        <String, dynamic>{'kind': kind.wireValue},
      );
      if (raw is Map) return PhotoFolderInfo.fromMap(raw);
    } catch (_) {}
    return null;
  }

  Future<PhotoFolderInfo?> selectFolder(PhotoFolderKind kind) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        'selectFolder',
        <String, dynamic>{'kind': kind.wireValue},
      );
      if (raw is Map) return PhotoFolderInfo.fromMap(raw);
    } catch (_) {}
    return null;
  }

  Future<void> clearFolder(PhotoFolderKind kind) async {
    try {
      await _channel.invokeMethod<void>(
        'clearFolder',
        <String, dynamic>{'kind': kind.wireValue},
      );
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
    required PhotoFolderKind kind,
    required String fileName,
    required String mimeType,
    bool overwrite = true,
  }) async {
    if (bytes.isEmpty || await selectedFolder(kind) == null) return null;
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        'writeImage',
        <String, dynamic>{
          'kind': kind.wireValue,
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

  String _safeStem(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'Cliente' : cleaned;
  }

  Future<List<PhotoSaveResult>> finalizePurchasePhotos(
    Iterable<String> paths, {
    required String customerName,
    String orderNumber = '',
    String draftId = '',
  }) async {
    final unique = <String>[];
    for (final raw in paths) {
      final path = raw.trim();
      if (path.isEmpty || unique.contains(path)) continue;
      final file = File(path);
      if (await file.exists()) unique.add(path);
    }
    if (unique.isEmpty) return const <PhotoSaveResult>[];

    final customer = _safeStem(customerName);

    final saved = <PhotoSaveResult>[];
    for (var i = 0; i < unique.length; i++) {
      final path = unique[i];
      final file = File(path);
      final bytes = await file.readAsBytes();
      final ext = _extension(path);
      final suffix = unique.length == 1 ? '' : '_${i + 1}';
      final name = '$customer$suffix$ext';
      final result = await saveBytes(
        bytes,
        kind: PhotoFolderKind.purchases,
        fileName: name,
        mimeType: _mimeForExtension(ext),
        overwrite: false,
      );
      if (result != null) saved.add(result);
    }
    return saved;
  }

  Future<PhotoSaveResult?> saveLocalFile(
    String path, {
    required PhotoFolderKind kind,
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
      kind: kind,
      fileName: name,
      mimeType: _mimeForExtension(ext),
      overwrite: overwrite,
    );
  }

  Future<Uint8List?> _bytesForNote(
    Note note,
    ApiService api, {
    String? localPath,
  }) async {
    final explicit = (localPath ?? '').trim();
    if (explicit.isNotEmpty) {
      final file = File(explicit);
      if (await file.exists()) return file.readAsBytes();
    }

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

  String _classifiedFileName(Note note, PhotoFolderKind kind) {
    final raw = (note.mediaPath ?? '').trim();
    final ext = _extension(raw);
    final identity = note.messageSid.trim().isNotEmpty
        ? note.messageSid
        : note.id.toString();
    final safeIdentity =
        identity.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_').take(48);
    final prefix =
        kind == PhotoFolderKind.remittances ? 'Remesa' : 'Compra';
    return '${prefix}_${_dateStamp(note.createdAt)}_$safeIdentity$ext';
  }

  Future<bool> archiveClassifiedNote(
    Note note,
    ApiService api, {
    required PhotoFolderKind kind,
    String? localPath,
  }) async {
    if (note.messageType != 'image') return false;
    final selected = await selectedFolder(kind);
    if (selected == null) return false;

    final prefs = await SharedPreferences.getInstance();
    final identity = note.messageSid.trim().isNotEmpty
        ? note.messageSid
        : note.id.toString();
    final key = '$_archivePrefix${kind.wireValue}_$identity';
    final archived = prefs.getString(key) ?? '';
    if (archived.startsWith('${selected.uri}|')) return false;

    final bytes = await _bytesForNote(note, api, localPath: localPath);
    if (bytes == null || bytes.isEmpty) return false;

    final ext = _extension(
      (localPath ?? '').trim().isNotEmpty
          ? localPath!
          : (note.mediaPath ?? '').trim(),
    );
    final saved = await saveBytes(
      bytes,
      kind: kind,
      fileName: _classifiedFileName(note, kind),
      mimeType: _mimeForExtension(ext),
      overwrite: true,
    );
    if (saved == null || saved.uri.isEmpty) return false;

    await prefs.setString(key, '${selected.uri}|${saved.uri}');
    return true;
  }
}

extension on String {
  String take(int count) =>
      length <= count ? this : substring(0, count);
}
