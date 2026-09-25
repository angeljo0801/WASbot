import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/note.dart';
import 'api_service.dart';
import 'knowledge_store.dart';

class NoteShareService {
  final ApiService api;

  const NoteShareService(this.api);

  Future<List<String>> _filesForNote(Note note) async {
    final out = <String>[];

    for (final path in note.photoPaths) {
      final file = File(path);
      if (await file.exists() && !out.contains(file.path)) {
        out.add(file.path);
      }
    }

    final mediaPath = note.mediaPath?.trim() ?? '';
    if (mediaPath.isEmpty) return out;

    final local = File(mediaPath);
    if (await local.exists()) {
      if (!out.contains(local.path)) out.add(local.path);
      return out;
    }

    final bytes = await api.fetchMediaBytes(mediaPath);
    if (bytes == null || bytes.isEmpty) return out;

    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/shared_inbox');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    var ext = '.bin';
    final lower = mediaPath.toLowerCase();
    for (final candidate in [
      '.jpg', '.jpeg', '.png', '.webp', '.pdf', '.doc', '.docx',
      '.xls', '.xlsx', '.txt', '.zip', '.mp3', '.m4a', '.mp4',
    ]) {
      if (lower.contains(candidate)) {
        ext = candidate;
        break;
      }
    }
    if (note.messageType == 'image' && ext == '.bin') ext = '.jpg';

    final safe = KnowledgeStore.noteKey(note)
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${folder.path}/$safe$ext');
    await file.writeAsBytes(bytes, flush: true);
    if (!out.contains(file.path)) out.add(file.path);
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
        .join('\n\n');

    final subject = notes.length == 1
        ? notes.first.title
        : 'WhatsBot · ${notes.length} elementos';

    await SharePlus.instance.share(
      ShareParams(
        text: text,
        subject: subject,
        files: files.map(XFile.new).toList(),
      ),
    );
  }
}
