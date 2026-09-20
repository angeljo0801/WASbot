import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note.dart';

class ApiService {
  static const _urlKey = 'backend_url';
  static const _apiKeyKey = 'backend_api_key';
  static const _cacheKey = 'notes_cache';

  Future<String> get baseUrl async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_urlKey) ?? 'http://10.0.2.2:8080').replaceAll(RegExp(r'/$'), '');
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

  Future<Map<String, String>> settings() async => {'url': await baseUrl, 'key': await apiKey};

  Future<Map<String, String>> _headers() async => {
        'Content-Type': 'application/json',
        'x-api-key': await apiKey,
      };

  Future<List<Note>> getNotes({String query = '', String category = ''}) async {
    try {
      final url = await baseUrl;
      final uri = Uri.parse('$url/api/notes').replace(queryParameters: {
        if (query.trim().isNotEmpty) 'q': query.trim(),
        if (category.isNotEmpty && category != 'Todas') 'category': category,
      });
      final r = await http.get(uri, headers: await _headers()).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('Servidor ${r.statusCode}');
      final list = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      final notes = list.map(Note.fromJson).toList();
      final p = await SharedPreferences.getInstance();
      await p.setString(_cacheKey, jsonEncode(notes.map((e) => e.toJson()).toList()));
      return notes;
    } catch (_) {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_cacheKey);
      if (raw == null) rethrow;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      var notes = list.map(Note.fromJson).toList();
      if (query.trim().isNotEmpty) {
        final q = query.toLowerCase();
        notes = notes.where((n) => '${n.title} ${n.content} ${n.tags.join(' ')}'.toLowerCase().contains(q)).toList();
      }
      if (category.isNotEmpty && category != 'Todas') notes = notes.where((n) => n.category == category).toList();
      return notes;
    }
  }

  Future<void> createNote({required String title, required String content, required String category}) async {
    final url = await baseUrl;
    final r = await http.post(Uri.parse('$url/api/notes'), headers: await _headers(), body: jsonEncode({
      'title': title,
      'content': content,
      'original_text': content,
      'category': category,
      'tags': <String>[],
    })).timeout(const Duration(seconds: 12));
    if (r.statusCode != 201) throw Exception('No se pudo guardar (${r.statusCode})');
  }

  Future<Note> updateNoteFromAi({
    required int id,
    required String title,
    required String content,
    required String category,
    required List<String> tags,
    required String aiProvider,
  }) async {
    final url = await baseUrl;
    final r = await http.patch(
      Uri.parse('$url/api/notes/$id'),
      headers: await _headers(),
      body: jsonEncode({
        'title': title,
        'content': content,
        'category': category,
        'tags': tags,
        'status': 'ready',
        'ai_provider': aiProvider,
      }),
    ).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw Exception('No se pudo actualizar (${r.statusCode})');
    return Note.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteNote(int id) async {
    final url = await baseUrl;
    final r = await http.delete(Uri.parse('$url/api/notes/$id'), headers: await _headers()).timeout(const Duration(seconds: 12));
    if (r.statusCode != 204) throw Exception('No se pudo borrar (${r.statusCode})');
  }

  Future<bool> health() async {
    try {
      final url = await baseUrl;
      final r = await http.get(Uri.parse('$url/health')).timeout(const Duration(seconds: 8));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
