import 'dart:io';

import 'package:flutter/material.dart';

import '../models/note.dart';

class NoteDetailPage extends StatelessWidget {
  final Note note;

  const NoteDetailPage({super.key, required this.note});

  IconData get icon => switch (note.messageType) {
        'image' => Icons.image_outlined,
        'audio' => Icons.mic_none,
        'document' => Icons.description_outlined,
        _ => Icons.notes_outlined,
      };

  String get aiLabel => switch (note.aiProvider) {
        'local' => 'IA local',
        'server' => 'IA servidor',
        _ => 'Reglas',
      };

  String get syncLabel => switch (note.status) {
        'pending_sync' => 'Pendiente de sincronizar',
        'synced' => 'Sincronizada',
        _ => note.status,
      };

  @override
  Widget build(BuildContext context) {
    final localImage = note.mediaPath != null && File(note.mediaPath!).existsSync();

    return Scaffold(
      appBar: AppBar(
        title: Text(note.title),
        actions: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon),
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
                Chip(label: Text(note.category)),
                Chip(label: Text(note.source == 'whatsapp' ? 'WhatsApp' : 'Manual')),
                Chip(label: Text(aiLabel)),
                if (note.isLocalRecord || note.status != 'ready')
                  Chip(label: Text(syncLabel)),
                ...note.tags.map((t) => Chip(label: Text('#$t'))),
              ],
            ),
            if (localImage) ...[
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(
                  File(note.mediaPath!),
                  width: double.infinity,
                  fit: BoxFit.contain,
                ),
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
              Text('Original', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SelectableText(note.originalText),
            ],
            if (note.mediaPath != null && !localImage) ...[
              const SizedBox(height: 28),
              Text(
                'Archivo original conservado',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                note.mediaPath!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
