import 'dart:io';

import 'package:flutter/material.dart';

import '../models/purchase_draft.dart';
import '../services/api_service.dart';
import '../services/knowledge_store.dart';
import '../services/paqueteria_purchase_sync_service.dart';

class DraftReviewPage extends StatefulWidget {
  final PurchaseDraft draft;
  final ApiService api;

  const DraftReviewPage({
    super.key,
    required this.draft,
    required this.api,
  });

  @override
  State<DraftReviewPage> createState() => _DraftReviewPageState();
}

class _DraftReviewPageState extends State<DraftReviewPage> {
  final store = KnowledgeStore.instance;
  late final TextEditingController customer;
  late final TextEditingController phone;
  late final TextEditingController shop;
  late final TextEditingController order;
  late final TextEditingController description;
  late final TextEditingController total;
  late List<Map<String, dynamic>> items;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    customer = TextEditingController(text: d.customerName);
    phone = TextEditingController(text: d.customerPhone);
    shop = TextEditingController(text: d.store);
    order = TextEditingController(text: d.orderNumber);
    description = TextEditingController(text: d.description);
    total = TextEditingController(
      text: d.total > 0 ? d.total.toStringAsFixed(2) : '',
    );
    items = d.items.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  @override
  void dispose() {
    customer.dispose();
    phone.dispose();
    shop.dispose();
    order.dispose();
    description.dispose();
    total.dispose();
    super.dispose();
  }

  double _money(String value) =>
      double.tryParse(value.replaceAll(',', '.').trim()) ?? 0;

  PurchaseDraft _current({String? status}) => widget.draft.copyWith(
        customerName: customer.text.trim(),
        customerPhone: phone.text.trim(),
        store: shop.text.trim().isEmpty ? 'Otra tienda' : shop.text.trim(),
        orderNumber: order.text.trim(),
        description: description.text.trim(),
        total: _money(total.text),
        items: items,
        status: status,
      );

  Future<void> _saveOnly() async {
    await store.saveDraft(_current());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Borrador actualizado.')),
    );
  }

  Future<void> _editItem(int index) async {
    final item = items[index];
    final name = TextEditingController(text: (item['name'] ?? '').toString());
    final price = TextEditingController(text: (item['price'] ?? '').toString());
    final qty = TextEditingController(text: (item['qty'] ?? 1).toString());
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Editar artículo'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Artículo'),
                ),
                TextField(
                  controller: price,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Precio'),
                ),
                TextField(
                  controller: qty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Cantidad'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Guardar'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    setState(() {
      items[index] = {
        ...item,
        'name': name.text.trim(),
        'price': _money(price.text),
        'qty': _money(qty.text) <= 0 ? 1.0 : _money(qty.text),
      };
    });
  }

  Future<void> _confirm() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final draft = _current(status: 'confirmed');
      await store.saveDraft(draft);

      if (draft.customerName.isNotEmpty) {
        final entity = await store.upsertEntity(
          draft.customerName,
          type: 'cliente',
        );
        await store.linkEntity(
          entity.id,
          draft.noteKey,
          relation: 'cliente',
        );
      }

      final sync = PaqueteriaPurchaseSyncService(widget.api);
      await sync.enqueue(
        externalId: 'whatsbot-draft-${draft.id}',
        customerName: draft.customerName,
        customerPhone: draft.customerPhone,
        title: draft.store,
        description: draft.description,
        photoPaths:
            draft.mediaPath.isEmpty ? const [] : <String>[draft.mediaPath],
        store: draft.store,
        total: draft.total,
        orderNumber: draft.orderNumber,
        items: draft.items,
        ocrText: draft.ocrText,
        ocrMeta: {
          'subtotal': draft.subtotal,
          'tax': draft.tax,
          'shipping': draft.shipping,
          'discount': draft.discount,
          'confidence': draft.confidence,
          'warnings': draft.warnings,
          'source': 'WhatsBot automatic OCR',
        },
        createdAt: draft.createdAt,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo confirmar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _discard() async {
    await store.saveDraft(_current(status: 'discarded'));
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final confidence = (d.confidence * 100).round();
    return Scaffold(
      appBar: AppBar(title: const Text('Borrador para Paquetería')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('Pendiente de confirmar'),
                subtitle: Text(
                  'OCR automático · confianza $confidence%. Nada se envía a Paquetería hasta que confirmes.',
                ),
              ),
            ),
            if (d.mediaPath.isNotEmpty && File(d.mediaPath).existsSync()) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(
                  File(d.mediaPath),
                  height: 220,
                  fit: BoxFit.contain,
                ),
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: customer,
              decoration: const InputDecoration(
                labelText: 'Cliente',
                helperText:
                    'Puedes cambiarlo aquí o escribir “esto es de María” en WhatsApp.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Teléfono del cliente',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: shop,
              decoration: const InputDecoration(
                labelText: 'Tienda',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: order,
              decoration: const InputDecoration(
                labelText: 'Número de pedido',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: total,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Total',
                prefixText: r'$ ',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: description,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Descripción',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Artículos detectados',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text('${items.length}'),
              ],
            ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('El OCR no separó artículos en esta imagen.'),
              ),
            for (var i = 0; i < items.length; i++)
              Card(
                child: ListTile(
                  title: Text((items[i]['name'] ?? 'Artículo').toString()),
                  subtitle: Text('x${items[i]['qty'] ?? 1}'),
                  trailing: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '\$${((items[i]['price'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
                      ),
                      IconButton(
                        onPressed: () => _editItem(i),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ],
                  ),
                ),
              ),
            if (d.warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(d.warnings.join('\n')),
                ),
              ),
            ],
            ExpansionTile(
              title: const Text('Texto OCR'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    d.ocrText.isEmpty ? 'Sin texto detectado' : d.ocrText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _saveOnly,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Guardar cambios al borrador'),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: saving ? null : _confirm,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(
                saving ? 'Enviando…' : 'Confirmar y enviar a Paquetería',
              ),
            ),
            TextButton(
              onPressed: saving ? null : _discard,
              child: const Text('Descartar borrador'),
            ),
          ],
        ),
      ),
    );
  }
}
