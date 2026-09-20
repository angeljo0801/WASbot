import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../services/api_service.dart';

class NewNotePage extends StatefulWidget {
  final ApiService api;

  const NewNotePage({super.key, required this.api});

  @override
  State<NewNotePage> createState() => _NewNotePageState();
}

class _NewNotePageState extends State<NewNotePage> {
  final title = TextEditingController();
  final content = TextEditingController();
  final picker = ImagePicker();

  String category = 'Inbox';
  String? photoPath;
  bool saving = false;
  bool pickingPhoto = false;

  final categories = const [
    'Inbox',
    'Trabajo',
    'Personal',
    'Compras',
    'Gastos',
    'Ideas',
    'Documentos',
    'Recordatorios',
    'Fotos',
  ];

  @override
  void dispose() {
    title.dispose();
    content.dispose();
    super.dispose();
  }

  Future<String> _persistPhoto(XFile image) async {
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/purchase_photos');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final source = File(image.path);
    final lower = image.path.toLowerCase();
    final extension = lower.endsWith('.png')
        ? '.png'
        : lower.endsWith('.webp')
            ? '.webp'
            : '.jpg';
    final target = File(
      '${folder.path}/purchase_${DateTime.now().microsecondsSinceEpoch}$extension',
    );
    await source.copy(target.path);
    return target.path;
  }

  Future<void> _pickPhoto(ImageSource source) async {
    if (pickingPhoto) return;
    setState(() => pickingPhoto = true);
    try {
      final image = await picker.pickImage(
        source: source,
        imageQuality: 88,
        maxWidth: 2200,
      );
      if (image == null) return;

      final savedPath = await _persistPhoto(image);
      final previous = photoPath;
      if (mounted) setState(() => photoPath = savedPath);

      if (previous != null && previous != savedPath) {
        try {
          final old = File(previous);
          if (await old.exists()) await old.delete();
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo añadir la foto: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => pickingPhoto = false);
    }
  }

  Future<void> _removePhoto() async {
    final path = photoPath;
    setState(() => photoPath = null);
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> save() async {
    if (title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Escribe un título para la nota.')),
      );
      return;
    }

    setState(() => saving = true);
    try {
      final note = await widget.api.createNote(
        title: title.text.trim(),
        content: content.text.trim(),
        category: category,
        mediaPath: category == 'Compras' ? photoPath : null,
      );
      if (!mounted) return;
      final message = note.pendingSync
          ? 'Guardada en el teléfono. Se sincronizará cuando haya servidor.'
          : 'Nota guardada.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo guardar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget _purchasePhotoSection() {
    final path = photoPath;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Foto de la compra',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'Opcional. La imagen se guarda dentro de WhatsBot y queda asociada a esta compra.',
            ),
            const SizedBox(height: 12),
            if (path != null && File(path).existsSync()) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(path),
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      pickingPhoto ? null : () => _pickPhoto(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Galería'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      pickingPhoto ? null : () => _pickPhoto(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Cámara'),
                ),
                if (path != null)
                  TextButton.icon(
                    onPressed: pickingPhoto ? null : _removePhoto,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Quitar foto'),
                  ),
              ],
            ),
            if (pickingPhoto) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Nueva nota')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'Título',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: category,
                items: categories
                    .map(
                      (x) => DropdownMenuItem(
                        value: x,
                        child: Text(x),
                      ),
                    )
                    .toList(),
                onChanged: (v) async {
                  final next = v ?? category;
                  if (category == 'Compras' &&
                      next != 'Compras' &&
                      photoPath != null) {
                    await _removePhoto();
                  }
                  if (mounted) setState(() => category = next);
                },
                decoration: const InputDecoration(
                  labelText: 'Categoría',
                  border: OutlineInputBorder(),
                ),
              ),
              if (category == 'Compras') ...[
                const SizedBox(height: 14),
                _purchasePhotoSection(),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: content,
                minLines: 6,
                maxLines: 14,
                decoration: const InputDecoration(
                  labelText: 'Contenido',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: saving ? null : save,
                icon: saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(saving ? 'Guardando…' : 'Guardar'),
              ),
            ],
          ),
        ),
      );
}
