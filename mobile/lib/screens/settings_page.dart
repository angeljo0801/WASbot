import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

class SettingsPage extends StatefulWidget {
  final ApiService api;
  const SettingsPage({super.key, required this.api});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final url = TextEditingController();
  final key = TextEditingController();
  final botNumber = TextEditingController();
  final newAllowedNumber = TextEditingController();

  String provider = 'twilio';
  List<String> allowedNumbers = [];
  bool loading = true;
  bool saving = false;
  bool checking = false;
  bool? serverOnline;
  bool? whatsappConnected;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    url.dispose();
    key.dispose();
    botNumber.dispose();
    newAllowedNumber.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final s = await widget.api.settings();
    final wa = await widget.api.whatsappSettings();
    if (!mounted) return;
    setState(() {
      url.text = s['url'] ?? '';
      key.text = s['key'] ?? '';
      provider = (wa['provider'] ?? 'twilio').toString();
      botNumber.text = (wa['bot_number'] ?? '').toString();
      final raw = wa['allowed_numbers'];
      allowedNumbers = raw is List ? raw.map((e) => e.toString()).toList() : <String>[];
      whatsappConnected = wa['connected'] as bool?;
      loading = false;
    });
  }

  void addAllowedNumber() {
    final normalized = widget.api.normalizePhone(newAllowedNumber.text);
    if (normalized.isEmpty) return;
    if (!allowedNumbers.contains(normalized)) {
      setState(() => allowedNumbers.add(normalized));
    }
    newAllowedNumber.clear();
  }

  Future<void> openLink(String value) async {
    final uri = Uri.parse(value);
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir el enlace.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo abrir Twilio: $e')),
        );
      }
    }
  }

  Widget twilioTools() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.open_in_new),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Herramientas de Twilio',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Puedes entrar a Twilio desde WhatsBot para comprar o gestionar el número y completar la configuración de WhatsApp.',
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: () => openLink('https://console.twilio.com/'),
                  icon: const Icon(Icons.login),
                  label: const Text('Abrir Twilio'),
                ),
                OutlinedButton.icon(
                  onPressed: () => openLink(
                    'https://console.twilio.com/us1/develop/phone-numbers/manage/incoming',
                  ),
                  icon: const Icon(Icons.dialpad_outlined),
                  label: const Text('Mis números'),
                ),
                OutlinedButton.icon(
                  onPressed: () => openLink(
                    'https://www.twilio.com/docs/whatsapp/self-sign-up',
                  ),
                  icon: const Icon(Icons.chat_outlined),
                  label: const Text('Configurar WhatsApp'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'En la consola de Twilio: Messaging → Senders → WhatsApp Senders.',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> save() async {
    setState(() => saving = true);
    await widget.api.saveSettings(url.text, key.text);
    final synced = await widget.api.saveWhatsAppSettings(
      provider: provider,
      botNumber: botNumber.text,
      allowedNumbers: allowedNumbers,
    );
    if (!mounted) return;
    setState(() => saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          synced
              ? 'Configuración guardada y sincronizada con el servidor.'
              : 'Configuración guardada en el teléfono. Se sincronizará cuando el servidor esté disponible.',
        ),
      ),
    );
  }

  Future<void> testConnection() async {
    setState(() => checking = true);
    await widget.api.saveSettings(url.text, key.text);
    final ok = await widget.api.health();
    Map<String, dynamic>? wa;
    if (ok) {
      wa = await widget.api.whatsappSettings();
    }
    if (!mounted) return;
    setState(() {
      checking = false;
      serverOnline = ok;
      whatsappConnected = wa?['connected'] as bool?;
    });
  }

  Widget statusCard() {
    final online = serverOnline;
    String serverText;
    IconData serverIcon;
    if (online == true) {
      serverText = 'Servidor conectado';
      serverIcon = Icons.cloud_done_outlined;
    } else if (online == false) {
      serverText = 'Servidor sin conexión';
      serverIcon = Icons.cloud_off_outlined;
    } else {
      serverText = 'Servidor no comprobado';
      serverIcon = Icons.cloud_outlined;
    }

    final wa = whatsappConnected;
    String waText;
    IconData waIcon;
    if (wa == true) {
      waText = 'WhatsApp conectado';
      waIcon = Icons.check_circle_outline;
    } else if (botNumber.text.trim().isEmpty) {
      waText = 'Falta el número de WhatsBot';
      waIcon = Icons.info_outline;
    } else if (allowedNumbers.isEmpty) {
      waText = 'Añade al menos un número autorizado';
      waIcon = Icons.info_outline;
    } else {
      waText = 'Configuración lista; falta validar el proveedor en el servidor';
      waIcon = Icons.pending_outlined;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(serverIcon),
                const SizedBox(width: 10),
                Expanded(child: Text(serverText)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(waIcon),
                const SizedBox(width: 10),
                Expanded(child: Text(waText)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Ajustes')),
        body: SafeArea(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
                  children: [
                    Text('Servidor', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text(
                      'WhatsBot recibe los mensajes en un servidor. La APK se conecta a ese servidor para mostrar y organizar tus notas.',
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: url,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'URL del servidor',
                        hintText: 'https://notas.tudominio.com',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: key,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'API key de la app',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: checking ? null : testConnection,
                      icon: checking
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label: Text(checking ? 'Comprobando…' : 'Probar conexión'),
                    ),
                    const SizedBox(height: 10),
                    statusCard(),
                    const Divider(height: 40),

                    Text('WhatsApp', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text(
                      'Aquí defines el número de WhatsBot y qué números personales tienen permiso para crear notas.',
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: provider,
                      decoration: const InputDecoration(
                        labelText: 'Proveedor',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'twilio', child: Text('Twilio')),
                        DropdownMenuItem(value: 'meta', child: Text('Meta Cloud API')),
                      ],
                      onChanged: (v) => setState(() => provider = v ?? provider),
                    ),
                    if (provider == 'twilio') ...[
                      const SizedBox(height: 14),
                      twilioTools(),
                    ],
                    const SizedBox(height: 14),
                    TextField(
                      controller: botNumber,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Número de WhatsBot',
                        hintText: '+1 772 555 1234',
                        helperText: 'Es el número virtual al que enviarás mensajes, fotos, audios y documentos.',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 22),
                    Text('Números autorizados', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    const Text(
                      'Solo los mensajes enviados desde estos números se convertirán en notas.',
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newAllowedNumber,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'Añadir número',
                              hintText: '+1 772 555 0000',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => addAllowedNumber(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          height: 56,
                          child: FilledButton(
                            onPressed: addAllowedNumber,
                            child: const Icon(Icons.add),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (allowedNumbers.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('Todavía no hay números autorizados.'),
                        ),
                      )
                    else
                      ...allowedNumbers.map(
                        (number) => Card(
                          child: ListTile(
                            leading: const Icon(Icons.person_outline),
                            title: Text(number),
                            trailing: IconButton(
                              tooltip: 'Quitar',
                              onPressed: () => setState(() => allowedNumbers.remove(number)),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 26),
                    FilledButton.icon(
                      onPressed: saving ? null : save,
                      icon: saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(saving ? 'Guardando…' : 'Guardar ajustes'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Las credenciales privadas de Twilio o Meta no se guardan dentro de la APK; permanecen en el servidor.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
        ),
      );
}
