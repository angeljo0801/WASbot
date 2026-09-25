class RemittanceOcrParse {
  final bool isRemittance;
  final String source;
  final String name;
  final double amount;
  final String date;
  final double confidence;
  final List<String> warnings;

  const RemittanceOcrParse({
    required this.isRemittance,
    required this.source,
    required this.name,
    required this.amount,
    required this.date,
    required this.confidence,
    required this.warnings,
  });

  static const none = RemittanceOcrParse(
    isRemittance: false,
    source: '',
    name: '',
    amount: 0,
    date: '',
    confidence: 0,
    warnings: <String>[],
  );
}

class RemittanceOcrParser {
  static final RegExp _money = RegExp(
    r'\$\s*([0-9]{1,6}(?:,[0-9]{3})*(?:\.[0-9]{2}))',
    caseSensitive: false,
  );

  static RemittanceOcrParse parse(String rawText) {
    final text = rawText
        .replaceAll('\u00A0', ' ')
        .replaceAll('＄', r'$')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .trim();
    if (text.isEmpty) return RemittanceOcrParse.none;

    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final joined = lines.join('\n');
    final upper = joined.toUpperCase();

    final paypalScore = _paypalScore(upper);
    final zelleScore = _zelleScore(upper);
    if (paypalScore < 3 && zelleScore < 3) {
      return RemittanceOcrParse.none;
    }

    final source = paypalScore >= zelleScore ? 'PayPal' : 'Zelle';
    final amount = source == 'PayPal'
        ? _paypalAmount(lines, joined)
        : _zelleAmount(lines, joined);
    final name = source == 'PayPal'
        ? _paypalName(lines, joined)
        : _zelleSenderName(lines);
    final date = _transactionDate(lines, joined);

    final warnings = <String>[];
    if (name.isEmpty) warnings.add('Nombre no detectado; puedes rellenarlo manualmente.');
    if (amount <= 0) warnings.add('Monto no detectado; puedes rellenarlo manualmente.');
    if (date.isEmpty) warnings.add('Fecha no detectada; puedes rellenarla manualmente.');

    var confidence = source == 'PayPal'
        ? (paypalScore / 8.0)
        : (zelleScore / 8.0);
    if (amount > 0) confidence += 0.10;
    if (name.isNotEmpty) confidence += 0.05;
    if (date.isNotEmpty) confidence += 0.05;
    confidence = confidence.clamp(0.0, 1.0).toDouble();

    return RemittanceOcrParse(
      isRemittance: true,
      source: source,
      name: name,
      amount: amount,
      date: date,
      confidence: confidence,
      warnings: warnings,
    );
  }

  static int _paypalScore(String upper) {
    var score = 0;
    if (upper.contains('PAYPAL')) score += 3;
    if (RegExp(r'SENT\s+YOU\s+\$[0-9]', caseSensitive: false)
        .hasMatch(upper)) {
      score += 4;
    }
    if (upper.contains('TRANSACTION DATE')) score += 1;
    if (upper.contains('GO TO PAYPAL')) score += 2;
    if (upper.contains('PAYPAL DEBIT')) score += 1;
    if (upper.contains('MONEY RECEIVED')) score += 2;
    if (RegExp(r'(?:YOU\s+RECEIVED|RECEIVED)\s+\$[0-9]', caseSensitive: false)
        .hasMatch(upper)) {
      score += 3;
    }
    if (upper.contains('AMOUNT') && upper.contains('TRANSACTION')) score += 1;
    return score;
  }

  static int _zelleScore(String upper) {
    var score = 0;
    if (upper.contains('ZELLE')) score += 4;
    if (upper.contains('PAYMENT SENT')) score += 2;
    if (upper.contains('YOUR PAYMENT IS SENT')) score += 3;
    if (upper.contains('ENVIAR OTRO PAGO')) score += 2;
    if (RegExp(r'ENVIASTE\s+\$[0-9]', caseSensitive: false)
        .hasMatch(upper)) {
      score += 3;
    }
    if (upper.contains('CONFIRMATION NUMBER') ||
        upper.contains('CONFIRMATION #') ||
        upper.contains('CODIGO DE CONFIRMACION') ||
        upper.contains('CÓDIGO DE CONFIRMACIÓN')) {
      score += 1;
    }
    if (upper.contains('ENROLLED AS') ||
        upper.contains('INSCRITO(A) COMO') ||
        upper.contains('INSCRITO COMO')) {
      score += 1;
    }
    if (upper.contains('THE MONEY WILL TYPICALLY BE AVAILABLE') ||
        upper.contains('EL DINERO GENERALMENTE ESTARA DISPONIBLE') ||
        upper.contains('EL DINERO GENERALMENTE ESTARÁ DISPONIBLE')) {
      score += 1;
    }
    if (upper.contains('SUCCESS')) score += 1;
    if (upper.contains('FROM') &&
        upper.contains('AMOUNT') &&
        upper.contains('DATE')) {
      score += 2;
    }
    if (upper.contains('CONFIRMATION NUMBER')) score += 1;
    return score;
  }

  static double _paypalAmount(List<String> lines, String joined) {
    final sentYou = RegExp(
      r'SENT\s+YOU\s+\$\s*([0-9]{1,6}(?:,[0-9]{3})*(?:\.[0-9]{2}))\s*USD',
      caseSensitive: false,
    ).firstMatch(joined);
    if (sentYou != null) {
      return _toMoney(sentYou.group(1));
    }
    final received = RegExp(
      r'(?:YOU\s+RECEIVED|RECEIVED)\s+\$\s*([0-9]{1,6}(?:,[0-9]{3})*(?:\.[0-9]{2}))',
      caseSensitive: false,
    ).firstMatch(joined);
    if (received != null) return _toMoney(received.group(1));
    return _labeledAmount(lines, const ['AMOUNT', 'MONTO', 'CANTIDAD']);
  }

  static double _zelleAmount(List<String> lines, String joined) {
    final sent = RegExp(
      r'\$\s*([0-9]{1,6}(?:,[0-9]{3})*(?:\.[0-9]{2}))\s+SENT\b',
      caseSensitive: false,
    ).firstMatch(joined);
    if (sent != null) return _toMoney(sent.group(1));

    final spanish = RegExp(
      r'ENVIASTE\s+\$\s*([0-9]{1,6}(?:,[0-9]{3})*(?:\.[0-9]{2}))',
      caseSensitive: false,
    ).firstMatch(joined);
    if (spanish != null) return _toMoney(spanish.group(1));

    final notification = RegExp(
      r'\$\s*([0-9]{1,6}(?:,[0-9]{3})*(?:\.[0-9]{2}))\s+WILL\s+BE\s+SENT\s+TO',
      caseSensitive: false,
    ).firstMatch(joined);
    if (notification != null) return _toMoney(notification.group(1));

    return _labeledAmount(lines, const ['AMOUNT', 'CANTIDAD', 'MONTO']);
  }

  static double _labeledAmount(List<String> lines, List<String> labels) {
    for (var i = 0; i < lines.length; i++) {
      final upper = lines[i].toUpperCase();
      if (!labels.any(upper.contains)) continue;
      final same = _money.firstMatch(lines[i]);
      if (same != null) return _toMoney(same.group(1));
      if (i + 1 < lines.length) {
        final next = _money.firstMatch(lines[i + 1]);
        if (next != null) return _toMoney(next.group(1));
      }
    }
    return 0;
  }

  static String _paypalName(List<String> lines, String joined) {
    final sentYou = RegExp(
      r'(^|\n)([^\n]{2,80}?)\s+SENT\s+YOU\s+\$\s*[0-9]',
      caseSensitive: false,
    ).firstMatch(joined);
    if (sentYou != null) {
      final value = _cleanName(sentYou.group(2) ?? '');
      if (_plausibleName(value)) return value;
    }

    final receivedFrom = RegExp(
      r'(?:RECEIVED\s+(?:FROM\s+)?|MONEY\s+RECEIVED\s+FROM\s+)([^\n]{2,80})',
      caseSensitive: false,
    ).firstMatch(joined);
    if (receivedFrom != null) {
      final value = _cleanName(receivedFrom.group(1) ?? '');
      if (_plausibleName(value)) return value;
    }

    for (var i = 0; i < lines.length; i++) {
      final upper = lines[i].toUpperCase();
      if (upper == 'FROM' && i + 1 < lines.length) {
        final value = _cleanName(lines[i + 1]);
        if (_plausibleName(value)) return value;
      }
    }
    return '';
  }

  static String _zelleSenderName(List<String> lines) {
    for (var i = 0; i < lines.length; i++) {
      final upper = lines[i].toUpperCase();
      if (upper == 'FROM' && i + 1 < lines.length) {
        final value = _cleanName(lines[i + 1]);
        if (_plausibleZelleSender(value)) return value;
      }
      final sentBy = RegExp(
        r'^(?:SENT\s+BY|ENVIADO\s+POR|DE)\s*[:\-]?\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(lines[i]);
      if (sentBy != null) {
        final value = _cleanName(sentBy.group(1) ?? '');
        if (_plausibleZelleSender(value)) return value;
      }
    }
    return '';
  }

  static bool _plausibleZelleSender(String value) {
    if (!_plausibleName(value)) return false;
    final upper = value.toUpperCase();
    const blocked = <String>[
      'BANK',
      'BANKING',
      'CHECKING',
      'SAVINGS',
      'ACCOUNT',
      'SAFE BALANCE',
      'ADV SAFEBALANCE',
      'ANGEL ESCOBEDO',
    ];
    return !blocked.any(upper.contains);
  }

  static String _transactionDate(List<String> lines, String joined) {
    final labeled = RegExp(
      r'(?:TRANSACTION\s+DATE|DATE|FECHA)\s*[:\-]?\s*'
      r'((?:JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|'
      r'JUL(?:Y)?|AUG(?:UST)?|SEP(?:TEMBER)?|OCT(?:OBER)?|NOV(?:EMBER)?|'
      r'DEC(?:EMBER)?)\s+\d{1,2},\s+\d{4})',
      caseSensitive: false,
    ).firstMatch(joined);
    if (labeled != null) return _normalizeDate(labeled.group(1) ?? '');

    for (var i = 0; i < lines.length; i++) {
      final upper = lines[i].toUpperCase();
      if (upper == 'DATE' || upper == 'FECHA' || upper == 'TRANSACTION DATE') {
        if (i + 1 < lines.length) {
          final normalized = _normalizeDate(lines[i + 1]);
          if (normalized.isNotEmpty) return normalized;
        }
      }
    }

    final slash = RegExp(
      r'\b(0?[1-9]|1[0-2])[/\-](0?[1-9]|[12][0-9]|3[01])[/\-](20\d{2})\b',
    ).firstMatch(joined);
    if (slash != null) {
      final m = int.parse(slash.group(1)!);
      final d = int.parse(slash.group(2)!);
      final y = int.parse(slash.group(3)!);
      return '${m.toString().padLeft(2, '0')}/'
          '${d.toString().padLeft(2, '0')}/$y';
    }
    return '';
  }

  static String _normalizeDate(String raw) {
    final clean = raw.trim();
    final match = RegExp(
      r'^(JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|'
      r'JUL(?:Y)?|AUG(?:UST)?|SEP(?:TEMBER)?|OCT(?:OBER)?|NOV(?:EMBER)?|'
      r'DEC(?:EMBER)?)\s+(\d{1,2}),\s+(\d{4})$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (match == null) return '';
    const months = <String, int>{
      'JAN': 1,
      'JANUARY': 1,
      'FEB': 2,
      'FEBRUARY': 2,
      'MAR': 3,
      'MARCH': 3,
      'APR': 4,
      'APRIL': 4,
      'MAY': 5,
      'JUN': 6,
      'JUNE': 6,
      'JUL': 7,
      'JULY': 7,
      'AUG': 8,
      'AUGUST': 8,
      'SEP': 9,
      'SEPTEMBER': 9,
      'OCT': 10,
      'OCTOBER': 10,
      'NOV': 11,
      'NOVEMBER': 11,
      'DEC': 12,
      'DECEMBER': 12,
    };
    final month = months[match.group(1)!.toUpperCase()];
    if (month == null) return '';
    final day = int.parse(match.group(2)!);
    final year = int.parse(match.group(3)!);
    return '${month.toString().padLeft(2, '0')}/'
        '${day.toString().padLeft(2, '0')}/$year';
  }

  static String _cleanName(String raw) => raw
      .replaceAll(RegExp(r'^[^A-Za-zÀ-ÿ]+'), '')
      .replaceAll(RegExp(r'[^A-Za-zÀ-ÿ .\-\']+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _plausibleName(String value) {
    if (value.length < 3 || value.length > 80) return false;
    final words = value.split(' ').where((e) => e.length > 1).toList();
    if (words.isEmpty || words.length > 7) return false;
    final upper = value.toUpperCase();
    const blocked = <String>[
      'PAYPAL',
      'AMOUNT',
      'TRANSACTION',
      'SUCCESS',
      'PAYMENT',
      'CONFIRMATION',
      'ENROLLED',
      'INSCRITO',
      'SENT YOU',
      'YOUR PAYMENT',
    ];
    return !blocked.any(upper.contains);
  }

  static double _toMoney(String? value) =>
      double.tryParse((value ?? '').replaceAll(',', '')) ?? 0;
}
