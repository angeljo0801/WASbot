import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import '../models/purchase_draft.dart';
import 'api_service.dart';
import 'knowledge_store.dart';
import 'store_ocr.dart';

class OcrPurchaseResult {
  final PurchaseDraft draft;
  final String ocrText;
  final bool created;
  const OcrPurchaseResult({
    required this.draft,
    required this.ocrText,
    required this.created,
  });
}

class OcrPurchaseService {
  final ApiService api;
  final KnowledgeStore store;

  OcrPurchaseService({
    required this.api,
    KnowledgeStore? store,
  }) : store = store ?? KnowledgeStore.instance;

  Future<String?> _materializeImage(Note note) async {
    final key = KnowledgeStore.noteKey(note);
    final state = await store.noteState(key);
    final cached = (state?['local_media_path'] ?? '').toString();
    if (cached.isNotEmpty && await File(cached).exists()) return cached;

    final original = note.mediaPath?.trim() ?? '';
    if (original.isNotEmpty && await File(original).exists()) {
      await store.saveNoteState(key, localMediaPath: original);
      return original;
    }

    if (original.isEmpty) return null;
    final bytes = await api.fetchMediaBytes(original);
    if (bytes == null || bytes.isEmpty) return null;

    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/inbox_media');
    if (!await folder.exists()) await folder.create(recursive: true);
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    var ext = '.jpg';
    final lower = original.toLowerCase();
    if (lower.contains('.png')) ext = '.png';
    if (lower.contains('.webp')) ext = '.webp';
    final file = File('${folder.path}/$safe$ext');
    await file.writeAsBytes(bytes, flush: true);
    await store.saveNoteState(key, localMediaPath: file.path);
    return file.path;
  }

  Future<OcrPurchaseResult?> processImage(Note note) async {
    if (note.messageType != 'image') return null;
    final key = KnowledgeStore.noteKey(note);
    final existing = await store.draftForNote(key);
    if (await store.isOcrProcessed(key) && existing != null) {
      return OcrPurchaseResult(
        draft: existing,
        ocrText: existing.ocrText,
        created: false,
      );
    }

    final path = await _materializeImage(note);
    if (path == null) return null;

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    String text = '';
    try {
      final recognized =
          await recognizer.processImage(InputImage.fromFilePath(path));
      text = recognized.text.trim();
    } finally {
      await recognizer.close();
    }

    final parsed = StoreOcrParser.parse(text);
    final warnings = <String>[...parsed.warnings];
    final otherDrafts = await store.drafts();
    final normalizedOcr = text
        .toLowerCase()
        .replaceAll(RegExp(r'\\s+'), ' ')
        .trim();
    for (final other in otherDrafts) {
      if (other.noteKey == key || other.status == 'discarded') continue;
      final sameOrder = parsed.orderNumber.trim().isNotEmpty &&
          other.orderNumber.trim().isNotEmpty &&
          parsed.orderNumber.trim().toLowerCase() ==
              other.orderNumber.trim().toLowerCase() &&
          parsed.store.trim().toLowerCase() ==
              other.store.trim().toLowerCase();
      final otherOcr = other.ocrText
          .toLowerCase()
          .replaceAll(RegExp(r'\\s+'), ' ')
          .trim();
      final sameImageText = normalizedOcr.length > 60 &&
          otherOcr.length > 60 &&
          normalizedOcr == otherOcr;
      if (sameOrder || sameImageText) {
        warnings.add(
          'Posible duplicado: ya existe otro borrador con la misma compra. Revísalo antes de confirmar.',
        );
        break;
      }
    }

    final now = DateTime.now();
    final draft = PurchaseDraft(
      id: existing?.id ??
          'draft_${key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}',
      noteKey: key,
      customerName: existing?.customerName ?? note.customerName,
      customerPhone: existing?.customerPhone ?? note.customerPhone,
      store: parsed.store,
      orderNumber: parsed.orderNumber,
      description: parsed.items.isEmpty
          ? note.title
          : parsed.items
              .take(5)
              .map((e) => (e['name'] ?? '').toString())
              .where((e) => e.isNotEmpty)
              .join(', '),
      total: parsed.total,
      subtotal: parsed.subtotal,
      tax: parsed.tax,
      shipping: parsed.shipping,
      discount: parsed.discount,
      items: parsed.items,
      ocrText: text,
      confidence: parsed.confidence,
      warnings: warnings,
      mediaPath: path,
      status: existing?.status ?? 'pending',
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );

    await store.saveDraft(draft);
    await store.saveNoteState(
      key,
      ocrProcessed: true,
      ocrText: text,
      localMediaPath: path,
    );

    if (text.isNotEmpty) {
      final current = note.content.trim();
      final placeholder = current.isEmpty ||
          current == '[Imagen recibida]' ||
          current == '[Archivo recibido]';
      final combined = placeholder
          ? 'OCR automático:\n$text'
          : current.contains(text)
              ? current
              : '$current\n\nOCR automático:\n$text';
      try {
        await api.updateNoteManual(
          note,
          content: combined,
          category: parsed.total > 0 ||
                  parsed.items.isNotEmpty ||
                  parsed.store != 'Otra tienda'
              ? 'Compras'
              : note.category,
          tags: {
            ...note.tags,
            'ocr',
            if (parsed.store != 'Otra tienda') parsed.store.toLowerCase(),
          }.toList(),
        );
      } catch (_) {}
    }

    return OcrPurchaseResult(
      draft: draft,
      ocrText: text,
      created: existing == null,
    );
  }

  String? customerCorrection(String text) {
    var clean = text.trim();
    clean = clean.replaceAll(RegExp(r'[.!?,;:]+$'), '').trim();
    final patterns = <RegExp>[
      RegExp(
        r'^(?:esto|eso|esta|esa|la foto|el pedido|la compra)\s+(?:es|son)\s+(?:de|para)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:es|son)\s+(?:de|para)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:ponlo|ponla|cambialo|cámbialo|cambiala|cámbiala)\s+(?:a nombre de|para|de)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^las?\s+(?:últimas?|ultimas?)\s+(?:\d+\s+)?fotos?\s+son\s+de\s+(.+)$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(clean);
      if (match == null) continue;
      final name = (match.group(1) ?? '').trim();
      if (name.isEmpty || name.length > 80) return null;
      return name;
    }
    return null;
  }

  Future<PurchaseDraft?> applyCustomerCorrection(
    String message,
    Note messageNote,
  ) async {
    final name = customerCorrection(message);
    if (name == null) return null;
    final pending = await store.latestPendingDraft();
    if (pending == null) return null;

    final warnings = <String>[...pending.warnings];
    final matches = await store.entities(query: name);
    final exactOrPrefix = matches
        .where(
          (e) =>
              e.type == 'cliente' &&
              (e.normalizedName == store.normalizeName(name) ||
                  e.normalizedName.startsWith(store.normalizeName(name) + ' ')),
        )
        .toList();
    if (exactOrPrefix.length > 1 &&
        !warnings.any((w) => w.startsWith('Nombre ambiguo:'))) {
      warnings.add(
        'Nombre ambiguo: hay varios clientes relacionados con “$name”. Confirma el cliente correcto antes de enviar a Paquetería.',
      );
    }

    final updated = pending.copyWith(
      customerName: name,
      warnings: warnings,
    );
    await store.saveDraft(updated);

    final entity = await store.upsertEntity(name, type: 'cliente');
    await store.linkEntity(
      entity.id,
      pending.noteKey,
      relation: 'cliente',
    );
    await store.linkEntity(
      entity.id,
      KnowledgeStore.noteKey(messageNote),
      relation: 'corrección',
    );
    return updated;
  }
}
