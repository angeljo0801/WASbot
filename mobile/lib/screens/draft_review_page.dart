import 'dart:io';

import 'package:flutter/material.dart';

import '../models/purchase_draft.dart';
import '../services/api_service.dart';
import '../services/knowledge_store.dart';
import '../services/ocr_purchase_service.dart';
import '../services/paqueteria_purchase_sync_service.dart';
import '../services/photo_storage_service.dart';
import 'fullscreen_image_viewer.dart';

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
  bool sharing = false;
  bool confirmedLocally = false;
  bool clientsLoading = true;
  bool ambiguityPrompted = false;
  String? clientHint;
  String selectedOcrPath = '';
  bool attachmentOcrWorking = false;
  bool itemSelectionMode = false;
  final Set<int> selectedItemIndices = <int>{};

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
    selectedOcrPath = d.mediaPath;
    confirmedLocally = d.status.startsWith('confirmed');
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
        mediaPath: selectedOcrPath,
        status: status ??
            (confirmedLocally ? 'confirmed' : widget.draft.status),
      );

  List<String> get _attachmentPaths {
    final paths = <String>[];
    for (final path in widget.draft.attachmentPaths) {
      if (path.trim().isNotEmpty &&
          File(path).existsSync() &&
          !paths.contains(path)) {
        paths.add(path);
      }
    }
    if (widget.draft.mediaPath.trim().isNotEmpty &&
        File(widget.draft.mediaPath).existsSync() &&
        !paths.contains(widget.draft.mediaPath)) {
      paths.add(widget.draft.mediaPath);
    }
    return paths;
  }

  Future<void> _useAttachmentForOcr(String path) async {
    if (attachmentOcrWorking) return;
    setState(() {
      attachmentOcrWorking = true;
      selectedOcrPath = path;
    });
    try {
      final result =
          await OcrPurchaseService(api: widget.api).parseLocalPurchaseImage(path);
      if (result == null) return;
      final parsed = result.parsed;
      setState(() {
        if (parsed.store.trim().isNotEmpty &&
            parsed.store != 'Otra tienda') {
          shop.text = parsed.store;
        }
        if (parsed.orderNumber.trim().isNotEmpty) {
          order.text = parsed.orderNumber;
        }
        if (parsed.total > 0) {
          total.text = parsed.total.toStringAsFixed(2);
        }
        if (parsed.items.isNotEmpty) {
          items = parsed.items
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
          description.text = parsed.items
              .take(5)
              .map((item) => (item['name'] ?? '').toString())
              .where((value) => value.isNotEmpty)
              .join(', ');
        }
      });
      final updated = _current().copyWith(
        ocrText: result.text,
        attachmentPaths: _attachmentPaths,
      );
      await store.saveDraft(updated);
      await store.syncOcrKeyEntities(updated);
    } finally {
      if (mounted) setState(() => attachmentOcrWorking = false);
    }
  }

  Future<void> _saveOnly() async {
    final draft = _current();
    await store.saveDraft(draft);
    await store.syncOcrKeyEntities(draft);
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

  Future<void> _deleteItem(int index) async {
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    final itemName = (item['name'] ?? 'Artículo').toString().trim();
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Borrar artículo'),
            content: Text(
              itemName.isEmpty
                  ? '¿Quieres borrar este artículo detectado?'
                  : '¿Quieres borrar “$itemName” de este borrador?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Borrar'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() {
      items.removeAt(index);
    });

    final updated = _current();
    await store.saveDraft(updated);
    await store.syncOcrKeyEntities(updated);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          itemName.isEmpty
              ? 'Artículo borrado.'
              : '“$itemName” fue borrado del borrador.',
        ),
      ),
    );
  }

  void _toggleItemSelection(int index) {
    if (index < 0 || index >= items.length) return;
    setState(() {
      if (selectedItemIndices.contains(index)) {
        selectedItemIndices.remove(index);
      } else {
        selectedItemIndices.add(index);
      }
    });
  }

  void _setItemSelectionMode(bool enabled) {
    setState(() {
      itemSelectionMode = enabled;
      if (!enabled) selectedItemIndices.clear();
    });
  }

  Future<void> _deleteSelectedItems() async {
    final valid = selectedItemIndices
        .where((index) => index >= 0 && index < items.length)
        .toList()
      ..sort();
    if (valid.isEmpty) return;

    final count = valid.length;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              count == 1
                  ? 'Borrar artículo'
                  : 'Borrar $count artículos',
            ),
            content: Text(
              count == 1
                  ? '¿Quieres borrar el artículo seleccionado de este borrador?'
                  : '¿Quieres borrar los $count artículos seleccionados de este borrador?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(count == 1 ? 'Borrar' : 'Borrar todos'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() {
      for (final index in valid.reversed) {
        items.removeAt(index);
      }
      selectedItemIndices.clear();
      itemSelectionMode = false;
    });

    final updated = _current();
    await store.saveDraft(updated);
    await store.syncOcrKeyEntities(updated);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 1
              ? 'Artículo borrado.'
              : '$count artículos borrados del borrador.',
        ),
      ),
    );
  }

  Future<bool> _resolveClientBeforeConfirm() async {
    final currentName = customer.text.trim();
    if (currentName.isEmpty || clients.isEmpty) return true;

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
        return false;
      }
    } else if (matches.length == 1 && phone.text.trim().isEmpty) {
      _applyClient(matches.first);
    }
    return true;
  }

  Future<void> _learnConfirmedCorrections(PurchaseDraft draft) async {
    Future<void> learn(
      String field,
      String original,
      String corrected,
    ) async {
      if (original.trim().isEmpty ||
          corrected.trim().isEmpty ||
          original.trim() == corrected.trim()) {
        return;
      }
      await widget.api.recordOcrCorrection(
        source: widget.draft.store,
        field: field,
        original: original,
        corrected: corrected,
      );
    }

    await learn(
      'total',
      widget.draft.total > 0 ? widget.draft.total.toStringAsFixed(2) : '',
      draft.total > 0 ? draft.total.toStringAsFixed(2) : '',
    );
    await learn(
      'customer_name',
      widget.draft.customerName,
      draft.customerName,
    );
    await learn(
      'order_number',
      widget.draft.orderNumber,
      draft.orderNumber,
    );
  }

  Future<void> _confirm() async {
    if (saving || sharing) return;
    if (!await _resolveClientBeforeConfirm()) return;

    setState(() => saving = true);
    try {
      final draft = _current(status: 'confirmed').copyWith(
        attachmentPaths: _attachmentPaths,
        updatedAt: DateTime.now(),
      );

      await _learnConfirmedCorrections(draft);
      await store.saveDraft(draft);
      await store.syncOcrKeyEntities(draft);

      await PhotoStorageService.instance.finalizePurchasePhotos(
        draft.attachmentPaths.isNotEmpty
            ? draft.attachmentPaths
            : (draft.mediaPath.isEmpty
                ? const <String>[]
                : <String>[draft.mediaPath]),
        customerName:
            draft.customerName.trim().isEmpty ? 'Cliente' : draft.customerName,
        orderNumber: draft.orderNumber,
        draftId: draft.id,
      );

      if (!mounted) return;
      setState(() => confirmedLocally = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Compra confirmada. Ahora puedes compartirla con Paquetería.',
          ),
        ),
      );
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

  Future<void> _shareWithPaqueteria() async {
    if (saving || sharing) return;
    if (!confirmedLocally) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Confirma primero la compra.'),
        ),
      );
      return;
    }

    setState(() => sharing = true);
    try {
      final draft = _current(status: 'confirmed').copyWith(
        attachmentPaths: _attachmentPaths,
        updatedAt: DateTime.now(),
      );
      await store.saveDraft(draft);
      await store.syncOcrKeyEntities(draft);

      final sync = PaqueteriaPurchaseSyncService(widget.api);
      final share = await sync.enqueue(
        externalId: 'whatsbot-draft-${draft.id}',
        customerName: draft.customerName,
        customerPhone: draft.customerPhone,
        title: draft.store,
        description: draft.description,
        photoPaths: draft.attachmentPaths.isNotEmpty
            ? draft.attachmentPaths
            : (draft.mediaPath.isEmpty
                ? const <String>[]
                : <String>[draft.mediaPath]),
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

      if (!share.uploaded) {
        await store.saveDraft(
          draft.copyWith(
            status: 'confirmed_pending_sync',
            updatedAt: DateTime.now(),
          ),
        );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Pendiente de compartir'),
            content: Text(
              share.message +
                  '\n\nLa compra sigue confirmada y WhatsBot volverá a intentarlo automáticamente.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Entendido'),
              ),
            ],
          ),
        );
        return;
      }

      await store.saveDraft(
        draft.copyWith(
          status: 'confirmed',
          updatedAt: DateTime.now(),
        ),
      );
      final combo = await widget.api.comboStatus();
      final lastPaqueteriaSync =
          (combo?['snapshot_updated_at'] ?? '').toString().trim();

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Compartido con Paquetería'),
          content: Text(
            lastPaqueteriaSync.isEmpty
                ? 'La compra llegó correctamente al puente de Paquetería. La app la importará en su próxima sincronización.'
                : 'La compra llegó correctamente al puente de Paquetería. Última sincronización detectada: $lastPaqueteriaSync.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo compartir: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  Future<void> _discard() async {
    final draft = _current(status: 'discarded');
    await store.saveDraft(draft);
    await store.clearOcrEntityLinks(draft.noteKey);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _openOcrImage(String path) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenImageViewer.file(
          title: 'Foto del OCR',
          path: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final attachments = _attachmentPaths;
    final confidence = (d.confidence * 100).round();
    return Scaffold(
      appBar: AppBar(title: const Text('Borrador para Paquetería')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            Card(
              child: ListTile(
                leading: Icon(
                  confirmedLocally
                      ? Icons.check_circle_outline
                      : Icons.auto_awesome,
                ),
                title: Text(
                  confirmedLocally
                      ? 'Compra confirmada'
                      : 'Pendiente de confirmar',
                ),
                subtitle: Text(
                  confirmedLocally
                      ? 'La compra está confirmada en WhatsBot. Compartir con Paquetería es una acción separada.'
                      : 'OCR automático · confianza $confidence%. Confirmar guarda la compra en WhatsBot; no la comparte con Paquetería.',
                ),
              ),
            ),
            if (attachments.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      attachments.length == 1
                          ? 'Foto adjunta'
                          : 'Fotos adjuntas (${attachments.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (attachmentOcrWorking)
                    const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (attachments.length == 1)
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _openOcrImage(attachments.first),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      width: double.infinity,
                      height: 240,
                      child: Image.file(
                        File(attachments.first),
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                )
              else
                SizedBox(
                  height: 230,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: attachments.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final path = attachments[index];
                      final selected = selectedOcrPath == path;
                      return SizedBox(
                        width: 180,
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () => _openOcrImage(path),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Image.file(
                                        File(path),
                                        fit: BoxFit.contain,
                                      ),
                                      if (selected)
                                        const Align(
                                          alignment: Alignment.topRight,
                                          child: Padding(
                                            padding: EdgeInsets.all(8),
                                            child: Icon(
                                              Icons.check_circle,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: double.infinity,
                                child: TextButton.icon(
                                  onPressed: attachmentOcrWorking
                                      ? null
                                      : () => _useAttachmentForOcr(path),
                                  icon: const Icon(
                                    Icons.document_scanner_outlined,
                                  ),
                                  label: Text(
                                    selected
                                        ? 'OCR seleccionado'
                                        : 'Usar para OCR',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                attachments.length == 1
                    ? 'Toca la imagen para verla en grande.'
                    : 'Toca una imagen para verla en grande o usa “Usar para OCR” para analizar esa foto.',
                style: Theme.of(context).textTheme.bodySmall,
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
                if (items.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: saving
                        ? null
                        : () => _setItemSelectionMode(!itemSelectionMode),
                    icon: Icon(
                      itemSelectionMode
                          ? Icons.close
                          : Icons.checklist_outlined,
                    ),
                    label: Text(itemSelectionMode ? 'Cancelar' : 'Seleccionar'),
                  ),
                ],
              ],
            ),
            if (itemSelectionMode && items.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      selectedItemIndices.isEmpty
                          ? 'Selecciona los artículos que quieras borrar.'
                          : '${selectedItemIndices.length} seleccionado(s)',
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: selectedItemIndices.isEmpty || saving
                        ? null
                        : _deleteSelectedItems,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('Borrar seleccionados'),
                  ),
                ],
              ),
            ],
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('El OCR no separó artículos en esta imagen.'),
              ),
            for (var i = 0; i < items.length; i++)
              Card(
                child: ListTile(
                  onTap: itemSelectionMode
                      ? () => _toggleItemSelection(i)
                      : null,
                  leading: itemSelectionMode
                      ? Checkbox(
                          value: selectedItemIndices.contains(i),
                          onChanged: (_) => _toggleItemSelection(i),
                        )
                      : null,
                  title: Text((items[i]['name'] ?? 'Artículo').toString()),
                  subtitle: Text('x${items[i]['qty'] ?? 1}'),
                  trailing: itemSelectionMode
                      ? Text(
                          '\$${((items[i]['price'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
                        )
                      : Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '\$${((items[i]['price'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
                            ),
                            IconButton(
                              tooltip: 'Editar artículo',
                              onPressed: () => _editItem(i),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: 'Borrar artículo',
                              onPressed:
                                  saving ? null : () => _deleteItem(i),
                              icon: const Icon(Icons.delete_outline),
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
              onPressed: saving || sharing ? null : _confirm,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(
                saving
                    ? 'Confirmando…'
                    : confirmedLocally
                        ? 'Confirmar cambios'
                        : 'Confirmar compra',
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: confirmedLocally && !saving && !sharing
                  ? _shareWithPaqueteria
                  : null,
              icon: sharing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(
                sharing ? 'Compartiendo…' : 'Compartir con Paquetería',
              ),
            ),
            TextButton(
              onPressed: saving || sharing ? null : _discard,
              child: const Text('Descartar borrador'),
            ),
          ],
        ),
      ),
    );
  }
}
