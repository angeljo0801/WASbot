import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';

class ApiService {
  static const _urlKey = 'backend_url';
  static const _apiKeyKey = 'backend_api_key';
  static const _cacheKey = 'notes_cache';
  static const _localNotesKey = 'local_notes';
  static const _waProviderKey = 'whatsapp_provider';
  static const _waBotNumberKey = 'whatsapp_bot_number';
  static const _waAllowedKey = 'whatsapp_allowed_numbers';

  Future<String> get baseUrl async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_urlKey) ?? '').replaceAll(RegExp(r'/$'), '');
  }

  Future<String> get apiKey async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_apiKeyKey) ?? 'dev-mobile-key';
  }

  Future<void> saveSettings(String url, String key) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_urlKey, url.trim().replaceAll(RegExp(r'/$'), ''));
    await p.setString(_apiKeyKey, key.trim());
  }

  Future<Map<String, String>> settings() async => {
        'url': await baseUrl,
        'key': await apiKey,
      };

  Future<Map<String, String>> _headers() async => {
        'Content-Type': 'application/json',
        'x-api-key': await apiKey,
      };

  String normalizePhone(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isEmpty ? '' : '+$digits';
  }

  Future<List<Note>> _loadLocalNotes() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_localNotesKey);
    if (raw == null || raw.isEmpty) return <Note>[];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(Note.fromJson).toList();
    } catch (_) {
      return <Note>[];
    }
  }

  Future<void> _saveLocalNotes(List<Note> notes) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _localNotesKey,
      jsonEncode(notes.map((e) => e.toJson()).toList()),
    );
  }

  Future<Map<String, dynamic>> whatsappSettings() async {
    final p = await SharedPreferences.getInstance();
    var provider = p.getString(_waProviderKey) ?? 'twilio';
    var botNumber = p.getString(_waBotNumberKey) ?? '';
    var allowed = p.getStringList(_waAllowedKey) ?? <String>[];
    bool? connected;

    final url = await baseUrl;
    if (url.isNotEmpty) {
      try {
        final r = await http.get(
          Uri.parse('$url/api/config'),
          headers: await _headers(),
        ).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final data = jsonDecode(r.body) as Map<String, dynamic>;
          provider = (data['whatsapp_provider'] ?? provider).toString();
          botNumber = (data['bot_number'] ?? botNumber).toString();
          final remoteAllowed = data['allowed_senders'];
          if (remoteAllowed is List) {
            allowed = remoteAllowed
                .map((e) => normalizePhone(e.toString()))
                .where((e) => e.isNotEmpty)
                .toList();
          }
          if (data['whatsapp_connected'] is bool) {
            connected = data['whatsapp_connected'] as bool;
          }
        }
      } catch (_) {}
    }

    return {
      'provider': provider,
      'bot_number': botNumber,
      'allowed_numbers': allowed,
      'connected': connected,
    };
  }

  Future<bool> saveWhatsAppSettings({
    required String provider,
    required String botNumber,
    required List<String> allowedNumbers,
  }) async {
    final p = await SharedPreferences.getInstance();
    final normalizedBot = normalizePhone(botNumber);
    final normalizedAllowed = allowedNumbers
        .map(normalizePhone)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();

    await p.setString(_waProviderKey, provider);
    await p.setString(_waBotNumberKey, normalizedBot);
    await p.setStringList(_waAllowedKey, normalizedAllowed);

    final url = await baseUrl;
    if (url.isEmpty) return false;

    try {
      final currentMode = await getProcessingMode(fallbackOnly: true);
      final r = await http.put(
        Uri.parse('$url/api/config'),
        headers: await _headers(),
        body: jsonEncode({
          'processing_mode': currentMode,
          'whatsapp_provider': provider,
          'bot_number': normalizedBot,
          'allowed_senders': normalizedAllowed,
        }),
      ).timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String> getProcessingMode({bool fallbackOnly = false}) async {
    final p = await SharedPreferences.getInstance();
    final fallback = p.getString('ai_mode') ?? 'server';
    if (fallbackOnly) return fallback;

    final url = await baseUrl;
    if (url.isEmpty) return fallback;

    try {
      final r = await http.get(
        Uri.parse('$url/api/config'),
        headers: await _headers(),
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        final mode = (data['processing_mode'] ?? fallback).toString();
        if (mode == 'local' || mode == 'server' || mode == 'rules') return mode;
      }
    } catch (_) {}
    return fallback;
  }

  Future<bool> setProcessingMode(String mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ai_mode', mode);

    final url = await baseUrl;
    if (url.isEmpty) return false;

    try {
      final wa = await whatsappSettings();
      final r = await http.put(
        Uri.parse('$url/api/config'),
        headers: await _headers(),
        body: jsonEncode({
          'processing_mode': mode,
          'whatsapp_provider': wa['provider'],
          'bot_number': wa['bot_number'],
          'allowed_senders': wa['allowed_numbers'],
        }),
      ).timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  List<Note> _filterNotes(
    List<Note> notes, {
    required String query,
    required String category,
  }) {
    var result = List<Note>.from(notes);
    if (query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      result = result
          .where(
            (n) => '${n.title} ${n.content} ${n.tags.join(' ')}'
                .toLowerCase()
                .contains(q),
          )
          .toList();
    }
    if (category.isNotEmpty && category != 'Todas') {
      result = result.where((n) => n.category == category).toList();
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  bool _remoteRepresentedByLocal(Note remote, List<Note> locals) {
    return locals.any((local) {
      if (local.remoteId != null && local.remoteId == remote.id) return true;
      if (local.status == 'synced' &&
          local.title == remote.title &&
          local.content == remote.content &&
          local.category == remote.category) {
        return true;
      }
      return false;
    });
  }

  Future<bool> _uploadLocalNote(Note note) async {
    final url = await baseUrl;
    if (url.isEmpty) return false;

    try {
      final r = await http
          .post(
            Uri.parse('$url/api/notes'),
            headers: await _headers(),
            body: jsonEncode({
              'title': note.title,
              'content': note.content,
              'original_text': note.originalText,
              'category': note.category,
              'tags': note.tags,
            }),
          )
          .timeout(const Duration(seconds: 12));

      if (r.statusCode != 201) return false;

      int? remoteId;
      try {
        final data = jsonDecode(r.body);
        if (data is Map && data['id'] is num) {
          remoteId = (data['id'] as num).toInt();
        }
      } catch (_) {}

      final locals = await _loadLocalNotes();
      final index = locals.indexWhere((n) => n.id == note.id);
      if (index >= 0) {
        locals[index] = locals[index].copyWith(
          remoteId: remoteId,
          status: 'synced',
        );
        await _saveLocalNotes(locals);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> syncPendingNotes() async {
    final url = await baseUrl;
    if (url.isEmpty) return;

    final locals = await _loadLocalNotes();
    for (final note in locals.where((n) => n.pendingSync).toList()) {
      await _uploadLocalNote(note);
    }
  }

  Future<List<Note>> getNotes({
    String query = '',
    String category = '',
  }) async {
    var locals = await _loadLocalNotes();
    final url = await baseUrl;

    if (url.isNotEmpty) {
      await syncPendingNotes();
      locals = await _loadLocalNotes();

      try {
        final uri = Uri.parse('$url/api/notes').replace(
          queryParameters: {
            if (query.trim().isNotEmpty) 'q': query.trim(),
            if (category.isNotEmpty && category != 'Todas') 'category': category,
          },
        );
        final r = await http
            .get(uri, headers: await _headers())
            .timeout(const Duration(seconds: 12));
        if (r.statusCode != 200) throw Exception('Servidor ${r.statusCode}');

        final list =
            (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
        final remote = list.map(Note.fromJson).toList();

        final p = await SharedPreferences.getInstance();
        await p.setString(
          _cacheKey,
          jsonEncode(remote.map((e) => e.toJson()).toList()),
        );

        final visibleRemote = remote
            .where((n) => !_remoteRepresentedByLocal(n, locals))
            .toList();
        final visibleLocal = _filterNotes(
          locals,
          query: query,
          category: category,
        );
        final merged = <Note>[...visibleLocal, ...visibleRemote]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return merged;
      } catch (_) {}
    }

    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_cacheKey);
    final cachedRemote = <Note>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        cachedRemote.addAll(list.map(Note.fromJson));
      } catch (_) {}
    }

    final filteredRemote = _filterNotes(
      cachedRemote
          .where((n) => !_remoteRepresentedByLocal(n, locals))
          .toList(),
      query: query,
      category: category,
    );
    final filteredLocal = _filterNotes(
      locals,
      query: query,
      category: category,
    );

    return <Note>[...filteredLocal, ...filteredRemote]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<Note> createNote({
    required String title,
    required String content,
    required String category,
    String? mediaPath,
  }) async {
    final now = DateTime.now();
    final note = Note(
      id: -now.microsecondsSinceEpoch,
      title: title,
      content: content,
      originalText: content,
      category: category,
      tags: const <String>[],
      source: 'manual',
      messageType: mediaPath == null ? 'text' : 'image',
      status: 'pending_sync',
      aiProvider: 'rules',
      mediaPath: mediaPath,
      createdAt: now,
    );

    final locals = await _loadLocalNotes();
    locals.add(note);
    await _saveLocalNotes(locals);

    await _uploadLocalNote(note);

    final refreshed = await _loadLocalNotes();
    return refreshed.firstWhere(
      (n) => n.id == note.id,
      orElse: () => note,
    );
  }

  Future<Note> updateNoteFromAi({
    required int id,
    required String title,
    required String content,
    required String category,
    required List<String> tags,
    required String aiProvider,
  }) async {
    if (id < 0) {
      final locals = await _loadLocalNotes();
      final index = locals.indexWhere((n) => n.id == id);
      if (index < 0) throw Exception('Nota local no encontrada');
      locals[index] = locals[index].copyWith(
        title: title,
        content: content,
        category: category,
        tags: tags,
        aiProvider: aiProvider,
      );
      await _saveLocalNotes(locals);
      return locals[index];
    }

    final url = await baseUrl;
    if (url.isEmpty) throw Exception('Servidor no configurado');

    final r = await http
        .patch(
          Uri.parse('$url/api/notes/$id'),
          headers: await _headers(),
          body: jsonEncode({
            'title': title,
            'content': content,
            'category': category,
            'tags': tags,
            'status': 'ready',
            'ai_source': aiProvider,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('No se pudo actualizar (${r.statusCode})');
    }
    return Note.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteNote(int id) async {
    if (id < 0) {
      final locals = await _loadLocalNotes();
      final index = locals.indexWhere((n) => n.id == id);
      if (index < 0) return;
      final note = locals[index];

      if (note.remoteId != null) {
        final url = await baseUrl;
        if (url.isNotEmpty) {
          try {
            await http
                .delete(
                  Uri.parse('$url/api/notes/${note.remoteId}'),
                  headers: await _headers(),
                )
                .timeout(const Duration(seconds: 12));
          } catch (_) {}
        }
      }

      locals.removeAt(index);
      await _saveLocalNotes(locals);
      return;
    }

    final url = await baseUrl;
    if (url.isEmpty) throw Exception('Servidor no configurado');
    final r = await http
        .delete(
          Uri.parse('$url/api/notes/$id'),
          headers: await _headers(),
        )
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 204) {
      throw Exception('No se pudo borrar (${r.statusCode})');
    }
  }

  Future<bool> health() async {
    final url = await baseUrl;
    if (url.isEmpty) return false;
    try {
      final r = await http
          .get(Uri.parse('$url/health'))
          .timeout(const Duration(seconds: 8));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
