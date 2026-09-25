import 'dart:convert';
import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';
import '../models/purchase_draft.dart';
import 'api_service.dart';
import 'knowledge_store.dart';
import 'ocr_natural_correction.dart';
import 'photo_storage_service.dart';
import 'remittance_ocr.dart';
import 'store_ocr.dart';

class OcrCorrectionApplyResult {
  final OcrNaturalCorrection correction;
  final int updatedCount;
  final String confirmation;
  final List<String> noteKeys;

  const OcrCorrectionApplyResult({
    required this.correction,
    required this.updatedCount,
    required this.confirmation,
    required this.noteKeys,
  });

  Map<String, dynamic> toJson() => {
        'field': correction.field.name,
        'value': correction.value,
        'batch': correction.batch,
        'count': correction.count,
        'target_type': correction.targetType,
        'updated_count': updatedCount,
        'confirmation': confirmation,
        'note_keys': noteKeys,
      };

  factory OcrCorrectionApplyResult.fromJson(Map<String, dynamic> json) {
    final fieldName = (json['field'] ?? '').toString();
    final field = OcrCorrectionField.values.firstWhere(
      (value) => value.name == fieldName,
      orElse: () => OcrCorrectionField.customerName,
    );
    final rawKeys = json['note_keys'];
    return OcrCorrectionApplyResult(
      correction: OcrNaturalCorrection(
        field: field,
        value: (json['value'] ?? '').toString(),
        batch: json['batch'] == true,
        count: (json['count'] as num?)?.toInt(),
        targetType: (json['target_type'] ?? 'purchase').toString(),
      ),
      updatedCount: (json['updated_count'] as num?)?.toInt() ?? 0,
      confirmation: (json['confirmation'] ?? '').toString(),
      noteKeys: rawKeys is List
          ? rawKeys.map((e) => e.toString()).toList()
          : const <String>[],
    );
  }
}

class LocalPurchaseOcrResult {
  final StoreOcrParse parsed;
  final String text;

  const LocalPurchaseOcrResult({
    required this.parsed,
    required this.text,
  });
}

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

  Future<LocalPurchaseOcrResult?> parseLocalPurchaseImage(
    String path,
  ) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    String text = '';
    try {
      final recognized =
          await recognizer.processImage(InputImage.fromFilePath(path));
      text = recognized.text.trim();
    } finally {
      await recognizer.close();
    }
    var parsed = StoreOcrParser.parse(text);
    parsed = await _applyStoreLearning(parsed);
    return LocalPurchaseOcrResult(parsed: parsed, text: text);
  }

  Future<PurchaseDraft> createDraftFromCombinedNote(Note note) async {
    final attachments = note.photoPaths
        .where((path) => path.trim().isNotEmpty && File(path).existsSync())
        .toList();

    var parsed = StoreOcrParser.parse(note.content);
    parsed = await _applyStoreLearning(parsed);
    var ocrText = note.content;
    String mediaPath = '';

    if (attachments.length == 1) {
      final imageResult = await parseLocalPurchaseImage(attachments.first);
      if (imageResult != null) {
        final imageParsed = imageResult.parsed;
        parsed = StoreOcrParse(
          store: imageParsed.store != 'Otra tienda'
              ? imageParsed.store
              : parsed.store,
          orderNumber: imageParsed.orderNumber.trim().isNotEmpty
              ? imageParsed.orderNumber
              : parsed.orderNumber,
          total: imageParsed.total > 0 ? imageParsed.total : parsed.total,
          subtotal:
              imageParsed.subtotal > 0 ? imageParsed.subtotal : parsed.subtotal,
          tax: imageParsed.tax > 0 ? imageParsed.tax : parsed.tax,
          shipping: imageParsed.shipping > 0
              ? imageParsed.shipping
              : parsed.shipping,
          discount: imageParsed.discount > 0
              ? imageParsed.discount
              : parsed.discount,
          expectedItemCount:
              imageParsed.expectedItemCount ?? parsed.expectedItemCount,
          items: imageParsed.items.isNotEmpty ? imageParsed.items : parsed.items,
          warnings: <String>[...parsed.warnings, ...imageParsed.warnings],
          confidence: imageParsed.confidence > parsed.confidence
              ? imageParsed.confidence
              : parsed.confidence,
        );
        ocrText = imageResult.text;
        mediaPath = attachments.first;
      }
    }

    final customer = await _resolveCustomerFromOcr(note.content);
    final now = DateTime.now();
    final draft = PurchaseDraft(
      id: 'draft_combined_' +
          KnowledgeStore.noteKey(note)
              .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_'),
      noteKey: KnowledgeStore.noteKey(note),
      customerName: note.customerName.trim().isNotEmpty
          ? note.customerName
          : (customer['name'] ?? ''),
      customerPhone: note.customerPhone.trim().isNotEmpty
          ? note.customerPhone
          : (customer['phone'] ?? ''),
      store: parsed.store,
      orderNumber: parsed.orderNumber,
      description: parsed.items.isNotEmpty
          ? parsed.items
              .take(5)
              .map((item) => (item['name'] ?? '').toString())
              .where((value) => value.isNotEmpty)
              .join(', ')
          : note.title,
      total: parsed.total,
      subtotal: parsed.subtotal,
      tax: parsed.tax,
      shipping: parsed.shipping,
      discount: parsed.discount,
      items: parsed.items,
      ocrText: ocrText,
      confidence: parsed.confidence,
      warnings: <String>[
        ...parsed.warnings,
        if (attachments.length > 1)
          'Hay varias imágenes adjuntas. Selecciona una si quieres ejecutar OCR sobre una foto específica.',
      ],
      mediaPath: mediaPath,
      attachmentPaths: attachments,
      status: 'pending',
      createdAt: now,
      updatedAt: now,
    );
    await store.saveDraft(draft);
    await store.syncOcrKeyEntities(draft);
    return draft;
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

  String _correctionResultKey(Note note) {
    final identity = note.messageSid.trim().isNotEmpty
        ? note.messageSid.trim()
        : note.id.toString();
    return 'ocr_natural_correction_result_' + identity;
  }

  bool _sameSender(Note candidate, Note messageNote) {
    final sender = messageNote.sender.trim();
    if (sender.isEmpty) return true;
    return candidate.sender.trim() == sender;
  }

  bool _sameNote(Note a, Note b) {
    if (a.id == b.id) return true;
    if (a.messageSid.trim().isNotEmpty &&
        a.messageSid.trim() == b.messageSid.trim()) {
      return true;
    }
    return false;
  }

  Future<List<Note>> _targetImageNotes(
    OcrNaturalCorrection correction,
    Note messageNote,
  ) async {
    final all = await api.getNotes();
    if (all.isEmpty) return const <Note>[];

    final ordered = all.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var messageIndex = ordered.indexWhere((note) => _sameNote(note, messageNote));
    if (messageIndex < 0) {
      messageIndex = ordered.indexWhere(
        (note) =>
            note.createdAt == messageNote.createdAt &&
            note.originalText == messageNote.originalText,
      );
    }

    final maxCount = correction.count ?? (correction.batch ? 12 : 1);
    final selected = <Note>[];

    if (messageIndex >= 0) {
      for (var i = messageIndex - 1; i >= 0 && selected.length < maxCount; i--) {
        final note = ordered[i];
        if (!_sameSender(note, messageNote)) continue;

        if (note.messageType == 'image') {
          selected.add(note);
          if (!correction.batch) break;
          continue;
        }

        if (correction.batch) {
          if (correction.count != null) {
            continue;
          }
          break;
        }
        if (!correction.batch) {
          continue;
        }
      }
    }

    if (selected.isNotEmpty) return selected;

    final fallback = all
        .where(
          (note) =>
              note.messageType == 'image' &&
              _sameSender(note, messageNote) &&
              !note.createdAt.isAfter(
                messageNote.createdAt.add(const Duration(seconds: 5)),
              ),
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (fallback.isEmpty) return const <Note>[];
    if (!correction.batch) return [fallback.first];

    final recent = <Note>[];
    DateTime? previous;
    for (final note in fallback) {
      if (recent.length >= maxCount) break;
      if (previous != null &&
          previous.difference(note.createdAt) >
              const Duration(minutes: 3)) {
        break;
      }
      if (messageNote.createdAt.difference(note.createdAt) >
          const Duration(minutes: 15)) {
        break;
      }
      recent.add(note);
      previous = note.createdAt;
    }
    return recent;
  }

  bool _draftMatchesTarget(
    PurchaseDraft draft,
    OcrNaturalCorrection correction,
  ) {
    if (correction.targetsRemittances) {
      return draft.draftType == 'remittance';
    }
    return draft.draftType != 'remittance';
  }

  Future<List<PurchaseDraft>> _targetDrafts(
    OcrNaturalCorrection correction,
    Note messageNote,
  ) async {
    final notes = await _targetImageNotes(correction, messageNote);
    final drafts = <PurchaseDraft>[];

    for (final note in notes) {
      PurchaseDraft? draft = await store.draftForNote(
        KnowledgeStore.noteKey(note),
      );
      if (draft == null) {
        try {
          draft = (await processImage(note))?.draft;
        } catch (_) {}
      }
      if (draft == null || !_draftMatchesTarget(draft, correction)) continue;
      drafts.add(draft);
      if (!correction.batch) break;
      if (correction.count != null && drafts.length >= correction.count!) {
        break;
      }
    }

    if (drafts.isNotEmpty) return drafts;

    if (correction.batch) return const <PurchaseDraft>[];

    final pending = await store.drafts(status: 'pending');
    for (final draft in pending) {
      if (_draftMatchesTarget(draft, correction)) return [draft];
    }
    return const <PurchaseDraft>[];
  }

  double? _parseCorrectionAmount(String raw) {
    var value = raw
        .replaceAll(RegExp(r'[^0-9,.-]'), '')
        .trim();
    if (value.isEmpty) return null;
    if (value.contains(',') && value.contains('.')) {
      value = value.replaceAll(',', '');
    } else if (value.contains(',')) {
      final parts = value.split(',');
      if (parts.length == 2 && parts.last.length <= 2) {
        value = parts.first + '.' + parts.last;
      } else {
        value = value.replaceAll(',', '');
      }
    }
    final parsed = double.tryParse(value);
    if (parsed == null || parsed < 0) return null;
    return parsed;
  }

  Future<Map<String, dynamic>> _resolveCorrectionCustomer(
    String name,
    PurchaseDraft draft,
  ) async {
    final warnings = <String>[
      ...draft.warnings.where(
        (warning) =>
            !warning.toLowerCase().startsWith('nombre ambiguo:') &&
            !warning.toLowerCase().contains('varios clientes'),
      ),
    ];
    final clients = await api.getClients();
    final matches = _matchingClients(name, clients);
    final normalizedName = store.normalizeName(name);

    var resolvedName = name;
    var resolvedPhone = draft.customerPhone;
    var ambiguous = false;

    if (matches.length == 1) {
      resolvedName = (matches.first['name'] ?? name).toString().trim();
      resolvedPhone =
          (matches.first['phone'] ?? resolvedPhone).toString().trim();
    } else if (matches.length > 1) {
      ambiguous = true;
      warnings.add(
        'Nombre ambiguo: hay ' +
            matches.length.toString() +
            ' clientes que coinciden con “' +
            name +
            '”. Elige cuál es antes de enviar a Paquetería.',
      );
    } else {
      final entities = await store.entities(query: name);
      final entityMatches = entities
          .where(
            (entity) =>
                entity.type == 'cliente' &&
                (entity.normalizedName == normalizedName ||
                    entity.normalizedName.startsWith(normalizedName + ' ')),
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

    return {
      'name': resolvedName,
      'phone': resolvedPhone,
      'warnings': warnings,
      'ambiguous': ambiguous,
    };
  }

  String _learningField(
    PurchaseDraft draft,
    OcrCorrectionField field,
  ) {
    if (draft.draftType == 'remittance') {
      return switch (field) {
        OcrCorrectionField.customerName => 'name',
        OcrCorrectionField.total => 'amount',
        OcrCorrectionField.remittanceDate => 'date',
        OcrCorrectionField.remittanceSource => 'source',
        OcrCorrectionField.store => 'source',
        OcrCorrectionField.orderNumber => 'order_number',
        OcrCorrectionField.description => 'description',
      };
    }
    return switch (field) {
      OcrCorrectionField.customerName => 'customer_name',
      OcrCorrectionField.total => 'total',
      OcrCorrectionField.store => 'store',
      OcrCorrectionField.orderNumber => 'order_number',
      OcrCorrectionField.description => 'description',
      OcrCorrectionField.remittanceDate => 'date',
      OcrCorrectionField.remittanceSource => 'source',
    };
  }

  String _originalFieldValue(
    PurchaseDraft draft,
    OcrCorrectionField field,
  ) {
    return switch (field) {
      OcrCorrectionField.customerName => draft.customerName,
      OcrCorrectionField.total =>
        draft.total > 0 ? draft.total.toStringAsFixed(2) : '',
      OcrCorrectionField.store => draft.store,
      OcrCorrectionField.orderNumber => draft.orderNumber,
      OcrCorrectionField.description => draft.description,
      OcrCorrectionField.remittanceDate => draft.remittanceDate,
      OcrCorrectionField.remittanceSource => draft.remittanceSource,
    };
  }

  String _sourceForLearning(PurchaseDraft draft) {
    if (draft.draftType == 'remittance') {
      return draft.remittanceSource.trim().isNotEmpty
          ? draft.remittanceSource
          : draft.store;
    }
    return draft.store;
  }

  Future<PurchaseDraft?> _applyCorrectionToDraft(
    PurchaseDraft draft,
    OcrNaturalCorrection correction,
  ) async {
    final original = _originalFieldValue(draft, correction.field);
    PurchaseDraft updated = draft;
    String correctedForLearning = correction.value;

    switch (correction.field) {
      case OcrCorrectionField.customerName:
        final resolved = await _resolveCorrectionCustomer(
          correction.value,
          draft,
        );
        final name = (resolved['name'] ?? correction.value).toString();
        final phone = (resolved['phone'] ?? draft.customerPhone).toString();
        final warnings = (resolved['warnings'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            draft.warnings;
        correctedForLearning = name;
        updated = draft.copyWith(
          customerName: name,
          customerPhone: phone,
          warnings: warnings,
        );
        break;
      case OcrCorrectionField.total:
        final amount = _parseCorrectionAmount(correction.value);
        if (amount == null) return null;
        correctedForLearning = amount.toStringAsFixed(2);
        updated = draft.copyWith(total: amount);
        break;
      case OcrCorrectionField.store:
        updated = draft.copyWith(
          store: correction.value,
          remittanceSource: draft.draftType == 'remittance'
              ? correction.value
              : draft.remittanceSource,
        );
        break;
      case OcrCorrectionField.orderNumber:
        updated = draft.copyWith(orderNumber: correction.value);
        break;
      case OcrCorrectionField.description:
        updated = draft.copyWith(description: correction.value);
        break;
      case OcrCorrectionField.remittanceDate:
        if (draft.draftType != 'remittance') return null;
        updated = draft.copyWith(remittanceDate: correction.value);
        break;
      case OcrCorrectionField.remittanceSource:
        if (draft.draftType != 'remittance') return null;
        updated = draft.copyWith(
          remittanceSource: correction.value,
          store: correction.value,
        );
        break;
    }

    await store.saveDraft(updated);
    await store.syncOcrKeyEntities(updated);

    try {
      await api.recordOcrCorrection(
        source: _sourceForLearning(draft),
        field: _learningField(draft, correction.field),
        original: original,
        corrected: correctedForLearning,
      );
    } catch (_) {}

    return updated;
  }

  String _fieldLabel(OcrCorrectionField field) {
    return switch (field) {
      OcrCorrectionField.customerName => 'cliente',
      OcrCorrectionField.total => 'total',
      OcrCorrectionField.store => 'tienda',
      OcrCorrectionField.orderNumber => 'número de pedido',
      OcrCorrectionField.description => 'descripción',
      OcrCorrectionField.remittanceDate => 'fecha',
      OcrCorrectionField.remittanceSource => 'origen',
    };
  }

  String _displayCorrectionValue(
    OcrNaturalCorrection correction,
    PurchaseDraft? firstUpdated,
  ) {
    if (firstUpdated == null) return correction.value;
    return switch (correction.field) {
      OcrCorrectionField.customerName => firstUpdated.customerName,
      OcrCorrectionField.total =>
        r'$' + firstUpdated.total.toStringAsFixed(2),
      OcrCorrectionField.store => firstUpdated.store,
      OcrCorrectionField.orderNumber => firstUpdated.orderNumber,
      OcrCorrectionField.description => firstUpdated.description,
      OcrCorrectionField.remittanceDate => firstUpdated.remittanceDate,
      OcrCorrectionField.remittanceSource => firstUpdated.remittanceSource,
    };
  }

  String _confirmation(
    OcrNaturalCorrection correction,
    int updatedCount,
    PurchaseDraft? firstUpdated,
  ) {
    final target = correction.targetsRemittances ? 'remesa' : 'compra';
    if (updatedCount <= 0) {
      return 'Entendí que quieres corregir el campo ' +
          _fieldLabel(correction.field) +
          ', pero no encontré ' +
          (correction.batch
              ? target + 's recientes'
              : 'una ' + target + ' reciente') +
          ' para actualizar.';
    }
    final value = _displayCorrectionValue(correction, firstUpdated);
    final where = updatedCount == 1
        ? 'en la ' + target
        : 'en ' + updatedCount.toString() + ' ' + target + 's';
    return 'Listo. Actualicé el campo ' +
        _fieldLabel(correction.field) +
        ' a “' +
        value +
        '” ' +
        where +
        '.';
  }

  Future<OcrCorrectionApplyResult?> applyNaturalLanguageCorrection(
    String message,
    Note messageNote,
  ) async {
    final correction = OcrNaturalCorrectionParser.parse(message);
    if (correction == null) return null;
    return applyCorrection(correction, messageNote);
  }

  Future<OcrCorrectionApplyResult> applyCorrection(
    OcrNaturalCorrection correction,
    Note messageNote,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final resultKey = _correctionResultKey(messageNote);
    final cached = prefs.getString(resultKey);
    if (cached != null && cached.trim().isNotEmpty) {
      try {
        return OcrCorrectionApplyResult.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    final targets = await _targetDrafts(correction, messageNote);
    final updated = <PurchaseDraft>[];
    for (final draft in targets) {
      final value = await _applyCorrectionToDraft(draft, correction);
      if (value != null) updated.add(value);
    }

    final result = OcrCorrectionApplyResult(
      correction: correction,
      updatedCount: updated.length,
      confirmation: _confirmation(
        correction,
        updated.length,
        updated.isEmpty ? null : updated.first,
      ),
      noteKeys: updated.map((draft) => draft.noteKey).toList(),
    );

    if (updated.isNotEmpty) {
      await prefs.setString(resultKey, jsonEncode(result.toJson()));
      if (correction.field == OcrCorrectionField.customerName) {
        final resolvedName = updated.first.customerName.trim();
        if (resolvedName.isNotEmpty) {
          final entity = await store.upsertEntity(
            resolvedName,
            type: 'cliente',
            aliases: updated.first.customerPhone.trim().isEmpty
                ? const []
                : [updated.first.customerPhone.trim()],
          );
          await store.linkEntity(
            entity.id,
            KnowledgeStore.noteKey(messageNote),
            relation: 'corrección',
          );
        }
      }
    }
    return result;
  }

  String? customerCorrection(String text) {
    final correction = OcrNaturalCorrectionParser.parse(text);
    if (correction?.field != OcrCorrectionField.customerName) return null;
    return correction!.value;
  }

  Future<PurchaseDraft?> applyCustomerCorrection(
    String message,
    Note messageNote,
  ) async {
    final result = await applyNaturalLanguageCorrection(message, messageNote);
    if (result == null ||
        result.correction.field != OcrCorrectionField.customerName ||
        result.noteKeys.isEmpty) {
      return null;
    }
    return store.draftForNote(result.noteKeys.first);
  }
}
