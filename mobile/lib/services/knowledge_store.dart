import 'dart:convert';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/entity_record.dart';
import '../models/note.dart';
import '../models/purchase_draft.dart';

class KnowledgeStore {
  static final KnowledgeStore instance = KnowledgeStore._();
  KnowledgeStore._();

  Database? _database;

  static String noteKey(Note note) {
    if (note.remoteId != null) return 'remote:${note.remoteId}';
    return 'note:${note.id}';
  }

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;
    final docs = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      '${docs.path}/whatsbot_knowledge.db',
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE note_state(
            note_key TEXT PRIMARY KEY,
            ocr_processed INTEGER NOT NULL DEFAULT 0,
            ocr_text TEXT NOT NULL DEFAULT '',
            local_media_path TEXT NOT NULL DEFAULT '',
            entities_processed INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE embeddings(
            note_key TEXT PRIMARY KEY,
            fingerprint TEXT NOT NULL,
            vector BLOB NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE entities(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            normalized_name TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'persona',
            aliases_json TEXT NOT NULL DEFAULT '[]',
            updated_at TEXT NOT NULL,
            UNIQUE(normalized_name, type)
          )
        ''');
        await db.execute('''
          CREATE TABLE entity_notes(
            entity_id TEXT NOT NULL,
            note_key TEXT NOT NULL,
            relation TEXT NOT NULL DEFAULT 'relacionado',
            created_at TEXT NOT NULL,
            PRIMARY KEY(entity_id, note_key)
          )
        ''');
        await db.execute('''
          CREATE TABLE purchase_drafts(
            id TEXT PRIMARY KEY,
            note_key TEXT NOT NULL UNIQUE,
            data_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE chat_messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
      },
    );
    _database = db;
    return db;
  }

  String normalizeName(String value) {
    var s = value.trim().toLowerCase();
    const from = 'áéíóúüñàèìòùäëïöü';
    const to = 'aeiouunaeiouaeiou';
    for (var i = 0; i < from.length; i++) {
      s = s.replaceAll(from[i], to[i]);
    }
    s = s.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _idFor(String type, String normalized) {
    var hash = 2166136261;
    for (final unit in utf8.encode('$type|$normalized')) {
      hash ^= unit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return '${type}_${hash.toRadixString(16)}';
  }

  Future<Map<String, dynamic>?> noteState(String noteKey) async {
    final db = await database;
    final rows = await db.query(
      'note_state',
      where: 'note_key = ?',
      whereArgs: [noteKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveNoteState(
    String noteKey, {
    bool? ocrProcessed,
    String? ocrText,
    String? localMediaPath,
    bool? entitiesProcessed,
  }) async {
    final db = await database;
    final current = await noteState(noteKey) ?? const <String, dynamic>{};
    await db.insert(
      'note_state',
      {
        'note_key': noteKey,
        'ocr_processed': ocrProcessed == null
            ? (current['ocr_processed'] ?? 0)
            : (ocrProcessed ? 1 : 0),
        'ocr_text': ocrText ?? (current['ocr_text'] ?? ''),
        'local_media_path':
            localMediaPath ?? (current['local_media_path'] ?? ''),
        'entities_processed': entitiesProcessed == null
            ? (current['entities_processed'] ?? 0)
            : (entitiesProcessed ? 1 : 0),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> isOcrProcessed(String noteKey) async =>
      ((await noteState(noteKey))?['ocr_processed'] as num?)?.toInt() == 1;

  Future<bool> areEntitiesProcessed(String noteKey) async =>
      ((await noteState(noteKey))?['entities_processed'] as num?)?.toInt() == 1;

  Future<void> saveEmbedding(
    String noteKey,
    String fingerprint,
    Uint8List vector,
  ) async {
    final db = await database;
    await db.insert(
      'embeddings',
      {
        'note_key': noteKey,
        'fingerprint': fingerprint,
        'vector': vector,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> embedding(String noteKey) async {
    final db = await database;
    final rows = await db.query(
      'embeddings',
      where: 'note_key = ?',
      whereArgs: [noteKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Uint8List>> allEmbeddingVectors() async {
    final db = await database;
    final rows = await db.query('embeddings');
    return {
      for (final row in rows)
        row['note_key']!.toString(): row['vector'] as Uint8List,
    };
  }

  Future<EntityRecord> upsertEntity(
    String name, {
    String type = 'persona',
    List<String> aliases = const [],
  }) async {
    final cleanName = name.trim();
    final normalized = normalizeName(cleanName);
    if (normalized.isEmpty) {
      throw ArgumentError('Nombre de entidad vacío');
    }
    final db = await database;
    final existing = await db.query(
      'entities',
      where: 'normalized_name = ? AND type = ?',
      whereArgs: [normalized, type],
      limit: 1,
    );
    final now = DateTime.now().toUtc().toIso8601String();
    if (existing.isNotEmpty) {
      final row = existing.first;
      final currentAliases = <String>{
        ...((jsonDecode((row['aliases_json'] ?? '[]').toString()) as List)
            .map((e) => e.toString())),
        ...aliases.map((e) => e.trim()).where((e) => e.isNotEmpty),
      };
      await db.update(
        'entities',
        {
          'name': cleanName.isEmpty ? row['name'] : cleanName,
          'aliases_json': jsonEncode(currentAliases.toList()),
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      return EntityRecord(
        id: row['id'].toString(),
        name: cleanName.isEmpty ? row['name'].toString() : cleanName,
        normalizedName: normalized,
        type: type,
        aliases: currentAliases.toList(),
        updatedAt: DateTime.parse(now),
      );
    }

    final id = _idFor(type, normalized);
    await db.insert(
      'entities',
      {
        'id': id,
        'name': cleanName,
        'normalized_name': normalized,
        'type': type,
        'aliases_json': jsonEncode(
          aliases.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        ),
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return EntityRecord(
      id: id,
      name: cleanName,
      normalizedName: normalized,
      type: type,
      aliases: aliases,
      updatedAt: DateTime.parse(now),
    );
  }

  Future<void> linkEntity(
    String entityId,
    String noteKey, {
    String relation = 'relacionado',
  }) async {
    final db = await database;
    await db.insert(
      'entity_notes',
      {
        'entity_id': entityId,
        'note_key': noteKey,
        'relation': relation,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<EntityRecord>> entities({String query = ''}) async {
    final db = await database;
    final args = <Object?>[];
    var where = '';
    if (query.trim().isNotEmpty) {
      where = 'WHERE e.name LIKE ? OR e.normalized_name LIKE ?';
      final q = '%${query.trim()}%';
      args.addAll([q, '%${normalizeName(query)}%']);
    }
    final rows = await db.rawQuery(
      '''
      SELECT e.*, COUNT(en.note_key) AS note_count
      FROM entities e
      LEFT JOIN entity_notes en ON en.entity_id = e.id
      $where
      GROUP BY e.id
      ORDER BY e.name COLLATE NOCASE
      ''',
      args,
    );
    return rows.map((row) {
      List<String> aliases = [];
      try {
        aliases = (jsonDecode((row['aliases_json'] ?? '[]').toString()) as List)
            .map((e) => e.toString())
            .toList();
      } catch (_) {}
      return EntityRecord.fromMap({...row, 'aliases': aliases});
    }).toList();
  }

  Future<EntityRecord?> findEntityByName(String name) async {
    final normalized = normalizeName(name);
    if (normalized.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'entities',
      where: 'normalized_name = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    List<String> aliases = [];
    try {
      aliases = (jsonDecode((row['aliases_json'] ?? '[]').toString()) as List)
          .map((e) => e.toString())
          .toList();
    } catch (_) {}
    return EntityRecord.fromMap({...row, 'aliases': aliases});
  }

  Future<List<String>> noteKeysForEntity(String entityId) async {
    final db = await database;
    final rows = await db.query(
      'entity_notes',
      columns: ['note_key'],
      where: 'entity_id = ?',
      whereArgs: [entityId],
      orderBy: 'created_at DESC',
    );
    return rows.map((e) => e['note_key'].toString()).toList();
  }

  Future<void> saveDraft(PurchaseDraft draft) async {
    final db = await database;
    await db.insert(
      'purchase_drafts',
      {
        'id': draft.id,
        'note_key': draft.noteKey,
        'data_json': draft.encode(),
        'status': draft.status,
        'updated_at': draft.updatedAt.toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<PurchaseDraft?> draftForNote(String noteKey) async {
    final db = await database;
    final rows = await db.query(
      'purchase_drafts',
      where: 'note_key = ?',
      whereArgs: [noteKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      return PurchaseDraft.decode(rows.first['data_json'].toString());
    } catch (_) {
      return null;
    }
  }

  Future<List<PurchaseDraft>> drafts({String? status}) async {
    final db = await database;
    final rows = await db.query(
      'purchase_drafts',
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status],
      orderBy: 'datetime(updated_at) DESC',
    );
    final out = <PurchaseDraft>[];
    for (final row in rows) {
      try {
        out.add(PurchaseDraft.decode(row['data_json'].toString()));
      } catch (_) {}
    }
    return out;
  }

  Future<PurchaseDraft?> latestPendingDraft() async {
    final list = await drafts(status: 'pending');
    return list.isEmpty ? null : list.first;
  }

  Future<void> addChatMessage(String role, String text) async {
    final db = await database;
    await db.insert('chat_messages', {
      'role': role,
      'text': text,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> chatMessages({int limit = 60}) async {
    final db = await database;
    final rows = await db.query(
      'chat_messages',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.toList();
  }

  Future<void> clearChat() async {
    final db = await database;
    await db.delete('chat_messages');
  }
}
