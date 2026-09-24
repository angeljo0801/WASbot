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
  List<Map<String, dynamic>> clients = <Map<String, dynamic>>[];
  bool saving = false;
  bool clientsLoading = true;
  bool ambiguityPrompted = false;
  String? clientHint;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadClients());
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

  String _normalize(String value) => store.normalizeName(value);

  List<Map<String, dynamic>> _matchesForName(String value) {
    final normalized = _normalize(value);
    if (normalized.isEmpty) return const <Map<String, dynamic>>[];
    final oneWord = !normalized.contains(' ');
    final exact = clients.where((client) {
      return _normalize((client['name'] ?? '').toString()) == normalized;
    }).toList();
    if (!oneWord && exact.isNotEmpty) return exact;
    return clients.where((client) {
      final name = _normalize((client['name'] ?? '').toString());
      if (name.isEmpty) return false;
      if (oneWord) {
        return name == normalized || name.startsWith(normalized + ' ');
      }
      return name == normalized ||
          name.startsWith(normalized + ' ') ||
          normalized.startsWith(name + ' ');
    }).toList();
  }

  bool _phoneMatchesOne(List<Map<String, dynamic>> matches) {
    final current = widget.api.normalizePhone(phone.text);
    if (current.isEmpty) return false;
    return matches.any(
      (client) =>
          widget.api.normalizePhone((client['phone'] ?? '').toString()) ==
          current,
    );
  }

  void _applyClient(Map<String, dynamic> client) {
    customer.text = (client['name'] ?? '').toString().trim();
    phone.text = (client['phone'] ?? '').toString().trim();
    setState(() {
      clientHint = 'Cliente vinculado a un registro existente.';
    });
  }

  Future<void> _loadClients() async {
    final values = await widget.api.getClients();
    if (!mounted) return;
    setState(() {
      clients = values;
      clientsLoading = false;
    });

    final current = customer.text.trim();
    if (current.isEmpty) return;
    final matches = _matchesForName(current);
    if (matches.length == 1) {
      if (phone.text.trim().isEmpty) {
        _applyClient(matches.first);
      }
      return;
    }
    if (matches.length > 1 && !ambiguityPrompted) {
      ambiguityPrompted = true;
      setState(() {
        clientHint = 'Hay ' +
            matches.length.toString() +
            ' clientes que coinciden con “' +
            current +
            '”. Elige cuál es.';
      });
      await _chooseClient(initialQuery: current, ambiguous: true);
    }
  }

  Future<void> _resolveTypedClient() async {
    final current = customer.text.trim();
    if (current.isEmpty || clients.isEmpty) return;
    final matches = _matchesForName(current);
    if (matches.length == 1) {
      _applyClient(matches.first);
    } else if (matches.length > 1) {
      setState(() {
        clientHint = 'Hay ' +
            matches.length.toString() +
            ' clientes que coinciden. Elige el correcto.';
      });
      await _chooseClient(initialQuery: current, ambiguous: true);
    } else {
      setState(() {
        clientHint =
            'Nombre manual. Si confirmas, Paquetería podrá crear o asociar este cliente.';
      });
    }
  }

  Future<void> _chooseClient({
    String initialQuery = '',
    bool ambiguous = false,
  }) async {
    var query = initialQuery;
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final normalizedQuery = _normalize(query);
          final visible = clients.where((client) {
            if (normalizedQuery.isEmpty) return true;
            final name = _normalize((client['name'] ?? '').toString());
            final clientPhone =
                widget.api.normalizePhone((client['phone'] ?? '').toString());
            return name.contains(normalizedQuery) ||
                clientPhone.contains(
                  query.replaceAll(RegExp(r'[^0-9]'), ''),
                );
          }).toList();

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.72,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ambiguous
                          ? '¿Cuál cliente es?'
                          : 'Seleccionar cliente',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      ambiguous
                          ? 'El nombre detectado coincide con varios clientes.'
                          : 'También puedes dejar el campo manual y escribir otro nombre.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      autofocus: false,
                      controller: TextEditingController(text: query)
                        ..selection = TextSelection.collapsed(
                          offset: query.length,
                        ),
                      onChanged: (value) =>
                          setSheetState(() => query = value),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: 'Buscar cliente',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: visible.isEmpty
                          ? const Center(
                              child: Text('No hay clientes que coincidan.'),
                            )
                          : ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (_, index) {
                                final client = visible[index];
                                final name =
                                    (client['name'] ?? '').toString().trim();
                                final clientPhone =
                                    (client['phone'] ?? '').toString().trim();
                                return ListTile(
                                  leading:
                                      const Icon(Icons.person_outline),
                                  title: Text(name),
                                  subtitle: clientPhone.isEmpty
                                      ? null
                                      : Text(clientPhone),
                                  onTap: () =>
                                      Navigator.pop(context, client),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    if (selected != null && mounted) {
      _applyClient(selected);
    }
  }

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

    final currentName = customer.text.trim();
    if (currentName.isNotEmpty && clients.isNotEmpty) {
      final matches = _matchesForName(currentName);
      if (matches.length > 1 && !_phoneMatchesOne(matches)) {
        await _chooseClient(initialQuery: currentName, ambiguous: true);
        final after = _matchesForName(customer.text.trim());
        if (after.length > 1 && !_phoneMatchesOne(after)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Elige cuál cliente es antes de confirmar el pedido.',
                ),
              ),
            );
          }
          return;
        }
      } else if (matches.length == 1 && phone.text.trim().isEmpty) {
        _applyClient(matches.first);
      }
    }

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
              onEditingComplete: _resolveTypedClient,
              decoration: InputDecoration(
                labelText: 'Cliente',
                helperText:
                    'Escríbelo manualmente, usa el detectado por OCR o elige uno registrado.',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Elegir cliente registrado',
                  onPressed: clientsLoading ? null : _chooseClient,
                  icon: clientsLoading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.person_search_outlined),
                ),
              ),
            ),
            if (clientHint != null) ...[
              const SizedBox(height: 6),
              Text(
                clientHint!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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
