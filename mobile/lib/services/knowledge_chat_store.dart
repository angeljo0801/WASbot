import 'dart:convert';
import 'dart:io';

import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class KnowledgeChatMessage {
  final String role;
  final String text;
  final DateTime createdAt;
  final List<String> sourceKeys;
  final double? responseSeconds;

  const KnowledgeChatMessage({
    required this.role,
    required this.text,
    required this.createdAt,
    this.sourceKeys = const [],
    this.responseSeconds,
  });

  KnowledgeChatMessage copyWith({
    String? text,
    List<String>? sourceKeys,
    double? responseSeconds,
  }) =>
      KnowledgeChatMessage(
        role: role,
        text: text ?? this.text,
        createdAt: createdAt,
        sourceKeys: sourceKeys ?? this.sourceKeys,
        responseSeconds: responseSeconds ?? this.responseSeconds,
      );

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'sourceKeys': sourceKeys,
        if (responseSeconds != null) 'responseSeconds': responseSeconds,
      };

  factory KnowledgeChatMessage.fromJson(Map<String, dynamic> json) =>
      KnowledgeChatMessage(
        role: json['role']?.toString() == 'assistant' ? 'assistant' : 'user',
        text: json['text']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        sourceKeys: (json['sourceKeys'] is List)
            ? (json['sourceKeys'] as List)
                .map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList()
            : const [],
        responseSeconds: (json['responseSeconds'] as num?)?.toDouble(),
      );
}

class KnowledgeChatSession {
  final String id;
  final String ownerType;
  final String ownerId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<KnowledgeChatMessage> messages;

  const KnowledgeChatSession({
    required this.id,
    required this.ownerType,
    required this.ownerId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
  });

  factory KnowledgeChatSession.empty({
    required String ownerType,
    required String ownerId,
  }) {
    final now = DateTime.now();
    return KnowledgeChatSession(
      id: 'chat_${now.microsecondsSinceEpoch}',
      ownerType: ownerType,
      ownerId: ownerId,
      title: 'Nuevo chat',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
  }

  KnowledgeChatSession copyWith({
    String? title,
    DateTime? updatedAt,
    List<KnowledgeChatMessage>? messages,
  }) =>
      KnowledgeChatSession(
        id: id,
        ownerType: ownerType,
        ownerId: ownerId,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        messages: messages ?? this.messages,
      );

  String conversationContext({
    int maxChars = 6500,
    int maxMessages = 14,
  }) {
    if (messages.isEmpty) return '(Sin mensajes anteriores)';
    final selected = messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    final chunks = <String>[];
    var used = 0;
    for (final message in selected.reversed) {
      final clean = message.text.trim();
      if (clean.isEmpty) continue;
      final label = message.role == 'assistant' ? 'ASISTENTE' : 'USUARIO';
      final line = '$label: $clean';
      final remaining = maxChars - used;
      if (remaining <= 80) break;
      final clipped =
          line.length > remaining ? line.substring(0, remaining) : line;
      chunks.add(clipped);
      used += clipped.length + 1;
    }
    return chunks.reversed.join('\n');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'ownerType': ownerType,
        'ownerId': ownerId,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory KnowledgeChatSession.fromJson(Map<String, dynamic> json) =>
      KnowledgeChatSession(
        id: json['id']?.toString() ?? '',
        ownerType: json['ownerType']?.toString() ?? 'knowledge',
        ownerId: json['ownerId']?.toString() ?? 'main',
        title: json['title']?.toString() ?? 'Chat',
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
            DateTime.now(),
        messages: (json['messages'] is List)
            ? (json['messages'] as List)
                .whereType<Map>()
                .map((e) => KnowledgeChatMessage.fromJson(
                      Map<String, dynamic>.from(e),
                    ))
                .toList()
            : const [],
      );

  static String titleFrom(String text, {String fallback = 'Nuevo chat'}) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return fallback;
    return clean.length <= 46
        ? clean
        : '${clean.substring(0, 46).trim()}…';
  }
}

class KnowledgeChatStore {
  static Future<File> _file() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/knowledge_chat');
    await dir.create(recursive: true);
    return File('${dir.path}/sessions.json');
  }

  static Future<List<KnowledgeChatSession>> loadAll() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => KnowledgeChatSession.fromJson(
                Map<String, dynamic>.from(e),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<KnowledgeChatSession>> listFor(
    String ownerType,
    String ownerId,
  ) async {
    final all = await loadAll();
    final result = all
        .where((s) => s.ownerType == ownerType && s.ownerId == ownerId)
        .toList();
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  static Future<void> save(KnowledgeChatSession session) async {
    final all = await loadAll();
    final index = all.indexWhere((s) => s.id == session.id);
    if (index >= 0) {
      all[index] = session;
    } else {
      all.add(session);
    }
    await (await _file()).writeAsString(
      jsonEncode(all.map((s) => s.toJson()).toList()),
      flush: true,
    );
  }

  static Future<void> delete(String sessionId) async {
    final all = await loadAll();
    all.removeWhere((s) => s.id == sessionId);
    await (await _file()).writeAsString(
      jsonEncode(all.map((s) => s.toJson()).toList()),
      flush: true,
    );
  }

  static Future<String?> exportPdf(
    KnowledgeChatSession session, {
    required String participantName,
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (_) => [
          pw.Text(
            session.title,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.Text('WhatsBot chat • $participantName'),
          pw.SizedBox(height: 18),
          ...session.messages
              .where((m) => m.text.trim().isNotEmpty)
              .map(
                (m) => pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 12),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        m.role == 'user' ? 'Tú' : participantName,
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(m.text),
                      if (m.responseSeconds != null &&
                          m.role == 'assistant')
                        pw.Text(
                          '${m.responseSeconds!.toStringAsFixed(1)} s',
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );

    final root = await getTemporaryDirectory();
    final safe = session.title.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final file = File(
      '${root.path}/WhatsBot_${safe}_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes(await doc.save(), flush: true);
    return FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        sourceFilePath: file.path,
        fileName: 'WhatsBot_$safe.pdf',
      ),
    );
  }
}
