import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/local_ai_service.dart';

class SettingsPage extends StatefulWidget {
  final ApiService api;
  final LocalAiService localAi;
  const SettingsPage({super.key, required this.api, required this.localAi});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final url = TextEditingController();
  final key = TextEditingController();
  String aiMode = AiMode.server;
  String modelPath = '';
  bool autoProcess = true;
  bool checking = false;
  bool modelLoading = false;
  bool? online;
  String? modelStatus;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    url.dispose();
    key.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final s = await widget.api.settings();
    final ai = await widget.localAi.settings();
    url.text = s['url']!;
    key.text = s['key']!;
    aiMode = ai.mode;
    modelPath = ai.modelPath;
    autoProcess = ai.autoProcess;
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    await widget.api.saveSettings(url.text, key.text);
    await widget.localAi.saveSettings(
      mode: aiMode,
      modelPath: modelPath,
      autoProcess: autoProcess,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Configuración guardada')));
    }
  }

  Future<void> test() async {
    setState(() => checking = true);
    await widget.api.saveSettings(url.text, key.text);
    final ok = await widget.api.health();
    if (mounted) setState(() { checking = false; online = ok; });
  }

  Future<void> chooseModel() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['gguf'],
      );
      if (file == null) return;
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Android no devolvió una ruta local para ese archivo.');
      }
      setState(() {
        modelPath = path;
        modelStatus = 'Modelo seleccionado';
      });
      await widget.localAi.saveSettings(mode: aiMode, modelPath: modelPath, autoProcess: autoProcess);
    } catch (e) {
      if (mounted) setState(() => modelStatus = 'No se pudo seleccionar: $e');
    }
  }

  Future<void> testModel() async {
    if (modelPath.isEmpty) {
      setState(() => modelStatus = 'Selecciona un archivo .gguf primero.');
      return;
    }
    setState(() {
      modelLoading = true;
      modelStatus = 'Cargando modelo…';
    });
    try {
      await widget.localAi.saveSettings(mode: AiMode.local, modelPath: modelPath, autoProcess: autoProcess);
      await widget.localAi.loadModel(modelPath);
      if (mounted) setState(() => modelStatus = 'Modelo local cargado correctamente.');
    } catch (e) {
      if (mounted) setState(() => modelStatus = 'Error al cargar: $e');
    } finally {
      if (mounted) setState(() => modelLoading = false);
    }
  }

  String modelName() {
    if (modelPath.isEmpty) return 'Ningún modelo seleccionado';
    return modelPath.split(Platform.pathSeparator).last;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Configuración')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Servidor', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('El número de WhatsApp puede venir de Meta o Twilio. Las credenciales de WhatsApp permanecen en el servidor.'),
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
              decoration: const InputDecoration(labelText: 'API key de la app', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: checking ? null : test, child: Text(checking ? 'Probando…' : 'Probar conexión'))),
                if (online != null) ...[
                  const SizedBox(width: 12),
                  Icon(online! ? Icons.check_circle : Icons.error_outline),
                ],
              ],
            ),
            const SizedBox(height: 28),
            Text('Inteligencia artificial', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('Puedes organizar las notas con un modelo GGUF directamente en el teléfono, con la IA del servidor, o solo con reglas básicas.'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: aiMode,
              decoration: const InputDecoration(labelText: 'Modo de IA', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: AiMode.local, child: Text('Local en este teléfono (GGUF / llama.cpp)')),
                DropdownMenuItem(value: AiMode.server, child: Text('Servidor / OpenAI-compatible / Ollama')),
                DropdownMenuItem(value: AiMode.rules, child: Text('Sin LLM — reglas básicas')),
              ],
              onChanged: (v) => setState(() => aiMode = v ?? aiMode),
            ),
            if (aiMode == AiMode.local) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Modelo local', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(modelName(), maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      const Text('Acepta modelos compatibles con llama.cpp en formato .gguf. Para móviles suelen funcionar mejor modelos cuantizados pequeños.'),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton.icon(onPressed: chooseModel, icon: const Icon(Icons.folder_open), label: const Text('Elegir GGUF')),
                          FilledButton.icon(
                            onPressed: modelLoading ? null : testModel,
                            icon: modelLoading
                                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.memory),
                            label: const Text('Probar modelo'),
                          ),
                        ],
                      ),
                      if (modelStatus != null) ...[
                        const SizedBox(height: 10),
                        Text(modelStatus!, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Organizar automáticamente'),
                subtitle: const Text('Cuando abras o actualices WhatsBot, procesa con el modelo local las notas nuevas de WhatsApp.'),
                value: autoProcess,
                onChanged: (v) => setState(() => autoProcess = v),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: save, icon: const Icon(Icons.save_outlined), label: const Text('Guardar configuración')),
          ],
        ),
      );
}
