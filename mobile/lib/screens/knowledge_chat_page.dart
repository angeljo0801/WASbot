import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/entity_record.dart';
import '../models/note.dart';
import '../services/ai_provider_service.dart';
import '../services/api_service.dart';
import '../services/embedding_service.dart';
import '../services/knowledge_chat_store.dart';
import '../services/knowledge_store.dart';
import 'knowledge_chat_widgets.dart';

class KnowledgeChatPage extends StatefulWidget {
  final ApiService api;
  final AiProviderService ai;
  final EmbeddingService embeddings;
  final EntityRecord? entity;

  const KnowledgeChatPage({
    super.key,
    required this.api,
    required this.ai,
    required this.embeddings,
    this.entity,
  });

  @override
  State<KnowledgeChatPage> createState() => _KnowledgeChatPageState();
}

class _KnowledgeChatPageState extends State<KnowledgeChatPage> {
  final store = KnowledgeStore.instance;
  final input = TextEditingController();

  List<KnowledgeChatSession> chats = [];
  String? activeId;
  List<Note> notes = [];

  bool loading = true;
  bool sending = false;
  bool embeddingReady = false;
  bool downloading = false;
  double downloadProgress = 0;

  bool useNotes = true;
  String responseMode = 'normal';

  Timer? _responseTimer;
  DateTime? _responseStartedAt;
  double _responseSeconds = 0;
  int _turnToken = 0;
  bool _cancelRequested = false;

  KnowledgeChatSession? get active {
    if (chats.isEmpty) return null;
    return chats.firstWhere(
      (c) => c.id == activeId,
      orElse: () => chats.first,
    );
  }

  String get _ownerType => widget.entity == null ? 'knowledge' : 'entity';
  String get _ownerId => widget.entity?.id ?? 'main';
  String get _participantName =>
      widget.entity == null ? 'WhatsBot AI' : 'WhatsBot · ${widget.entity!.name}';

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    _responseTimer?.cancel();
    input.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    var sessions = await KnowledgeChatStore.listFor(_ownerType, _ownerId);
    final allNotes = await widget.api.getNotes();
    final ready = await widget.embeddings.isReady();

    if (sessions.isEmpty) {
      final legacy = await store.chatMessages();
      if (widget.entity == null && legacy.isNotEmpty) {
        final now = DateTime.now();
        final imported = KnowledgeChatSession(
          id: 'chat_imported_${now.microsecondsSinceEpoch}',
          ownerType: _ownerType,
          ownerId: _ownerId,
          title: 'Chat anterior',
          createdAt: now,
          updatedAt: now,
          messages: legacy.map((m) {
            var sourceKeys = <String>[];
            final raw = m['sources_json'];
            if (raw is String && raw.isNotEmpty) {
              try {
                final decoded = jsonDecode(raw);
                if (decoded is List) {
                  sourceKeys =
                      decoded.map((e) => e.toString()).toList(growable: false);
                }
              } catch (_) {}
            }
            return KnowledgeChatMessage(
              role: (m['role'] ?? '').toString() == 'assistant'
                  ? 'assistant'
                  : 'user',
              text: (m['text'] ?? '').toString(),
              createdAt:
                  DateTime.tryParse((m['created_at'] ?? '').toString()) ?? now,
              sourceKeys: sourceKeys,
            );
          }).toList(),
        );
        await KnowledgeChatStore.save(imported);
        sessions = [imported];
      } else {
        final created = KnowledgeChatSession.empty(
          ownerType: _ownerType,
          ownerId: _ownerId,
        );
        await KnowledgeChatStore.save(created);
        sessions = [created];
      }
    }

    if (!mounted) return;
    setState(() {
      chats = sessions;
      activeId = sessions.first.id;
      notes = allNotes;
      embeddingReady = ready;
      useNotes = prefs.getBool('whatsbot_chat_use_notes') ?? true;
      responseMode =
          prefs.getString('whatsbot_chat_response_mode') ?? 'normal';
      loading = false;
    });
  }

  void _put(KnowledgeChatSession session) {
    final next = List<KnowledgeChatSession>.from(chats);
    final index = next.indexWhere((c) => c.id == session.id);
    if (index >= 0) {
      next[index] = session;
    } else {
      next.insert(0, session);
    }
    next.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (mounted) {
      setState(() {
        chats = next;
        activeId = session.id;
      });
    }
  }

  Future<void> _newChat() async {
    if (sending) return;
    final created = KnowledgeChatSession.empty(
      ownerType: _ownerType,
      ownerId: _ownerId,
    );
    await KnowledgeChatStore.save(created);
    _put(created);
  }

  Future<void> _delete(KnowledgeChatSession session) async {
    await KnowledgeChatStore.delete(session.id);
    var next = chats.where((c) => c.id != session.id).toList();
    if (next.isEmpty) {
      final created = KnowledgeChatSession.empty(
        ownerType: _ownerType,
        ownerId: _ownerId,
      );
      await KnowledgeChatStore.save(created);
      next = [created];
    }
    if (!mounted) return;
    setState(() {
      chats = next;
      activeId = next.first.id;
    });
  }

  Future<void> _export(KnowledgeChatSession session) async {
    if (session.messages.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Este chat todavía está vacío.')),
        );
      }
      return;
    }
    final path = await KnowledgeChatStore.exportPdf(
      session,
      participantName: _participantName,
    );
    if (!mounted || path == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Chat exportado como PDF.')),
    );
  }

  Future<void> _history() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (bc) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(bc).size.height * .72,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Historial de chats',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Nuevo chat',
                      onPressed: () {
                        Navigator.pop(bc);
                        _newChat();
                      },
                      icon: const Icon(Icons.add_comment_outlined),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final c in chats)
                      ListTile(
                        leading: Icon(
                          c.id == activeId
                              ? Icons.chat_bubble
                              : Icons.chat_bubble_outline,
                        ),
                        title: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('${c.messages.length} mensaje(s)'),
                        onTap: () {
                          setState(() => activeId = c.id);
                          Navigator.pop(bc);
                        },
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: 'Exportar PDF',
                              onPressed: () => _export(c),
                              icon: const Icon(Icons.picture_as_pdf_outlined),
                            ),
                            IconButton(
                              tooltip: 'Borrar',
                              onPressed: () {
                                Navigator.pop(bc);
                                _delete(c);
                              },
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setResponseMode(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('whatsbot_chat_response_mode', value);
    if (mounted) setState(() => responseMode = value);
  }

  Future<void> _setUseNotes(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('whatsbot_chat_use_notes', value);
    if (mounted) setState(() => useNotes = value);
  }

  void _startResponseTimer() {
    _responseTimer?.cancel();
    _responseStartedAt = DateTime.now();
    _responseSeconds = 0;
    _responseTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (!mounted || _responseStartedAt == null) return;
        setState(() {
          _responseSeconds = DateTime.now()
                  .difference(_responseStartedAt!)
                  .inMilliseconds /
              1000.0;
        });
      },
    );
  }

  void _stopResponseTimer() {
    if (_responseStartedAt != null) {
      _responseSeconds =
          DateTime.now().difference(_responseStartedAt!).inMilliseconds /
              1000.0;
    }
    _responseTimer?.cancel();
    _responseTimer = null;
    _responseStartedAt = null;
  }

  Future<void> downloadEmbeddings() async {
    if (downloading) return;
    setState(() {
      downloading = true;
      downloadProgress = 0;
    });
    try {
      await widget.embeddings.downloadModel(
        onProgress: (p) {
          if (mounted) setState(() => downloadProgress = p.fraction);
        },
      );
      await widget.embeddings.indexAll(
        notes,
        onProgress: (done, total) {
          if (mounted && total > 0) {
            setState(() => downloadProgress = done / total);
          }
        },
      );
      if (mounted) {
        setState(() => embeddingReady = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Memoria semántica lista. Las notas ya se pueden buscar por significado.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo preparar embeddings: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  Future<EntityRecord?> _entityInQuestion(String question) async {
    if (widget.entity != null) return widget.entity;
    final normalized = store.normalizeName(question);
    final entities = await store.entities();
    EntityRecord? best;
    for (final entity in entities) {
      if (entity.normalizedName.length < 2) continue;
      if (normalized == entity.normalizedName ||
          normalized.contains(entity.normalizedName)) {
        if (best == null ||
            entity.normalizedName.length > best.normalizedName.length) {
          best = entity;
        }
      }
    }
    return best;
  }

  String _excerpt(Note note, int maxChars) {
    final text = (note.content.trim().isNotEmpty
            ? note.content
            : note.originalText)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length > maxChars
        ? '${text.substring(0, maxChars)}…'
        : text;
  }

  String _friendlyAiError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('failed to load model') ||
        lower.contains('no pude cargar el gguf') ||
        lower.contains('modelo local no pudo cargarse')) {
      return 'No pude cargar el modelo local. WhatsBot intentó también Local AI Manager. '
          'Abre Ajustes de IA y usa Local AI Manager o vuelve a seleccionar el GGUF.';
    }
    if (lower.contains('local ai manager') &&
        (lower.contains('no respondió') || lower.contains('comunicarme'))) {
      return 'Local AI Manager no respondió. Ábrelo, carga el modelo y vuelve a intentar.';
    }
    final firstLine = text.split('\n').first.trim();
    return firstLine.length > 260
        ? '${firstLine.substring(0, 260)}…'
        : firstLine;
  }

  Future<void> _stop() async {
    if (!sending) return;
    _cancelRequested = true;
    _turnToken++;
    await widget.ai.cancelCurrent();
    _stopResponseTimer();

    final session = active;
    if (session != null &&
        session.messages.isNotEmpty &&
        session.messages.last.role == 'assistant') {
      final nextMessages =
          List<KnowledgeChatMessage>.from(session.messages);
      if (nextMessages.last.text.trim().isEmpty ||
          nextMessages.last.text == 'Pensando…') {
        nextMessages[nextMessages.length - 1] =
            nextMessages.last.copyWith(
          text: 'Respuesta detenida.',
          responseSeconds: _responseSeconds,
        );
      } else {
        nextMessages[nextMessages.length - 1] =
            nextMessages.last.copyWith(
          responseSeconds: _responseSeconds,
        );
      }
      final saved = session.copyWith(
        updatedAt: DateTime.now(),
        messages: nextMessages,
      );
      _put(saved);
      await KnowledgeChatStore.save(saved);
    }
    if (mounted) setState(() => sending = false);
  }

  Future<void> send() async {
    final question = input.text.trim();
    final session = active;
    if (question.isEmpty || sending || session == null) return;

    input.clear();
    final history = session.conversationContext(
      maxChars: responseMode == 'fast'
          ? 3500
          : responseMode == 'deep'
              ? 9000
              : 6000,
      maxMessages: responseMode == 'fast'
          ? 8
          : responseMode == 'deep'
              ? 18
              : 12,
    );

    final now = DateTime.now();
    final pendingMessages =
        List<KnowledgeChatMessage>.from(session.messages)
          ..add(
            KnowledgeChatMessage(
              role: 'user',
              text: question,
              createdAt: now,
            ),
          )
          ..add(
            KnowledgeChatMessage(
              role: 'assistant',
              text: 'Pensando…',
              createdAt: now,
            ),
          );

    final pending = session.copyWith(
      title: session.messages.isEmpty
          ? KnowledgeChatSession.titleFrom(question)
          : session.title,
      updatedAt: now,
      messages: pendingMessages,
    );
    _put(pending);
    await KnowledgeChatStore.save(pending);

    final token = ++_turnToken;
    _cancelRequested = false;
    if (mounted) setState(() => sending = true);
    _startResponseTimer();

    try {
      EntityRecord? entity;
      Set<String>? restrict;
      List<Note> selected = [];

      if (useNotes) {
        entity = await _entityInQuestion(question);
        if (entity != null) {
          restrict = (await store.noteKeysForEntity(entity.id)).toSet();
        }

        final limit = responseMode == 'fast'
            ? 4
            : responseMode == 'deep'
                ? 12
                : 8;
        final hits = await widget.embeddings.search(
          question,
          notes,
          limit: limit,
          restrictKeys: restrict,
        );
        selected = hits.isNotEmpty
            ? hits.map((e) => e.note).toList()
            : (restrict == null
                ? notes.take(limit).toList()
                : notes
                    .where(
                      (n) => restrict!.contains(
                        KnowledgeStore.noteKey(n),
                      ),
                    )
                    .take(limit)
                    .toList());
      }

      final excerptLimit = responseMode == 'fast'
          ? 450
          : responseMode == 'deep'
              ? 1200
              : 850;

      final blocks = <String>[];
      for (var i = 0; i < selected.length; i++) {
        final note = selected[i];
        final state =
            await store.noteState(KnowledgeStore.noteKey(note));
        final ocr = (state?['ocr_text'] ?? '').toString().trim();
        final clippedOcr = ocr.length > excerptLimit
            ? '${ocr.substring(0, excerptLimit)}…'
            : ocr;
        blocks.add(
          '[N${i + 1}] ${note.title}\n'
          'Categoría: ${note.category}\n'
          'Fecha: ${note.createdAt.toLocal()}\n'
          'Contenido: ${_excerpt(note, excerptLimit)}'
          '${clippedOcr.isEmpty ? '' : '\nOCR: $clippedOcr'}',
        );
      }

      const system =
          'Eres el chat privado de conocimiento de WhatsBot. '
          'Habla de forma natural y útil. '
          'Cuando se habiliten las notas, úsalas como fuente principal para datos personales del usuario. '
          'Si un dato debería venir de las notas y no aparece, dilo claramente. '
          'No inventes nombres, montos, fechas, tracking ni relaciones. '
          'Cuando uses una nota, cita su marcador [N1], [N2], etc. '
          'Puedes conectar información de varias notas cuando sea razonable.';

      final promptParts = <String>[
        'CONVERSACIÓN:\n$history',
        if (useNotes && entity != null)
          'Entidad consultada: ${entity.name} (${entity.type})',
        if (useNotes)
          'BASE DE NOTAS RELEVANTE:\n'
              '${blocks.isEmpty ? '(sin notas relevantes)' : blocks.join('\n\n')}'
        else
          'BASE DE NOTAS: desactivada para este mensaje.',
        'PREGUNTA:\n$question',
      ];

      final answer = await widget.ai.ask(
        system: system,
        prompt: promptParts.join('\n\n'),
        maxTokens: responseMode == 'fast'
            ? 650
            : responseMode == 'deep'
                ? 1900
                : 1200,
        temperature: responseMode == 'deep' ? 0.15 : 0.2,
      );

      if (!mounted ||
          token != _turnToken ||
          _cancelRequested) {
        return;
      }

      _stopResponseTimer();
      final current = active;
      if (current == null ||
          current.id != pending.id ||
          current.messages.isEmpty) {
        return;
      }

      final nextMessages =
          List<KnowledgeChatMessage>.from(current.messages);
      nextMessages[nextMessages.length - 1] =
          nextMessages.last.copyWith(
        text: answer,
        sourceKeys:
            selected.map(KnowledgeStore.noteKey).toList(growable: false),
        responseSeconds: _responseSeconds,
      );

      final saved = current.copyWith(
        updatedAt: DateTime.now(),
        messages: nextMessages,
      );
      _put(saved);
      await KnowledgeChatStore.save(saved);
    } catch (e) {
      if (!mounted || token != _turnToken || _cancelRequested) {
        return;
      }
      _stopResponseTimer();
      final current = active;
      if (current != null &&
          current.id == pending.id &&
          current.messages.isNotEmpty) {
        final nextMessages =
            List<KnowledgeChatMessage>.from(current.messages);
        nextMessages[nextMessages.length - 1] =
            nextMessages.last.copyWith(
          text: 'No pude responder: ${_friendlyAiError(e)}',
          responseSeconds: _responseSeconds,
        );
        final saved = current.copyWith(
          updatedAt: DateTime.now(),
          messages: nextMessages,
        );
        _put(saved);
        await KnowledgeChatStore.save(saved);
      }
    } finally {
      if (token == _turnToken) {
        _stopResponseTimer();
        if (mounted) setState(() => sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = active;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entity == null
              ? 'Chat con tus notas'
              : 'Chat · ${widget.entity!.name}',
        ),
        actions: [
          IconButton(
            tooltip: 'Nuevo chat',
            onPressed: sending ? null : _newChat,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: 'Historial',
            onPressed: sending ? null : _history,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: 'Exportar PDF',
            onPressed:
                session == null ? null : () => _export(session),
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'fast',
                          label: Text('Fast'),
                        ),
                        ButtonSegment(
                          value: 'normal',
                          label: Text('Normal'),
                        ),
                        ButtonSegment(
                          value: 'deep',
                          label: Text('Deep'),
                        ),
                      ],
                      selected: {responseMode},
                      onSelectionChanged: sending
                          ? null
                          : (values) =>
                              _setResponseMode(values.first),
                    ),
                  ),
                  SwitchListTile(
                    dense: true,
                    title: const Text('Usar tus notas'),
                    subtitle: Text(
                      useNotes
                          ? 'Puede consultar notas, OCR y entidades cuando sean relevantes.'
                          : 'Chat general sin consultar tu base de notas.',
                    ),
                    value: useNotes,
                    onChanged: sending ? null : _setUseNotes,
                  ),
                  if (useNotes && !embeddingReady)
                    MaterialBanner(
                      content: Text(
                        downloading
                            ? 'Preparando embeddings… ${(downloadProgress * 100).round()}%'
                            : 'Activa la memoria semántica para buscar por significado.',
                      ),
                      leading: const Icon(Icons.memory_outlined),
                      actions: [
                        TextButton(
                          onPressed:
                              downloading ? null : downloadEmbeddings,
                          child: const Text('Descargar'),
                        ),
                      ],
                    ),
                  const Divider(height: 1),
                  Expanded(
                    child: KnowledgeChatTranscript(
                      messages:
                          session?.messages ?? const [],
                      participantName: _participantName,
                      api: widget.api,
                      notes: notes,
                      emptyText: widget.entity == null
                          ? 'Pregunta cualquier cosa. Puedes consultar tus notas, clientes, compras, tracking y OCR.'
                          : 'Pregunta cualquier cosa sobre ${widget.entity!.name}.',
                      liveResponseSeconds: _responseSeconds,
                      isResponding: sending,
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: input,
                              minLines: 1,
                              maxLines: 5,
                              textInputAction:
                                  TextInputAction.newline,
                              decoration: InputDecoration(
                                hintText: widget.entity == null
                                    ? 'Pregúntale cualquier cosa…'
                                    : 'Pregunta sobre ${widget.entity!.name}…',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          sending
                              ? IconButton(
                                  tooltip: 'Detener',
                                  onPressed: _stop,
                                  icon: const Icon(
                                    Icons.stop_circle_outlined,
                                  ),
                                )
                              : IconButton(
                                  tooltip: 'Enviar',
                                  onPressed: send,
                                  icon:
                                      const Icon(Icons.send_rounded),
                                ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
