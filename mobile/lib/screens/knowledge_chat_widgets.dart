import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';
import '../services/api_service.dart';
import '../services/knowledge_chat_store.dart';
import '../services/whatsbot_translation_service.dart';
import 'note_detail_page.dart';

class KnowledgeChatTranscript extends StatefulWidget {
  final List<KnowledgeChatMessage> messages;
  final String participantName;
  final ApiService api;
  final List<Note> notes;
  final String emptyText;
  final double? liveResponseSeconds;
  final bool isResponding;

  const KnowledgeChatTranscript({
    super.key,
    required this.messages,
    required this.participantName,
    required this.api,
    required this.notes,
    this.emptyText = 'Empieza una conversación.',
    this.liveResponseSeconds,
    this.isResponding = false,
  });

  @override
  State<KnowledgeChatTranscript> createState() =>
      _KnowledgeChatTranscriptState();
}

class _KnowledgeChatTranscriptState extends State<KnowledgeChatTranscript> {
  static const _autoSpanishKey = 'whatsbot_auto_translate_spanish';
  bool _autoSpanish = false;

  @override
  void initState() {
    super.initState();
    _loadTranslationPreference();
    WhatsBotTranslationService.warmUpSpanish();
  }

  Future<void> _loadTranslationPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => _autoSpanish = prefs.getBool(_autoSpanishKey) ?? false,
    );
  }

  Future<void> _setAutoSpanish(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSpanishKey, value);
    if (!mounted) return;
    setState(() => _autoSpanish = value);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'Traducción automática al español activada.'
              : 'Traducción automática desactivada.',
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Note? _noteForKey(String key) {
    for (final note in widget.notes) {
      if (key == 'remote:${note.remoteId}' || key == 'note:${note.id}') {
        return note;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.emptyText,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      itemCount: widget.messages.length,
      itemBuilder: (context, index) {
        final message =
            widget.messages[widget.messages.length - 1 - index];
        return _KnowledgeChatBubble(
          key: ValueKey(
            '${message.createdAt.microsecondsSinceEpoch}:${message.role}',
          ),
          message: message,
          participantName: widget.participantName,
          autoSpanish: _autoSpanish,
          onAutoSpanishChanged: _setAutoSpanish,
          sourceNotes: message.sourceKeys
              .map(_noteForKey)
              .whereType<Note>()
              .toList(),
          api: widget.api,
          liveResponseSeconds:
              index == 0 && message.role == 'assistant'
                  ? widget.liveResponseSeconds
                  : null,
          isResponding: index == 0 &&
              message.role == 'assistant' &&
              widget.isResponding,
        );
      },
    );
  }
}

class _KnowledgeChatBubble extends StatefulWidget {
  final KnowledgeChatMessage message;
  final String participantName;
  final bool autoSpanish;
  final Future<void> Function(bool value) onAutoSpanishChanged;
  final List<Note> sourceNotes;
  final ApiService api;
  final double? liveResponseSeconds;
  final bool isResponding;

  const _KnowledgeChatBubble({
    super.key,
    required this.message,
    required this.participantName,
    required this.autoSpanish,
    required this.onAutoSpanishChanged,
    required this.sourceNotes,
    required this.api,
    this.liveResponseSeconds,
    this.isResponding = false,
  });

  @override
  State<_KnowledgeChatBubble> createState() => _KnowledgeChatBubbleState();
}

class _KnowledgeChatBubbleState extends State<_KnowledgeChatBubble> {
  String? _spanish;
  bool _showSpanish = false;
  bool _translating = false;
  Timer? _autoTimer;

  bool get _mine => widget.message.role == 'user';

  bool get _isTemporaryStatus {
    final text = widget.message.text.trim().toLowerCase();
    return text == 'pensando…' ||
        text == 'pensando...' ||
        text == 'thinking…' ||
        text == 'thinking...';
  }

  bool get _canTranslate =>
      !_mine && widget.message.text.trim().isNotEmpty && !_isTemporaryStatus;

  @override
  void initState() {
    super.initState();
    _scheduleAutoTranslation();
  }

  @override
  void didUpdateWidget(covariant _KnowledgeChatBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.text != widget.message.text) {
      _autoTimer?.cancel();
      _spanish = null;
      _showSpanish = false;
      _translating = false;
      _scheduleAutoTranslation();
    } else if (!oldWidget.autoSpanish && widget.autoSpanish) {
      _scheduleAutoTranslation();
    } else if (oldWidget.autoSpanish && !widget.autoSpanish) {
      _autoTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }

  void _scheduleAutoTranslation() {
    _autoTimer?.cancel();
    if (!widget.autoSpanish || !_canTranslate) return;
    _autoTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted && widget.autoSpanish && _canTranslate) {
        _translate(show: true);
      }
    });
  }

  Future<void> _translate({required bool show}) async {
    if (!_canTranslate || _translating) return;
    _autoTimer?.cancel();
    if (_spanish != null) {
      if (mounted) setState(() => _showSpanish = show);
      return;
    }
    if (mounted) {
      setState(() {
        _translating = true;
        if (show) _showSpanish = true;
      });
    }
    try {
      final translated =
          await WhatsBotTranslationService.toSpanish(widget.message.text);
      if (!mounted) return;
      setState(() {
        _spanish = translated;
        _showSpanish = show;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _translating = false;
        _showSpanish = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'La traducción offline todavía no está lista. Conéctate una vez para descargar el traductor.',
          ),
        ),
      );
      return;
    }
    if (mounted) setState(() => _translating = false);
  }

  Future<void> _toggleSpanish() async {
    if (_showSpanish) {
      setState(() => _showSpanish = false);
      return;
    }
    await _translate(show: true);
  }

  Future<void> _copyMessage() async {
    final text =
        (_showSpanish && _spanish != null ? _spanish! : widget.message.text)
            .trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copiado al portapapeles.'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayedText =
        _showSpanish && _spanish != null ? _spanish! : widget.message.text;

    return Align(
      alignment: _mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * .86,
        ),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _mine
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(_mine ? 16 : 4),
            bottomRight: Radius.circular(_mine ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _mine ? 'Tú' : widget.participantName,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (widget.message.text.isNotEmpty) ...[
              const SizedBox(height: 5),
              SelectableText(
                _translating && _showSpanish && _spanish == null
                    ? 'Traduciendo al español…'
                    : displayedText,
              ),
            ],
            if (!_mine && widget.sourceNotes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < widget.sourceNotes.length; i++)
                    ActionChip(
                      avatar: const Icon(Icons.notes_outlined, size: 15),
                      label: Text(
                        '[N${i + 1}] ${widget.sourceNotes[i].title}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NoteDetailPage(
                            note: widget.sourceNotes[i],
                            api: widget.api,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (_canTranslate) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _translating ? null : _toggleSpanish,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    icon: const Icon(Icons.translate, size: 17),
                    label: Text(_showSpanish ? 'Original' : 'ES'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        widget.onAutoSpanishChanged(!widget.autoSpanish),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    icon: Icon(
                      widget.autoSpanish
                          ? Icons.check_circle_outline
                          : Icons.autorenew_rounded,
                      size: 17,
                    ),
                    label: Text(
                      widget.autoSpanish ? 'Auto ES on' : 'Auto ES',
                    ),
                  ),
                ],
              ),
            ],
            if (widget.message.text.trim().isNotEmpty) ...[
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _copyMessage,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  icon: const Icon(Icons.copy_outlined, size: 17),
                  label: const Text('Copiar'),
                ),
              ),
            ],
            if (!_mine && widget.isResponding) ...[
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${(widget.liveResponseSeconds ?? 0).toStringAsFixed(1)} s',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ),
            ] else if (!_mine && widget.message.responseSeconds != null) ...[
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${widget.message.responseSeconds!.toStringAsFixed(1)} s',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
