import 'package:flutter/material.dart';
import '../services/api_service.dart';

class NewNotePage extends StatefulWidget {
  final ApiService api;
  const NewNotePage({super.key, required this.api});
  @override State<NewNotePage> createState() => _NewNotePageState();
}

class _NewNotePageState extends State<NewNotePage> {
  final title = TextEditingController();
  final content = TextEditingController();
  String category = 'Inbox';
  bool saving = false;
  final categories = const ['Inbox','Trabajo','Personal','Compras','Gastos','Ideas','Documentos','Recordatorios','Fotos'];

  Future<void> save() async {
    if (title.text.trim().isEmpty) return;
    setState(() => saving = true);
    try {
      await widget.api.createNote(title: title.text.trim(), content: content.text.trim(), category: category);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nueva nota')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      TextField(controller: title, decoration: const InputDecoration(labelText: 'Título', border: OutlineInputBorder())),
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(initialValue: category, items: categories.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(), onChanged:(v)=>setState(()=>category=v??category), decoration: const InputDecoration(labelText:'Categoría',border:OutlineInputBorder())),
      const SizedBox(height: 14),
      TextField(controller: content, minLines: 6, maxLines: 14, decoration: const InputDecoration(labelText: 'Contenido', alignLabelWithHint: true, border: OutlineInputBorder())),
      const SizedBox(height: 18),
      FilledButton.icon(onPressed: saving ? null : save, icon: saving ? const SizedBox.square(dimension:18,child:CircularProgressIndicator(strokeWidth:2)) : const Icon(Icons.save_outlined), label: const Text('Guardar')),
    ]),
  );
}
