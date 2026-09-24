import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';
import 'local_ai_service.dart';

class AiProvider {
  static const openai = 'openai';
  static const gemini = 'gemini';
  static const localServer = 'local_server';
  static const manager = 'manager';
  static const device = 'device';
  static const rules = 'rules';

  static const values = <String>{
    openai,
    gemini,
    localServer,
    manager,
    device,
    rules,
  };
}

class AiProviderSettings {
  final String provider;
  final bool autoProcess;
  final String deviceModelPath;
  final String openAiBaseUrl;
  final String openAiModel;
  final String openAiKey;
  final String geminiModel;
  final String geminiKey;
  final String localBaseUrl;
  final String localModel;
  final String localKey;

  const AiProviderSettings({
    required this.provider,
    required this.autoProcess,
    required this.deviceModelPath,
    required this.openAiBaseUrl,
    required this.openAiModel,
    required this.openAiKey,
    required this.geminiModel,
    required this.geminiKey,
    required this.localBaseUrl,
    required this.localModel,
    required this.localKey,
  });
}

class AiProviderService {
  static const _secure = FlutterSecureStorage();
  static const MethodChannel _managerChannel =
      MethodChannel('com.angelapps.local_ai_manager/client');

  final LocalAiService localAi;

  AiProviderService({required this.localAi});

  Future<AiProviderSettings> settings() async {
    final p = await SharedPreferences.getInstance();
    final local = await localAi.settings();

    var provider = p.getString('ai_provider')?.trim() ?? '';
    if (!AiProvider.values.contains(provider)) {
      provider = local.mode == AiMode.local
          ? AiProvider.device
          : local.mode == AiMode.rules
              ? AiProvider.rules
              : AiProvider.openai;
    }

    String prefOr(String key, String fallback) {
      final value = p.getString(key)?.trim() ?? '';
      return value.isEmpty ? fallback : value;
    }

    return AiProviderSettings(
      provider: provider,
      autoProcess: local.autoProcess,
      deviceModelPath: local.modelPath,
      openAiBaseUrl: prefOr('openai_base_url', 'https://api.openai.com/v1'),
      openAiModel: prefOr('openai_model', 'gpt-5.6-luna'),
      openAiKey: (await _secure.read(key: 'openai_api_key') ?? '').trim(),
      geminiModel: prefOr('gemini_model', 'gemini-2.5-flash'),
      geminiKey: (await _secure.read(key: 'gemini_api_key') ?? '').trim(),
      localBaseUrl: prefOr('local_base_url', 'http://127.0.0.1:11434/v1'),
      localModel: prefOr('local_model', 'llama3.2:3b'),
      localKey: (await _secure.read(key: 'local_llm_api_key') ?? '').trim(),
    );
  }

  Future<void> save(AiProviderSettings value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ai_provider', value.provider);
    await p.setString('openai_base_url', value.openAiBaseUrl.trim());
    await p.setString('openai_model', value.openAiModel.trim());
    await p.setString('gemini_model', value.geminiModel.trim());
    await p.setString('local_base_url', value.localBaseUrl.trim());
    await p.setString('local_model', value.localModel.trim());

    await _writeSecret('openai_api_key', value.openAiKey);
    await _writeSecret('gemini_api_key', value.geminiKey);
    await _writeSecret('local_llm_api_key', value.localKey);

    final mode = value.provider == AiProvider.device
        ? AiMode.local
        : value.provider == AiProvider.rules
            ? AiMode.rules
            : AiMode.server;

    await localAi.saveSettings(
      mode: mode,
      modelPath: value.deviceModelPath,
      autoProcess: value.autoProcess,
    );
  }

  Future<void> _writeSecret(String key, String value) async {
    final clean = value.trim();
    if (clean.isEmpty) {
      await _secure.delete(key: key);
    } else {
      await _secure.write(key: key, value: clean);
    }
  }

  String sourceId(String provider) {
    if (provider == AiProvider.openai) return 'openai';
    if (provider == AiProvider.gemini) return 'gemini';
    if (provider == AiProvider.localServer) return 'local_server';
    if (provider == AiProvider.manager) return 'manager';
    if (provider == AiProvider.device) return 'local';
    return 'rules';
  }

  String label(String provider) {
    if (provider == AiProvider.openai) return 'OpenAI';
    if (provider == AiProvider.gemini) return 'Gemini';
    if (provider == AiProvider.localServer) return 'Servidor local';
    if (provider == AiProvider.manager) return 'Local AI Manager';
    if (provider == AiProvider.device) return 'GGUF local';
    return 'Reglas';
  }

  Future<void> test(AiProviderSettings s) async {
    if (s.provider == AiProvider.rules) return;
    if (s.provider == AiProvider.device) {
      if (s.deviceModelPath.trim().isEmpty) {
        throw Exception('Selecciona primero un modelo GGUF.');
      }
      await localAi.loadModel(s.deviceModelPath);
      return;
    }
    if (s.provider == AiProvider.manager) {
      await _managerChannel
          .invokeMethod<String>('ping')
          .timeout(const Duration(seconds: 12));
      return;
    }
    if (s.provider == AiProvider.openai) {
      await _askOpenAiCompatible(
        baseUrl: s.openAiBaseUrl,
        apiKey: s.openAiKey,
        model: s.openAiModel,
        system: 'Responde únicamente con la palabra OK.',
        prompt: 'Prueba de conexión de WhatsBot.',
      );
      return;
    }
    if (s.provider == AiProvider.gemini) {
      await _askGemini(
        apiKey: s.geminiKey,
        model: s.geminiModel,
        prompt: 'Responde únicamente con la palabra OK.',
      );
      return;
    }
    await _askOpenAiCompatible(
      baseUrl: s.localBaseUrl,
      apiKey: s.localKey,
      model: s.localModel,
      system: 'Responde únicamente con la palabra OK.',
      prompt: 'Prueba de conexión de WhatsBot.',
    );
  }

  Future<String> ask({
    required String system,
    required String prompt,
    int maxTokens = 1000,
    double temperature = 0.2,
  }) async {
    final settingsValue = await settings();
    if (settingsValue.provider == AiProvider.rules) {
      throw StateError('Selecciona un modelo de IA para usar el chat.');
    }
    if (settingsValue.provider == AiProvider.device) {
      if (settingsValue.deviceModelPath.trim().isEmpty) {
        throw StateError('Selecciona primero un modelo GGUF.');
      }
      await localAi.saveSettings(
        mode: AiMode.local,
        modelPath: settingsValue.deviceModelPath,
        autoProcess: settingsValue.autoProcess,
      );
      return localAi.ask(
        system: system,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
      );
    }
    if (settingsValue.provider == AiProvider.manager) {
      return _askManager(system: system, prompt: prompt);
    }
    if (settingsValue.provider == AiProvider.openai) {
      return _askOpenAiCompatible(
        baseUrl: settingsValue.openAiBaseUrl,
        apiKey: settingsValue.openAiKey,
        model: settingsValue.openAiModel,
        system: system,
        prompt: prompt,
      );
    }
    if (settingsValue.provider == AiProvider.gemini) {
      return _askGemini(
        apiKey: settingsValue.geminiKey,
        model: settingsValue.geminiModel,
        prompt: system + '\n\n' + prompt,
      );
    }
    return _askOpenAiCompatible(
      baseUrl: settingsValue.localBaseUrl,
      apiKey: settingsValue.localKey,
      model: settingsValue.localModel,
      system: system,
      prompt: prompt,
    );
  }

  Future<List<Map<String, String>>> extractEntities(Note note) async {
    final settingsValue = await settings();
    final out = <Map<String, String>>[];
    if (note.customerName.trim().isNotEmpty) {
      out.add({
        'name': note.customerName.trim(),
        'type': 'cliente',
      });
    }
    if (settingsValue.provider == AiProvider.rules) return out;

    final source = [
      note.title,
      note.content,
      note.originalText,
      note.tags.join(' '),
    ].where((e) => e.trim().isNotEmpty).join('\n');
    if (source.trim().isEmpty) return out;

    const systemPrompt =
        'Extrae entidades útiles de una nota privada de WhatsBot. '
        'Devuelve SOLO un array JSON. Cada elemento debe tener name y type. '
        'type debe ser uno de: cliente, persona, tienda, paquete, tracking, pedido. '
        'Incluye solo entidades explícitas; no inventes nada. '
        'Para personas usa el nombre más completo disponible. '
        'Evita crear entidades para palabras genéricas.';

    final answer = await ask(
      system: systemPrompt,
      prompt: source,
      maxTokens: 500,
      temperature: 0.1,
    );

    dynamic decoded;
    try {
      decoded = jsonDecode(answer.trim());
    } catch (_) {
      final start = answer.indexOf('[');
      final end = answer.lastIndexOf(']');
      if (start >= 0 && end > start) {
        try {
          decoded = jsonDecode(answer.substring(start, end + 1));
        } catch (_) {}
      }
    }

    if (decoded is List) {
      for (final item in decoded) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString().trim();
        var type =
            (item['type'] ?? 'persona').toString().trim().toLowerCase();
        if (name.isEmpty) continue;
        const allowed = {
          'cliente',
          'persona',
          'tienda',
          'paquete',
          'tracking',
          'pedido',
        };
        if (!allowed.contains(type)) type = 'persona';
        final duplicate = out.any(
          (e) =>
              e['name']!.toLowerCase() == name.toLowerCase() &&
              e['type'] == type,
        );
        if (!duplicate) {
          out.add({'name': name, 'type': type});
        }
      }
    }
    return out.take(12).toList();
  }

  Future<OrganizedNote> organize(Note note) async {
    final s = await settings();
    if (s.provider == AiProvider.rules) {
      throw StateError('El modo Reglas no usa un modelo de IA.');
    }

    if (s.provider == AiProvider.device) {
      if (s.deviceModelPath.trim().isEmpty) {
        throw StateError('Selecciona primero un modelo GGUF.');
      }
      await localAi.saveSettings(
        mode: AiMode.local,
        modelPath: s.deviceModelPath,
        autoProcess: s.autoProcess,
      );
      return localAi.organize(note);
    }

    final sourceText = note.content.trim().isNotEmpty
        ? note.content.trim()
        : note.originalText.trim();

    const system =
        'Eres el organizador privado de WhatsBot. '
        'Devuelve SOLO JSON válido, sin markdown, con las claves title, content, category, tags. '
        'category debe ser exactamente una de: Inbox, Trabajo, Personal, Compras, Gastos, Ideas, Documentos, Recordatorios, Fotos. '
        'tags debe ser un array de 0 a 6 strings cortos. '
        'Conserva exactamente nombres, teléfonos, fechas, cantidades, precios y tracking. '
        'Corrige redacción y OCR solo cuando sea obvio. No inventes datos.';

    final prompt = 'Tipo de mensaje: ' +
        note.messageType +
        '\\nTexto original: ' +
        note.originalText +
        '\\nContenido disponible: ' +
        sourceText;

    String raw;
    if (s.provider == AiProvider.manager) {
      raw = await _askManager(system: system, prompt: prompt);
    } else if (s.provider == AiProvider.openai) {
      raw = await _askOpenAiCompatible(
        baseUrl: s.openAiBaseUrl,
        apiKey: s.openAiKey,
        model: s.openAiModel,
        system: system,
        prompt: prompt,
      );
    } else if (s.provider == AiProvider.gemini) {
      raw = await _askGemini(
        apiKey: s.geminiKey,
        model: s.geminiModel,
        prompt: system + '\\n\\n' + prompt,
      );
    } else {
      raw = await _askOpenAiCompatible(
        baseUrl: s.localBaseUrl,
        apiKey: s.localKey,
        model: s.localModel,
        system: system,
        prompt: prompt,
      );
    }

    final data = _extractJson(raw);
    if (data == null) {
      throw const FormatException('El modelo no devolvió JSON válido.');
    }

    const categories = {
      'Inbox',
      'Trabajo',
      'Personal',
      'Compras',
      'Gastos',
      'Ideas',
      'Documentos',
      'Recordatorios',
      'Fotos',
    };
    final requestedCategory = (data['category'] ?? 'Inbox').toString();
    final category =
        categories.contains(requestedCategory) ? requestedCategory : 'Inbox';
    final rawTags = data['tags'];
    final tags = rawTags is List
        ? rawTags
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .take(6)
            .toList()
        : <String>[];
    final title = (data['title'] ?? note.title).toString().trim();

    return OrganizedNote(
      title: title.isEmpty ? note.title : title,
      content: (data['content'] ?? sourceText).toString().trim(),
      category: category,
      tags: tags,
    );
  }

  Future<String> _askManager({
    required String system,
    required String prompt,
  }) async {
    try {
      final answer = await _managerChannel
          .invokeMethod<String>('ask', {
            'prompt': prompt,
            'system': system,
            'maxTokens': 700,
            'temperature': 0.15,
          })
          .timeout(const Duration(minutes: 6));
      final text = (answer ?? '').trim();
      if (text.isEmpty) {
        throw Exception('Local AI Manager no devolvió una respuesta.');
      }
      return text;
    } on PlatformException catch (e) {
      final message = e.message?.trim() ?? '';
      throw Exception(
        message.isEmpty
            ? 'No pude comunicarme con Local AI Manager.'
            : message,
      );
    }
  }

  Future<String> _askOpenAiCompatible({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String system,
    required String prompt,
  }) async {
    final cleanBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final cleanModel = model.trim();
    if (cleanBase.isEmpty) throw Exception('Indica la URL base.');
    if (cleanModel.isEmpty) throw Exception('Indica el modelo.');
    if (cleanBase.contains('api.openai.com') && apiKey.trim().isEmpty) {
      throw Exception('Escribe tu API key de OpenAI.');
    }

    final headers = <String, String>{'Content-Type': 'application/json'};
    if (apiKey.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ' + apiKey.trim();
    }

    final response = await http
        .post(
          Uri.parse(cleanBase + '/chat/completions'),
          headers: headers,
          body: jsonEncode({
            'model': cleanModel,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': prompt},
            ],
          }),
        )
        .timeout(const Duration(minutes: 3));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'El modelo respondió ' +
            response.statusCode.toString() +
            ': ' +
            _errorMessage(response.body),
      );
    }

    final data = jsonDecode(response.body);
    final content =
        data['choices']?[0]?['message']?['content']?.toString() ?? '';
    if (content.trim().isEmpty) {
      throw Exception('El modelo devolvió una respuesta vacía.');
    }
    return content;
  }

  Future<String> _askGemini({
    required String apiKey,
    required String model,
    required String prompt,
  }) async {
    final key = apiKey.trim();
    final cleanModel = model.trim();
    if (key.isEmpty) throw Exception('Escribe tu API key de Gemini.');
    if (cleanModel.isEmpty) throw Exception('Indica el modelo de Gemini.');

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/' +
          cleanModel +
          ':generateContent?key=' +
          key,
    );
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt},
                ],
              },
            ],
            'generationConfig': {'temperature': 0.15},
          }),
        )
        .timeout(const Duration(minutes: 3));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Gemini respondió ' +
            response.statusCode.toString() +
            ': ' +
            _errorMessage(response.body),
      );
    }

    final data = jsonDecode(response.body);
    final text =
        data['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ??
            '';
    if (text.trim().isEmpty) {
      throw Exception('Gemini devolvió una respuesta vacía.');
    }
    return text;
  }

  Map<String, dynamic>? _extractJson(String raw) {
    var text = raw.trim();
    if (text.startsWith('~~~json')) {
      text = text.substring(7).trim();
    } else if (text.startsWith('~~~')) {
      text = text.substring(3).trim();
    }
    if (text.endsWith('~~~')) {
      text = text.substring(0, text.length - 3).trim();
    }

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

  String _errorMessage(String body) {
    try {
      final data = jsonDecode(body);
      final error = data['error'];
      if (error is Map && error['message'] != null) {
        return error['message'].toString();
      }
    } catch (_) {}
    return body.length > 300 ? body.substring(0, 300) + '…' : body;
  }
}
