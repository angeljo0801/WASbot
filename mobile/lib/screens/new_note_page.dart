import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../services/api_service.dart';
import '../services/paqueteria_purchase_sync_service.dart';

class NewNotePage extends StatefulWidget {
  final ApiService api;

  const NewNotePage({super.key, required this.api});

  @override
  State<NewNotePage> createState() => _NewNotePageState();
}

class _NewNotePageState extends State<NewNotePage> {
  final title = TextEditingController();
  final content = TextEditingController();
  final customerName = TextEditingController();
  final customerPhone = TextEditingController();
  final picker = ImagePicker();

  String category = 'Inbox';
  final List<String> photoPaths = [];
  bool saving = false;
  bool pickingPhoto = false;

  final categories = const [
    'Inbox',
    'Clientes',
    'Trabajo',
    'Personal',
    'Compras',
    'Gastos',
    'Ideas',
    'Documentos',
    'Recordatorios',
    'Fotos',
    'Remesas',
  ];

  @override
  void dispose() {
    title.dispose();
    content.dispose();
    customerName.dispose();
    customerPhone.dispose();
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
      '${folder.path}/purchase_${DateTime.now().microsecondsSinceEpoch}_${photoPaths.length}$extension',
    );
    await source.copy(target.path);
    return target.path;
  }

  Future<void> _pickPhotos(String action) async {
    if (pickingPhoto) return;
    setState(() => pickingPhoto = true);
    try {
      final added = <String>[];
      if (action == 'camera') {
        final image = await picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 88,
          maxWidth: 2200,
        );
        if (image != null) added.add(await _persistPhoto(image));
      } else {
        final images = await picker.pickMultiImage(
          imageQuality: 88,
          maxWidth: 2200,
        );
        for (final image in images) {
          added.add(await _persistPhoto(image));
        }
      }
      if (mounted && added.isNotEmpty) {
        setState(() => photoPaths.addAll(added));
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

  Future<void> _removePhoto(String path) async {
    setState(() => photoPaths.remove(path));
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _clearPurchasePhotos() async {
    final old = List<String>.from(photoPaths);
    setState(() => photoPaths.clear());
    for (final path in old) {
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
    if (category == 'Compras' && customerName.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Escribe el nombre del cliente.')),
      );
      return;
    }
    if (category == 'Compras' && customerPhone.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Escribe el número del cliente.')),
      );
      return;
    }

    setState(() => saving = true);
    try {
      final isPurchase = category == 'Compras';
      final note = await widget.api.createNote(
        title: title.text.trim(),
        content: content.text.trim(),
        category: category,
        mediaPath: isPurchase && photoPaths.isNotEmpty ? photoPaths.first : null,
        customerName: isPurchase ? customerName.text.trim() : '',
        customerPhone: isPurchase ? customerPhone.text.trim() : '',
        photoPaths: isPurchase ? List<String>.from(photoPaths) : const <String>[],
      );

      var purchaseSyncPending = false;
      if (isPurchase) {
        final sync = PaqueteriaPurchaseSyncService(widget.api);
        await sync.enqueue(
          externalId: 'whatsbot-${note.id}',
          customerName: customerName.text.trim(),
          customerPhone: customerPhone.text.trim(),
          title: title.text.trim(),
          description: content.text.trim(),
          photoPaths: List<String>.from(photoPaths),
          createdAt: note.createdAt,
        );
        purchaseSyncPending = await sync.pendingCount() > 0;
      }

      if (!mounted) return;
      final message = isPurchase
          ? (purchaseSyncPending
              ? 'Compra guardada. Quedó pendiente de sincronizar con Paquetería.'
              : 'Compra guardada y enviada para sincronizar con Paquetería.')
          : (note.pendingSync
              ? 'Guardada en el teléfono. Se sincronizará cuando haya servidor.'
              : 'Nota guardada.');
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

  Widget _purchaseSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Datos de la compra',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: customerName,
              decoration: const InputDecoration(
                labelText: 'Nombre del cliente *',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: customerPhone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Número / teléfono *',
                prefixIcon: Icon(Icons.phone_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Fotos de la compra',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              'Opcional. Puedes guardar una o varias fotos, igual que en Paquetería.',
            ),
            const SizedBox(height: 10),
            if (photoPaths.isNotEmpty)
              SizedBox(
                height: 116,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: photoPaths.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, index) {
                    final path = photoPaths[index];
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(path),
                            width: 116,
                            height: 116,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          right: 2,
                          top: 2,
                          child: IconButton.filled(
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _removePhoto(path),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            if (photoPaths.isNotEmpty) const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      pickingPhoto ? null : () => _pickPhotos('gallery'),
                  icon: const Icon(Icons.collections_outlined),
                  label: const Text('Galería'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      pickingPhoto ? null : () => _pickPhotos('camera'),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Cámara'),
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
                decoration: InputDecoration(
                  labelText: category == 'Compras'
                      ? 'Compra / tienda / título'
                      : 'Título',
                  border: const OutlineInputBorder(),
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
                      photoPaths.isNotEmpty) {
                    await _clearPurchasePhotos();
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
                _purchaseSection(),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: content,
                minLines: 6,
                maxLines: 14,
                decoration: InputDecoration(
                  labelText: category == 'Compras'
                      ? 'Detalles de la compra'
                      : 'Contenido',
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
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
