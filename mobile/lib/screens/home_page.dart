import 'dart:async';

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../services/api_service.dart';
import '../services/local_ai_service.dart';
import '../services/paqueteria_purchase_sync_service.dart';
import 'ai_settings_page.dart';
import 'combo_page.dart';
import 'new_note_page.dart';
import 'note_detail_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final api = ApiService();
  final localAi = LocalAiService();
  final search = TextEditingController();
  final categories = const [
    'Todas', 'Inbox', 'Trabajo', 'Personal', 'Compras', 'Gastos',
    'Ideas', 'Documentos', 'Recordatorios', 'Fotos'
  ];

  String category = 'Todas';
  List<Note> notes = [];
  bool loading = true;
  bool localAiRunning = false;
  int localAiDone = 0;
  int localAiTotal = 0;
  int paqueteriaPending = 0;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    search.dispose();
    unawaited(localAi.dispose());
    super.dispose();
  }

  Future<void> refresh({bool runLocalAi = true}) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
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
    if (runLocalAi && error == null) unawaited(_processPendingLocal());
  }

  Future<void> _processPendingLocal({bool force = false}) async {
    if (localAiRunning) return;
    final settings = await localAi.settings();
    if (settings.mode != AiMode.local || settings.modelPath.isEmpty) return;
    if (!settings.autoProcess && !force) return;

    final candidates = notes
        .where((n) => n.source == 'whatsapp' && (force || n.aiProvider != 'local'))
        .take(20)
        .toList();
    if (candidates.isEmpty) return;

    if (mounted) {
      setState(() {
        localAiRunning = true;
        localAiDone = 0;
        localAiTotal = candidates.length;
      });
    }

    try {
      await localAi.loadModel(settings.modelPath);
      for (final note in candidates) {
        try {
          final organized = await localAi.organize(note);
          await api.updateNoteFromAi(
            id: note.id,
            title: organized.title,
            content: organized.content,
            category: organized.category,
            tags: organized.tags,
            aiProvider: 'local',
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('IA local: no se pudo organizar “${note.title}”: $e')),
            );
          }
          break;
        } finally {
          if (mounted) setState(() => localAiDone++);
        }
      }
      if (mounted) await refresh(runLocalAi: false);
    } finally {
      if (mounted) setState(() => localAiRunning = false);
    }
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
        _ => Icons.notes_outlined,
      };

  String aiLabel(Note n) => switch (n.aiProvider) {
        'local' => 'IA local',
        'server' => 'IA servidor',
        _ => 'Reglas',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsBot'),
        actions: [
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
                    onProcessNow: () => _processPendingLocal(force: true),
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
      floatingActionButton: FloatingActionButton.extended(
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
            if (localAiRunning)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Expanded(child: Text('IA local organizando notas… $localAiDone/$localAiTotal')),
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
                  leading: CircleAvatar(child: Icon(typeIcon(n))),
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
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'delete') remove(n);
                    },
                    itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Borrar'))],
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => NoteDetailPage(note: n, api: api)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
