import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../services/api_service.dart';
import '../services/background_service.dart';
import '../services/ai_provider_service.dart';
import '../services/local_ai_service.dart';
import '../services/paqueteria_purchase_sync_service.dart';
import '../services/embedding_service.dart';
import '../services/knowledge_pipeline.dart';
import '../services/knowledge_store.dart';
import '../services/note_share_service.dart';
import '../services/ocr_purchase_service.dart';
import '../services/remittance_sms_service.dart';
import '../services/paypal_email_notification_service.dart';
import 'ai_activity_page.dart';
import 'ai_settings_page.dart';
import 'combo_page.dart';
import 'conversations_page.dart';
import 'draft_review_page.dart';
import 'fullscreen_image_viewer.dart';
import 'remittance_draft_review_page.dart';
import 'entities_page.dart';
import 'knowledge_chat_page.dart';
import 'new_note_page.dart';
import 'note_detail_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final api = ApiService();
  final localAi = LocalAiService();
  late final AiProviderService ai;
  late final EmbeddingService embeddings;
  late final KnowledgePipeline knowledge;
  final search = TextEditingController();
  final categories = const [
    'Todas', 'Inbox', 'Clientes', 'Trabajo', 'Personal', 'Compras', 'Gastos',
    'Ideas', 'Documentos', 'Recordatorios', 'Fotos', 'Remesas'
  ];

  String category = 'Todas';
  List<Note> notes = [];
  bool loading = true;
  bool aiRunning = false;
  int aiDone = 0;
  int aiTotal = 0;
  String aiRunningLabel = 'IA';
  int paqueteriaPending = 0;
  int pendingDrafts = 0;
  bool knowledgeRunning = false;
  int knowledgeDone = 0;
  int knowledgeTotal = 0;
  String knowledgeLabel = '';
  String? error;
  final Set<int> selectedNoteIds = <int>{};
  bool shareWorking = false;
  bool deleteSelectionWorking = false;
  Timer? _backgroundTimer;
  Timer? _replyTimer;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  bool _backgroundTickRunning = false;
  bool _replyTickRunning = false;
  final Map<String, Future<Uint8List?>> _thumbnailCache =
      <String, Future<Uint8List?>>{};
  final remittanceSms = RemittanceSmsService();
  final payPalEmail = PayPalEmailNotificationService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ai = AiProviderService(localAi: localAi);
    embeddings = EmbeddingService();
    knowledge = KnowledgePipeline(
      api: api,
      ai: ai,
      embeddings: embeddings,
    );
    _backgroundTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) {
        if (_lifecycleState != AppLifecycleState.resumed) {
          unawaited(_backgroundTick());
        }
      },
    );
    _replyTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_processPendingReplies()),
    );
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_backgroundTick());
    }
  }

  Future<void> _backgroundTick() async {
    if (_backgroundTickRunning) return;
    final enabled = await WhatsBotBackgroundService.preferenceEnabled();
    if (!enabled) return;

    _backgroundTickRunning = true;
    try {
      if (!WhatsBotBackgroundService.isRunning) {
        final started = await WhatsBotBackgroundService.restore();
        if (!started) return;
      }

      final sync = PaqueteriaPurchaseSyncService(api);
      await sync.flush();
      await remittanceSms.syncPending(api);
      await payPalEmail.syncPending(api);

      final latest = await api.getNotes();
      notes = latest;
      await _runPostRefreshIntelligence();

      if (mounted) {
        final pending = await sync.pendingCount();
        setState(() {
          paqueteriaPending = pending;
          notes = List<Note>.from(notes);
        });
      }
    } catch (_) {
      // El siguiente ciclo vuelve a intentar sin interrumpir la app.
    } finally {
      _backgroundTickRunning = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundTimer?.cancel();
    _replyTimer?.cancel();
    search.dispose();
    unawaited(localAi.dispose());
    unawaited(embeddings.dispose());
    super.dispose();
  }

  Future<void> refresh({bool runLocalAi = true}) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await remittanceSms.syncPending(api);
      await payPalEmail.syncPending(api);
      notes = await api.getNotes(query: search.text, category: category);
    } catch (e) {
      error = 'Configura el servidor para comenzar. $e';
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (error == null) {
      final sync = PaqueteriaPurchaseSyncService(api);
      unawaited(() async {
        await sync.flush();
        final pending = await sync.pendingCount();
        if (mounted) setState(() => paqueteriaPending = pending);
      }());
    }
    if (error == null) {
      unawaited(_loadKnowledgeCounts());
      if (runLocalAi) {
        unawaited(_runPostRefreshIntelligence());
      }
    }
  }

  Future<void> _loadKnowledgeCounts() async {
    final drafts = await KnowledgeStore.instance.drafts(status: 'pending');
    if (mounted) setState(() => pendingDrafts = drafts.length);
  }

  Future<void> _runPostRefreshIntelligence() async {
    await _repairContactCategories();
    await _processPendingReplies();
    await _processPendingAi();
    await _processKnowledge();
  }

  Future<void> _repairContactCategories() async {
    final misplaced = notes
        .where(
          (note) =>
              note.source == 'whatsapp' &&
              note.messageType == 'contact' &&
              note.category != 'Clientes',
        )
        .take(50)
        .toList();
    if (misplaced.isEmpty) return;

    var changed = false;
    for (final note in misplaced) {
      try {
        final tags = <String>{
          ...note.tags,
          'contacto',
          'cliente',
          'whatsapp',
        }.toList();
        await api.updateNoteManual(
          note,
          category: 'Clientes',
          tags: tags,
        );
        changed = true;
      } catch (_) {
        // Keep the contact pending; a later refresh will retry.
      }
    }

    if (changed) {
      final refreshed =
          await api.getNotes(query: search.text, category: category);
      notes = refreshed;
      if (mounted) setState(() {});
    }
  }

  Future<void> _processKnowledge() async {
    if (knowledgeRunning) return;
    if (mounted) {
      setState(() {
        knowledgeRunning = true;
        knowledgeDone = 0;
        knowledgeTotal = notes.length;
        knowledgeLabel = '';
      });
    }
    try {
      await knowledge.processNotes(
        notes,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            knowledgeDone = p.done;
            knowledgeTotal = p.total;
            knowledgeLabel = p.label;
          });
        },
      );
      await _loadKnowledgeCounts();
      final refreshed =
          await api.getNotes(query: search.text, category: category);
      if (mounted) setState(() => notes = refreshed);
    } finally {
      if (mounted) setState(() => knowledgeRunning = false);
    }
  }

  Future<void> _processPendingReplies() async {
    if (_replyTickRunning || aiRunning) return;

    _replyTickRunning = true;
    try {
      final pending = await api.pendingWhatsAppReplies(limit: 5);
      if (pending.isEmpty) return;

      final settings = await ai.settings();
      final aiAvailable = settings.autoProcess &&
          settings.provider != AiProvider.rules &&
          !(settings.provider == AiProvider.device &&
              settings.deviceModelPath.trim().isEmpty);

      for (final note in pending) {
        if (note.sender.trim().isEmpty ||
            note.messageType != 'text' ||
            note.replyStatus == 'sent' ||
            note.replyStatus == 'handled') {
          continue;
        }

        final rawMessage = note.originalText.trim().isNotEmpty
            ? note.originalText
            : note.content;

        OcrCorrectionApplyResult? correction;
        try {
          correction = await knowledge.ocr.applyNaturalLanguageCorrection(
            rawMessage,
            note,
          );
        } catch (_) {}

        if (correction == null && aiAvailable) {
          try {
            final interpreted = await ai.interpretOcrCorrection(rawMessage);
            if (interpreted != null) {
              correction = await knowledge.ocr.applyCorrection(
                interpreted,
                note,
              );
            }
          } catch (_) {}
        }

        if (correction != null) {
          final handled = await api.markWhatsappHandled(
            noteId: note.id,
            reason: correction.updatedCount > 0
                ? 'ocr_correction_applied'
                : 'ocr_correction_understood_no_target',
          );
          if (!handled) break;
          continue;
        }

        if (!aiAvailable) continue;

        final reply = await ai.replyToWhatsapp(note);
        if (reply.trim().isEmpty) continue;

        final sent = await api.sendAiReply(
          noteId: note.id,
          body: reply,
        );
        if (!sent) break;
      }
    } catch (_) {
      // Pending items retry on a later foreground/background tick.
    } finally {
      _replyTickRunning = false;
    }
  }

  Future<void> _processPendingAi({bool force = false}) async {
    if (aiRunning || _replyTickRunning) return;
    final settings = await ai.settings();
    if (settings.provider == AiProvider.rules) return;
    if (!settings.autoProcess && !force) return;
    if (settings.provider == AiProvider.device &&
        settings.deviceModelPath.trim().isEmpty) {
      return;
    }

    final sourceId = ai.sourceId(settings.provider);
    final candidates = notes
        .where(
          (n) =>
              n.source == 'whatsapp' &&
              (force || n.aiProvider != sourceId),
        )
        .take(20)
        .toList();
    if (candidates.isEmpty) return;

    if (mounted) {
      setState(() {
        aiRunning = true;
        aiDone = 0;
        aiTotal = candidates.length;
        aiRunningLabel = ai.label(settings.provider);
      });
    }

    try {
      if (settings.provider == AiProvider.device) {
        await localAi.loadModel(settings.deviceModelPath);
      }
      for (final note in candidates) {
        try {
          if (note.category == 'Remesas' || note.messageType == 'remittance') {
            await api.updateNoteFromAi(
              id: note.id,
              title: note.title,
              content: note.content,
              category: 'Remesas',
              tags: note.tags,
              aiProvider: sourceId,
            );
            continue;
          }

          if (note.messageType == 'contact') {
            final tags = <String>{
              ...note.tags,
              'contacto',
              'cliente',
              'whatsapp',
            }.toList();
            await api.updateNoteFromAi(
              id: note.id,
              title: note.title,
              content: note.content,
              category: 'Clientes',
              tags: tags,
              aiProvider: sourceId,
            );
            continue;
          }

          if (note.category == 'Remesas' || note.tags.contains('remesa')) {
            await api.updateNoteFromAi(
              id: note.id,
              title: note.title,
              content: note.content,
              category: 'Remesas',
              tags: note.tags,
              aiProvider: sourceId,
            );
            continue;
          }

          final organized = await ai.organize(note);
          await api.updateNoteFromAi(
            id: note.id,
            title: organized.title,
            content: organized.content,
            category: organized.category,
            tags: organized.tags,
            aiProvider: sourceId,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  ai.label(settings.provider) +
                      ': no se pudo organizar “' +
                      note.title +
                      '”: ' +
                      e.toString(),
                ),
              ),
            );
          }
          break;
        } finally {
          if (mounted) setState(() => aiDone++);
        }
      }
      if (mounted) await refresh(runLocalAi: false);
    } finally {
      if (mounted) setState(() => aiRunning = false);
    }
  }

  String? _imagePathFor(Note note) {
    final media = (note.mediaPath ?? '').trim();
    if (media.isNotEmpty) return media;
    for (final path in note.photoPaths) {
      if (path.trim().isNotEmpty) return path.trim();
    }
    return null;
  }

  bool _isImageNote(Note note) =>
      note.messageType == 'image' ||
      _imagePathFor(note) != null ||
      note.category == 'Fotos';

  Future<Uint8List?> _remoteThumbnail(String path) async {
    final existing = _thumbnailCache[path];
    if (existing != null) {
      final bytes = await existing;
      if (bytes != null && bytes.isNotEmpty) return bytes;
      _thumbnailCache.remove(path);
    }

    final future = api.fetchMediaBytes(path);
    _thumbnailCache[path] = future;
    final bytes = await future;
    if (bytes == null || bytes.isEmpty) {
      _thumbnailCache.remove(path);
    }
    return bytes;
  }

  Widget _imageFallback(Note note) => CircleAvatar(
        child: Icon(typeIcon(note)),
      );

  Widget _noteThumbnail(
    Note note, {
    bool interactive = true,
  }) {
    final path = _imagePathFor(note);
    if (path == null || !_isImageNote(note)) {
      return CircleAvatar(child: Icon(typeIcon(note)));
    }

    final file = File(path);
    if (file.existsSync()) {
      final image = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 62,
          height: 62,
          child: Image.file(
            file,
            fit: BoxFit.cover,
            cacheWidth: 220,
            errorBuilder: (_, __, ___) => _imageFallback(note),
          ),
        ),
      );
      if (!interactive) return image;
      return GestureDetector(
        onTap: () => _openImagePath(path),
        child: image,
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _remoteThumbnail(path),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SizedBox(
            width: 62,
            height: 62,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: const Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }

        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return _imageFallback(note);
        }

        final image = ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 62,
            height: 62,
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              cacheWidth: 220,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _imageFallback(note),
            ),
          ),
        );
        if (!interactive) return image;
        return GestureDetector(
          onTap: () => _openImageBytes(bytes),
          child: image,
        );
      },
    );
  }

  Future<void> _openImagePath(String path) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenImageViewer.file(
          title: 'Imagen',
          path: path,
        ),
      ),
    );
  }

  Future<void> _openImageBytes(Uint8List bytes) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenImageViewer.memory(
          title: 'Imagen',
          bytes: bytes,
        ),
      ),
    );
  }

  bool get selectionMode => selectedNoteIds.isNotEmpty;

  void _toggleSelection(Note note) {
    setState(() {
      if (!selectedNoteIds.add(note.id)) {
        selectedNoteIds.remove(note.id);
      }
    });
  }

  void _clearSelection() {
    if (selectedNoteIds.isEmpty) return;
    setState(selectedNoteIds.clear);
  }

  Future<void> _shareSelected() async {
    if (shareWorking || selectedNoteIds.isEmpty) return;
    final selected = notes
        .where((note) => selectedNoteIds.contains(note.id))
        .toList();
    if (selected.isEmpty) {
      _clearSelection();
      return;
    }

    setState(() => shareWorking = true);
    try {
      await NoteShareService(api).shareNotes(selected);
      if (mounted) _clearSelection();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudieron compartir los archivos: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => shareWorking = false);
    }
  }

  Future<void> _deleteSelectedNotes() async {
    if (deleteSelectionWorking || selectedNoteIds.isEmpty) return;

    final selected = notes
        .where((note) => selectedNoteIds.contains(note.id))
        .toList();
    if (selected.isEmpty) {
      _clearSelection();
      return;
    }

    final count = selected.length;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              count == 1 ? 'Borrar nota' : 'Borrar $count notas',
            ),
            content: Text(
              count == 1
                  ? '¿Quieres borrar la nota seleccionada?'
                  : '¿Quieres borrar las $count notas seleccionadas?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.delete_outline),
                label: Text(count == 1 ? 'Borrar' : 'Borrar todas'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => deleteSelectionWorking = true);
    var deleted = 0;
    final failed = <Note>[];

    for (final note in selected) {
      try {
        await api.deleteNote(note.id);
        final imagePath = _imagePathFor(note);
        if (imagePath != null) _thumbnailCache.remove(imagePath);
        deleted++;
      } catch (_) {
        failed.add(note);
      }
    }

    if (!mounted) return;
    setState(() {
      selectedNoteIds
        ..clear()
        ..addAll(failed.map((note) => note.id));
      deleteSelectionWorking = false;
    });

    await refresh(runLocalAi: false);
    if (!mounted) return;

    final message = failed.isEmpty
        ? (deleted == 1 ? 'Nota borrada.' : '$deleted notas borradas.')
        : '$deleted borradas; ${failed.length} no se pudieron borrar.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> add() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => NewNotePage(api: api)),
    );
    if (changed == true) refresh();
  }

  Future<void> remove(Note n) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Borrar nota'),
            content: Text('¿Borrar “${n.title}”?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Borrar')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await api.deleteNote(n.id);
      await refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String date(Note n) {
    final d = n.createdAt.toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} · '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  IconData typeIcon(Note n) => switch (n.messageType) {
        'image' => Icons.image_outlined,
        'audio' => Icons.mic_none,
        'document' => Icons.description_outlined,
        'contact' => Icons.person_add_alt_1_outlined,
        'remittance' => Icons.payments_outlined,
        _ => Icons.notes_outlined,
      };

  String aiLabel(Note n) => switch (n.aiProvider) {
        'openai' => 'OpenAI',
        'gemini' => 'Gemini',
        'local_server' => 'IA local',
        'manager' => 'Local AI Manager',
        'local' => 'GGUF local',
        'server' => 'IA servidor',
        _ => 'Reglas',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: selectionMode
            ? IconButton(
                tooltip: 'Cancelar selección',
                onPressed: _clearSelection,
                icon: const Icon(Icons.close),
              )
            : null,
        title: Text(
          selectionMode
              ? '${selectedNoteIds.length} seleccionado(s)'
              : 'WhatsBot',
        ),
        actions: selectionMode
            ? [
                IconButton(
                  tooltip: 'Borrar seleccionados',
                  onPressed: deleteSelectionWorking || shareWorking
                      ? null
                      : _deleteSelectedNotes,
                  icon: deleteSelectionWorking
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                ),
                IconButton(
                  tooltip: 'Compartir seleccionados',
                  onPressed: deleteSelectionWorking || shareWorking
                      ? null
                      : _shareSelected,
                  icon: shareWorking
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.share_outlined),
                ),
              ]
            : [
          IconButton(
            tooltip: 'Conversaciones de WhatsApp',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConversationsPage(api: api),
              ),
            ),
            icon: const Icon(Icons.forum_outlined),
          ),
          IconButton(
            tooltip: 'Actividad de WhatsBot',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AiActivityPage(api: api),
              ),
            ),
            icon: const Icon(Icons.timeline_outlined),
          ),
          IconButton(
            tooltip: 'Chat con tus notas',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => KnowledgeChatPage(
                  api: api,
                  ai: ai,
                  embeddings: embeddings,
                ),
              ),
            ),
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            tooltip: 'Entidades',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => EntitiesPage(
                  api: api,
                  ai: ai,
                  embeddings: embeddings,
                ),
              ),
            ),
            icon: const Icon(Icons.account_tree_outlined),
          ),
          IconButton(
            tooltip: 'Paquetería',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ComboPage(api: api)),
              );
              if (mounted) refresh();
            },
            icon: const Icon(Icons.hub_outlined),
          ),
          IconButton(
            tooltip: 'Inteligencia artificial',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AiSettingsPage(
                    api: api,
                    localAi: localAi,
                    onProcessNow: () => _processPendingAi(force: true),
                  ),
                ),
              );
              if (mounted) refresh();
            },
            icon: const Icon(Icons.psychology_outlined),
          ),
          IconButton(
            tooltip: 'Configuración',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsPage(api: api)),
              );
              if (mounted) refresh();
            },
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: selectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: add,
              icon: const Icon(Icons.add),
              label: const Text('Nota'),
            ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            Text('Tu bandeja personal desde WhatsApp', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (pendingDrafts > 0)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.pending_actions_outlined),
                  title: Text(
                    '$pendingDrafts borrador(es) OCR pendientes de confirmar',
                  ),
                  subtitle: const Text(
                    'Revísalos antes de confirmar compras o remesas.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final drafts = await KnowledgeStore.instance
                        .drafts(status: 'pending');
                    if (!mounted || drafts.isEmpty) return;
                    final first = drafts.first;
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => first.draftType == 'remittance'
                            ? RemittanceDraftReviewPage(
                                draft: first,
                                api: api,
                              )
                            : DraftReviewPage(
                                draft: first,
                                api: api,
                              ),
                      ),
                    );
                    if (mounted) {
                      await _loadKnowledgeCounts();
                      refresh();
                    }
                  },
                ),
              ),
            if (paqueteriaPending > 0)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.sync_problem_outlined),
                  title: Text(
                    paqueteriaPending.toString() +
                        ' compra(s) pendientes de sincronizar con Paquetería',
                  ),
                  subtitle: const Text(
                    'WhatsBot las conserva localmente y volverá a intentarlo automáticamente.',
                  ),
                  trailing: IconButton(
                    tooltip: 'Reintentar',
                    onPressed: refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ),
            if (knowledgeRunning)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Analizando Inbox… $knowledgeDone/$knowledgeTotal'
                          '${knowledgeLabel.isEmpty ? '' : ' · $knowledgeLabel'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (aiRunning)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          aiRunningLabel +
                              ' organizando notas… ' +
                              aiDone.toString() +
                              '/' +
                              aiTotal.toString(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            SearchBar(
              controller: search,
              hintText: 'Buscar nombres, precios, ideas…',
              leading: const Icon(Icons.search),
              trailing: [
                IconButton(
                  onPressed: () {
                    search.clear();
                    refresh();
                  },
                  icon: const Icon(Icons.clear),
                ),
              ],
              onSubmitted: (_) => refresh(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: categories
                    .map(
                      (c) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(c),
                          selected: category == c,
                          onSelected: (_) {
                            setState(() => category = c);
                            refresh();
                          },
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
            if (loading)
              const Padding(padding: EdgeInsets.all(36), child: Center(child: CircularProgressIndicator())),
            if (error != null && !loading)
              Card(child: Padding(padding: const EdgeInsets.all(18), child: Text(error!))),
            if (!loading && error == null && notes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(36),
                child: Center(child: Text('Todavía no hay notas. Envíale un mensaje al bot o crea una manual.')),
              ),
            ...notes.map(
              (n) => Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  selected: selectedNoteIds.contains(n.id),
                  leading: SizedBox(
                    width: 62,
                    height: 62,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        _noteThumbnail(
                          n,
                          interactive: !selectionMode,
                        ),
                        if (selectedNoteIds.contains(n.id))
                          Positioned(
                            right: -3,
                            bottom: -3,
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor:
                                  Theme.of(context).colorScheme.primary,
                              child: Icon(
                                Icons.check,
                                size: 16,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  title: Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      if (n.isPurchase && n.customerName.isNotEmpty) ...[
                        Text(
                          n.customerPhone.isEmpty
                              ? n.customerName
                              : '${n.customerName} · ${n.customerPhone}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(n.content.replaceAll('\n', ' '), maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 6),
                      Text(
                        '${n.category} · ${n.source == 'whatsapp' ? 'WhatsApp' : 'Manual'} · ${aiLabel(n)} · ${date(n)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  trailing: selectionMode
                      ? Checkbox(
                          value: selectedNoteIds.contains(n.id),
                          onChanged: deleteSelectionWorking
                              ? null
                              : (_) => _toggleSelection(n),
                        )
                      : PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'delete') remove(n);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Borrar'),
                            ),
                          ],
                        ),
                  onLongPress: () => _toggleSelection(n),
                  onTap: () async {
                    if (selectionMode) {
                      _toggleSelection(n);
                      return;
                    }
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => NoteDetailPage(note: n, api: api),
                      ),
                    );
                    if (mounted) refresh();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
