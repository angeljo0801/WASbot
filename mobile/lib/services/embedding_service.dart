import 'dart:math' as math;
import 'dart:typed_data';

import 'package:betto_inferencing/betto_inferencing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';
import 'knowledge_store.dart';

class EmbeddingDownloadProgress {
  final int received;
  final int total;
  const EmbeddingDownloadProgress(this.received, this.total);

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

class SemanticHit {
  final Note note;
  final double score;
  const SemanticHit(this.note, this.score);
}

class EmbeddingService {
  static const modelId = 'multilingual-e5-small';
  static const _readyKey = 'embedding_model_ready_v1';

  final KnowledgeStore store;
  OnnxEmbeddingModel? _model;
  bool _loading = false;

  EmbeddingService({KnowledgeStore? store})
      : store = store ?? KnowledgeStore.instance;

  bool get isLoaded => _model != null;
  bool get isLoading => _loading;

  Future<String> cacheDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/embedding_models';
  }

  Future<bool> isReady() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_readyKey) ?? false;
  }

  Future<void> downloadModel({
    void Function(EmbeddingDownloadProgress progress)? onProgress,
  }) async {
    await _load(
      allowDownload: true,
      onProgress: onProgress,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_readyKey, true);
  }

  Future<OnnxEmbeddingModel?> _load({
    required bool allowDownload,
    void Function(EmbeddingDownloadProgress progress)? onProgress,
  }) async {
    if (_model != null) return _model;
    if (_loading) {
      while (_loading) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return _model;
    }
    if (!allowDownload && !await isReady()) return null;

    _loading = true;
    try {
      final spec = ModelCatalog.lookup(modelId);
      final model = await OnnxEmbeddingModel.load(
        spec: spec,
        cacheDir: await cacheDirectory(),
        onProgress: (received, total) {
          onProgress?.call(EmbeddingDownloadProgress(received, total));
        },
      );
      _model = model;
      return model;
    } finally {
      _loading = false;
    }
  }

  String fingerprint(String text) {
    var hash = 2166136261;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  String noteText(Note note, {String ocrText = ''}) {
    final pieces = <String>[
      note.title,
      note.content,
      note.originalText,
      note.customerName,
      note.customerPhone,
      note.tags.join(' '),
      ocrText,
    ].map((e) => e.trim()).where((e) => e.isNotEmpty);
    return pieces.join('\n');
  }

  Future<bool> indexNote(Note note, {String ocrText = ''}) async {
    final model = await _load(allowDownload: false);
    if (model == null) return false;

    final key = KnowledgeStore.noteKey(note);
    final text = noteText(note, ocrText: ocrText);
    if (text.trim().isEmpty) return false;
    final fp = fingerprint(text);
    final current = await store.embedding(key);
    if (current != null && current['fingerprint']?.toString() == fp) {
      return false;
    }

    final (vector, _) = await model.embed(
      text,
      kind: EmbeddingKind.document,
    );
    await store.saveEmbedding(key, fp, quantise(vector));
    return true;
  }

  Future<int> indexAll(
    List<Note> notes, {
    void Function(int done, int total)? onProgress,
  }) async {
    final model = await _load(allowDownload: false);
    if (model == null) return 0;
    var changed = 0;
    var done = 0;
    for (final note in notes) {
      final state = await store.noteState(KnowledgeStore.noteKey(note));
      final ocr = (state?['ocr_text'] ?? '').toString();
      if (await indexNote(note, ocrText: ocr)) changed++;
      done++;
      onProgress?.call(done, notes.length);
    }
    return changed;
  }

  Future<List<SemanticHit>> search(
    String query,
    List<Note> notes, {
    int limit = 8,
    Set<String>? restrictKeys,
  }) async {
    final clean = query.trim();
    if (clean.isEmpty) return const [];
    final model = await _load(allowDownload: false);
    if (model == null) {
      return _lexicalSearch(clean, notes,
          limit: limit, restrictKeys: restrictKeys);
    }

    final (queryVector, _) = await model.embed(
      clean,
      kind: EmbeddingKind.query,
    );
    final vectors = await store.allEmbeddingVectors();
    final candidates = <SemanticHit>[];
    for (final note in notes) {
      final key = KnowledgeStore.noteKey(note);
      if (restrictKeys != null && !restrictKeys.contains(key)) continue;
      final packed = vectors[key];
      if (packed == null) continue;
      final doc = dequantise(packed);
      final n = math.min(queryVector.length, doc.length);
      var score = 0.0;
      for (var i = 0; i < n; i++) {
        score += queryVector[i] * doc[i];
      }
      candidates.add(SemanticHit(note, score));
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.take(limit).toList();
  }

  List<SemanticHit> _lexicalSearch(
    String query,
    List<Note> notes, {
    required int limit,
    Set<String>? restrictKeys,
  }) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9áéíóúüñ]+', caseSensitive: false))
        .where((e) => e.length > 1)
        .toSet();
    final hits = <SemanticHit>[];
    for (final note in notes) {
      final key = KnowledgeStore.noteKey(note);
      if (restrictKeys != null && !restrictKeys.contains(key)) continue;
      final haystack = noteText(note).toLowerCase();
      var score = 0.0;
      for (final word in words) {
        if (haystack.contains(word)) score += 1.0;
      }
      if (score > 0) hits.add(SemanticHit(note, score));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  Future<void> dispose() async {
    final model = _model;
    _model = null;
    model?.dispose();
  }
}
