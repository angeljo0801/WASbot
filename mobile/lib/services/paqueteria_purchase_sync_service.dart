import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

class PaqueteriaPurchaseSyncService {
  static const _queueKey = 'paqueteria_purchase_sync_queue';

  final ApiService api;

  PaqueteriaPurchaseSyncService(this.api);

  Future<List<Map<String, dynamic>>> _queue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveQueue(List<Map<String, dynamic>> queue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, jsonEncode(queue));
  }

  Future<void> enqueue({
    required String externalId,
    required String customerName,
    required String customerPhone,
    required String title,
    required String description,
    required List<String> photoPaths,
    String store = 'WhatsBot',
    double total = 0,
    String orderNumber = '',
    List<Map<String, dynamic>> items = const <Map<String, dynamic>>[],
    String ocrText = '',
    Map<String, dynamic> ocrMeta = const <String, dynamic>{},
    DateTime? createdAt,
  }) async {
    final queue = await _queue();
    final item = <String, dynamic>{
      'external_id': externalId,
      'customer_name': customerName.trim(),
      'customer_phone': api.normalizePhone(customerPhone),
      'title': title.trim(),
      'description': description.trim(),
      'store': store.trim().isEmpty ? 'WhatsBot' : store.trim(),
      'total': total,
      'order_number': orderNumber.trim(),
      'items': items,
      'ocr_text': ocrText,
      'ocr_meta': ocrMeta,
      'photo_paths': photoPaths,
      'created_at': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
    };
    final index = queue.indexWhere((e) => e['external_id'] == externalId);
    if (index >= 0) {
      queue[index] = item;
    } else {
      queue.add(item);
    }
    await _saveQueue(queue);
    await flush();
  }

  Future<int> flush() async {
    final url = await api.baseUrl;
    if (url.isEmpty) return 0;
    final key = await api.apiKey;
    var queue = await _queue();
    if (queue.isEmpty) return 0;
    var synced = 0;
    final pending = <Map<String, dynamic>>[];

    for (final item in queue) {
      try {
        final photos = <Map<String, String>>[];
        final paths = ((item['photo_paths'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty);
        for (final path in paths) {
          final file = File(path);
          if (!await file.exists()) continue;
          final bytes = await file.readAsBytes();
          if (bytes.length > 8 * 1024 * 1024) continue;
          photos.add({
            'name': file.uri.pathSegments.isEmpty
                ? 'purchase.jpg'
                : file.uri.pathSegments.last,
            'data': base64Encode(bytes),
          });
        }

        final body = {
          'external_id': item['external_id'],
          'customer_name': item['customer_name'],
          'customer_phone': item['customer_phone'],
          'title': item['title'],
          'description': item['description'],
          'store': item['store'],
          'total': item['total'],
          'order_number': item['order_number'] ?? '',
          'items': item['items'] ?? const <Map<String, dynamic>>[],
          'ocr_text': item['ocr_text'] ?? '',
          'ocr_meta': item['ocr_meta'] ?? const <String, dynamic>{},
          'created_at': item['created_at'],
          'photos': photos,
        };
        final response = await http
            .post(
              Uri.parse('$url/api/purchases'),
              headers: {
                'Content-Type': 'application/json',
                'x-api-key': key,
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 30));
        if (response.statusCode == 200 || response.statusCode == 201) {
          synced++;
        } else {
          pending.add(item);
        }
      } catch (_) {
        pending.add(item);
      }
    }
    queue = pending;
    await _saveQueue(queue);
    return synced;
  }

  Future<int> pendingCount() async => (await _queue()).length;
}
