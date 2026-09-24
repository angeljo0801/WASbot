import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/ai_provider_service.dart';
import '../services/api_service.dart';
import '../services/embedding_service.dart';
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
  late final AiProviderService ai;
  late final EmbeddingService embeddings;

  String provider = AiProvider.openai;
  String modelPath = '';
  bool autoProcess = true;
  bool loading = true;
  bool saving = false;
  bool testing = false;
  bool processing = false;
  bool embeddingReady = false;
  bool embeddingDownloading = false;
  double embeddingProgress = 0;
  String? status;

  final openAiUrl = TextEditingController();
  final openAiModel = TextEditingController();
  final openAiKey = TextEditingController();
  final geminiModel = TextEditingController();
  final geminiKey = TextEditingController();
  final localUrl = TextEditingController();
  final localModel = TextEditingController();
  final localKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    ai = AiProviderService(localAi: widget.localAi);
    embeddings = EmbeddingService();
    load();
  }

  @override
  void dispose() {
    openAiUrl.dispose();
    openAiModel.dispose();
    openAiKey.dispose();
    geminiModel.dispose();
    geminiKey.dispose();
    localUrl.dispose();
    localModel.dispose();
    localKey.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final values = await Future.wait([
      ai.settings(),
      embeddings.isReady(),
    ]);
    final s = values[0] as AiProviderSettings;
    final ready = values[1] as bool;
    if (!mounted) return;
    setState(() {
      provider = s.provider;
      modelPath = s.deviceModelPath;
      autoProcess = s.autoProcess;
      openAiUrl.text = s.openAiBaseUrl;
      openAiModel.text = s.openAiModel;
      openAiKey.text = s.openAiKey;
      geminiModel.text = s.geminiModel;
      geminiKey.text = s.geminiKey;
      localUrl.text = s.localBaseUrl;
      localModel.text = s.localModel;
      localKey.text = s.localKey;
      embeddingReady = ready;
      loading = false;
    });
  }

  AiProviderSettings currentSettings() => AiProviderSettings(
        provider: provider,
        autoProcess: autoProcess,
        deviceModelPath: modelPath,
        openAiBaseUrl: openAiUrl.text.trim(),
        openAiModel: openAiModel.text.trim(),
        openAiKey: openAiKey.text.trim(),
        geminiModel: geminiModel.text.trim(),
        geminiKey: geminiKey.text.trim(),
        localBaseUrl: localUrl.text.trim(),
        localModel: localModel.text.trim(),
        localKey: localKey.text.trim(),
      );

  String backendMode() {
    if (provider == AiProvider.device) return AiMode.local;
    if (provider == AiProvider.rules) return AiMode.rules;
    return AiMode.server;
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      await ai.save(currentSettings());
      final synced = await widget.api.setProcessingMode(backendMode());
      if (!mounted) return;
      setState(() {
        status = synced
            ? 'Ajustes de IA guardados y sincronizados.'
            : 'Ajustes guardados en el teléfono. El servidor se sincronizará cuando esté disponible.';
      });
    } catch (e) {
      if (mounted) setState(() => status = 'No se pudo guardar: ' + e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
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
      if (mounted) {
        setState(() {
          modelPath = path;
          status = 'Modelo GGUF seleccionado.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = 'No se pudo seleccionar: ' + e.toString());
    }
  }

  Future<void> testProvider() async {
    setState(() {
      testing = true;
      status = 'Probando ' + ai.label(provider) + '…';
    });
    try {
      final s = currentSettings();
      await ai.save(s);
      await ai.test(s);
      if (mounted) {
        setState(() => status = ai.label(provider) + ' respondió correctamente.');
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Error: ' + e.toString());
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Future<void> downloadEmbeddingModel() async {
    if (embeddingDownloading) return;
    setState(() {
      embeddingDownloading = true;
      embeddingProgress = 0;
      status = 'Preparando memoria semántica…';
    });
    try {
      await embeddings.downloadModel(
        onProgress: (progress) {
          if (mounted) {
            setState(() => embeddingProgress = progress.fraction);
          }
        },
      );
      final notes = await widget.api.getNotes();
      await embeddings.indexAll(
        notes,
        onProgress: (done, total) {
          if (mounted && total > 0) {
            setState(() => embeddingProgress = done / total);
          }
        },
      );
      if (!mounted) return;
      setState(() {
        embeddingReady = true;
        embeddingProgress = 1;
        status =
            'Memoria semántica lista. Las notas nuevas se indexarán automáticamente.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => status = 'No se pudo preparar embeddings: $e');
      }
    } finally {
      if (mounted) setState(() => embeddingDownloading = false);
    }
  }

  Future<void> processNow() async {
    if (provider == AiProvider.rules) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reglas básicas no usan un modelo de IA.')),
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
          const SnackBar(content: Text('Procesamiento con IA iniciado.')),
        );
      }
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Widget choice(String value, IconData icon, String title, String subtitle) {
    return Card(
      child: RadioListTile<String>(
        value: value,
        groupValue: provider,
        onChanged: (v) => setState(() {
          provider = v ?? provider;
          status = null;
        }),
        secondary: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
      ),
    );
  }

  Widget secretField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.key_outlined),
        border: const OutlineInputBorder(),
      ),
    );
  }

  String modelName() {
    if (modelPath.isEmpty) return 'Ningún modelo seleccionado';
    return modelPath.split(Platform.pathSeparator).last;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Ajustes de IA')),
        body: SafeArea(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
                  children: [
                    const Text(
                      'Elige qué cerebro usará WhatsBot',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Ahora puedes escoger el proveedor igual que en Memora. '
                      'Las claves de IA se guardan cifradas en el teléfono y no se envían al backend de WhatsBot.',
                    ),
                    const SizedBox(height: 14),
                    choice(
                      AiProvider.openai,
                      Icons.public,
                      'OpenAI / compatible',
                      'Usa OpenAI o cualquier API compatible con /chat/completions.',
                    ),
                    choice(
                      AiProvider.gemini,
                      Icons.cloud_outlined,
                      'Gemini online',
                      'Usa una API key de Google AI Studio.',
                    ),
                    choice(
                      AiProvider.localServer,
                      Icons.dns_outlined,
                      'LLM local / servidor',
                      'Ollama, LM Studio u otro servidor OpenAI-compatible.',
                    ),
                    choice(
                      AiProvider.manager,
                      Icons.hub_outlined,
                      'Local AI Manager',
                      'Usa el modelo compartido cargado en Local Manager sin volver a cargar otro GGUF en WhatsBot.',
                    ),
                    choice(
                      AiProvider.device,
                      Icons.memory,
                      'GGUF en este teléfono',
                      'Usa directamente un modelo GGUF con llama.cpp.',
                    ),
                    choice(
                      AiProvider.rules,
                      Icons.rule_outlined,
                      'Reglas básicas',
                      'No usa un LLM. Es la opción más simple.',
                    ),
                    const SizedBox(height: 16),
                    if (provider == AiProvider.openai) ...[
                      TextField(
                        controller: openAiUrl,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'URL base',
                          hintText: 'https://api.openai.com/v1',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: openAiModel,
                        decoration: const InputDecoration(
                          labelText: 'Modelo',
                          hintText: 'gpt-5.6-luna',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      secretField(openAiKey, 'API key de OpenAI'),
                    ],
                    if (provider == AiProvider.gemini) ...[
                      TextField(
                        controller: geminiModel,
                        decoration: const InputDecoration(
                          labelText: 'Modelo de Gemini',
                          hintText: 'gemini-2.5-flash',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      secretField(geminiKey, 'API key de Gemini'),
                    ],
                    if (provider == AiProvider.localServer) ...[
                      TextField(
                        controller: localUrl,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'URL del servidor',
                          hintText: 'http://192.168.1.20:11434/v1',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: localModel,
                        decoration: const InputDecoration(
                          labelText: 'Nombre del modelo',
                          hintText: 'llama3.2:3b',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      secretField(localKey, 'Clave opcional'),
                      const SizedBox(height: 8),
                      const Text(
                        'Si el servidor está en otro equipo, usa su IP local. '
                        '127.0.0.1 solo funciona si el servidor corre en el propio teléfono.',
                      ),
                    ],
                    if (provider == AiProvider.manager) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Row(
                                children: [
                                  Icon(Icons.hub_outlined),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Conexión con Local AI Manager',
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 8),
                              Text(
                                'WhatsBot usará el modelo que tengas cargado en Local Manager. '
                                'No necesitas configurar una API key ni volver a cargar el modelo dentro de WhatsBot.',
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Para usarlo, Local AI Manager debe estar instalado y tener un modelo activo.',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (provider == AiProvider.device) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Modelo GGUF',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                modelName(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: testing ? null : chooseModel,
                                icon: const Icon(Icons.folder_open),
                                label: const Text('Elegir GGUF'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.memory_outlined),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Memoria semántica',
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                ),
                                Chip(
                                  label: Text(
                                    embeddingReady ? 'Lista' : 'No descargada',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Usa un modelo multilingüe pequeño de embeddings para indexar automáticamente tus notas y permitir búsquedas por significado en el chat.',
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Se descarga una sola vez y trabaja localmente en el teléfono. La primera descarga ronda los 470 MB.',
                              style: TextStyle(fontSize: 12),
                            ),
                            if (embeddingDownloading) ...[
                              const SizedBox(height: 12),
                              LinearProgressIndicator(
                                value: embeddingProgress > 0 &&
                                        embeddingProgress < 1
                                    ? embeddingProgress
                                    : null,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${(embeddingProgress * 100).round()}%',
                              ),
                            ],
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: embeddingDownloading
                                  ? null
                                  : downloadEmbeddingModel,
                              icon: const Icon(Icons.download_outlined),
                              label: Text(
                                embeddingReady
                                    ? 'Revisar / reindexar'
                                    : 'Descargar modelo de embeddings',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (provider != AiProvider.rules) ...[
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Organizar automáticamente'),
                        subtitle: const Text(
                          'Procesa las notas nuevas de WhatsApp con el proveedor seleccionado.',
                        ),
                        value: autoProcess,
                        onChanged: (v) => setState(() => autoProcess = v),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: testing ? null : testProvider,
                        icon: testing
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.science_outlined),
                        label: Text(
                          testing
                              ? 'Probando…'
                              : 'Probar ' + ai.label(provider),
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: processing || testing ? null : processNow,
                        icon: processing
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.auto_awesome),
                        label: Text(
                          processing
                              ? 'Procesando…'
                              : 'Procesar pendientes ahora',
                        ),
                      ),
                    ],
                    if (status != null) ...[
                      const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(status!),
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
                      label: Text(
                        saving ? 'Guardando…' : 'Guardar y usar esta opción',
                      ),
                    ),
                  ],
                ),
        ),
      );
}
