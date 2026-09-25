import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

class PaqueteriaPurchaseShareResult {
  final bool uploaded;
  final bool pending;
  final int pendingCount;
  final String message;

  const PaqueteriaPurchaseShareResult({
    required this.uploaded,
    required this.pending,
    required this.pendingCount,
    required this.message,
  });
}

class PaqueteriaPurchaseSyncService {
  static const _queueKey = 'paqueteria_purchase_sync_queue';
  static const _lastErrorKey = 'paqueteria_purchase_sync_last_error';

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

  Future<PaqueteriaPurchaseShareResult> enqueue({
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

    final remaining = await _queue();
    final stillPending = remaining.any(
      (entry) => entry['external_id'] == externalId,
    );
    final prefs = await SharedPreferences.getInstance();
    final lastError = (prefs.getString(_lastErrorKey) ?? '').trim();
    final url = await api.baseUrl;
    final key = await api.apiKey;

    if (!stillPending) {
      return PaqueteriaPurchaseShareResult(
        uploaded: true,
        pending: false,
        pendingCount: remaining.length,
        message:
            'WhatsBot compartió la compra con el puente de Paquetería.',
      );
    }

    var message = 'La compra quedó pendiente de sincronizar con Paquetería.';
    if (url.trim().isEmpty) {
      message = 'Configura el servidor de WhatsBot para compartir con Paquetería.';
    } else if (key.trim().isEmpty) {
      message = 'Falta la clave de sincronización para compartir con Paquetería.';
    } else if (lastError.isNotEmpty) {
      message = 'No se pudo compartir ahora: $lastError';
    }

    return PaqueteriaPurchaseShareResult(
      uploaded: false,
      pending: true,
      pendingCount: remaining.length,
      message: message,
    );
  }

  Future<int> flush() async {
    final prefs = await SharedPreferences.getInstance();
    final url = await api.baseUrl;
    if (url.isEmpty) {
      await prefs.setString(_lastErrorKey, 'servidor no configurado');
      return 0;
    }
    final key = await api.apiKey;
    if (key.isEmpty) {
      await prefs.setString(_lastErrorKey, 'clave de sincronización vacía');
      return 0;
    }
    var queue = await _queue();
    if (queue.isEmpty) {
      await prefs.remove(_lastErrorKey);
      return 0;
    }
    var synced = 0;
    var lastError = '';
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
          final body = response.body.trim();
          final shortBody = body.length > 180 ? body.substring(0, 180) : body;
          lastError = 'servidor respondió ${response.statusCode}' +
              (shortBody.isEmpty ? '' : ': $shortBody');
        }
      } catch (e) {
        pending.add(item);
        lastError = e.toString();
      }
    }
    queue = pending;
    await _saveQueue(queue);
    if (lastError.isEmpty) {
      await prefs.remove(_lastErrorKey);
    } else {
      await prefs.setString(_lastErrorKey, lastError);
    }
    return synced;
  }

  Future<int> pendingCount() async => (await _queue()).length;
}
