enum OcrCorrectionField {
  customerName,
  total,
  store,
  orderNumber,
  description,
  remittanceDate,
  remittanceSource,
}

class OcrNaturalCorrection {
  final OcrCorrectionField field;
  final String value;
  final bool batch;
  final int? count;
  final String targetType;

  const OcrNaturalCorrection({
    required this.field,
    required this.value,
    required this.batch,
    required this.count,
    required this.targetType,
  });

  bool get targetsRemittances => targetType == 'remittance';
  bool get targetsPurchases => targetType == 'purchase';
}

class OcrNaturalCorrectionParser {
  const OcrNaturalCorrectionParser._();

  static String _cleanValue(String value) {
    var out = value.trim();
    out = out.replaceFirst(
      RegExp(
        r'^(?:una?\s+)?(?:clienta|cliente)\s+(?:llamada|llamado)\s+',
        caseSensitive: false,
      ),
      '',
    );
    out = out.replaceFirst(
      RegExp(r'^(?:llamada|llamado)\s+', caseSensitive: false),
      '',
    );
    out = out.replaceAll(RegExp(r'[.!?,;:]+$'), '').trim();
    if ((out.startsWith('"') && out.endsWith('"')) ||
        (out.startsWith('“') && out.endsWith('”'))) {
      out = out.substring(1, out.length - 1).trim();
    }
    return out;
  }

  static int? _count(String text) {
    final match = RegExp(
      r'(?:ultimas|últimas|ultimos|últimos)\s+(\d{1,2})\s+(?:fotos|imagenes|imágenes|compras|pedidos|remesas)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    final value = int.tryParse(match.group(1) ?? '');
    if (value == null || value <= 0) return null;
    return value > 20 ? 20 : value;
  }

  static bool _isBatch(String text) {
    return RegExp(
      r'\b(?:estas|esas|aquellas)\s+(?:fotos|imagenes|imágenes|compras|remesas)\b|'
      r'\b(?:fotos|imagenes|imágenes)\s+que\s+(?:te\s+)?(?:acabo|acabe|acabé)\s+de\s+enviar\b|'
      r'\b(?:ultimas|últimas|ultimos|últimos)\s+(?:\d+\s+)?(?:fotos|imagenes|imágenes|compras|pedidos|remesas)\b',
      caseSensitive: false,
    ).hasMatch(text);
  }

  static String _targetType(String text, OcrCorrectionField field) {
    if (RegExp(r'\bremesa(?:s)?\b', caseSensitive: false).hasMatch(text)) {
      return 'remittance';
    }
    if (RegExp(
      r'\b(?:compra|compras|pedido|pedidos|clienta|cliente)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'purchase';
    }
    if (field == OcrCorrectionField.remittanceDate ||
        field == OcrCorrectionField.remittanceSource) {
      return 'remittance';
    }
    return 'purchase';
  }

  static OcrNaturalCorrection? parse(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return null;

    final count = _count(clean);
    final batch = _isBatch(clean) || count != null;

    final customerPatterns = <RegExp>[
      RegExp(
        r'^(?:estas|esas|aquellas)?\s*(?:fotos|imagenes|imágenes|compras|pedidos)?(?:\s+que\s+(?:te\s+)?(?:acabo|acabe|acabé)\s+de\s+enviar)?\s+(?:son|es)\s+(?:de|para)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:el\s+)?(?:cliente|clienta|nombre\s+del\s+cliente)\s+(?:de\s+(?:estas|esas|las\s+ultimas|las\s+últimas)\s+(?:fotos|compras|pedidos)\s+)?(?:es|son|:)?\s*(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:pon|ponle|cambia|cámbia|cámbialo|cambialo|actualiza|corrige)\b.*?\b(?:cliente|clienta|nombre\s+del\s+cliente)\b\s*(?:a|por|como|en|:)?\s*(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:esto|eso|esta|esa|la\s+foto|el\s+pedido|la\s+compra)\s+(?:es|son)\s+(?:de|para)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:las?\s+)?(?:ultimas|últimas)\s+(?:\d+\s+)?(?:fotos|compras|pedidos)\s+son\s+(?:de|para)\s+(.+)$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in customerPatterns) {
      final match = pattern.firstMatch(clean);
      if (match == null) continue;
      final value = _cleanValue(match.group(1) ?? '');
      if (value.isEmpty || value.length > 100) return null;
      return OcrNaturalCorrection(
        field: OcrCorrectionField.customerName,
        value: value,
        batch: batch,
        count: count,
        targetType: _targetType(clean, OcrCorrectionField.customerName),
      );
    }

    final fieldPatterns = <({OcrCorrectionField field, RegExp pattern})>[
      (
        field: OcrCorrectionField.total,
        pattern: RegExp(
          r'^(?:pon|ponle|cambia|cámbialo|corrige|actualiza)?\s*(?:el\s+)?(?:campo\s+)?(?:total|monto)\s*(?:de\s+.+?\s+)?(?:es|a|por|=|:)?\s*\$?([0-9][0-9.,]*)$',
          caseSensitive: false,
        ),
      ),
      (
        field: OcrCorrectionField.store,
        pattern: RegExp(
          r'^(?:pon|ponle|cambia|corrige|actualiza)?\s*(?:la\s+)?(?:campo\s+)?(?:tienda|store)\s*(?:de\s+.+?\s+)?(?:es|a|por|=|:)?\s*(.+)$',
          caseSensitive: false,
        ),
      ),
      (
        field: OcrCorrectionField.orderNumber,
        pattern: RegExp(
          r'^(?:pon|ponle|cambia|corrige|actualiza)?\s*(?:el\s+)?(?:campo\s+)?(?:numero|número|#)\s*(?:de\s+)?pedido\s*(?:de\s+.+?\s+)?(?:es|a|por|=|:)?\s*(.+)$',
          caseSensitive: false,
        ),
      ),
      (
        field: OcrCorrectionField.description,
        pattern: RegExp(
          r'^(?:pon|ponle|cambia|corrige|actualiza)?\s*(?:la\s+)?(?:campo\s+)?(?:descripcion|descripción)\s*(?:de\s+.+?\s+)?(?:es|a|por|=|:)?\s*(.+)$',
          caseSensitive: false,
        ),
      ),
      (
        field: OcrCorrectionField.remittanceDate,
        pattern: RegExp(
          r'^(?:pon|ponle|cambia|corrige|actualiza)?\s*(?:la\s+)?(?:campo\s+)?fecha\s+(?:de\s+la\s+remesa\s+)?(?:es|a|por|=|:)?\s*(.+)$',
          caseSensitive: false,
        ),
      ),
      (
        field: OcrCorrectionField.remittanceSource,
        pattern: RegExp(
          r'^(?:pon|ponle|cambia|corrige|actualiza)?\s*(?:el\s+)?(?:campo\s+)?(?:origen|fuente)\s+(?:de\s+la\s+remesa\s+)?(?:es|a|por|=|:)?\s*(.+)$',
          caseSensitive: false,
        ),
      ),
    ];

    for (final item in fieldPatterns) {
      final match = item.pattern.firstMatch(clean);
      if (match == null) continue;
      final value = _cleanValue(match.group(1) ?? '');
      if (value.isEmpty || value.length > 160) return null;
      return OcrNaturalCorrection(
        field: item.field,
        value: value,
        batch: batch,
        count: count,
        targetType: _targetType(clean, item.field),
      );
    }
    return null;
  }
}
