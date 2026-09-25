import 'dart:convert';
import 'dart:typed_data';

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

  Future<Map<String, dynamic>> remittanceSettings() async {
    final url = await baseUrl;
    if (url.isEmpty) return const <String, dynamic>{};
    try {
      final r = await http
          .get(
            Uri.parse('$url/api/remittances/settings'),
            headers: await _headers(),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return const <String, dynamic>{};
      final decoded = jsonDecode(r.body);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<Map<String, dynamic>> saveRemittanceAgents(
    List<String> agents,
  ) async {
    final url = await baseUrl;
    if (url.isEmpty) return const <String, dynamic>{};
    final normalized = agents
        .map(normalizePhone)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    try {
      final r = await http.put(
        Uri.parse('$url/api/remittances/agents'),
        headers: await _headers(),
        body: jsonEncode({'agents': normalized}),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return const <String, dynamic>{};
      final decoded = jsonDecode(r.body);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<Map<String, dynamic>> regenerateRemittanceCode() async {
    final url = await baseUrl;
    if (url.isEmpty) return const <String, dynamic>{};
    try {
      final r = await http.post(
        Uri.parse('$url/api/remittances/code/regenerate'),
        headers: await _headers(),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return const <String, dynamic>{};
      final decoded = jsonDecode(r.body);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<bool> ingestRemittanceSms({
    required String text,
    required String receivedAt,
    required String smsId,
  }) async {
    final url = await baseUrl;
    if (url.isEmpty) return false;
    try {
      final r = await http.post(
        Uri.parse('$url/api/remittances/sms'),
        headers: await _headers(),
        body: jsonEncode({
          'text': text,
          'received_at': receivedAt,
          'sms_id': smsId,
        }),
      ).timeout(const Duration(seconds: 12));
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }
  Future<bool> ingestPayPalRemittanceEmail({
    required String subject,
    required String body,
    required String receivedAt,
    required String emailId,
  }) async {
    final url = await baseUrl;
    if (url.isEmpty) return false;
    try {
      final r = await http.post(
        Uri.parse('$url/api/remittances/paypal-email'),
        headers: await _headers(),
        body: jsonEncode({
          'subject': subject,
          'body': body,
          'received_at': receivedAt,
          'email_id': emailId,
        }),
      ).timeout(const Duration(seconds: 12));
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> saveOcrRemittance({
    required int noteId,
    required String source,
    required String name,
    required double amount,
    required String date,
    required String ocrText,
  }) async {
    final url = await baseUrl;
    if (url.isEmpty) return const <String, dynamic>{};
    try {
      final response = await http.post(
        Uri.parse('$url/api/remittances/ocr'),
        headers: await _headers(),
        body: jsonEncode({
          'note_id': noteId,
          'source': source,
          'name': name,
          'amount': amount,
          'date': date,
          'ocr_text': ocrText,
        }),
      ).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return const <String, dynamic>{};
      final decoded = jsonDecode(response.body);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<List<Map<String, dynamic>>> getConversations({int limit = 100}) async {
    final url = await baseUrl;
    if (url.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final uri = Uri.parse('$url/api/conversations').replace(
        queryParameters: {'limit': limit.clamp(1, 300).toString()},
      );
      final r = await http
          .get(uri, headers: await _headers())
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const <Map<String, dynamic>>[];
      final decoded = jsonDecode(r.body);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> getConversationMessages(
    String sender, {
    int limit = 100,
  }) async {
    final url = await baseUrl;
    if (url.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final safeSender = Uri.encodeComponent(normalizePhone(sender));
      final uri = Uri.parse('$url/api/conversations/$safeSender').replace(
        queryParameters: {'limit': limit.clamp(1, 300).toString()},
      );
      final r = await http
          .get(uri, headers: await _headers())
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const <Map<String, dynamic>>[];
      final decoded = jsonDecode(r.body);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> getActivity({int limit = 100}) async {
    final url = await baseUrl;
    if (url.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final uri = Uri.parse('$url/api/activity').replace(
        queryParameters: {'limit': limit.clamp(1, 300).toString()},
      );
      final r = await http
          .get(uri, headers: await _headers())
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const <Map<String, dynamic>>[];
      final decoded = jsonDecode(r.body);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<bool> recordOcrCorrection({
    required String source,
    required String field,
    required String original,
    required String corrected,
  }) async {
    if (original.trim().isEmpty ||
        corrected.trim().isEmpty ||
        original.trim() == corrected.trim()) {
      return false;
    }
    final url = await baseUrl;
    if (url.isEmpty) return false;
    try {
      final r = await http.post(
        Uri.parse('$url/api/ocr/corrections'),
        headers: await _headers(),
        body: jsonEncode({
          'source': source,
          'field': field,
          'original': original,
          'corrected': corrected,
        }),
      ).timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getOcrCorrections(String source) async {
    final url = await baseUrl;
    if (url.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final uri = Uri.parse('$url/api/ocr/corrections').replace(
        queryParameters: {'source': source},
      );
      final r = await http
          .get(uri, headers: await _headers())
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return const <Map<String, dynamic>>[];
      final decoded = jsonDecode(r.body);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> getClients() async {
    final url = await baseUrl;
    if (url.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final r = await http
          .get(
            Uri.parse('$url/api/clients'),
            headers: await _headers(),
          )
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const <Map<String, dynamic>>[];
      final decoded = jsonDecode(r.body);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => (e['name'] ?? '').toString().trim().isNotEmpty)
          .toList();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
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
            (n) => '${n.title} ${n.content} ${n.customerName} ${n.customerPhone} ${n.tags.join(' ')}'
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
    String customerName = '',
    String customerPhone = '',
    List<String> photoPaths = const <String>[],
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
      customerName: customerName,
      customerPhone: normalizePhone(customerPhone),
      photoPaths: photoPaths,
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

  Future<Note> updateNoteManual(
    Note note, {
    String? title,
    String? content,
    String? category,
    List<String>? tags,
  }) async {
    final nextTitle = title ?? note.title;
    final nextContent = content ?? note.content;
    final nextCategory = category ?? note.category;
    final nextTags = tags ?? note.tags;

    if (note.id < 0) {
      final locals = await _loadLocalNotes();
      final index = locals.indexWhere((n) => n.id == note.id);
      if (index < 0) throw Exception('Nota local no encontrada');
      locals[index] = locals[index].copyWith(
        title: nextTitle,
        content: nextContent,
        category: nextCategory,
        tags: nextTags,
      );
      await _saveLocalNotes(locals);
      if (locals[index].remoteId != null) {
        final url = await baseUrl;
        if (url.isNotEmpty) {
          try {
            await http
                .patch(
                  Uri.parse('$url/api/notes/${locals[index].remoteId}'),
                  headers: await _headers(),
                  body: jsonEncode({
                    'title': nextTitle,
                    'content': nextContent,
                    'category': nextCategory,
                    'tags': nextTags,
                  }),
                )
                .timeout(const Duration(seconds: 20));
          } catch (_) {}
        }
      }
      return locals[index];
    }

    final url = await baseUrl;
    if (url.isEmpty) throw Exception('Servidor no configurado');
    final response = await http
        .patch(
          Uri.parse('$url/api/notes/${note.id}'),
          headers: await _headers(),
          body: jsonEncode({
            'title': nextTitle,
            'content': nextContent,
            'category': nextCategory,
            'tags': nextTags,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('No se pudo actualizar (${response.statusCode})');
    }
    return Note.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
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

  Future<Uint8List?> fetchMediaBytes(String path) async {
    final url = await baseUrl;
    if (url.isEmpty || path.trim().isEmpty) return null;
    try {
      final uri = path.startsWith('http')
          ? Uri.parse(path)
          : Uri.parse(url).resolve(path);
      final r = await http
          .get(uri, headers: await _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      return r.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  Future<List<Note>> pendingWhatsAppReplies({int limit = 10}) async {
    final url = await baseUrl;
    if (url.isEmpty) return const <Note>[];

    final safeLimit = limit.clamp(1, 20);
    try {
      final uri = Uri.parse('$url/api/whatsapp/replies/pending').replace(
        queryParameters: {'limit': safeLimit.toString()},
      );
      final r = await http
          .get(uri, headers: await _headers())
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const <Note>[];

      final decoded = jsonDecode(r.body);
      if (decoded is! List) return const <Note>[];
      return decoded
          .whereType<Map>()
          .map((e) => Note.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const <Note>[];
    }
  }

  Future<bool> sendAiReply({
    required int noteId,
    required String body,
  }) async {
    final text = body.trim();
    if (noteId <= 0 || text.isEmpty) return false;

    final url = await baseUrl;
    if (url.isEmpty) return false;

    try {
      final r = await http
          .post(
            Uri.parse('$url/api/whatsapp/replies/$noteId'),
            headers: await _headers(),
            body: jsonEncode({'body': text}),
          )
          .timeout(const Duration(seconds: 30));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> comboStatus() async {
    final url = await baseUrl;
    if (url.isEmpty) return null;
    try {
      final r = await http
          .get(
            Uri.parse('$url/api/combo/status'),
            headers: await _headers(),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body);
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> paqueteriaSnapshot() async {
    final url = await baseUrl;
    if (url.isEmpty) return null;
    try {
      final r = await http
          .get(
            Uri.parse('$url/api/paqueteria/snapshot'),
            headers: await _headers(),
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body);
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
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
