import 'package:flutter/services.dart';

import 'api_service.dart';

class PayPalEmailNotificationService {
  static const MethodChannel _channel =
      MethodChannel('whatsbot/paypal_email');

  Future<bool> hasAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } catch (_) {
      return false;
    }
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
      final subject = (map['subject'] ?? '').toString().trim();
      final body = (map['body'] ?? '').toString().trim();
      final timestamp = (map['timestamp'] as num?)?.toInt() ?? 0;
      if (id.isEmpty || subject.isEmpty || timestamp <= 0) continue;

      final receivedAt = DateTime.fromMillisecondsSinceEpoch(
        timestamp,
        isUtc: true,
      ).toIso8601String();

      final ok = await api.ingestPayPalRemittanceEmail(
        subject: subject,
        body: body,
        receivedAt: receivedAt,
        emailId: id,
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
