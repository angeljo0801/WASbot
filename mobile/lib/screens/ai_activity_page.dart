import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/api_service.dart';

class AiActivityPage extends StatefulWidget {
  final ApiService api;

  const AiActivityPage({super.key, required this.api});

  @override
  State<AiActivityPage> createState() => _AiActivityPageState();
}

class _AiActivityPageState extends State<AiActivityPage> {
  bool loading = true;
  List<Map<String, dynamic>> rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    final values = await widget.api.getActivity(limit: 200);
    if (!mounted) return;
    setState(() {
      rows = values;
      loading = false;
    });
  }

  String _title(String type) => switch (type) {
        'whatsapp_inbound' => 'Mensaje recibido',
        'whatsapp_reply' => 'Respuesta de WhatsBot',
        'remittance_duplicate' => 'Duplicado de remesa detectado',
        'business_action' => 'Acción de negocio',
        'client_identity' => 'Cliente identificado',
        'clients_unified' => 'Clientes sincronizados',
        'ocr_correction' => 'Corrección OCR aprendida',
        _ => type.replaceAll('_', ' '),
      };

  IconData _icon(String type) => switch (type) {
        'whatsapp_inbound' => Icons.call_received,
        'whatsapp_reply' => Icons.send_outlined,
        'remittance_duplicate' => Icons.copy_all_outlined,
        'business_action' => Icons.bolt_outlined,
        'client_identity' => Icons.person_search_outlined,
        'clients_unified' => Icons.sync_outlined,
        'ocr_correction' => Icons.school_outlined,
        _ => Icons.info_outline,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Actividad de WhatsBot')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: loading
            ? const ListView(
                children: [
                  SizedBox(height: 180),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : rows.isEmpty
                ? const ListView(
                    children: [
                      SizedBox(height: 180),
                      Center(child: Text('Aún no hay actividad registrada.')),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final type = (row['event_type'] ?? '').toString();
                      final status = (row['status'] ?? '').toString();
                      final detail = row['detail'];
                      final detailText = detail is Map && detail.isNotEmpty
                          ? const JsonEncoder.withIndent('  ').convert(detail)
                          : '';
                      return Card(
                        child: ExpansionTile(
                          leading: Icon(_icon(type)),
                          title: Text(_title(type)),
                          subtitle: Text(
                            [
                              status,
                              (row['sender'] ?? '').toString(),
                              (row['created_at'] ?? '').toString(),
                            ].where((e) => e.isNotEmpty).join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          children: [
                            if (detailText.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  16,
                                ),
                                child: SelectableText(detailText),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
