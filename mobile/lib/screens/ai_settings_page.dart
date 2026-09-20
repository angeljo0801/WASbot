import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/local_ai_service.dart';

class AiSettingsPage extends StatefulWidget {
  final ApiService api;
  final LocalAiService localAi;
  final Future<void> Function() onProcessNow;

  const AiSettingsPage({
    super.key,
    required this.api,
    required this.localAi,
    required this.onProcessNow,
  });

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  String aiMode = AiMode.server;
  String modelPath = '';
  bool autoProcess = true;
  bool loading = true;
  bool saving = false;
  bool modelLoading = false;
  bool processing = false;
  String? modelStatus;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final ai = await widget.localAi.settings();
    var mode = ai.mode;
    try {
      mode = await widget.api.getProcessingMode();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      aiMode = mode;
      modelPath = ai.modelPath;
      autoProcess = ai.autoProcess;
      loading = false;
    });
  }

  Future<void> save() async {
    setState(() => saving = true);
    await widget.localAi.saveSettings(
      mode: aiMode,
      modelPath: modelPath,
      autoProcess: autoProcess,
    );
    final synced = await widget.api.setProcessingMode(aiMode);
    if (!mounted) return;
    setState(() => saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          synced
              ? 'Ajustes de IA guardados y sincronizados.'
              : 'Ajustes de IA guardados en el teléfono. Se sincronizarán cuando el servidor esté disponible.',
        ),
      ),
    );
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
        modelStatus = 'Modelo seleccionado.';
      });
      await widget.localAi.saveSettings(
        mode: aiMode,
        modelPath: modelPath,
        autoProcess: autoProcess,
      );
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
      await widget.localAi.saveSettings(
        mode: AiMode.local,
        modelPath: modelPath,
        autoProcess: autoProcess,
      );
      await widget.localAi.loadModel(modelPath);
      if (mounted) setState(() => modelStatus = 'Modelo local cargado correctamente.');
    } catch (e) {
      if (mounted) setState(() => modelStatus = 'Error al cargar: $e');
    } finally {
      if (mounted) setState(() => modelLoading = false);
    }
  }

  Future<void> processNow() async {
    if (aiMode != AiMode.local) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona IA local para procesar las notas en el teléfono.')),
      );
      return;
    }
    if (modelPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona primero un modelo GGUF.')),
      );
      return;
    }
    await save();
    if (!mounted) return;
    setState(() => processing = true);
    try {
      await widget.onProcessNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Procesamiento local iniciado.')),
        );
      }
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  String modelName() {
    if (modelPath.isEmpty) return 'Ningún modelo seleccionado';
    return modelPath.split(Platform.pathSeparator).last;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Inteligencia artificial')),
        body: SafeArea(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
                  children: [
                    Text('Modelo para organizar notas', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text(
                      'Elige dónde quieres que se interpreten y organicen los mensajes recibidos por WhatsApp.',
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      initialValue: aiMode,
                      decoration: const InputDecoration(
                        labelText: 'Modo de IA',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: AiMode.local,
                          child: Text('Local en este teléfono (GGUF / LLaMA)'),
                        ),
                        DropdownMenuItem(
                          value: AiMode.server,
                          child: Text('Servidor / OpenAI-compatible / Ollama'),
                        ),
                        DropdownMenuItem(
                          value: AiMode.rules,
                          child: Text('Sin LLM — reglas básicas'),
                        ),
                      ],
                      onChanged: (v) => setState(() => aiMode = v ?? aiMode),
                    ),
                    if (aiMode == AiMode.local) ...[
                      const SizedBox(height: 18),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Modelo local', style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              Text(modelName(), maxLines: 2, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 6),
                              const Text(
                                'Puedes elegir cualquier modelo compatible con llama.cpp en formato GGUF. El archivo permanece en tu teléfono.',
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: modelLoading ? null : chooseModel,
                                    icon: const Icon(Icons.folder_open),
                                    label: const Text('Elegir GGUF'),
                                  ),
                                  FilledButton.icon(
                                    onPressed: modelLoading ? null : testModel,
                                    icon: modelLoading
                                        ? const SizedBox.square(
                                            dimension: 18,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        : const Icon(Icons.memory),
                                    label: Text(modelLoading ? 'Cargando…' : 'Probar modelo'),
                                  ),
                                ],
                              ),
                              if (modelStatus != null) ...[
                                const SizedBox(height: 12),
                                Text(modelStatus!),
                              ],
                            ],
                          ),
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Organizar automáticamente'),
                        subtitle: const Text(
                          'Al abrir o actualizar WhatsBot, procesa las notas nuevas con el modelo local.',
                        ),
                        value: autoProcess,
                        onChanged: (v) => setState(() => autoProcess = v),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: processing || modelLoading ? null : processNow,
                        icon: processing
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.auto_awesome),
                        label: Text(processing ? 'Procesando…' : 'Procesar pendientes ahora'),
                      ),
                    ],
                    const SizedBox(height: 28),
                    FilledButton.icon(
                      onPressed: saving ? null : save,
                      icon: saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(saving ? 'Guardando…' : 'Guardar IA'),
                    ),
                  ],
                ),
        ),
      );
}
