import 'package:flutter/services.dart';

import 'api_service.dart';

class RemittanceSmsService {
  static const MethodChannel _channel = MethodChannel('whatsbot/sms');

  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (_) {}
  }

  Future<int> syncPending(ApiService api) async {
    List<dynamic> raw;
    try {
      raw = await _channel.invokeMethod<List<dynamic>>('pending') ?? const [];
    } catch (_) {
      return 0;
    }

    var synced = 0;
    final ack = <String>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = (map['id'] ?? '').toString();
      final body = (map['body'] ?? '').toString().trim();
      final timestamp = (map['timestamp'] as num?)?.toInt() ?? 0;
      if (id.isEmpty || body.isEmpty || timestamp <= 0) continue;

      final receivedAt = DateTime.fromMillisecondsSinceEpoch(
        timestamp,
        isUtc: true,
      ).toIso8601String();
      final ok = await api.ingestRemittanceSms(
        text: body,
        receivedAt: receivedAt,
        smsId: id,
      );
      if (ok) {
        ack.add(id);
        synced++;
      }
    }

    if (ack.isNotEmpty) {
      try {
        await _channel.invokeMethod('ack', ack);
      } catch (_) {}
    }
    return synced;
  }
}
