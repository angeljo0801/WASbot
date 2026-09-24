import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/entity_record.dart';
import '../models/note.dart';
import '../services/ai_provider_service.dart';
import '../services/api_service.dart';
import '../services/embedding_service.dart';
import '../services/knowledge_store.dart';
import 'note_detail_page.dart';

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
  final scroll = ScrollController();
  List<Map<String, dynamic>> messages = [];
  List<Note> notes = [];
  bool loading = true;
  bool sending = false;
  bool embeddingReady = false;
  bool downloading = false;
  double downloadProgress = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final values = await Future.wait([
      widget.api.getNotes(),
      store.chatMessages(),
      widget.embeddings.isReady(),
    ]);
    if (!mounted) return;
    setState(() {
      notes = values[0] as List<Note>;
      messages = values[1] as List<Map<String, dynamic>>;
      embeddingReady = values[2] as bool;
      loading = false;
    });
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
            content: Text('Memoria semántica lista. Las notas ya se pueden buscar por significado.'),
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

  List<String> _sourceKeys(Map<String, dynamic> message) {
    final raw = message['sources_json'];
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return const <String>[];
  }

  Note? _noteForKey(String key) {
    for (final note in notes) {
      if (KnowledgeStore.noteKey(note) == key) return note;
    }
    return null;
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
        ? firstLine.substring(0, 260) + '…'
        : firstLine;
  }

  String _excerpt(Note note) {
    final text = (note.content.trim().isNotEmpty
            ? note.content
            : note.originalText)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length > 900 ? '${text.substring(0, 900)}…' : text;
  }

  Future<void> send() async {
    final question = input.text.trim();
    if (question.isEmpty || sending) return;
    input.clear();
    await store.addChatMessage('user', question);
    setState(() {
      messages.add({'role': 'user', 'text': question});
      sending = true;
    });
    _scrollDown();

    try {
      final entity = await _entityInQuestion(question);
      Set<String>? restrict;
      if (entity != null) {
        restrict = (await store.noteKeysForEntity(entity.id)).toSet();
      }

      final hits = await widget.embeddings.search(
        question,
        notes,
        limit: 8,
        restrictKeys: restrict,
      );
      final selected = hits.isNotEmpty
          ? hits.map((e) => e.note).toList()
          : (restrict == null
              ? notes.take(8).toList()
              : notes
                  .where((n) => restrict!.contains(KnowledgeStore.noteKey(n)))
                  .take(8)
                  .toList());

      final blocks = <String>[];
      for (var i = 0; i < selected.length; i++) {
        final note = selected[i];
        final state = await store.noteState(KnowledgeStore.noteKey(note));
        final ocr = (state?['ocr_text'] ?? '').toString().trim();
        blocks.add(
          '[N${i + 1}] ${note.title}\n'
          'Categoría: ${note.category}\n'
          'Fecha: ${note.createdAt.toLocal()}\n'
          'Contenido: ${_excerpt(note)}'
          '${ocr.isEmpty ? '' : '\nOCR: ${ocr.length > 700 ? ocr.substring(0, 700) + '…' : ocr}'}',
        );
      }

      final recent = messages
          .where((m) => m['role'] == 'user' || m['role'] == 'assistant')
          .toList()
          .reversed
          .take(6)
          .toList()
          .reversed
          .map((m) => '${m['role']}: ${m['text']}')
          .join('\n');

      const system =
          'Eres el chat privado de conocimiento de WhatsBot. '
          'Responde usando como fuente principal las notas recuperadas. '
          'Si una respuesta no está sustentada por las notas, dilo claramente. '
          'No inventes nombres, montos, fechas, tracking ni relaciones. '
          'Cuando uses una nota, cita su marcador [N1], [N2], etc. '
          'Puedes conectar información de varias notas cuando sea razonable.';
      final prompt = [
        if (entity != null)
          'Entidad consultada: ${entity.name} (${entity.type})',
        'Conversación reciente:\n$recent',
        'Pregunta actual: $question',
        'Notas recuperadas:\n${blocks.isEmpty ? '(sin notas relevantes)' : blocks.join('\n\n')}',
      ].join('\n\n');

      final answer = await widget.ai.ask(
        system: system,
        prompt: prompt,
        maxTokens: 1200,
        temperature: 0.2,
      );
      final sourceKeys =
          selected.map(KnowledgeStore.noteKey).toList(growable: false);
      await store.addChatMessage(
        'assistant',
        answer,
        sourceKeys: sourceKeys,
      );
      if (!mounted) return;
      setState(() {
        messages.add({
          'role': 'assistant',
          'text': answer,
          'sources_json': jsonEncode(sourceKeys),
        });
      });
    } catch (e) {
      final message = 'No pude responder: ' + _friendlyAiError(e);
      await store.addChatMessage('assistant', message);
      if (mounted) {
        setState(() => messages.add({'role': 'assistant', 'text': message}));
      }
    } finally {
      if (mounted) setState(() => sending = false);
      _scrollDown();
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasClients) return;
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final entity = widget.entity;
    return Scaffold(
      appBar: AppBar(
        title: Text(entity == null ? 'Chat con tus notas' : 'Chat · ${entity.name}'),
        actions: [
          IconButton(
            tooltip: 'Limpiar conversación',
            onPressed: () async {
              await store.clearChat();
              if (mounted) setState(() => messages.clear());
            },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!embeddingReady)
              MaterialBanner(
                content: Text(
                  downloading
                      ? 'Preparando el modelo de embeddings… ${(downloadProgress * 100).round()}%'
                      : 'Activa la memoria semántica para buscar por significado en todas las notas.',
                ),
                leading: const Icon(Icons.memory_outlined),
                actions: [
                  TextButton(
                    onPressed: downloading ? null : downloadEmbeddings,
                    child: const Text('Descargar'),
                  ),
                ],
              ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                      itemCount: messages.length + (sending ? 1 : 0),
                      itemBuilder: (_, index) {
                        if (index == messages.length) {
                          return const Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }
                        final m = messages[index];
                        final user = m['role'] == 'user';
                        final sourceNotes = _sourceKeys(m)
                            .map(_noteForKey)
                            .whereType<Note>()
                            .toList();
                        return Align(
                          alignment:
                              user ? Alignment.centerRight : Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520),
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SelectableText(
                                      (m['text'] ?? '').toString(),
                                    ),
                                    if (!user && sourceNotes.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      const Text(
                                        'Fuentes',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: [
                                          for (var i = 0;
                                              i < sourceNotes.length;
                                              i++)
                                            ActionChip(
                                              avatar: const Icon(
                                                Icons.notes_outlined,
                                                size: 16,
                                              ),
                                              label: Text(
                                                '[N${i + 1}] ${sourceNotes[i].title}',
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              onPressed: () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) => NoteDetailPage(
                                                    note: sourceNotes[i],
                                                    api: widget.api,
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      minLines: 1,
                      maxLines: 5,
                      onSubmitted: (_) => send(),
                      decoration: InputDecoration(
                        hintText: entity == null
                            ? 'Pregunta por María, un tracking, una compra…'
                            : 'Pregunta cualquier cosa sobre ${entity.name}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: sending ? null : send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
