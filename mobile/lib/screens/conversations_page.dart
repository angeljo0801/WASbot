import 'package:flutter/material.dart';

import '../services/api_service.dart';

class ConversationsPage extends StatefulWidget {
  final ApiService api;

  const ConversationsPage({super.key, required this.api});

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  bool loading = true;
  List<Map<String, dynamic>> conversations = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    final rows = await widget.api.getConversations();
    if (!mounted) return;
    setState(() {
      conversations = rows;
      loading = false;
    });
  }

  String _time(dynamic value) {
    final dt = DateTime.tryParse((value ?? '').toString())?.toLocal();
    if (dt == null) return '';
    return dt.month.toString().padLeft(2, '0') +
        '/' +
        dt.day.toString().padLeft(2, '0') +
        ' ' +
        dt.hour.toString().padLeft(2, '0') +
        ':' +
        dt.minute.toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conversaciones')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: loading
            ? const ListView(
                children: [
                  SizedBox(height: 180),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : conversations.isEmpty
                ? const ListView(
                    children: [
                      SizedBox(height: 180),
                      Center(child: Text('Todavía no hay conversaciones.')),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final row = conversations[index];
                      final name =
                          (row['display_name'] ?? row['sender'] ?? 'Contacto')
                              .toString();
                      final sender = (row['sender'] ?? '').toString();
                      final pending = (row['pending_count'] as num?)?.toInt() ?? 0;
                      final failed = (row['failed_count'] as num?)?.toInt() ?? 0;
                      final last = (row['last_message'] ?? '').toString().trim();
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text(
                              name.trim().isEmpty
                                  ? '?'
                                  : name.trim().substring(0, 1).toUpperCase(),
                            ),
                          ),
                          title: Text(name),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (name != sender && sender.isNotEmpty)
                                Text(sender),
                              if (last.isNotEmpty)
                                Text(
                                  last,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              Text(
                                [
                                  if (pending > 0) pending.toString() + ' pendiente(s)',
                                  if (failed > 0) failed.toString() + ' error(es)',
                                  _time(row['updated_at']),
                                ].where((e) => e.isNotEmpty).join(' · '),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                          trailing: failed > 0
                              ? const Icon(Icons.error_outline)
                              : pending > 0
                                  ? const Icon(Icons.schedule_outlined)
                                  : const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ConversationDetailPage(
                                  api: widget.api,
                                  sender: sender,
                                  displayName: name,
                                ),
                              ),
                            );
                            if (mounted) _load();
                          },
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class ConversationDetailPage extends StatefulWidget {
  final ApiService api;
  final String sender;
  final String displayName;

  const ConversationDetailPage({
    super.key,
    required this.api,
    required this.sender,
    required this.displayName,
  });

  @override
  State<ConversationDetailPage> createState() =>
      _ConversationDetailPageState();
}

class _ConversationDetailPageState extends State<ConversationDetailPage> {
  bool loading = true;
  List<Map<String, dynamic>> messages = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    final rows = await widget.api.getConversationMessages(widget.sender);
    if (!mounted) return;
    setState(() {
      messages = rows;
      loading = false;
    });
  }

  String _status(Map<String, dynamic> row) {
    final direction = (row['direction'] ?? '').toString();
    if (direction == 'in') return 'Recibido';
    return switch ((row['status'] ?? '').toString()) {
      'sent' => 'Enviado',
      'failed' => 'Error',
      'sending' => 'Enviando',
      'pending' => 'Pendiente',
      _ => (row['status'] ?? '').toString(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.displayName),
            Text(
              widget.sender,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: loading
            ? const ListView(
                children: [
                  SizedBox(height: 180),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 32),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final row = messages[index];
                  final mine = (row['direction'] ?? '') == 'out';
                  final text = (row['text'] ?? '').toString();
                  final error = (row['error'] ?? '').toString();
                  return Align(
                    alignment:
                        mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 330),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: mine
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (text.isNotEmpty) SelectableText(text),
                          if (text.isEmpty)
                            Text(
                              (row['message_type'] ?? 'archivo').toString(),
                              style: const TextStyle(
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          const SizedBox(height: 5),
                          Text(
                            _status(row),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (error.isNotEmpty)
                            Text(
                              error,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
