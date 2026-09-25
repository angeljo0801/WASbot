import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/note.dart';
import '../models/purchase_draft.dart';
import '../services/api_service.dart';
import '../services/knowledge_store.dart';
import '../services/note_share_service.dart';
import '../services/ocr_purchase_service.dart';
import 'draft_review_page.dart';
import 'remittance_draft_review_page.dart';
import 'fullscreen_image_viewer.dart';

class NoteDetailPage extends StatefulWidget {
  final Note note;
  final ApiService api;

  const NoteDetailPage({
    super.key,
    required this.note,
    required this.api,
  });

  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage> {
  static const categories = [
    'Inbox',
    'Clientes',
    'Trabajo',
    'Personal',
    'Compras',
    'Gastos',
    'Ideas',
    'Documentos',
    'Recordatorios',
    'Fotos',
  ];

  late Note note;
  PurchaseDraft? draft;
  bool working = false;
  bool ocrWorking = false;
  String? ocrStatus;

  IconData _noteTypeIcon(Note value) {
    return switch (value.messageType) {
      'image' => Icons.image_outlined,
      'document' => Icons.insert_drive_file_outlined,
      'audio' => Icons.audiotrack_outlined,
      'video' => Icons.videocam_outlined,
      'contact' => Icons.contact_page_outlined,
      _ => Icons.notes_outlined,
    };
  }

  Future<String?> _materializeCombinedImage(Note value) async {
    for (final path in value.photoPaths) {
      final file = File(path);
      if (await file.exists()) return file.path;
    }
    final raw = (value.mediaPath ?? '').trim();
    if (raw.isEmpty) return null;
    final local = File(raw);
    if (await local.exists()) return local.path;
    if (value.messageType != 'image') return null;

    final bytes = await widget.api.fetchMediaBytes(raw);
    if (bytes == null || bytes.isEmpty) return null;
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/combined_media');
    if (!await folder.exists()) await folder.create(recursive: true);
    final safe = KnowledgeStore.noteKey(value)
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    var ext = '.jpg';
    final lower = raw.toLowerCase();
    if (lower.contains('.png')) ext = '.png';
    if (lower.contains('.webp')) ext = '.webp';
    final file = File(
      '${folder.path}/combined_${safe}_${DateTime.now().microsecondsSinceEpoch}$ext',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> createPurchaseDraftFromCombined() async {
    setState(() => working = true);
    try {
      final service = OcrPurchaseService(api: widget.api);
      final created = await service.createDraftFromCombinedNote(note);
      draft = created;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DraftReviewPage(
            draft: created,
            api: widget.api,
          ),
        ),
      );
      await loadDraft();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo crear el borrador: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  void initState() {
    super.initState();
    note = widget.note;
    loadDraft().then((_) {
      if (note.messageType == 'image' && draft == null) {
        _runOcr(auto: true);
      }
    });
  }

  Future<void> loadDraft() async {
    final value = await KnowledgeStore.instance
        .draftForNote(KnowledgeStore.noteKey(note));
    if (mounted) setState(() => draft = value);
  }

  Future<void> _openDraftReview() async {
    final current = draft;
    if (current == null) return;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => current.draftType == 'remittance'
            ? RemittanceDraftReviewPage(
                draft: current,
                api: widget.api,
              )
            : DraftReviewPage(
                draft: current,
                api: widget.api,
              ),
      ),
    );
    if (changed == true) {
      await loadDraft();
    }
  }

  Future<void> _runOcr({bool force = false, bool auto = false}) async {
    if (ocrWorking || note.messageType != 'image') return;
    if (mounted) {
      setState(() {
        ocrWorking = true;
        ocrStatus = auto
            ? 'Analizando imagen automáticamente…'
            : force
                ? 'Reprocesando OCR…'
                : 'Escaneando imagen con OCR…';
      });
    }

    try {
      final service = OcrPurchaseService(api: widget.api);
      final result = await service.processImage(note, force: force);
      if (!mounted) return;
      if (result == null) {
        setState(() {
          ocrStatus = 'No pude procesar esta imagen con OCR.';
        });
        return;
      }
      setState(() {
        draft = result.draft;
        if (result.ocrText.trim().isEmpty) {
          ocrStatus = 'OCR completado, pero no se detectó texto suficiente.';
        } else if (result.draft.draftType == 'remittance') {
          ocrStatus =
              'Remesa ${result.draft.remittanceSource} detectada · revisa el borrador.';
        } else {
          ocrStatus = 'Compra detectada · borrador preparado para revisar.';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          ocrStatus = 'OCR falló: $e';
        });
      }
    } finally {
      if (mounted) setState(() => ocrWorking = false);
    }
  }

  IconData get icon => switch (note.messageType) {
        'image' => Icons.image_outlined,
        'audio' => Icons.mic_none,
        'document' => Icons.description_outlined,
        'contact' => Icons.person_add_alt_1_outlined,
        'remittance' => Icons.payments_outlined,
        _ => Icons.notes_outlined,
      };

  String get aiLabel => switch (note.aiProvider) {
        'openai' => 'OpenAI',
        'gemini' => 'Gemini',
        'local_server' => 'IA local',
        'manager' => 'Local AI Manager',
        'local' => 'GGUF local',
        'server' => 'IA servidor',
        _ => 'Reglas',
      };

  Future<String?> _localMedia() async {
    final raw = note.mediaPath?.trim() ?? '';
    if (raw.isEmpty) return null;
    final direct = File(raw);
    if (await direct.exists()) return direct.path;

    final bytes = await widget.api.fetchMediaBytes(raw);
    if (bytes == null || bytes.isEmpty) return null;
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/shared_inbox');
    if (!await folder.exists()) await folder.create(recursive: true);

    var ext = '.bin';
    final lower = raw.toLowerCase();
    for (final candidate in [
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.pdf',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
      '.txt',
      '.zip',
      '.mp3',
      '.m4a',
      '.mp4'
    ]) {
      if (lower.contains(candidate)) {
        ext = candidate;
        break;
      }
    }
    if (note.messageType == 'image' && ext == '.bin') ext = '.jpg';
    final safe = KnowledgeStore.noteKey(note)
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${folder.path}/$safe$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> classify() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: categories
              .map(
                (c) => ListTile(
                  leading: Icon(c == note.category
                      ? Icons.check_circle
                      : Icons.label_outline),
                  title: Text(c),
                  onTap: () => Navigator.pop(context, c),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (selected == null || selected == note.category) return;
    setState(() => working = true);
    try {
      note = await widget.api.updateNoteManual(note, category: selected);
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> shareNote() async {
    setState(() => working = true);
    try {
      await NoteShareService(widget.api).shareNotes([note]);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> openOriginal() async {
    setState(() => working = true);
    try {
      final local = await _localMedia();
      if (local == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No pude preparar el archivo.')),
          );
        }
        return;
      }
      await OpenFilex.open(local);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _openLocalPhoto(String path) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenImageViewer.file(
          title: 'Foto',
          path: path,
        ),
      ),
    );
  }

  Future<void> _openMemoryPhoto(Uint8List bytes) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenImageViewer.memory(
          title: 'Foto',
          bytes: bytes,
        ),
      ),
    );
  }

  Future<void> combine() async {
    final all = await widget.api.getNotes();
    final candidates = all.where((n) => n.id != note.id).take(60).toList();
    if (!mounted || candidates.isEmpty) return;
    final selected = <int>{};
    final previewFutures = <int, Future<String?>>{
      for (final candidate in candidates)
        if (candidate.messageType == 'image')
          candidate.id: _materializeCombinedImage(candidate),
    };
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialog) => AlertDialog(
              title: const Text('Combinar notas'),
              content: SizedBox(
                width: double.maxFinite,
                height: 420,
                child: ListView(
                  children: candidates
                      .map(
                        (other) => CheckboxListTile(
                          value: selected.contains(other.id),
                          secondary: other.messageType == 'image'
                              ? FutureBuilder<String?>(
                                  future: previewFutures[other.id],
                                  builder: (context, snapshot) {
                                    final path = snapshot.data;
                                    if (path != null &&
                                        path.isNotEmpty &&
                                        File(path).existsSync()) {
                                      return ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: SizedBox(
                                          width: 68,
                                          height: 68,
                                          child: Image.file(
                                            File(path),
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                const CircleAvatar(
                                              child: Icon(
                                                Icons.broken_image_outlined,
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                    if (snapshot.connectionState ==
                                        ConnectionState.waiting) {
                                      return const SizedBox(
                                        width: 68,
                                        height: 68,
                                        child: Center(
                                          child: SizedBox.square(
                                            dimension: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                    return const CircleAvatar(
                                      child: Icon(Icons.image_outlined),
                                    );
                                  },
                                )
                              : CircleAvatar(
                                  child: Icon(
                                    _noteTypeIcon(other),
                                    size: 20,
                                  ),
                                ),
                          title: Text(other.title),
                          subtitle: Text(
                            other.content.replaceAll('\n', ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (v) => setDialog(() {
                            if (v == true) {
                              selected.add(other.id);
                            } else {
                              selected.remove(other.id);
                            }
                          }),
                        ),
                      )
                      .toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(context, true),
                  child: const Text('Combinar'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (!ok) return;

    final chosen = [
      note,
      ...candidates.where((n) => selected.contains(n.id)),
    ];
    final content = chosen
        .map(
          (n) =>
              '--- ${n.title} ---\n${n.content.trim().isNotEmpty ? n.content : n.originalText}',
        )
        .join('\n\n');
    final combinedPhotos = <String>[];
    for (final source in chosen.where((value) => value.messageType == 'image')) {
      final path = await _materializeCombinedImage(source);
      if (path != null && !combinedPhotos.contains(path)) {
        combinedPhotos.add(path);
      }
    }

    final merged = await widget.api.createNote(
      title: 'Combinada: ${note.title}',
      content: content,
      category: note.category,
      mediaPath: combinedPhotos.length == 1 ? combinedPhotos.first : null,
      photoPaths: combinedPhotos,
    );

    final knowledge = KnowledgeStore.instance;
    final entities = await knowledge.entities();
    final sourceKeys = chosen.map(KnowledgeStore.noteKey).toSet();
    for (final entity in entities) {
      final keys = (await knowledge.noteKeysForEntity(entity.id)).toSet();
      if (keys.intersection(sourceKeys).isNotEmpty) {
        await knowledge.linkEntity(
          entity.id,
          KnowledgeStore.noteKey(merged),
          relation: 'combinado',
        );
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nota combinada creada; las originales se conservaron.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final localPhotos = <String>[];
    for (final path in note.photoPaths) {
      if (File(path).existsSync()) localPhotos.add(path);
    }
    if (localPhotos.isEmpty &&
        note.mediaPath != null &&
        File(note.mediaPath!).existsSync() &&
        note.messageType == 'image') {
      localPhotos.add(note.mediaPath!);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(note.title),
        actions: [
          IconButton(
            tooltip: 'Clasificar',
            onPressed: working ? null : classify,
            icon: const Icon(Icons.drive_file_move_outline),
          ),
          IconButton(
            tooltip: 'Compartir',
            onPressed: working ? null : shareNote,
            icon: const Icon(Icons.share_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'combine') combine();
              if (value == 'purchase_draft') createPurchaseDraftFromCombined();
              if (value == 'open') openOriginal();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'combine',
                child: Text('Combinar con otras notas'),
              ),
              if (note.title.startsWith('Combinada:'))
                const PopupMenuItem(
                  value: 'purchase_draft',
                  child: Text('Crear borrador de compra'),
                ),
              if (note.mediaPath?.isNotEmpty == true)
                const PopupMenuItem(
                  value: 'open',
                  child: Text('Abrir archivo original'),
                ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.label_outline, size: 18),
                  label: Text(note.category),
                  onPressed: working ? null : classify,
                ),
                Chip(
                  label:
                      Text(note.source == 'whatsapp' ? 'WhatsApp' : 'Manual'),
                ),
                Chip(label: Text(aiLabel)),
                ...note.tags.map((t) => Chip(label: Text('#$t'))),
              ],
            ),
            if (note.messageType == 'image') ...[
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            draft != null
                                ? Icons.document_scanner_outlined
                                : Icons.auto_awesome_outlined,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              draft != null
                                  ? 'OCR procesado'
                                  : 'OCR de imagen',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          if (ocrWorking)
                            const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        ocrStatus ??
                            (draft != null
                                ? 'La imagen ya fue analizada y tiene un borrador listo para revisar.'
                                : 'WhatsBot decidirá si la imagen es una compra o una remesa y preparará el borrador correspondiente.'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: ocrWorking
                                  ? null
                                  : () => _runOcr(force: draft != null),
                              icon: Icon(
                                draft == null
                                    ? Icons.document_scanner_outlined
                                    : Icons.refresh,
                              ),
                              label: Text(
                                draft == null
                                    ? 'Escanear con OCR'
                                    : 'Reprocesar OCR',
                              ),
                            ),
                          ),
                          if (draft != null) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  await _openDraftReview();
                                },
                                icon: const Icon(Icons.preview_outlined),
                                label: const Text('Ver borrador'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (draft?.pending == true) ...[
              const SizedBox(height: 14),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.pending_actions_outlined),
                  title: Text(
                    draft!.draftType == 'remittance'
                        ? 'Remesa detectada · pendiente'
                        : 'Pedido detectado · pendiente',
                  ),
                  subtitle: Text(
                    draft!.draftType == 'remittance'
                        ? [
                            draft!.remittanceSource,
                            if (draft!.total > 0)
                              '\\${draft!.total.toStringAsFixed(2)}',
                          ].where((e) => e.trim().isNotEmpty).join(' · ')
                        : draft!.customerName.isEmpty
                            ? 'OCR listo. Revisa y asigna el cliente.'
                            : 'Cliente: ${draft!.customerName} · ${draft!.store}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await _openDraftReview();
                  },
                ),
              ),
            ],
            if (note.isPurchase &&
                (note.customerName.isNotEmpty ||
                    note.customerPhone.isNotEmpty)) ...[
              const SizedBox(height: 14),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(note.customerName.isEmpty
                      ? 'Cliente'
                      : note.customerName),
                  subtitle: note.customerPhone.isEmpty
                      ? null
                      : SelectableText(note.customerPhone),
                ),
              ),
            ],
            if (localPhotos.isNotEmpty) ...[
              const SizedBox(height: 18),
              SizedBox(
                height: 280,
                child: PageView.builder(
                  itemCount: localPhotos.length,
                  itemBuilder: (_, index) => InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _openLocalPhoto(localPhotos[index]),
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.file(
                              File(localPhotos[index]),
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.68),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.zoom_in_outlined,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Toca para ampliar',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ] else if (note.messageType == 'image' &&
                note.mediaPath?.isNotEmpty == true) ...[
              const SizedBox(height: 18),
              FutureBuilder(
                future: widget.api.fetchMediaBytes(note.mediaPath!),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const SizedBox(
                      height: 200,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final bytes = snapshot.data;
                  if (bytes == null || bytes.isEmpty) {
                    return const Text('No se pudo cargar la imagen.');
                  }
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _openMemoryPhoto(bytes),
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.68),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.zoom_in_outlined,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Toca para ampliar',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
            if (note.messageType == 'document' ||
                note.messageType == 'audio' ||
                note.messageType == 'video') ...[
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: working ? null : openOriginal,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Abrir / previsualizar archivo'),
              ),
            ],
            const SizedBox(height: 18),
            SelectableText(
              note.content.isEmpty ? 'Sin contenido' : note.content,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (note.originalText.isNotEmpty &&
                note.originalText != note.content) ...[
              const SizedBox(height: 28),
              Text('Original',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SelectableText(note.originalText),
            ],
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: working ? null : shareNote,
              icon: const Icon(Icons.share_outlined),
              label: const Text('Compartir nota / archivo'),
            ),
          ],
        ),
      ),
    );
  }
}
