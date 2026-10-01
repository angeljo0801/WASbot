import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/note.dart';
import 'api_service.dart';
import 'knowledge_store.dart';

class NoteShareService {
  final ApiService api;

  const NoteShareService(this.api);

  String _extensionFor(String raw, Note note) {
    final lower = raw.toLowerCase();
    for (final candidate in [
      '.jpg', '.jpeg', '.png', '.webp', '.pdf', '.doc', '.docx',
      '.xls', '.xlsx', '.txt', '.zip', '.mp3', '.m4a', '.mp4',
    ]) {
      if (lower.contains(candidate)) return candidate;
    }
    return note.messageType == 'image' || note.category == 'Fotos'
        ? '.jpg'
        : '.bin';
  }

  Future<String?> _materialize(Note note, String rawPath, int index) async {
    final path = rawPath.trim();
    if (path.isEmpty) return null;

    final local = File(path);
    if (await local.exists()) return local.path;

    final bytes = await api.fetchMediaBytes(path);
    if (bytes == null || bytes.isEmpty) return null;

    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/shared_inbox');
    if (!await folder.exists()) await folder.create(recursive: true);

    final safe = KnowledgeStore.noteKey(note)
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final ext = _extensionFor(path, note);
    final file = File('${folder.path}/${safe}_$index$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<List<String>> _filesForNote(Note note) async {
    final out = <String>[];
    final candidates = <String>[
      ...note.photoPaths,
      if ((note.mediaPath ?? '').trim().isNotEmpty) note.mediaPath!.trim(),
    ];

    var index = 0;
    for (final raw in candidates) {
      final path = await _materialize(note, raw, index++);
      if (path != null && !out.contains(path)) out.add(path);
    }
    return out;
  }

  Future<void> shareNotes(List<Note> notes) async {
    if (notes.isEmpty) return;

    final files = <String>[];
    for (final note in notes) {
      final noteFiles = await _filesForNote(note);
      for (final path in noteFiles) {
        if (!files.contains(path)) files.add(path);
      }
    }

    final text = notes
        .map((note) {
          final body = note.content.trim().isNotEmpty
              ? note.content.trim()
              : note.originalText.trim();
          return body.isEmpty ? note.title : '${note.title}\n$body';
        })
        .join('\n\n')
        .trim();

    final subject = notes.length == 1
        ? notes.first.title
        : 'WhatsBot · ${notes.length} elementos';

    final params = ShareParams(
      text: text.isEmpty ? subject : text,
      subject: subject,
      files: files.isEmpty ? null : files.map(XFile.new).toList(),
    );
    await SharePlus.instance.share(params);
  }
}
