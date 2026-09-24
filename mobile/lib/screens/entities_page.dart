import 'package:flutter/material.dart';

import '../models/entity_record.dart';
import '../models/note.dart';
import '../services/ai_provider_service.dart';
import '../services/api_service.dart';
import '../services/embedding_service.dart';
import '../services/knowledge_store.dart';
import 'knowledge_chat_page.dart';
import 'note_detail_page.dart';

class EntitiesPage extends StatefulWidget {
  final ApiService api;
  final AiProviderService ai;
  final EmbeddingService embeddings;

  const EntitiesPage({
    super.key,
    required this.api,
    required this.ai,
    required this.embeddings,
  });

  @override
  State<EntitiesPage> createState() => _EntitiesPageState();
}

class _EntitiesPageState extends State<EntitiesPage> {
  final store = KnowledgeStore.instance;
  final search = TextEditingController();
  List<EntityRecord> entities = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final values = await store.entities(query: search.text);
    if (!mounted) return;
    setState(() {
      entities = values;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Entidades')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              const Text(
                'Personas, clientes, tiendas, pedidos y tracking relacionados con tus notas.',
              ),
              const SizedBox(height: 12),
              SearchBar(
                controller: search,
                hintText: 'Buscar María, Amazon, tracking…',
                leading: const Icon(Icons.search),
                onSubmitted: (_) => load(),
                trailing: [
                  IconButton(
                    onPressed: () {
                      search.clear();
                      load();
                    },
                    icon: const Icon(Icons.clear),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (loading)
                const Center(child: CircularProgressIndicator())
              else if (entities.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text(
                      'Todavía no hay entidades. WhatsBot las irá creando y relacionando a medida que procese tus notas.',
                    ),
                  ),
                )
              else
                ...entities.map(
                  (entity) => Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Icon(
                          entity.type == 'cliente'
                              ? Icons.person_outline
                              : entity.type == 'tienda'
                                  ? Icons.store_outlined
                                  : entity.type == 'tracking'
                                      ? Icons.local_shipping_outlined
                                      : Icons.hub_outlined,
                        ),
                      ),
                      title: Text(entity.name),
                      subtitle: Text(
                        '${entity.type} · ${entity.noteCount} nota(s) relacionada(s)',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EntityDetailPage(
                            entity: entity,
                            api: widget.api,
                            ai: widget.ai,
                            embeddings: widget.embeddings,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

class EntityDetailPage extends StatefulWidget {
  final EntityRecord entity;
  final ApiService api;
  final AiProviderService ai;
  final EmbeddingService embeddings;

  const EntityDetailPage({
    super.key,
    required this.entity,
    required this.api,
    required this.ai,
    required this.embeddings,
  });

  @override
  State<EntityDetailPage> createState() => _EntityDetailPageState();
}

class _EntityDetailPageState extends State<EntityDetailPage> {
  List<Note> notes = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final keys =
        (await KnowledgeStore.instance.noteKeysForEntity(widget.entity.id))
            .toSet();
    final all = await widget.api.getNotes();
    if (!mounted) return;
    setState(() {
      notes =
          all.where((n) => keys.contains(KnowledgeStore.noteKey(n))).toList();
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.entity.name)),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => KnowledgeChatPage(
                api: widget.api,
                ai: widget.ai,
                embeddings: widget.embeddings,
                entity: widget.entity,
              ),
            ),
          ),
          icon: const Icon(Icons.chat_bubble_outline),
          label: const Text('Preguntar'),
        ),
        body: SafeArea(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.account_tree_outlined),
                        title: Text(widget.entity.name),
                        subtitle: Text(
                          '${widget.entity.type} · ${notes.length} nota(s)',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (notes.isEmpty)
                      const Text('No hay notas relacionadas todavía.'),
                    ...notes.map(
                      (note) => Card(
                        child: ListTile(
                          title: Text(note.title),
                          subtitle: Text(
                            note.content.replaceAll('\n', ' '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  NoteDetailPage(note: note, api: widget.api),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
}
