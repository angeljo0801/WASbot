import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import 'fullscreen_image_viewer.dart';

class PackagesSyncPage extends StatefulWidget {
  final ApiService api;

  const PackagesSyncPage({super.key, required this.api});

  @override
  State<PackagesSyncPage> createState() => _PackagesSyncPageState();
}

class _PackagesSyncPageState extends State<PackagesSyncPage> {
  final search = TextEditingController();
  List<Map<String, dynamic>> packages = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> clients = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> purchases = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> recipients = <Map<String, dynamic>>[];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _snapshotRows(
    Map<String, dynamic>? snapshot,
    String key,
  ) {
    final payload = snapshot?['payload'];
    if (payload is! Map) return const <Map<String, dynamic>>[];
    final raw = payload[key];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => row['deleted'] != true)
        .toList();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final values = await Future.wait<dynamic>([
        widget.api.getSyncedPackages(),
        widget.api.getClients(),
        widget.api.getSyncedPurchases(),
        widget.api.paqueteriaSnapshot(),
      ]);
      packages = (values[0] as List<Map<String, dynamic>>);
      clients = (values[1] as List<Map<String, dynamic>>);
      purchases = (values[2] as List<Map<String, dynamic>>);
      recipients = _snapshotRows(
        values[3] as Map<String, dynamic>?,
        'recipients',
      );
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PackageSyncEditPage(
          api: widget.api,
          existing: existing,
          clients: clients,
          purchases: purchases,
          recipients: recipients,
        ),
      ),
    );
    if (changed == true) await load();
  }

  String _clientLabel(Map<String, dynamic> package) {
    final explicit = (package['client_name'] ?? '').toString().trim();
    if (explicit.isNotEmpty) return explicit;
    final id = (package['client_external_id'] ?? '').toString();
    for (final client in clients) {
      if ((client['external_id'] ?? client['id'] ?? '').toString() == id) {
        return (client['name'] ?? 'Cliente').toString();
      }
    }
    return 'Sin cliente';
  }

  @override
  Widget build(BuildContext context) {
    final q = search.text.trim().toLowerCase();
    final visible = packages.where((package) {
      if (q.isEmpty) return true;
      return [
        package['tracking'],
        package['carrier'],
        package['status'],
        package['client_name'],
        package['notes'],
      ].join(' ').toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Paquetes'),
        actions: [
          IconButton(
            tooltip: 'Sincronizar',
            onPressed: loading ? null : load,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: loading ? null : () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Paquete'),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: const Text('Paquetes sincronizados'),
                subtitle: const Text(
                  'Usa los mismos campos de Paquetería. Los cambios quedan disponibles para la próxima sincronización de ambas apps.',
                ),
              ),
            ),
            const SizedBox(height: 10),
            SearchBar(
              controller: search,
              leading: const Icon(Icons.search),
              hintText: 'Tracking, cliente, courier o estado',
              onChanged: (_) => setState(() {}),
              trailing: [
                if (search.text.isNotEmpty)
                  IconButton(
                    onPressed: () {
                      search.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.clear),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!loading && error != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error!),
                ),
              ),
            if (!loading && error == null && visible.isEmpty)
              const Padding(
                padding: EdgeInsets.all(36),
                child: Center(child: Text('No hay paquetes sincronizados.')),
              ),
            for (final package in visible)
              Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.inventory_2_outlined),
                  ),
                  title: Text(
                    (package['tracking'] ?? 'Sin tracking').toString(),
                  ),
                  subtitle: Text(
                    '${_clientLabel(package)} · ${package['carrier'] ?? 'Auto / Otro'}\n'
                    '${package['status'] ?? 'Tracking creado'} · '
                    '${((package['bill_weight'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)} lb',
                  ),
                  isThreeLine: true,
                  onTap: () => _edit(package),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PackageSyncEditPage extends StatefulWidget {
  final ApiService api;
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> clients;
  final List<Map<String, dynamic>> purchases;
  final List<Map<String, dynamic>> recipients;

  const PackageSyncEditPage({
    super.key,
    required this.api,
    required this.clients,
    required this.purchases,
    required this.recipients,
    this.existing,
  });

  @override
  State<PackageSyncEditPage> createState() => _PackageSyncEditPageState();
}

class _PackageSyncEditPageState extends State<PackageSyncEditPage> {
  final tracking = TextEditingController();
  final weightUs = TextEditingController();
  final weightCu = TextEditingController();
  final billWeight = TextEditingController();
  final notes = TextEditingController();
  final List<String> newPhotoPaths = <String>[];

  String carrier = 'Auto / Otro';
  String status = 'Tracking creado';
  String clientExternalId = '';
  String purchaseExternalId = '';
  String recipientId = '';
  bool saving = false;

  static const statuses = <String>[
    'Tracking creado',
    'En tránsito',
    'Sale para entrega',
    'Recibido',
    'Verificado',
    'Listo para Cuba',
    'Asignado a viaje',
    'En tránsito a Cuba',
    'Llegó a Cuba',
    'Entregado',
    'Problema',
  ];

  static const carriers = <String>[
    'Auto / Otro',
    'UPS',
    'FedEx',
    'USPS',
    'DHL',
    'Amazon',
  ];

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    tracking.text = (p?['tracking'] ?? '').toString();
    carrier = (p?['carrier'] ?? inferCarrier(tracking.text)).toString();
    status = (p?['status'] ?? 'Tracking creado').toString();
    clientExternalId = (p?['client_external_id'] ?? '').toString();
    purchaseExternalId = (p?['purchase_external_id'] ?? '').toString();
    recipientId = (p?['recipient_id'] ?? '').toString();
    weightUs.text = _numText(p?['weight_us']);
    weightCu.text = _numText(p?['weight_cu']);
    billWeight.text = _numText(p?['bill_weight']);
    notes.text = (p?['notes'] ?? '').toString();
  }

  @override
  void dispose() {
    tracking.dispose();
    weightUs.dispose();
    weightCu.dispose();
    billWeight.dispose();
    notes.dispose();
    super.dispose();
  }

  static String _numText(dynamic value) {
    if (value == null) return '';
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    if (parsed == null || parsed == 0) return '';
    return parsed.toString();
  }

  double _number(String value) =>
      double.tryParse(value.replaceAll(',', '.').trim()) ?? 0;

  String _clientId(Map<String, dynamic> row) =>
      (row['external_id'] ?? row['id'] ?? '').toString();

  String _purchaseId(Map<String, dynamic> row) =>
      (row['external_id'] ?? row['id'] ?? '').toString();

  Map<String, dynamic>? _client() {
    for (final client in widget.clients) {
      if (_clientId(client) == clientExternalId) return client;
    }
    return null;
  }

  Map<String, dynamic>? _recipient() {
    for (final recipient in widget.recipients) {
      if ((recipient['id'] ?? '').toString() == recipientId) return recipient;
    }
    return null;
  }

  void _autoBillWeight() {
    if (billWeight.text.trim().isNotEmpty) return;
    final us = _number(weightUs.text);
    final cu = _number(weightCu.text);
    final value = us > 0 ? us : cu;
    if (value > 0) billWeight.text = value.toStringAsFixed(2);
  }

  Future<void> _pickPhotos() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 88);
    if (picked.isEmpty || !mounted) return;
    setState(() {
      for (final image in picked) {
        if (!newPhotoPaths.contains(image.path)) {
          newPhotoPaths.add(image.path);
        }
      }
    });
  }

  Future<List<Map<String, String>>> _encodedPhotos() async {
    final out = <Map<String, String>>[];
    for (final path in newPhotoPaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      if (bytes.length > 8 * 1024 * 1024) continue;
      out.add({
        'name': file.uri.pathSegments.isEmpty
            ? 'package.jpg'
            : file.uri.pathSegments.last,
        'data': base64Encode(bytes),
      });
    }
    return out;
  }

  Future<void> _openRemotePhoto(String path) async {
    final bytes = await widget.api.fetchMediaBytes(path);
    if (!mounted || bytes == null || bytes.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenImageViewer.memory(
          title: 'Foto del paquete',
          bytes: bytes,
        ),
      ),
    );
  }

  Future<void> save() async {
    if (saving) return;
    final code = tracking.text.trim();
    if (code.isEmpty || clientExternalId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tracking y cliente son obligatorios.')),
      );
      return;
    }

    setState(() => saving = true);
    try {
      final client = _client();
      final recipient = _recipient();
      final now = DateTime.now().toUtc().toIso8601String();
      final existingId = (widget.existing?['external_id'] ?? '').toString();
      final externalId = existingId.isNotEmpty
          ? existingId
          : 'whatsbot-package-${DateTime.now().microsecondsSinceEpoch}';

      await widget.api.upsertSyncedPackage({
        'external_id': externalId,
        'tracking': code,
        'carrier': carrier,
        'client_external_id': clientExternalId,
        'client_name': (client?['name'] ?? '').toString(),
        'client_phone': (client?['phone'] ?? '').toString(),
        'purchase_external_id': purchaseExternalId,
        'recipient_id': recipientId,
        'recipient_name': (recipient?['name'] ?? '').toString(),
        'weight_us': _number(weightUs.text),
        'weight_cu': _number(weightCu.text),
        'bill_weight': _number(billWeight.text),
        'status': status,
        'notes': notes.text.trim(),
        'photos': await _encodedPhotos(),
        'received_at': status == 'Recibido'
            ? ((widget.existing?['received_at'] ?? '').toString().trim().isEmpty
                ? now
                : (widget.existing?['received_at'] ?? '').toString())
            : (widget.existing?['received_at'] ?? '').toString(),
        'source': 'whatsbot',
        'created_at': (widget.existing?['created_at'] ?? now).toString(),
      });

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo guardar el paquete: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget _drop(
    String label,
    String value,
    List<DropdownMenuItem<String>> items,
    ValueChanged<String?> onChanged,
  ) {
    final valid = value.isNotEmpty && items.any((item) => item.value == value);
    return DropdownButtonFormField<String>(
      initialValue: valid ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items,
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final remotePhotos = ((widget.existing?['photo_urls'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Nuevo paquete' : 'Editar paquete'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: tracking,
            onChanged: (value) {
              if (widget.existing == null) {
                setState(() => carrier = inferCarrier(value));
              }
            },
            decoration: const InputDecoration(
              labelText: 'Tracking / QR / código *',
            ),
          ),
          const SizedBox(height: 12),
          _drop(
            'Courier',
            carrier,
            carriers
                .map((value) => DropdownMenuItem(
                      value: value,
                      child: Text(value),
                    ))
                .toList(),
            (value) => setState(() => carrier = value ?? carrier),
          ),
          const SizedBox(height: 12),
          _drop(
            'Cliente *',
            clientExternalId,
            widget.clients
                .map((client) => DropdownMenuItem(
                      value: _clientId(client),
                      child: Text((client['name'] ?? 'Cliente').toString()),
                    ))
                .toList(),
            (value) => setState(() {
              clientExternalId = value ?? '';
              purchaseExternalId = '';
              recipientId = '';
            }),
          ),
          const SizedBox(height: 12),
          _drop(
            'Compra / pedido relacionado',
            purchaseExternalId,
            widget.purchases
                .where((purchase) {
                  if (clientExternalId.isEmpty) return true;
                  final name = (_client()?['name'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();
                  final purchaseName =
                      (purchase['customer_name'] ?? '').toString().trim().toLowerCase();
                  return name.isEmpty || purchaseName.isEmpty || name == purchaseName;
                })
                .map((purchase) => DropdownMenuItem(
                      value: _purchaseId(purchase),
                      child: Text(
                        '${purchase['store'] ?? 'Compra'} · '
                        '${purchase['description'] ?? purchase['order_number'] ?? ''}',
                      ),
                    ))
                .toList(),
            (value) => setState(() => purchaseExternalId = value ?? ''),
          ),
          const SizedBox(height: 12),
          _drop(
            'Destinatario en Cuba',
            recipientId,
            widget.recipients
                .where((recipient) {
                  final id = (recipient['clientId'] ?? '').toString();
                  return clientExternalId.isEmpty ||
                      id.isEmpty ||
                      id == clientExternalId;
                })
                .map((recipient) => DropdownMenuItem(
                      value: (recipient['id'] ?? '').toString(),
                      child: Text(
                        '${recipient['name'] ?? 'Destinatario'} · '
                        '${recipient['province'] ?? ''}',
                      ),
                    ))
                .toList(),
            (value) => setState(() => recipientId = value ?? ''),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: weightUs,
                  onChanged: (_) => _autoBillWeight(),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration:
                      const InputDecoration(labelText: 'Peso EE. UU. (lb)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: weightCu,
                  onChanged: (_) => _autoBillWeight(),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration:
                      const InputDecoration(labelText: 'Peso Cuba (lb)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: billWeight,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Peso facturado (lb)'),
          ),
          const SizedBox(height: 12),
          _drop(
            'Estado',
            status,
            statuses
                .map((value) => DropdownMenuItem(
                      value: value,
                      child: Text(value),
                    ))
                .toList(),
            (value) => setState(() => status = value ?? status),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: notes,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Notas'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: saving ? null : _pickPhotos,
            icon: const Icon(Icons.add_a_photo_outlined),
            label: const Text('Añadir fotos del paquete'),
          ),
          if (remotePhotos.isNotEmpty || newPhotoPaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 86,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final path in remotePhotos)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InkWell(
                        onTap: () => _openRemotePhoto(path),
                        child: Container(
                          width: 86,
                          height: 86,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                          child: const Icon(Icons.image_outlined),
                        ),
                      ),
                    ),
                  for (var i = 0; i < newPhotoPaths.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              File(newPhotoPaths[i]),
                              width: 86,
                              height: 86,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: IconButton.filledTonal(
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  setState(() => newPhotoPaths.removeAt(i)),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: saving ? null : save,
            icon: saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(saving ? 'Guardando…' : 'Guardar y sincronizar'),
          ),
        ],
      ),
    );
  }
}

String inferCarrier(String tracking) {
  final value = tracking.trim().toUpperCase();
  if (value.startsWith('1Z')) return 'UPS';
  if (value.startsWith('TBA')) return 'Amazon';
  if (RegExp(r'^(94|93|92|95)\d{18,22}$').hasMatch(value)) return 'USPS';
  if (RegExp(r'^\d{12,15}$').hasMatch(value)) return 'FedEx';
  if (RegExp(r'^\d{10}$').hasMatch(value)) return 'DHL';
  return 'Auto / Otro';
}
