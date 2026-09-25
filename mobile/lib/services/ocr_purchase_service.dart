import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import '../models/purchase_draft.dart';
import 'api_service.dart';
import 'knowledge_store.dart';
import 'photo_storage_service.dart';
import 'remittance_ocr.dart';
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
  final PhotoStorageService photoStorage = PhotoStorageService.instance;

  OcrPurchaseService({
    required this.api,
    KnowledgeStore? store,
  }) : store = store ?? KnowledgeStore.instance;

  String? _learnedValue(
    List<Map<String, dynamic>> hints,
    String field,
    String original, {
    int minOccurrences = 1,
  }) {
    final clean = original.trim();
    if (clean.isEmpty) return null;
    for (final hint in hints) {
      if ((hint['field_name'] ?? '').toString() != field) continue;
      if ((hint['original_value'] ?? '').toString().trim() != clean) continue;
      final occurrences = (hint['occurrences'] as num?)?.toInt() ?? 0;
      if (occurrences < minOccurrences) continue;
      final corrected = (hint['corrected_value'] ?? '').toString().trim();
      if (corrected.isNotEmpty) return corrected;
    }
    return null;
  }

  Future<RemittanceOcrParse> _applyRemittanceLearning(
    RemittanceOcrParse parsed,
  ) async {
    if (!parsed.isRemittance || parsed.source.trim().isEmpty) return parsed;
    final hints = await api.getOcrCorrections(parsed.source);
    if (hints.isEmpty) return parsed;

    final learnedName = _learnedValue(hints, 'name', parsed.name);
    final amountOriginal =
        parsed.amount > 0 ? parsed.amount.toStringAsFixed(2) : '';
    final learnedAmount =
        _learnedValue(hints, 'amount', amountOriginal);
    final learnedDate = _learnedValue(hints, 'date', parsed.date);

    return RemittanceOcrParse(
      isRemittance: parsed.isRemittance,
      source: parsed.source,
      name: learnedName ?? parsed.name,
      amount: double.tryParse(learnedAmount ?? '') ?? parsed.amount,
      date: learnedDate ?? parsed.date,
      confidence: parsed.confidence,
      warnings: [
        ...parsed.warnings,
        if (learnedName != null ||
            learnedAmount != null ||
            learnedDate != null)
          'Se aplicó una corrección aprendida de revisiones anteriores.',
      ],
    );
  }

  Future<StoreOcrParse> _applyStoreLearning(StoreOcrParse parsed) async {
    if (parsed.store.trim().isEmpty) return parsed;
    final hints = await api.getOcrCorrections(parsed.store);
    if (hints.isEmpty) return parsed;

    final totalOriginal =
        parsed.total > 0 ? parsed.total.toStringAsFixed(2) : '';
    final learnedTotal = _learnedValue(hints, 'total', totalOriginal);
    final learnedOrder =
        _learnedValue(hints, 'order_number', parsed.orderNumber);
    final changed = learnedTotal != null || learnedOrder != null;
    if (!changed) return parsed;

    return StoreOcrParse(
      store: parsed.store,
      orderNumber: learnedOrder ?? parsed.orderNumber,
      total: double.tryParse(learnedTotal ?? '') ?? parsed.total,
      subtotal: parsed.subtotal,
      tax: parsed.tax,
      shipping: parsed.shipping,
      discount: parsed.discount,
      expectedItemCount: parsed.expectedItemCount,
      items: parsed.items,
      warnings: [
        ...parsed.warnings,
        'Se aplicó una corrección aprendida de revisiones anteriores.',
      ],
      confidence: parsed.confidence,
    );
  }

  String _cleanCustomerCandidate(String raw) {
    var value = raw.trim();
    value = value.replaceFirst(
      RegExp(
        r'^(?:ship\s+to|deliver\s+to|delivery\s+to|enviar\s+a|env[ií]a\s+a)\s*[:-]?\s*',
        caseSensitive: false,
      ),
      '',
    );
    value = value.trim();
    if (value.contains(',')) {
      value = value.split(',').first.trim();
    }
    final digit = RegExp(r'\d').firstMatch(value);
    if (digit != null && digit.start > 0) {
      value = value.substring(0, digit.start).trim();
    }
    value = value
        .replaceAll(RegExp(r'^[^A-Za-zÀ-ÿ]+'), '')
        .replaceAll(RegExp(r'[^A-Za-zÀ-ÿ .-]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return value;
  }

  bool _plausibleCustomerLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty || line.length > 90) return false;
    final normalized = store.normalizeName(line);
    if (normalized.isEmpty) return false;
    const blocked = <String>[
      'total',
      'pay with',
      'prime visa',
      'amazon',
      'place your order',
      'free one day',
      'no rush',
      'shipping',
      'delivery',
      'tomorrow',
      'friday',
      'ships from',
      'sold by',
      'search or ask',
      'includes tax',
    ];
    for (final word in blocked) {
      if (normalized.contains(store.normalizeName(word))) return false;
    }
    final words = normalized.split(' ').where((e) => e.length > 1).toList();
    return words.isNotEmpty && words.length <= 5;
  }

  String _extractCustomerCandidate(String text) {
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((e) => e.isNotEmpty)
        .toList();

    for (var i = 0; i < lines.length; i++) {
      final normalized = store.normalizeName(lines[i]);
      final isShipTo = normalized.contains('ship to') ||
          normalized.contains('deliver to') ||
          normalized.contains('delivery to') ||
          normalized.contains('enviar a') ||
          normalized.contains('envia a');
      if (!isShipTo) continue;

      final sameLine = _cleanCustomerCandidate(lines[i]);
      if (sameLine.isNotEmpty &&
          store.normalizeName(sameLine) != 'ship to' &&
          _plausibleCustomerLine(sameLine)) {
        return sameLine;
      }

      for (var j = i + 1; j < lines.length && j <= i + 12; j++) {
        final candidate = _cleanCustomerCandidate(lines[j]);
        if (_plausibleCustomerLine(candidate)) {
          return candidate;
        }
      }
    }

    for (final line in lines) {
      if (!RegExp(r'^[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ .-]{1,60},\s*\d')
          .hasMatch(line)) {
        continue;
      }
      final candidate = _cleanCustomerCandidate(line);
      if (_plausibleCustomerLine(candidate)) return candidate;
    }
    return '';
  }

  List<Map<String, dynamic>> _matchingClients(
    String value,
    List<Map<String, dynamic>> clients,
  ) {
    final normalized = store.normalizeName(value);
    if (normalized.isEmpty) return const <Map<String, dynamic>>[];
    final oneWord = !normalized.contains(' ');
    final exact = clients.where((client) {
      final clientName =
          store.normalizeName((client['name'] ?? '').toString());
      return clientName == normalized;
    }).toList();
    if (!oneWord && exact.isNotEmpty) return exact;
    return clients.where((client) {
      final clientName =
          store.normalizeName((client['name'] ?? '').toString());
      if (clientName.isEmpty) return false;
      if (oneWord) {
        return clientName == normalized ||
            clientName.startsWith(normalized + ' ');
      }
      return clientName == normalized ||
          clientName.startsWith(normalized + ' ') ||
          normalized.startsWith(clientName + ' ');
    }).toList();
  }

  Future<Map<String, String>> _resolveCustomerFromOcr(String text) async {
    final clients = await api.getClients();
    final candidate = _extractCustomerCandidate(text);

    if (candidate.isNotEmpty) {
      final matches = _matchingClients(candidate, clients);
      if (matches.length == 1) {
        return {
          'name': (matches.first['name'] ?? candidate).toString().trim(),
          'phone': (matches.first['phone'] ?? '').toString().trim(),
          'warning': '',
        };
      }
      if (matches.length > 1) {
        return {
          'name': candidate,
          'phone': '',
          'warning': 'Encontré “' +
              candidate +
              '” en la imagen, pero coincide con ' +
              matches.length.toString() +
              ' clientes. Elige cuál es antes de confirmar.',
        };
      }
      return {'name': candidate, 'phone': '', 'warning': ''};
    }

    final normalizedText = ' ' + store.normalizeName(text) + ' ';
    final fullMatches = <Map<String, dynamic>>[];
    var longest = 0;
    for (final client in clients) {
      final name = store.normalizeName((client['name'] ?? '').toString());
      if (name.length < 3) continue;
      if (!normalizedText.contains(' ' + name + ' ')) continue;
      if (name.length > longest) {
        longest = name.length;
        fullMatches
          ..clear()
          ..add(client);
      } else if (name.length == longest) {
        fullMatches.add(client);
      }
    }

    if (fullMatches.length == 1) {
      final client = fullMatches.first;
      final name = (client['name'] ?? '').toString().trim();
      return {
        'name': name,
        'phone': (client['phone'] ?? '').toString().trim(),
        'warning': '',
      };
    }
    if (fullMatches.length > 1) {
      final label =
          (fullMatches.first['name'] ?? 'ese nombre').toString().trim();
      return {
        'name': label,
        'phone': '',
        'warning': 'El OCR encontró “' +
            label +
            '”, pero hay varios clientes coincidentes. Elige el cliente correcto antes de confirmar.',
      };
    }

    return const {'name': '', 'phone': '', 'warning': ''};
  }

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

  String _remittanceContent(PurchaseDraft draft) {
    final lines = <String>['Origen: ${draft.remittanceSource}'];
    if (draft.customerName.trim().isNotEmpty) {
      lines.add('Nombre: ${draft.customerName.trim()}');
    }
    if (draft.total > 0) {
      lines.add('Monto: \$${draft.total.toStringAsFixed(2)}');
    }
    if (draft.remittanceDate.trim().isNotEmpty) {
      lines.add('Fecha: ${draft.remittanceDate.trim()}');
    }
    return lines.join('\n');
  }

  String _remittanceTitle(PurchaseDraft draft) {
    final parts = <String>['Remesa', draft.remittanceSource];
    if (draft.total > 0) {
      parts.add('\$${draft.total.toStringAsFixed(2)}');
    }
    return parts.where((e) => e.trim().isNotEmpty).join(' · ');
  }

  Future<OcrPurchaseResult> _saveRemittanceDraft({
    required Note note,
    required String key,
    required String path,
    required String text,
    required RemittanceOcrParse parsed,
    required PurchaseDraft? existing,
  }) async {
    final now = DateTime.now();
    final draft = PurchaseDraft(
      id: existing?.id ??
          'draft_${key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}',
      noteKey: key,
      customerName: (existing?.draftType == 'remittance' &&
              existing!.customerName.trim().isNotEmpty)
          ? existing.customerName
          : parsed.name,
      customerPhone: '',
      store: parsed.source,
      orderNumber: '',
      description: 'Remesa ${parsed.source}',
      total: (existing?.draftType == 'remittance' && existing!.total > 0)
          ? existing.total
          : parsed.amount,
      subtotal: 0,
      tax: 0,
      shipping: 0,
      discount: 0,
      items: const <Map<String, dynamic>>[],
      ocrText: text,
      confidence: parsed.confidence,
      warnings: parsed.warnings,
      mediaPath: path,
      status: existing?.status ?? 'pending',
      draftType: 'remittance',
      remittanceSource: parsed.source,
      remittanceDate: (existing?.draftType == 'remittance' &&
              existing!.remittanceDate.trim().isNotEmpty)
          ? existing.remittanceDate
          : parsed.date,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );

    await store.saveDraft(draft);
    await store.clearOcrEntityLinks(key);
    await store.saveNoteState(
      key,
      ocrProcessed: true,
      ocrText: text,
      localMediaPath: path,
      entitiesProcessed: true,
    );
    await photoStorage.archiveClassifiedNote(
      note,
      api,
      kind: PhotoFolderKind.remittances,
      localPath: path,
    );

    try {
      await api.updateNoteManual(
        note,
        title: _remittanceTitle(draft),
        content: _remittanceContent(draft),
        category: 'Remesas',
        tags: <String>{
          ...note.tags,
          'ocr',
          'remesa',
          draft.remittanceSource.toLowerCase(),
        }.toList(),
      );
    } catch (_) {}

    return OcrPurchaseResult(
      draft: draft,
      ocrText: text,
      created: existing == null,
    );
  }

  Future<OcrPurchaseResult?> processImage(
    Note note, {
    bool force = false,
  }) async {
    if (note.messageType != 'image') return null;
    final key = KnowledgeStore.noteKey(note);
    final existing = await store.draftForNote(key);
    if (!force && await store.isOcrProcessed(key) && existing != null) {
      if (existing.draftType == 'remittance') {
        await photoStorage.archiveClassifiedNote(
          note,
          api,
          kind: PhotoFolderKind.remittances,
          localPath: existing.mediaPath,
        );
      } else if (existing.total > 0 ||
          existing.items.isNotEmpty ||
          existing.store != 'Otra tienda') {
        await photoStorage.archiveClassifiedNote(
          note,
          api,
          kind: PhotoFolderKind.purchases,
          localPath: existing.mediaPath,
        );
      }
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

    var remittance = RemittanceOcrParser.parse(text);
    if (remittance.isRemittance) {
      remittance = await _applyRemittanceLearning(remittance);
      return _saveRemittanceDraft(
        note: note,
        key: key,
        path: path,
        text: text,
        parsed: remittance,
        existing: existing,
      );
    }

    var parsed = StoreOcrParser.parse(text);
    parsed = await _applyStoreLearning(parsed);
    final customerResolution = await _resolveCustomerFromOcr(text);
    final clientHints = await api.getOcrCorrections(parsed.store);
    final learnedCustomer = _learnedValue(
      clientHints,
      'customer_name',
      customerResolution['name'] ?? '',
      minOccurrences: 2,
    );
    if (learnedCustomer != null) {
      customerResolution['name'] = learnedCustomer;
      customerResolution['warning'] =
          'Se aplicó una corrección aprendida para el nombre del cliente.';
    }
    final warnings = <String>[...parsed.warnings];
    final customerWarning = customerResolution['warning'] ?? '';
    if (customerWarning.isNotEmpty) {
      warnings.add(customerWarning);
    }
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
      customerName: (existing?.customerName.trim().isNotEmpty ?? false)
          ? existing!.customerName
          : note.customerName.trim().isNotEmpty
              ? note.customerName
              : (customerResolution['name'] ?? ''),
      customerPhone: (existing?.customerPhone.trim().isNotEmpty ?? false)
          ? existing!.customerPhone
          : note.customerPhone.trim().isNotEmpty
              ? note.customerPhone
              : (customerResolution['phone'] ?? ''),
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
    await store.syncOcrKeyEntities(draft);
    await store.saveNoteState(
      key,
      ocrProcessed: true,
      ocrText: text,
      localMediaPath: path,
    );

    final recognizedPurchase = parsed.total > 0 ||
        parsed.items.isNotEmpty ||
        parsed.store != 'Otra tienda';
    if (recognizedPurchase) {
      await photoStorage.archiveClassifiedNote(
        note,
        api,
        kind: PhotoFolderKind.purchases,
        localPath: path,
      );
    }

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

    final warnings = <String>[
      ...pending.warnings.where((w) => !w.startsWith('Nombre ambiguo:')),
    ];
    final clients = await api.getClients();
    final clientMatches = _matchingClients(name, clients);
    final normalizedName = store.normalizeName(name);

    String resolvedName = name;
    String resolvedPhone = pending.customerPhone;
    bool ambiguous = false;

    if (clientMatches.length == 1) {
      resolvedName =
          (clientMatches.first['name'] ?? name).toString().trim();
      resolvedPhone =
          (clientMatches.first['phone'] ?? resolvedPhone).toString().trim();
    } else if (clientMatches.length > 1) {
      ambiguous = true;
      warnings.add(
        'Nombre ambiguo: hay ' +
            clientMatches.length.toString() +
            ' clientes que coinciden con “' +
            name +
            '”. Elige cuál es antes de enviar a Paquetería.',
      );
    } else {
      final entities = await store.entities(query: name);
      final entityMatches = entities
          .where(
            (e) =>
                e.type == 'cliente' &&
                (e.normalizedName == normalizedName ||
                    e.normalizedName.startsWith(normalizedName + ' ')),
          )
          .toList();
      if (entityMatches.length == 1) {
        resolvedName = entityMatches.first.name;
      } else if (entityMatches.length > 1) {
        ambiguous = true;
        warnings.add(
          'Nombre ambiguo: hay varios clientes relacionados con “' +
              name +
              '”. Elige cuál es antes de enviar a Paquetería.',
        );
      }
    }

    final updated = pending.copyWith(
      customerName: resolvedName,
      customerPhone: resolvedPhone,
      warnings: warnings,
    );
    await store.saveDraft(updated);
    await store.syncOcrKeyEntities(updated);

    if (!ambiguous) {
      final entity = await store.upsertEntity(
        resolvedName,
        type: 'cliente',
        aliases: resolvedPhone.isEmpty ? const [] : [resolvedPhone],
      );
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
    }
    return updated;
  }

}
