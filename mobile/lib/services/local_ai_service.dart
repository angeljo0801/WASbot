import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';

class AiMode {
  static const local = 'local';
  static const server = 'server';
  static const rules = 'rules';
}

class LocalAiSettings {
  final String mode;
  final String modelPath;
  final bool autoProcess;

  const LocalAiSettings({
    required this.mode,
    required this.modelPath,
    required this.autoProcess,
  });
}

class OrganizedNote {
  final String title;
  final String content;
  final String category;
  final List<String> tags;

  const OrganizedNote({
    required this.title,
    required this.content,
    required this.category,
    required this.tags,
  });
}

class LocalAiService {
  static const _modeKey = 'ai_mode';
  static const _modelPathKey = 'local_ai_model_path';
  static const _autoProcessKey = 'local_ai_auto_process';

  LlamaController? _controller;
  String? _loadedModelPath;
  bool _loading = false;

  bool get isLoading => _loading;
  bool get isLoaded => _controller != null && _loadedModelPath != null;
  String? get loadedModelPath => _loadedModelPath;

  Future<LocalAiSettings> settings() async {
    final p = await SharedPreferences.getInstance();
    return LocalAiSettings(
      mode: p.getString(_modeKey) ?? AiMode.server,
      modelPath: p.getString(_modelPathKey) ?? '',
      autoProcess: p.getBool(_autoProcessKey) ?? true,
    );
  }

  Future<void> saveSettings({
    required String mode,
    required String modelPath,
    required bool autoProcess,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_modeKey, mode);
    await p.setString(_modelPathKey, modelPath.trim());
    await p.setBool(_autoProcessKey, autoProcess);
  }

  Future<void> loadConfiguredModel() async {
    final s = await settings();
    if (s.mode != AiMode.local) {
      throw StateError('La IA local no está seleccionada.');
    }
    if (s.modelPath.isEmpty) {
      throw StateError('Selecciona un archivo GGUF primero.');
    }
    await loadModel(s.modelPath);
  }

  Future<void> loadModel(String path) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('La IA local de WhatsBot está habilitada en Android.');
    }
    if (path.trim().isEmpty) {
      throw ArgumentError('Ruta de modelo vacía.');
    }
    if (_loadedModelPath == path && _controller != null) return;

    _loading = true;
    try {
      await dispose();
      final controller = LlamaController();
      var gpuLayers = 0;
      try {
        final gpu = await controller.detectGpu();
        gpuLayers = gpu.recommendedGpuLayers;
      } catch (_) {
        gpuLayers = 0;
      }
      await controller.loadModel(
        modelPath: path,
        contextSize: 4096,
        threads: 6,
        gpuLayers: gpuLayers,
      );
      _controller = controller;
      _loadedModelPath = path;
    } finally {
      _loading = false;
    }
  }

  Future<String> ask({
    required String system,
    required String prompt,
    int maxTokens = 900,
    double temperature = 0.2,
  }) async {
    final settings = await this.settings();
    if (settings.mode != AiMode.local) {
      throw StateError('El modo de IA actual no es local.');
    }
    await loadModel(settings.modelPath);
    final controller = _controller;
    if (controller == null) {
      throw StateError('No se pudo cargar el modelo local.');
    }

    final buffer = StringBuffer();
    final completer = Completer<void>();
    late StreamSubscription<String> sub;
    sub = controller
        .generateChat(
          messages: [
            ChatMessage(role: 'system', content: system),
            ChatMessage(role: 'user', content: prompt),
          ],
          maxTokens: maxTokens,
          temperature: temperature,
          topP: 0.9,
          repeatPenalty: 1.1,
        )
        .listen(
          buffer.write,
          onError: (Object error, StackTrace stack) {
            if (!completer.isCompleted) {
              completer.completeError(error, stack);
            }
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );

    try {
      await completer.future.timeout(const Duration(minutes: 6));
    } finally {
      await sub.cancel();
    }
    final answer = buffer.toString().trim();
    if (answer.isEmpty) {
      throw Exception('El modelo local devolvió una respuesta vacía.');
    }
    return answer;
  }

  Future<OrganizedNote> organize(Note note) async {
    final s = await settings();
    if (s.mode != AiMode.local) {
      throw StateError('El modo de IA actual no es local.');
    }
    await loadModel(s.modelPath);
    final controller = _controller;
    if (controller == null) throw StateError('No se pudo cargar el modelo local.');

    final sourceText = note.content.trim().isNotEmpty
        ? note.content.trim()
        : note.originalText.trim();
    final system = '''Eres el organizador privado de WhatsBot. Recibes una nota enviada por WhatsApp. Devuelve SOLO JSON válido, sin markdown, con estas claves exactas: title, content, category, tags. category debe ser exactamente una de: Inbox, Trabajo, Personal, Compras, Gastos, Ideas, Documentos, Recordatorios, Fotos. tags debe ser un array de 0 a 6 strings cortos. Conserva exactamente nombres, fechas, cantidades y precios cuando existan. Corrige redacción y OCR solo cuando sea obvio. No inventes datos.''';
    final user = '''Tipo de mensaje: ${note.messageType}\nTexto original: ${note.originalText}\nContenido disponible: $sourceText''';

    final buffer = StringBuffer();
    final completer = Completer<void>();
    late StreamSubscription<String> sub;
    sub = controller.generateChat(
      messages: [
        ChatMessage(role: 'system', content: system),
        ChatMessage(role: 'user', content: user),
      ],
      maxTokens: 700,
      temperature: 0.15,
      topP: 0.9,
      repeatPenalty: 1.1,
    ).listen(
      buffer.write,
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    try {
      await completer.future.timeout(const Duration(minutes: 4));
    } finally {
      await sub.cancel();
    }

    final data = _extractJson(buffer.toString());
    if (data == null) {
      throw const FormatException('El modelo no devolvió JSON válido.');
    }
    const categories = {
      'Inbox', 'Trabajo', 'Personal', 'Compras', 'Gastos',
      'Ideas', 'Documentos', 'Recordatorios', 'Fotos'
    };
    final rawCategory = (data['category'] ?? 'Inbox').toString();
    final category = categories.contains(rawCategory) ? rawCategory : 'Inbox';
    final rawTags = data['tags'];
    final tags = rawTags is List
        ? rawTags.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).take(6).toList()
        : <String>[];
    return OrganizedNote(
      title: (data['title'] ?? note.title).toString().trim().isEmpty
          ? note.title
          : (data['title'] ?? note.title).toString().trim(),
      content: (data['content'] ?? sourceText).toString().trim(),
      category: category,
      tags: tags,
    );
  }

  Map<String, dynamic>? _extractJson(String raw) {
    var text = raw.trim();
    text = text.replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
    text = text.replaceFirst(RegExp(r'\s*```$'), '');
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final decoded = jsonDecode(text.substring(start, end + 1));
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  Future<void> stop() async {
    try {
      await _controller?.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    final controller = _controller;
    _controller = null;
    _loadedModelPath = null;
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }
}
