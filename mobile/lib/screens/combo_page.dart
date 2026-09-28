import 'package:flutter/material.dart';

import '../services/api_service.dart';

class ComboPage extends StatefulWidget {
  final ApiService api;
  const ComboPage({super.key, required this.api});

  @override
  State<ComboPage> createState() => _ComboPageState();
}

class _ComboPageState extends State<ComboPage> {
  final search = TextEditingController();
  Map<String, dynamic>? snapshot;
  List<Map<String, dynamic>> syncedClients = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> syncedPurchases = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> syncedPackages = <Map<String, dynamic>>[];
  bool loading = true;
  bool syncing = false;
  String? error;
  DateTime? lastManualSync;

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

  List<Map<String, dynamic>> rows(String key) {
    final payload = snapshot?['payload'];
    if (payload is! Map) return [];
    final raw = payload[key];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => e['deleted'] != true)
        .toList();
  }

  String clientName(String? id) {
    final clients = syncedClients.isNotEmpty ? syncedClients : rows('clients');
    for (final c in clients) {
      if ((c['id'] ?? '').toString() == (id ?? '')) {
        return (c['name'] ?? 'Sin cliente').toString();
      }
    }
    return 'Sin cliente';
  }

  bool matches(Map<String, dynamic> item) {
    final q = search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return item.values.join(' ').toLowerCase().contains(q);
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final values = await Future.wait<dynamic>([
        widget.api.paqueteriaSnapshot(),
        widget.api.getClients(),
        widget.api.getSyncedPurchases(),
        widget.api.getSyncedPackages(),
      ]);
      snapshot = values[0] as Map<String, dynamic>?;
      syncedClients = values[1] as List<Map<String, dynamic>>;
      syncedPurchases = values[2] as List<Map<String, dynamic>>;
      syncedPackages = values[3] as List<Map<String, dynamic>>;
      if (snapshot == null &&
          syncedClients.isEmpty &&
          syncedPurchases.isEmpty &&
          syncedPackages.isEmpty) {
        error = 'Paquetería todavía no ha enviado datos al servidor.';
      }
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> syncNow() async {
    if (syncing) return;
    setState(() {
      syncing = true;
      error = null;
    });
    try {
      final values = await Future.wait<dynamic>([
        widget.api.paqueteriaSnapshot(),
        widget.api.getClients(),
        widget.api.getSyncedPurchases(),
        widget.api.getSyncedPackages(),
      ]);
      snapshot = values[0] as Map<String, dynamic>?;
      syncedClients = values[1] as List<Map<String, dynamic>>;
      syncedPurchases = values[2] as List<Map<String, dynamic>>;
      syncedPackages = values[3] as List<Map<String, dynamic>>;
      lastManualSync = DateTime.now();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sincronizado: ${syncedClients.length} clientes · '
            '${syncedPurchases.length} compras · '
            '${syncedPackages.length} paquetes',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo sincronizar: $e')),
      );
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final clients = (syncedClients.isNotEmpty ? syncedClients : rows('clients'))
        .where(matches)
        .toList();
    final purchases =
        (syncedPurchases.isNotEmpty ? syncedPurchases : rows('purchases'))
            .where(matches)
            .toList();
    final packages =
        (syncedPackages.isNotEmpty ? syncedPackages : rows('packages'))
            .where(matches)
            .toList();
    final payments = rows('payments').where(matches).toList();
    final updated = (snapshot?['updated_at'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(title: const Text('Paquetería')),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Combo WhatsBot + Paquetería',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Vista sincronizada para consultar clientes, compras, paquetes y pagos desde WhatsBot.',
                    ),
                    if (updated.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Último envío de Paquetería: ' + updated),
                    ],
                    if (lastManualSync != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Última sincronización manual: '
                        '${lastManualSync!.hour.toString().padLeft(2, '0')}:'
                        '${lastManualSync!.minute.toString().padLeft(2, '0')}',
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: syncing ? null : syncNow,
                        icon: syncing
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync),
                        label: Text(
                          syncing
                              ? 'Sincronizando…'
                              : 'Sincronizar con Paquetería',
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Actualiza Clientes, Compras y Paquetes con la última información enviada por Paquetería.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            SearchBar(
              controller: search,
              hintText: 'Buscar cliente, tracking, compra…',
              leading: const Icon(Icons.search),
              trailing: [
                IconButton(
                  onPressed: () {
                    search.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.clear),
                ),
              ],
              onChanged: (_) => setState(() {}),
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
            if (!loading && error == null) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text('Clientes ' + clients.length.toString())),
                  Chip(label: Text('Compras ' + purchases.length.toString())),
                  Chip(label: Text('Paquetes ' + packages.length.toString())),
                  Chip(label: Text('Pagos ' + payments.length.toString())),
                ],
              ),
              const SizedBox(height: 10),
              ExpansionTile(
                leading: const Icon(Icons.people_outline),
                title: Text('Clientes (' + clients.length.toString() + ')'),
                children: clients.take(100).map((c) {
                  final phone = (c['phone'] ?? '').toString();
                  return ListTile(
                    title: Text((c['name'] ?? 'Sin nombre').toString()),
                    subtitle: phone.isEmpty ? null : Text(phone),
                  );
                }).toList(),
              ),
              ExpansionTile(
                leading: const Icon(Icons.shopping_bag_outlined),
                title: Text('Compras (' + purchases.length.toString() + ')'),
                children: purchases.take(100).map((p) {
                  final canonicalName =
                      (p['customer_name'] ?? '').toString().trim();
                  final name = canonicalName.isNotEmpty
                      ? canonicalName
                      : clientName((p['clientId'] ?? '').toString());
                  final total = p['clientTotal'] ?? p['total'] ?? 0;
                  final status = (p['status'] ?? 'Sin estado').toString();
                  return ListTile(
                    title: Text((p['store'] ?? p['title'] ?? 'Compra').toString()),
                    subtitle: Text(name + ' · USD ' + total.toString() + ' · ' + status),
                  );
                }).toList(),
              ),
              ExpansionTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text('Paquetes (' + packages.length.toString() + ')'),
                children: packages.take(100).map((p) {
                  final canonicalName =
                      (p['client_name'] ?? '').toString().trim();
                  final name = canonicalName.isNotEmpty
                      ? canonicalName
                      : clientName((p['clientId'] ?? '').toString());
                  return ListTile(
                    title: Text((p['tracking'] ?? 'Sin tracking').toString()),
                    subtitle: Text(
                      name + ' · ' + (p['status'] ?? 'Sin estado').toString(),
                    ),
                  );
                }).toList(),
              ),
              ExpansionTile(
                leading: const Icon(Icons.payments_outlined),
                title: Text('Pagos (' + payments.length.toString() + ')'),
                children: payments.take(100).map((p) {
                  final name = clientName((p['clientId'] ?? '').toString());
                  return ListTile(
                    title: Text(
                      name + ' · USD ' + (p['amount'] ?? 0).toString(),
                    ),
                    subtitle: Text((p['date'] ?? '').toString()),
                  );
                }).toList(),
              ),
              const SizedBox(height: 18),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    'También puedes consultar por WhatsApp: “saldo de María”, '
                    '“tracking 1Z…”, “paquetes de Juan”, “compras de Ana” o '
                    '“listos para Cuba”. Envía “ayuda” al bot para ver los comandos.',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
