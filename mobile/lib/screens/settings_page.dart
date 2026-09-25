import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../services/background_service.dart';
import '../services/remittance_sms_service.dart';
import '../services/paypal_email_notification_service.dart';
import 'backup_page.dart';

class SettingsPage extends StatefulWidget {
  final ApiService api;
  const SettingsPage({super.key, required this.api});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  final url = TextEditingController();
  final key = TextEditingController();
  final botNumber = TextEditingController();
  final newAllowedNumber = TextEditingController();
  final newRemittanceAgent = TextEditingController();
  final remittanceSms = RemittanceSmsService();
  final payPalEmail = PayPalEmailNotificationService();

  String provider = 'twilio';
  List<String> allowedNumbers = [];
  bool loading = true;
  bool saving = false;
  bool checking = false;
  bool? serverOnline;
  bool? whatsappConnected;
  Map<String, dynamic>? combo;
  bool backgroundEnabled = true;
  bool backgroundBusy = false;
  List<String> remittanceAgents = <String>[];
  String remittanceCode = '';
  String remittanceCodeDate = '';
  bool smsPermission = false;
  bool remittanceBusy = false;
  bool paypalNotificationAccess = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshPayPalNotificationAccess(sync: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    url.dispose();
    key.dispose();
    botNumber.dispose();
    newAllowedNumber.dispose();
    newRemittanceAgent.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final s = await widget.api.settings();
    final wa = await widget.api.whatsappSettings();
    final remittance = await widget.api.remittanceSettings();
    final background = await WhatsBotBackgroundService.preferenceEnabled();
    final smsAllowed = await remittanceSms.hasPermission();
    final paypalAllowed = await payPalEmail.hasAccess();
    if (!mounted) return;
    setState(() {
      url.text = s['url'] ?? '';
      key.text = s['key'] ?? '';
      provider = (wa['provider'] ?? 'twilio').toString();
      botNumber.text = (wa['bot_number'] ?? '').toString();
      final raw = wa['allowed_numbers'];
      allowedNumbers = raw is List ? raw.map((e) => e.toString()).toList() : <String>[];
      whatsappConnected = wa['connected'] as bool?;
      final rawAgents = remittance['agents'];
      remittanceAgents = rawAgents is List
          ? rawAgents.map((e) => e.toString()).toList()
          : <String>[];
      remittanceCode = (remittance['daily_code'] ?? '').toString();
      remittanceCodeDate = (remittance['code_date'] ?? '').toString();
      smsPermission = smsAllowed;
      paypalNotificationAccess = paypalAllowed;
      backgroundEnabled = background;
      loading = false;
    });
  }

  Future<bool> syncWhatsAppSettings({bool notify = false}) async {
    await widget.api.saveSettings(url.text, key.text);
    final synced = await widget.api.saveWhatsAppSettings(
      provider: provider,
      botNumber: botNumber.text,
      allowedNumbers: allowedNumbers,
    );
    if (notify && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            synced
                ? 'Números autorizados sincronizados con el servidor.'
                : 'No se pudo sincronizar con el servidor. Revisa la URL y la API key.',
          ),
        ),
      );
    }
    return synced;
  }

  Future<void> addAllowedNumber() async {
    final normalized = widget.api.normalizePhone(newAllowedNumber.text);
    if (normalized.isEmpty) return;
    if (!allowedNumbers.contains(normalized)) {
      setState(() => allowedNumbers.add(normalized));
    }
    newAllowedNumber.clear();
    await syncWhatsAppSettings(notify: true);
  }

  Future<void> removeAllowedNumber(String number) async {
    setState(() => allowedNumbers.remove(number));
    await syncWhatsAppSettings(notify: true);
  }

  Future<void> addRemittanceAgent() async {
    final normalized = widget.api.normalizePhone(newRemittanceAgent.text);
    if (normalized.isEmpty) return;
    if (allowedNumbers.contains(normalized)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Ese número es operador administrativo. Quítalo de Números autorizados antes de registrarlo como agente de Remesas.',
            ),
          ),
        );
      }
      return;
    }
    final next = <String>{...remittanceAgents, normalized}.toList();
    setState(() => remittanceBusy = true);
    final saved = await widget.api.saveRemittanceAgents(next);
    if (!mounted) return;
    setState(() {
      remittanceBusy = false;
      if (saved.isNotEmpty) {
        final raw = saved['agents'];
        remittanceAgents = raw is List
            ? raw.map((e) => e.toString()).toList()
            : next;
        remittanceCode = (saved['daily_code'] ?? remittanceCode).toString();
        remittanceCodeDate =
            (saved['code_date'] ?? remittanceCodeDate).toString();
        newRemittanceAgent.clear();
      }
    });
  }

  Future<void> removeRemittanceAgent(String number) async {
    final next = remittanceAgents.where((e) => e != number).toList();
    setState(() => remittanceBusy = true);
    final saved = await widget.api.saveRemittanceAgents(next);
    if (!mounted) return;
    setState(() {
      remittanceBusy = false;
      if (saved.isNotEmpty) {
        final raw = saved['agents'];
        remittanceAgents = raw is List
            ? raw.map((e) => e.toString()).toList()
            : next;
      }
    });
  }

  Future<void> regenerateRemittanceAccessCode() async {
    if (remittanceBusy) return;
    setState(() => remittanceBusy = true);
    final data = await widget.api.regenerateRemittanceCode();
    if (!mounted) return;
    setState(() {
      remittanceBusy = false;
      if (data.isNotEmpty) {
        remittanceCode = (data['daily_code'] ?? '').toString();
        remittanceCodeDate = (data['code_date'] ?? '').toString();
      }
    });
    if (data.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Código regenerado. Las sesiones de agentes anteriores quedaron cerradas.',
          ),
        ),
      );
    }
  }

  Future<void> enableRemittanceSms() async {
    final allowed = await remittanceSms.requestPermission();
    if (!mounted) return;
    setState(() => smsPermission = allowed);
    if (!allowed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sin permiso de SMS, WhatsBot no puede registrar automáticamente las remesas de BofA.',
          ),
        ),
      );
      return;
    }
    final imported = await remittanceSms.syncPending(widget.api);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          imported > 0
              ? 'Permiso activado. Se registraron $imported remesa(s) pendiente(s).'
              : 'Permiso de SMS activado para remesas de BofA.',
        ),
      ),
    );
  }
  Future<void> _refreshPayPalNotificationAccess({
    bool sync = false,
  }) async {
    final allowed = await payPalEmail.hasAccess();
    if (!mounted) return;
    setState(() => paypalNotificationAccess = allowed);
    if (allowed && sync) {
      final imported = await payPalEmail.syncPending(widget.api);
      if (!mounted) return;
      if (imported > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Se registraron $imported remesa(s) de PayPal.',
            ),
          ),
        );
      }
    }
  }

  Future<void> enablePayPalEmailNotifications() async {
    final opened = await payPalEmail.openSettings();
    if (!opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Activa WhatsBot en Acceso a notificaciones y vuelve a la app.',
        ),
      ),
    );
  }

  Future<void> setBackgroundEnabled(bool value) async {
    if (backgroundBusy) return;
    setState(() => backgroundBusy = true);
    final ok = await WhatsBotBackgroundService.setEnabled(value);
    if (!mounted) return;
    setState(() {
      backgroundBusy = false;
      backgroundEnabled = value && ok;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? (ok
                  ? 'WhatsBot seguirá trabajando cuando esté minimizado o la pantalla esté apagada.'
                  : 'No pude activar el modo en segundo plano. Revisa los permisos y la optimización de batería.')
              : 'Modo en segundo plano desactivado.',
        ),
      ),
    );
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
    final synced = await syncWhatsAppSettings();
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
    final synced = await widget.api.saveWhatsAppSettings(
      provider: provider,
      botNumber: botNumber.text,
      allowedNumbers: allowedNumbers,
    );
    final ok = await widget.api.health();
    Map<String, dynamic>? wa;
    Map<String, dynamic>? comboStatus;
    if (ok) {
      wa = await widget.api.whatsappSettings();
      comboStatus = await widget.api.comboStatus();
    }
    if (!mounted) return;
    setState(() {
      checking = false;
      serverOnline = ok;
      whatsappConnected = wa?['connected'] as bool?;
      combo = comboStatus;
    });
    if (ok && !synced && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'El servidor responde, pero no pude sincronizar WhatsApp. Revisa la API key.',
          ),
        ),
      );
    }
  }

  Widget comboCard() {
    final data = combo;
    if (data == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.hub_outlined),
          title: Text('Combo WhatsBot + Paquetería'),
          subtitle: Text('Pulsa Probar conexión para comprobar la sincronización.'),
        ),
      );
    }
    final counts = data['snapshot_counts'];
    final map = counts is Map ? Map<String, dynamic>.from(counts) : <String, dynamic>{};
    final clients = map['clients'] ?? 0;
    final purchases = map['purchases'] ?? 0;
    final packages = map['packages'] ?? 0;
    final pending = data['pending_purchase_conversations'] ?? 0;
    final updated = (data['snapshot_updated_at'] ?? '').toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Combo WhatsBot + Paquetería',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('Clientes: $clients · Compras: $purchases · Paquetes: $packages'),
            const SizedBox(height: 4),
            Text('Conversaciones de compra pendientes: $pending'),
            if (updated.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Última sincronización del negocio: $updated'),
            ],
          ],
        ),
      ),
    );
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
                    const SizedBox(height: 12),
                    comboCard(),
                    const SizedBox(height: 12),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.backup_outlined),
                        title: const Text('Salvas'),
                        subtitle: const Text(
                          'Copia automática diaria, crear salva y restaurar desde Descargas/WhatsBot.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const BackupPage()),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: SwitchListTile(
                        secondary: const Icon(Icons.sync_lock_outlined),
                        title: const Text('Trabajar en segundo plano'),
                        subtitle: const Text(
                          'Mantiene WhatsBot activo para sincronizar mensajes, procesar notas e IA automática aun cuando minimices la app o apagues la pantalla. Android mostrará una notificación mientras esté activo.',
                        ),
                        value: backgroundEnabled,
                        onChanged: backgroundBusy
                            ? null
                            : (value) => setBackgroundEnabled(value),
                      ),
                    ),
                    const Divider(height: 40),

                    Text('WhatsApp', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text(
                      'Aquí defines el número de WhatsBot y qué números personales son operadores autorizados. Esos números pueden crear notas y clientes, preparar compras y consultar datos sincronizados de Paquetería.',
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
                      'Estos son los operadores autorizados para usar las funciones del combo: clientes, compras, saldos, tracking y consultas de Paquetería.',
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
                            onPressed: () => addAllowedNumber(),
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
                              onPressed: () => removeAllowedNumber(number),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                        ),
                      ),
                    const Divider(height: 42),
                    Text(
                      'Remesas',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'WhatsBot registra las remesas recibidas por SMS de Bank of America y pagos de PayPal detectados en Gmail, guardando nombre, monto y fecha. Los agentes de esta sección solo pueden consultar Remesas.',
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.key_outlined),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Código de agentes de hoy',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              remittanceCode.isEmpty
                                  ? '-----'
                                  : remittanceCode,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineMedium,
                            ),
                            if (remittanceCodeDate.isNotEmpty)
                              Text('Fecha: $remittanceCodeDate'),
                            const SizedBox(height: 10),
                            const Text(
                              'Cambia automáticamente cada día. Al regenerarlo, los agentes autenticados tienen que introducir el nuevo código.',
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: remittanceBusy
                                  ? null
                                  : regenerateRemittanceAccessCode,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Regenerar código'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Agentes de Remesas',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Estos números pueden escribirle a WhatsBot, pero solo acceden a Remesas después de autenticarse con el código diario. Para comprobar una remesa deben conocer nombre y monto.',
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newRemittanceAgent,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'Añadir agente',
                              hintText: '+1 772 555 0000',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => addRemittanceAgent(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          height: 56,
                          child: FilledButton(
                            onPressed:
                                remittanceBusy ? null : addRemittanceAgent,
                            child: const Icon(Icons.add),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (remittanceAgents.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('Todavía no hay agentes de Remesas.'),
                        ),
                      )
                    else
                      ...remittanceAgents.map(
                        (number) => Card(
                          child: ListTile(
                            leading: const Icon(Icons.badge_outlined),
                            title: Text(number),
                            subtitle: const Text('Solo Remesas'),
                            trailing: IconButton(
                              tooltip: 'Quitar agente',
                              onPressed: remittanceBusy
                                  ? null
                                  : () => removeRemittanceAgent(number),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                    Card(
                      child: ListTile(
                        leading: Icon(
                          smsPermission
                              ? Icons.sms_outlined
                              : Icons.sms_failed_outlined,
                        ),
                        title: const Text('SMS de Bank of America'),
                        subtitle: Text(
                          smsPermission
                              ? 'Activo. Se procesan automáticamente los SMS con el formato de remesa de BofA.'
                              : 'Hace falta permiso de SMS para registrar automáticamente las remesas que llegan al teléfono.',
                        ),
                        trailing: smsPermission
                            ? const Icon(Icons.check_circle_outline)
                            : TextButton(
                                onPressed: enableRemittanceSms,
                                child: const Text('Activar'),
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Card(
                      child: ListTile(
                        leading: Icon(
                          paypalNotificationAccess
                              ? Icons.mark_email_read_outlined
                              : Icons.mark_email_unread_outlined,
                        ),
                        title: const Text('Correos de PayPal'),
                        subtitle: Text(
                          paypalNotificationAccess
                              ? 'Activo. WhatsBot detecta en las notificaciones de Gmail los pagos de PayPal con el formato “nombre sent you \$monto USD”.'
                              : 'Activa el acceso a notificaciones para registrar automáticamente los pagos de PayPal que lleguen por Gmail.',
                        ),
                        trailing: paypalNotificationAccess
                            ? IconButton(
                                tooltip: 'Comprobar ahora',
                                onPressed: () =>
                                    _refreshPayPalNotificationAccess(sync: true),
                                icon: const Icon(Icons.refresh),
                              )
                            : TextButton(
                                onPressed: enablePayPalEmailNotifications,
                                child: const Text('Activar'),
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
