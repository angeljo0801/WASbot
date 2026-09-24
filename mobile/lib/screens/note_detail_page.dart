import 'dart:io';

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../services/api_service.dart';

class NoteDetailPage extends StatelessWidget {
  final Note note;
  final ApiService api;

  const NoteDetailPage({super.key, required this.note, required this.api});

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
    final photos = note.photoPaths
        .where((path) => File(path).existsSync())
        .toList();
    if (photos.isEmpty &&
        note.mediaPath != null &&
        File(note.mediaPath!).existsSync()) {
      photos.add(note.mediaPath!);
    }

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
            if (note.isPurchase &&
                (note.customerName.isNotEmpty || note.customerPhone.isNotEmpty)) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Cliente',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (note.customerName.isNotEmpty)
                        Row(
                          children: [
                            const Icon(Icons.person_outline, size: 20),
                            const SizedBox(width: 8),
                            Expanded(child: SelectableText(note.customerName)),
                          ],
                        ),
                      if (note.customerPhone.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.phone_outlined, size: 20),
                            const SizedBox(width: 8),
                            Expanded(child: SelectableText(note.customerPhone)),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            if (photos.isEmpty &&
                note.messageType == 'image' &&
                note.mediaPath != null &&
                note.mediaPath!.isNotEmpty &&
                !File(note.mediaPath!).existsSync()) ...[
              const SizedBox(height: 18),
              FutureBuilder(
                future: api.fetchMediaBytes(note.mediaPath!),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const SizedBox(
                      height: 180,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (bytes == null || bytes.isEmpty) {
                    return const Card(
                      child: Padding(
                        padding: EdgeInsets.all(14),
                        child: Text('La imagen está guardada en el servidor, pero no se pudo cargar ahora.'),
                      ),
                    );
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.memory(
                      bytes,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    ),
                  );
                },
              ),
            ],
            if (photos.isNotEmpty) ...[
              const SizedBox(height: 18),
              SizedBox(
                height: 260,
                child: PageView.builder(
                  itemCount: photos.length,
                  itemBuilder: (_, index) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(
                        File(photos[index]),
                        width: double.infinity,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
              if (photos.length > 1) ...[
                const SizedBox(height: 6),
                Center(child: Text('${photos.length} fotos')),
              ],
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
            if (note.mediaPath != null &&
                photos.isEmpty) ...[
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
