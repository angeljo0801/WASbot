import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WhatsBotBackupBridge {
  static const _channel = MethodChannel('com.whatsbot.whatsbot/backups');

  static Future<Map<String, dynamic>> write({
    required String fileName,
    required Uint8List bytes,
    bool overwrite = false,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'writeBackup',
      {'fileName': fileName, 'bytes': bytes, 'overwrite': overwrite},
    );
    return Map<String, dynamic>.from(raw ?? const {});
  }

  static Future<List<Map<String, dynamic>>> list() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listBackups');
    return (raw ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Future<Uint8List> read(String uri) async {
    return await _channel.invokeMethod<Uint8List>(
          'readBackup',
          {'uri': uri},
        ) ??
        Uint8List(0);
  }
}

class WhatsBotBackupService {
  static const _enabledKey = 'whatsbot_auto_backup_enabled';
  static const _lastKey = 'whatsbot_last_auto_backup_at';

  static bool _sensitive(String key) {
    final k = key.toLowerCase();
    return k.contains('token') ||
        k.contains('password') ||
        k.contains('secret') ||
        k.contains('api_key') ||
        k.contains('apikey') ||
        k == 'backend_api_key';
  }

  static bool _skipPreference(String key) {
    final k = key.toLowerCase();
    return _sensitive(key) ||
        k == 'local_ai_model_path' ||
        k.contains('model_path');
  }

  static bool _skipFile(File file) {
    final p = file.path.toLowerCase().replaceAll('\\', '/');
    return p.contains('/models/') ||
        p.contains('/model_cache/') ||
        p.endsWith('.gguf') ||
        p.endsWith('.safetensors');
  }

  static Future<Map<String, dynamic>> _preferences() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    final excluded = <String>[];
    for (final key in prefs.getKeys()) {
      if (_skipPreference(key)) {
        excluded.add(key);
        continue;
      }
      final value = prefs.get(key);
      if (value is String ||
          value is bool ||
          value is int ||
          value is double ||
          value is List<String>) {
        out[key] = value;
      }
    }
    return {'values': out, 'excluded': excluded};
  }

  static Future<void> _addDir(
    Archive archive,
    Directory root,
    String prefix,
  ) async {
    if (!await root.exists()) return;
    final base = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : root.path + Platform.pathSeparator;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || _skipFile(entity)) continue;
      if (!entity.path.startsWith(base)) continue;
      final rel = entity.path.substring(base.length).replaceAll('\\', '/');
      if (rel.isEmpty) continue;
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile('$prefix/$rel', bytes.length, bytes));
    }
  }

  static Future<Uint8List> buildBackup() async {
    final archive = Archive();
    final prefs = await _preferences();

    final metaBytes = utf8.encode(jsonEncode({
      'format': 'WhatsBotBackup',
      'formatVersion': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'applicationId': 'com.whatsbot.whatsbot',
      'modelsIncluded': false,
      'credentialsIncluded': false,
      'excludedPreferences': prefs['excluded'],
    }));
    archive.addFile(
      ArchiveFile('meta/backup.json', metaBytes.length, metaBytes),
    );

    final prefBytes = utf8.encode(jsonEncode(prefs['values']));
    archive.addFile(
      ArchiveFile('meta/preferences.json', prefBytes.length, prefBytes),
    );

    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    await _addDir(archive, docs, 'documents');
    if (support.path != docs.path) {
      await _addDir(archive, support, 'support');
    }

    final bytes = ZipEncoder().encode(archive);
    return Uint8List.fromList(bytes);
  }

  static Future<Map<String, dynamic>> createManual() async {
    final bytes = await buildBackup();
    final now = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return WhatsBotBackupBridge.write(
      fileName:
          'WhatsBot-Backup-${now.year}${p(now.month)}${p(now.day)}-'
          '${p(now.hour)}${p(now.minute)}${p(now.second)}.zip',
      bytes: bytes,
    );
  }

  static Future<void> autoBackupIfDue() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_enabledKey) ?? true)) return;
    final last = DateTime.tryParse(prefs.getString(_lastKey) ?? '');
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(hours: 24)) {
      return;
    }
    final bytes = await buildBackup();
    await WhatsBotBackupBridge.write(
      fileName: 'WhatsBot-AutoBackup.zip',
      bytes: bytes,
      overwrite: true,
    );
    await prefs.setString(_lastKey, now.toIso8601String());
  }

  static Future<bool> autoEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  static Future<void> setAutoEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  static Future<void> _clearRestorableFiles(Directory root) async {
    if (!await root.exists()) return;
    for (final entity in await root.list(followLinks: false).toList()) {
      final lower = entity.path.toLowerCase().replaceAll('\\', '/');
      if (lower.endsWith('/models') || lower.endsWith('/model_cache')) {
        continue;
      }
      if (entity is File) {
        if (_skipFile(entity)) continue;
        await entity.delete();
      } else if (entity is Directory) {
        await entity.delete(recursive: true);
      }
    }
  }

  static Future<void> restore(String uri) async {
    final bytes = await WhatsBotBackupBridge.read(uri);
    if (bytes.isEmpty) throw Exception('La salva está vacía.');

    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? metaFile;
    ArchiveFile? prefsFile;
    for (final file in archive.files) {
      if (file.name == 'meta/backup.json') metaFile = file;
      if (file.name == 'meta/preferences.json') prefsFile = file;
    }
    if (metaFile == null || prefsFile == null) {
      throw Exception('Este archivo no es una salva válida de WhatsBot.');
    }

    final meta = jsonDecode(utf8.decode(metaFile.content as List<int>));
    if (meta is! Map || meta['format'] != 'WhatsBotBackup') {
      throw Exception('Formato de salva no compatible.');
    }

    final prefs = await SharedPreferences.getInstance();
    final preserved = <String, Object?>{};
    for (final key in prefs.getKeys()) {
      if (_skipPreference(key)) preserved[key] = prefs.get(key);
    }
    final autoEnabled = prefs.getBool(_enabledKey) ?? true;

    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    await _clearRestorableFiles(docs);
    if (support.path != docs.path) await _clearRestorableFiles(support);

    for (final file in archive.files) {
      if (!file.isFile) continue;
      Directory? root;
      String? rel;
      if (file.name.startsWith('documents/')) {
        root = docs;
        rel = file.name.substring('documents/'.length);
      } else if (file.name.startsWith('support/')) {
        root = support;
        rel = file.name.substring('support/'.length);
      }
      if (root == null || rel == null || rel.isEmpty || rel.contains('..')) {
        continue;
      }
      final out = File(
        root.path +
            Platform.pathSeparator +
            rel.replaceAll('/', Platform.pathSeparator),
      );
      if (_skipFile(out)) continue;
      await out.parent.create(recursive: true);
      await out.writeAsBytes(List<int>.from(file.content as List), flush: true);
    }

    final prefData = jsonDecode(utf8.decode(prefsFile.content as List<int>));
    if (prefData is Map) {
      await prefs.clear();
      for (final e in prefData.entries) {
        final key = e.key.toString();
        if (_skipPreference(key)) continue;
        await _setPreference(prefs, key, e.value);
      }
      for (final e in preserved.entries) {
        await _setPreference(prefs, e.key, e.value);
      }
      if (!prefs.containsKey(_enabledKey)) {
        await prefs.setBool(_enabledKey, autoEnabled);
      }
    }
  }

  static Future<void> _setPreference(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is List) {
      await prefs.setStringList(key, value.map((x) => x.toString()).toList());
    }
  }
}
