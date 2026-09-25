import 'dart:io';

import 'package:flutter/material.dart';

import '../models/purchase_draft.dart';
import '../services/api_service.dart';
import '../services/knowledge_store.dart';
import 'fullscreen_image_viewer.dart';

class RemittanceDraftReviewPage extends StatefulWidget {
  final PurchaseDraft draft;
  final ApiService api;

  const RemittanceDraftReviewPage({
    super.key,
    required this.draft,
    required this.api,
  });

  @override
  State<RemittanceDraftReviewPage> createState() =>
      _RemittanceDraftReviewPageState();
}

class _RemittanceDraftReviewPageState
    extends State<RemittanceDraftReviewPage> {
  final store = KnowledgeStore.instance;
  late final TextEditingController name;
  late final TextEditingController amount;
  late final TextEditingController date;
  late String source;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    source = draft.remittanceSource.trim().isEmpty
        ? 'Zelle'
        : draft.remittanceSource.trim();
    name = TextEditingController(text: draft.customerName);
    amount = TextEditingController(
      text: draft.total > 0 ? draft.total.toStringAsFixed(2) : '',
    );
    date = TextEditingController(text: draft.remittanceDate);
  }

  @override
  void dispose() {
    name.dispose();
    amount.dispose();
    date.dispose();
    super.dispose();
  }

  double _money(String value) =>
      double.tryParse(value.replaceAll(',', '').replaceAll(r'$', '').trim()) ??
      0;

  PurchaseDraft _current({String? status}) => widget.draft.copyWith(
        customerName: name.text.trim(),
        customerPhone: '',
        store: source,
        total: _money(amount.text),
        status: status,
        draftType: 'remittance',
        remittanceSource: source,
        remittanceDate: date.text.trim(),
      );

  Future<void> _saveOnly() async {
    await store.saveDraft(_current());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Borrador de remesa actualizado.')),
    );
  }

  int _noteId() {
    final raw = widget.draft.noteKey.trim().split(':').last;
    final value = int.tryParse(raw) ?? 0;
    return value > 0 ? value : 0;
  }

  Future<void> _confirm() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final draft = _current(status: 'confirmed');

      Future<void> learn(
        String field,
        String original,
        String corrected,
      ) async {
        if (original.trim().isEmpty ||
            corrected.trim().isEmpty ||
            original.trim() == corrected.trim()) {
          return;
        }
        await widget.api.recordOcrCorrection(
          source: widget.draft.remittanceSource,
          field: field,
          original: original,
          corrected: corrected,
        );
      }

      await learn('name', widget.draft.customerName, draft.customerName);
      await learn(
        'amount',
        widget.draft.total > 0 ? widget.draft.total.toStringAsFixed(2) : '',
        draft.total > 0 ? draft.total.toStringAsFixed(2) : '',
      );
      await learn(
        'date',
        widget.draft.remittanceDate,
        draft.remittanceDate,
      );

      final result = await widget.api.saveOcrRemittance(
        noteId: _noteId(),
        source: draft.remittanceSource,
        name: draft.customerName,
        amount: draft.total,
        date: draft.remittanceDate,
        ocrText: draft.ocrText,
      );
      if (result.isEmpty) {
        throw Exception(
          'No se pudo confirmar la remesa en el servidor. El borrador sigue pendiente.',
        );
      }

      if (result['duplicate'] == true) {
        final duplicateOf = result['duplicate_of'];
        await store.saveDraft(draft.copyWith(status: 'discarded'));
        await store.clearOcrEntityLinks(draft.noteKey);
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Remesa duplicada'),
              content: Text(
                duplicateOf == null
                    ? 'WhatsBot detectó que esta remesa ya estaba registrada.'
                    : 'WhatsBot detectó que coincide con la remesa #' +
                        duplicateOf.toString() +
                        '. No se creó otra remesa.',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Entendido'),
                ),
              ],
            ),
          );
          if (mounted) Navigator.pop(context, true);
        }
        return;
      }

      await store.saveDraft(draft);
      await store.clearOcrEntityLinks(draft.noteKey);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _discard() async {
    await store.saveDraft(_current(status: 'discarded'));
    await store.clearOcrEntityLinks(widget.draft.noteKey);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _pickDate() async {
    final parts = date.text.trim().split('/');
    DateTime initial = DateTime.now();
    if (parts.length == 3) {
      final month = int.tryParse(parts[0]);
      final day = int.tryParse(parts[1]);
      final year = int.tryParse(parts[2]);
      if (month != null && day != null && year != null) {
        initial = DateTime(year, month, day);
      }
    }
    final value = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (value == null) return;
    date.text =
        '${value.month.toString().padLeft(2, '0')}/'
        '${value.day.toString().padLeft(2, '0')}/'
        '${value.year}';
  }

  Future<void> _openImage() async {
    final path = widget.draft.mediaPath.trim();
    if (path.isEmpty || !File(path).existsSync()) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenImageViewer.file(
          title: 'Foto de la remesa',
          path: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final confidence = (draft.confidence * 100).round();

    return Scaffold(
      appBar: AppBar(title: const Text('Borrador de Remesa')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: Text(
                  draft.remittanceSource.isEmpty
                      ? 'Remesa detectada'
                      : 'Remesa ${draft.remittanceSource} detectada',
                ),
                subtitle: Text(
                  'Confianza OCR: $confidence% · Revisa los datos antes de confirmar.',
                ),
              ),
            ),
            if (draft.mediaPath.isNotEmpty &&
                File(draft.mediaPath).existsSync()) ...[
              const SizedBox(height: 10),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _openImage,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        height: 260,
                        width: double.infinity,
                        child: Image.file(
                          File(draft.mediaPath),
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.68),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.zoom_in_outlined,
                            color: Colors.white,
                            size: 18,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Toca para ampliar',
                            style: TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            DropdownButtonFormField<String>(
              initialValue: source,
              decoration: const InputDecoration(
                labelText: 'Origen',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'Zelle', child: Text('Zelle')),
                DropdownMenuItem(value: 'PayPal', child: Text('PayPal')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => source = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Nombre (opcional)',
                hintText: 'Déjalo vacío si no aparece claramente',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monto (opcional)',
                prefixText: r'$ ',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: date,
              decoration: InputDecoration(
                labelText: 'Fecha (opcional)',
                hintText: 'MM/DD/YYYY',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Elegir fecha',
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
            ),
            if (draft.warnings.isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Revisión recomendada',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      ...draft.warnings.map(
                        (warning) => Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Text('• $warning'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            const Text(
              'Nombre, monto y fecha son opcionales. WhatsBot solo rellena lo que puede leer con suficiente claridad.',
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: saving ? null : _discard,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Descartar'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: saving ? null : _saveOnly,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Guardar borrador'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: saving ? null : _confirm,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: const Text('Confirmar remesa'),
            ),
          ],
        ),
      ),
    );
  }
}
