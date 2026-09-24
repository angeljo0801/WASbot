import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/backup_service.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool loading = true;
  bool working = false;
  bool autoEnabled = true;
  List<Map<String, dynamic>> backups = const [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final enabled = await WhatsBotBackupService.autoEnabled();
    final list = await WhatsBotBackupBridge.list();
    if (!mounted) return;
    setState(() {
      autoEnabled = enabled;
      backups = list;
      loading = false;
    });
  }

  Future<void> createBackup() async {
    setState(() => working = true);
    try {
      final result = await WhatsBotBackupService.createManual();
      await load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Salva creada en Descargas/WhatsBot: '
            '${result['name']?.toString() ?? 'salva'}',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo crear la salva: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> restore(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('¿Restaurar esta salva?'),
            content: Text(
              'Los datos locales actuales de WhatsBot se reemplazarán con '
              '“${item['name']?.toString() ?? 'salva'}”. '
              'Las claves privadas y el modelo de IA no se restauran.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Restaurar'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    setState(() => working = true);
    try {
      await WhatsBotBackupService.restore(item['uri']?.toString() ?? '');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Salva restaurada'),
          content: const Text(
            'Cierra y vuelve a abrir WhatsBot para cargar todo el estado restaurado.',
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                SystemNavigator.pop();
              },
              child: const Text('Cerrar WhatsBot'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo restaurar: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  String date(Map<String, dynamic> item) {
    final ms = (item['modifiedMs'] as num?)?.toInt();
    if (ms == null || ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} '
        '${p(d.hour)}:${p(d.minute)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Salvas')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Salva automática diaria'),
                    subtitle: const Text(
                      'Se guarda en Descargas/WhatsBot y sobrevive aunque desinstales la app.',
                    ),
                    value: autoEnabled,
                    onChanged: working
                        ? null
                        : (value) async {
                            await WhatsBotBackupService.setAutoEnabled(value);
                            if (mounted) setState(() => autoEnabled = value);
                          },
                  ),
                  FilledButton.icon(
                    onPressed: working ? null : createBackup,
                    icon: const Icon(Icons.backup_outlined),
                    label: Text(working ? 'Trabajando…' : 'Crear salva ahora'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Incluye notas locales, caché, categorías, ajustes y fotos '
                    'guardadas por WhatsBot. No incluye claves API, tokens, '
                    'contraseñas ni archivos GGUF.',
                  ),
                  const Divider(height: 30),
                  if (backups.isEmpty)
                    const Text('Todavía no hay salvas guardadas.'),
                  for (final item in backups)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.restore_outlined),
                        title: Text(item['name']?.toString() ?? 'Salva'),
                        subtitle: Text(date(item)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: working ? null : () => restore(item),
                      ),
                    ),
                ],
              ),
      );
}
