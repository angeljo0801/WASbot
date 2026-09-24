import '../models/note.dart';
import 'ai_provider_service.dart';
import 'api_service.dart';
import 'embedding_service.dart';
import 'knowledge_store.dart';
import 'ocr_purchase_service.dart';

class KnowledgePipelineProgress {
  final int done;
  final int total;
  final String label;
  const KnowledgePipelineProgress(this.done, this.total, this.label);
}

class KnowledgePipeline {
  final ApiService api;
  final AiProviderService ai;
  final KnowledgeStore store;
  final EmbeddingService embeddings;
  late final OcrPurchaseService ocr;

  KnowledgePipeline({
    required this.api,
    required this.ai,
    KnowledgeStore? store,
    EmbeddingService? embeddings,
  })  : store = store ?? KnowledgeStore.instance,
        embeddings = embeddings ??
            EmbeddingService(store: store ?? KnowledgeStore.instance) {
    ocr = OcrPurchaseService(api: api, store: this.store);
  }

  String _allText(Note note, {String ocrText = ''}) => [
        note.title,
        note.content,
        note.originalText,
        note.customerName,
        note.customerPhone,
        note.tags.join(' '),
        ocrText,
      ].where((e) => e.trim().isNotEmpty).join('\n');

  Future<void> _linkKnownEntities(Note note, String ocrText) async {
    final text = store.normalizeName(_allText(note, ocrText: ocrText));
    if (text.isEmpty) return;
    final entities = await store.entities();
    for (final entity in entities) {
      final needle = entity.normalizedName;
      if (needle.length < 3) continue;
      final pattern = RegExp(
        '(^|\\s)' + RegExp.escape(needle) + r'(\s|$)',
        caseSensitive: false,
      );
      if (pattern.hasMatch(text)) {
        await store.linkEntity(
          entity.id,
          KnowledgeStore.noteKey(note),
          relation: 'mencionado',
        );
      }
    }
  }

  Future<void> _linkContactEntity(Note note) async {
    if (note.messageType != 'contact') return;
    final content = note.content;
    final nameMatch = RegExp(
      r'^Nombre:\s*(.+)    final key = KnowledgeStore.noteKey(note);
    if (await store.areEntitiesProcessed(key)) return;
    try {
      final entities = await ai.extractEntities(note);
      for (final raw in entities) {
        final name = (raw['name'] ?? '').trim();
        if (name.isEmpty) continue;
        final entity = await store.upsertEntity(
          name,
          type: (raw['type'] ?? 'persona').trim(),
        );
        await store.linkEntity(
          entity.id,
          key,
          relation: 'detectado',
        );
      }
      await store.saveNoteState(key, entitiesProcessed: true);
    } catch (_) {
      // Keep pending so a later run can retry with another model/provider.
    }
  }

  Future<void> processNotes(
    List<Note> notes, {
    void Function(KnowledgePipelineProgress progress)? onProgress,
    int maxNotes = 40,
  }) async {
    final candidates = notes.take(maxNotes).toList().reversed.toList();
    var done = 0;
    for (final note in candidates) {
      final key = KnowledgeStore.noteKey(note);
      onProgress?.call(
        KnowledgePipelineProgress(done, candidates.length, note.title),
      );

      if (note.messageType == 'image') {
        try {
          await ocr.processImage(note);
        } catch (_) {}
      }

      if (note.messageType == 'text' || note.originalText.trim().isNotEmpty) {
        try {
          await ocr.applyCustomerCorrection(
            note.originalText.trim().isNotEmpty
                ? note.originalText
                : note.content,
            note,
          );
        } catch (_) {}
      }

      if (note.messageType == 'contact') {
        try {
          await _linkContactEntity(note);
        } catch (_) {}
      }

      if (note.customerName.trim().isNotEmpty) {
        try {
          final entity = await store.upsertEntity(
            note.customerName,
            type: 'cliente',
          );
          await store.linkEntity(entity.id, key, relation: 'cliente');
        } catch (_) {}
      }

      final state = await store.noteState(key);
      final ocrText = (state?['ocr_text'] ?? '').toString();
      try {
        await _linkKnownEntities(note, ocrText);
      } catch (_) {}
      await _extractAndLinkEntities(note);

      try {
        await embeddings.indexNote(note, ocrText: ocrText);
      } catch (_) {}

      done++;
      onProgress?.call(
        KnowledgePipelineProgress(done, candidates.length, note.title),
      );
    }
  }
}
,
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(content);
    final phoneMatch = RegExp(
      r'^Tel[eé]fono:\s*(.+)    final key = KnowledgeStore.noteKey(note);
    if (await store.areEntitiesProcessed(key)) return;
    try {
      final entities = await ai.extractEntities(note);
      for (final raw in entities) {
        final name = (raw['name'] ?? '').trim();
        if (name.isEmpty) continue;
        final entity = await store.upsertEntity(
          name,
          type: (raw['type'] ?? 'persona').trim(),
        );
        await store.linkEntity(
          entity.id,
          key,
          relation: 'detectado',
        );
      }
      await store.saveNoteState(key, entitiesProcessed: true);
    } catch (_) {
      // Keep pending so a later run can retry with another model/provider.
    }
  }

  Future<void> processNotes(
    List<Note> notes, {
    void Function(KnowledgePipelineProgress progress)? onProgress,
    int maxNotes = 40,
  }) async {
    final candidates = notes.take(maxNotes).toList().reversed.toList();
    var done = 0;
    for (final note in candidates) {
      final key = KnowledgeStore.noteKey(note);
      onProgress?.call(
        KnowledgePipelineProgress(done, candidates.length, note.title),
      );

      if (note.messageType == 'image') {
        try {
          await ocr.processImage(note);
        } catch (_) {}
      }

      if (note.messageType == 'text' || note.originalText.trim().isNotEmpty) {
        try {
          await ocr.applyCustomerCorrection(
            note.originalText.trim().isNotEmpty
                ? note.originalText
                : note.content,
            note,
          );
        } catch (_) {}
      }

      if (note.customerName.trim().isNotEmpty) {
        try {
          final entity = await store.upsertEntity(
            note.customerName,
            type: 'cliente',
          );
          await store.linkEntity(entity.id, key, relation: 'cliente');
        } catch (_) {}
      }

      final state = await store.noteState(key);
      final ocrText = (state?['ocr_text'] ?? '').toString();
      try {
        await _linkKnownEntities(note, ocrText);
      } catch (_) {}
      await _extractAndLinkEntities(note);

      try {
        await embeddings.indexNote(note, ocrText: ocrText);
      } catch (_) {}

      done++;
      onProgress?.call(
        KnowledgePipelineProgress(done, candidates.length, note.title),
      );
    }
  }
}
,
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(content);
    final name = (nameMatch?.group(1) ?? '').trim();
    if (name.isEmpty) return;
    final phone = (phoneMatch?.group(1) ?? '').trim();
    final entity = await store.upsertEntity(
      name,
      type: 'cliente',
      aliases: phone.isEmpty ? const [] : [phone],
    );
    await store.linkEntity(
      entity.id,
      KnowledgeStore.noteKey(note),
      relation: 'contacto',
    );
    await store.saveNoteState(
      KnowledgeStore.noteKey(note),
      entitiesProcessed: true,
    );
  }

  Future<void> _extractAndLinkEntities(Note note) async {
    final key = KnowledgeStore.noteKey(note);
    if (await store.areEntitiesProcessed(key)) return;
    try {
      final entities = await ai.extractEntities(note);
      for (final raw in entities) {
        final name = (raw['name'] ?? '').trim();
        if (name.isEmpty) continue;
        final entity = await store.upsertEntity(
          name,
          type: (raw['type'] ?? 'persona').trim(),
        );
        await store.linkEntity(
          entity.id,
          key,
          relation: 'detectado',
        );
      }
      await store.saveNoteState(key, entitiesProcessed: true);
    } catch (_) {
      // Keep pending so a later run can retry with another model/provider.
    }
  }

  Future<void> processNotes(
    List<Note> notes, {
    void Function(KnowledgePipelineProgress progress)? onProgress,
    int maxNotes = 40,
  }) async {
    final candidates = notes.take(maxNotes).toList().reversed.toList();
    var done = 0;
    for (final note in candidates) {
      final key = KnowledgeStore.noteKey(note);
      onProgress?.call(
        KnowledgePipelineProgress(done, candidates.length, note.title),
      );

      if (note.messageType == 'image') {
        try {
          await ocr.processImage(note);
        } catch (_) {}
      }

      if (note.messageType == 'text' || note.originalText.trim().isNotEmpty) {
        try {
          await ocr.applyCustomerCorrection(
            note.originalText.trim().isNotEmpty
                ? note.originalText
                : note.content,
            note,
          );
        } catch (_) {}
      }

      if (note.customerName.trim().isNotEmpty) {
        try {
          final entity = await store.upsertEntity(
            note.customerName,
            type: 'cliente',
          );
          await store.linkEntity(entity.id, key, relation: 'cliente');
        } catch (_) {}
      }

      final state = await store.noteState(key);
      final ocrText = (state?['ocr_text'] ?? '').toString();
      try {
        await _linkKnownEntities(note, ocrText);
      } catch (_) {}
      await _extractAndLinkEntities(note);

      try {
        await embeddings.indexNote(note, ocrText: ocrText);
      } catch (_) {}

      done++;
      onProgress?.call(
        KnowledgePipelineProgress(done, candidates.length, note.title),
      );
    }
  }
}
