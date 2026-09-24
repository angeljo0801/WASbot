double _number(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
}

String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);


class StoreOcrParse {
  final String store;
  final String orderNumber;
  final double total;
  final double subtotal;
  final double tax;
  final double shipping;
  final double discount;
  final int expectedItemCount;
  final List<Map<String, dynamic>> items;
  final List<String> warnings;
  final double confidence;

  const StoreOcrParse({
    required this.store,
    required this.orderNumber,
    required this.total,
    required this.subtotal,
    required this.tax,
    required this.shipping,
    required this.discount,
    required this.expectedItemCount,
    required this.items,
    required this.warnings,
    required this.confidence,
  });

  bool get isOnlineStore =>
      const {'AMAZON', 'ALIEXPRESS', 'TEMU', 'SHEIN'}
          .contains(store.toUpperCase());
}

class _OcrMoneyToken {
  final double value;
  final int start;
  final int end;
  const _OcrMoneyToken(this.value, this.start, this.end);
}

class StoreOcrParser {
  static final RegExp _money = RegExp(
    r'(?:US\s*)?\$?\s*(-?\d{1,6}(?:,\d{3})*(?:[.,]\d{2}))',
    caseSensitive: false,
  );

  static StoreOcrParse parse(String rawText) {
    final text = _normalize(rawText);
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final joined = lines.join('\n');
    final upper = joined.toUpperCase();

    final store = _detectStore(upper);
    final expectedItems = _expectedItemCount(upper);

    double subtotal = 0;
    double tax = 0;
    double shipping = 0;
    double discount = 0;
    double total = 0;

    if (store == 'Amazon') {
      subtotal = _labeledAmount(
        lines,
        [RegExp(r'^\s*ITEMS\s*\(\s*\d+\s*\)\s*:', caseSensitive: false)],
      );
      shipping = _labeledAmount(
        lines,
        [RegExp(r'SHIPPING\s*&\s*HANDLING', caseSensitive: false)],
      );
      tax = _labeledAmount(
        lines,
        [
          RegExp(r'ESTIMATED\s+TAX', caseSensitive: false),
          RegExp(r'\bTAX\b', caseSensitive: false),
        ],
      );
      total = _labeledAmount(
        lines,
        [
          RegExp(r'ORDER\s+TOTAL', caseSensitive: false),
          RegExp(r'GRAND\s+TOTAL', caseSensitive: false),
        ],
      );
    } else if (store == 'AliExpress') {
      subtotal = _labeledAmount(
        lines,
        [RegExp(r'\bSUB\s*TOTAL\b', caseSensitive: false)],
      );
      tax = _labeledAmount(
        lines,
        [RegExp(r'\bTAX\b', caseSensitive: false)],
      );
      shipping = _labeledAmount(
        lines,
        [RegExp(r'^\s*SHIPPING\b', caseSensitive: false)],
      );
      discount = _labeledAmount(
        lines,
        [RegExp(r'\b(DISCOUNT|COUPON|SAVED)\b', caseSensitive: false)],
      );
      total = _labeledAmount(
        lines,
        [
          RegExp(r'^\s*TOTAL\s*[:\-]?', caseSensitive: false),
          RegExp(r'\bORDER\s+TOTAL\b', caseSensitive: false),
        ],
      );
    } else if (store == 'SHEIN') {
      subtotal = _labeledAmount(
        lines,
        [RegExp(r'\bSUB\s*TOTAL\b', caseSensitive: false)],
      );
      tax = _labeledAmount(
        lines,
        [RegExp(r'\bTAX\b', caseSensitive: false)],
      );
      shipping = _labeledAmount(
        lines,
        [RegExp(r'\bSHIPPING\b', caseSensitive: false)],
      );
      discount = _labeledAmount(
        lines,
        [RegExp(r'\b(SAVED|SAVE|DISCOUNT|COUPON)\b', caseSensitive: false)],
      );
      total = _labeledAmount(
        lines,
        [RegExp(r'\b(ORDER\s+TOTAL|GRAND\s+TOTAL)\b', caseSensitive: false)],
      );
      if (total == 0) {
        // On SHEIN checkout screenshots the product grid sits above
        // "Payment Method". Searching too far upward can mistake a product
        // price (for example $5.60) for the order total. Restrict total
        // detection to the checkout footer.
        total = _checkoutFooterAmount(
          lines,
          action: 'PLACE ORDER',
          startMarker: 'PAYMENT METHOD',
          preferFirstOnLine: true,
        );
      }
    } else if (store == 'Temu') {
      subtotal = _labeledAmount(
        lines,
        [RegExp(r'\bSUB\s*TOTAL\b', caseSensitive: false)],
      );
      tax = _labeledAmount(
        lines,
        [RegExp(r'\bTAX\b', caseSensitive: false)],
      );
      shipping = _labeledAmount(
        lines,
        [RegExp(r'\bSHIPPING\b', caseSensitive: false)],
      );
      discount = _labeledAmount(
        lines,
        [RegExp(r'\b(APPLIED|SAVED|SAVE|DISCOUNT|COUPON)\b', caseSensitive: false)],
      );
      total = _labeledAmount(
        lines,
        [RegExp(r'\b(ORDER\s+TOTAL|GRAND\s+TOTAL)\b', caseSensitive: false)],
      );
      if (total == 0) {
        total = _checkoutFooterAmount(
          lines,
          action: 'ORDER AND PAY',
          startMarker: 'PAYMENT METHODS',
          preferFirstOnLine: false,
          preferLowerWhenMultiple: true,
        );
      }
    } else {
      subtotal = _labeledAmount(
        lines,
        [RegExp(r'\b(SUBTOTAL|SUB\s*TOTAL)\b', caseSensitive: false)],
      );
      tax = _labeledAmount(
        lines,
        [RegExp(r'\b(SALES\s*TAX|TAX)\b', caseSensitive: false)],
      );
      shipping = _labeledAmount(
        lines,
        [RegExp(r'\b(SHIPPING|DELIVERY\s+FEE)\b', caseSensitive: false)],
      );
      discount = _labeledAmount(
        lines,
        [RegExp(r'\b(DISCOUNT|COUPON|SAVED)\b', caseSensitive: false)],
      );
      total = _labeledAmount(
        lines,
        [
          RegExp(r'\bGRAND\s+TOTAL\b', caseSensitive: false),
          RegExp(r'\bAMOUNT\s+DUE\b', caseSensitive: false),
          RegExp(r'\bBALANCE\s+DUE\b', caseSensitive: false),
          RegExp(r'^\s*TOTAL\s*[:\-]?', caseSensitive: false),
        ],
      );
    }

    final orderNumber = _orderNumber(lines, upper);
    final items = _extractItems(lines, store);

    if (subtotal == 0 && items.isNotEmpty) {
      subtotal = items.fold<double>(
        0,
        (sum, item) =>
            sum + _number(item['price']) * _number(item['qty']),
      );
    }
    if (total == 0 && subtotal > 0) {
      final online =
          const {'Amazon', 'AliExpress', 'Temu', 'SHEIN'}.contains(store);
      final completeItemSet =
          expectedItems == 0 ||
          (items.isNotEmpty && items.length >= expectedItems);
      if (!online || completeItemSet) {
        final calculated = subtotal + tax + shipping - discount;
        if (calculated > 0) total = calculated;
      }
    }

    final warnings = <String>[];
    if (store == 'Otra tienda') {
      warnings.add('Tienda no reconocida automáticamente');
    }
    if (total <= 0) {
      warnings.add('No pude confirmar el total');
    }
    if (expectedItems > 0 && items.length < expectedItems) {
      if (store == 'Amazon' && items.isEmpty) {
        warnings.add(
          'La captura parece un resumen: muestra $expectedItems artículos, pero no sus nombres',
        );
      } else {
        warnings.add(
          'Solo pude asociar nombre y precio a ${items.length} de $expectedItems artículos',
        );
      }
    }

    double confidence = 0.15;
    if (store != 'Otra tienda') confidence += 0.25;
    if (total > 0) confidence += 0.30;
    if (expectedItems > 0) confidence += 0.10;
    if (items.isNotEmpty) confidence += 0.10;
    if (orderNumber.isNotEmpty) confidence += 0.05;
    if (warnings.isEmpty) confidence += 0.05;
    confidence = confidence.clamp(0.0, 1.0).toDouble();

    return StoreOcrParse(
      store: store,
      orderNumber: orderNumber,
      total: total,
      subtotal: subtotal,
      tax: tax,
      shipping: shipping,
      discount: discount,
      expectedItemCount: expectedItems,
      items: items,
      warnings: warnings,
      confidence: confidence,
    );
  }

  static String _normalize(String raw) => raw
      .replaceAll('\u00A0', ' ')
      .replaceAll('＄', r'$')
      .replaceAll('–', '-')
      .replaceAll('—', '-')
      .trim();

  static String _detectStore(String upper) {
    if (upper.contains('ALIEXPRESS') ||
        (upper.contains('ORDER CONFIRMATION') &&
            upper.contains('SHIPPED BY'))) {
      return 'AliExpress';
    }
    if (upper.contains('SHEIN') || upper.contains('SHIP FROM SHEIN')) {
      return 'SHEIN';
    }
    if (upper.contains('TEMU') ||
        upper.contains('FREE SHIPPING FROM TEMU') ||
        upper.contains('ORDER AND PAY')) {
      return 'Temu';
    }
    if (upper.contains('AMAZON') ||
        (upper.contains('PLACE YOUR ORDER') &&
            upper.contains('ESTIMATED TAX'))) {
      return 'Amazon';
    }
    const known = <String, String>{
      'WALMART': 'Walmart',
      'COSTCO': 'Costco',
      'TARGET': 'Target',
      'WALGREENS': 'Walgreens',
      'PUBLIX': 'Publix',
      'CVS': 'CVS',
    };
    for (final entry in known.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    return 'Otra tienda';
  }

  static int _expectedItemCount(String upper) {
    final patterns = <RegExp>[
      RegExp(r'CHECKOUT\s*\(\s*(\d{1,3})\s*\)', caseSensitive: false),
      RegExp(r'ORDER\s+AND\s+PAY\s*\(\s*(\d{1,3})\s*\)', caseSensitive: false),
      RegExp(r'SHIP\s+FROM\s+SHEIN\s*\(\s*(\d{1,3})\s*\)', caseSensitive: false),
      RegExp(r'ITEMS\s*\(\s*(\d{1,3})\s*\)', caseSensitive: false),
      RegExp(r'VIEW\s*\(\s*(\d{1,3})\s*\)', caseSensitive: false),
    ];
    var best = 0;
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(upper)) {
        final value = int.tryParse(match.group(1) ?? '') ?? 0;
        if (value > best) best = value;
      }
    }
    return best;
  }

  static String _orderNumber(List<String> lines, String upper) {
    final explicit = RegExp(
      r'(?:ORDER|PEDIDO)\s*(?:#|NO\.?|NUMBER|ID|NRO\.?)\s*[:#\-]?\s*([A-Z0-9\-]{5,})',
      caseSensitive: false,
    );
    for (final line in lines) {
      final match = explicit.firstMatch(line);
      if (match != null) return match.group(1) ?? '';
    }
    final amazon = RegExp(r'\b\d{3}-\d{7}-\d{7}\b').firstMatch(upper);
    return amazon?.group(0) ?? '';
  }

  static double _labeledAmount(
    List<String> lines,
    List<RegExp> labels,
  ) {
    for (final label in labels) {
      for (var i = lines.length - 1; i >= 0; i--) {
        final line = lines[i];
        final upper = line.toUpperCase();
        if (!label.hasMatch(line)) continue;
        if (upper.contains('SUBTOTAL') &&
            !label.pattern.toUpperCase().contains('SUB')) {
          continue;
        }
        final values = _moneyTokens(line);
        if (values.isNotEmpty) return values.last.value.abs();
        if (i + 1 < lines.length) {
          final next = _moneyTokens(lines[i + 1]);
          if (next.isNotEmpty) return next.first.value.abs();
        }
      }
    }
    return 0;
  }

  static double _checkoutFooterAmount(
    List<String> lines, {
    required String action,
    required String startMarker,
    required bool preferFirstOnLine,
    bool preferLowerWhenMultiple = false,
  }) {
    var actionIndex = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].toUpperCase().contains(action)) {
        actionIndex = i;
        break;
      }
    }
    if (actionIndex < 0) return 0;

    var startIndex = 0;
    for (var i = actionIndex; i >= 0; i--) {
      if (lines[i].toUpperCase().contains(startMarker)) {
        startIndex = i;
        break;
      }
    }

    // First prefer a line with two amounts in the footer. SHEIN commonly
    // renders current total first and the old/struck-through amount second:
    // "$61.38  $88.46".
    for (var i = actionIndex; i >= startIndex; i--) {
      final upper = lines[i].toUpperCase();
      if (_isPromoLine(upper) ||
          upper.contains('SHIPPING') ||
          upper.contains('DELIVERY')) {
        continue;
      }
      final values = _moneyTokens(lines[i]);
      if (values.length >= 2) {
        final positive = values
            .map((e) => e.value.abs())
            .where((e) => e > 0)
            .toList();
        if (positive.isEmpty) continue;
        if (preferLowerWhenMultiple) {
          positive.sort();
          return positive.first;
        }
        return (preferFirstOnLine ? values.first.value : values.last.value)
            .abs();
      }
    }

    // Then accept the closest non-promotional amount, but never leave the
    // payment/footer region. This prevents product-card prices from being
    // selected as the order total.
    for (var i = actionIndex; i >= startIndex; i--) {
      final upper = lines[i].toUpperCase();
      if (_isPromoLine(upper)) continue;
      final values = _moneyTokens(lines[i]);
      if (values.isEmpty) continue;
      return (preferFirstOnLine ? values.first.value : values.last.value)
          .abs();
    }
    return 0;
  }

  static double _amountNearAction(
    List<String> lines,
    List<String> actions, {
    required bool preferFirstOnLine,
  }) {
    for (var i = lines.length - 1; i >= 0; i--) {
      final upper = lines[i].toUpperCase();
      if (!actions.any(upper.contains)) continue;
      for (var distance = 0; distance <= 7; distance++) {
        final index = i - distance;
        if (index < 0) break;
        final candidate = lines[index];
        final candidateUpper = candidate.toUpperCase();
        if (_isPromoLine(candidateUpper)) continue;
        final values = _moneyTokens(candidate);
        if (values.isEmpty) continue;
        return (preferFirstOnLine
                ? values.first.value
                : values.last.value)
            .abs();
      }
    }
    return 0;
  }

  static bool _isPromoLine(String upper) =>
      upper.contains('SAVED') ||
      upper.contains('SAVE ') ||
      upper.contains('APPLIED') ||
      upper.contains('COUPON') ||
      upper.contains('% OFF') ||
      upper.contains('POINTS');

  static List<Map<String, dynamic>> _extractItems(
    List<String> lines,
    String store,
  ) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final upper = line.toUpperCase();
      if (_isStructuralLine(upper)) continue;

      final tokens = _moneyTokens(line);
      if (tokens.isEmpty) continue;

      var name = _cleanProductName(
        line.substring(0, tokens.first.start),
      );

      if (!_isProductName(name, store)) {
        for (var back = 1; back <= 2; back++) {
          final index = i - back;
          if (index < 0) break;
          final previous = _cleanProductName(lines[index]);
          if (_moneyTokens(previous).isNotEmpty) continue;
          if (_isProductName(previous, store)) {
            name = previous;
            break;
          }
        }
      }

      if (!_isProductName(name, store)) continue;

      final price = tokens.first.value.abs();
      if (price <= 0) continue;
      final qty = _quantityNear(lines, i);
      final key =
          '${name.toUpperCase()}|${price.toStringAsFixed(2)}|$qty';
      if (!seen.add(key)) continue;

      items.add({
        'id': _newId(),
        'name': name,
        'price': price,
        'qty': qty,
        'clientId': '',
      });
    }

    return items;
  }

  static bool _isStructuralLine(String upper) {
    return RegExp(
      r'\b(TOTAL|SUBTOTAL|TAX|SHIPPING|DELIVERY|PAYMENT|MASTERCARD|VISA|PAYPAL|VENMO|CHECKOUT|PLACE ORDER|ORDER AND PAY|ORDER CONFIRMATION|SHIPPING ADDRESS|BILLING ADDRESS|SHIP FROM|SHIPS FROM|FREE SHIPPING|COURIER|PROMO CODE|SUMMARY|SAVED|SAVE|DISCOUNT|COUPON|POINTS|APPLIED|LOCAL WAREHOUSE|NO IMPORT CHARGES|GREAT DEAL|LIMITED TIME|ALMOST SOLD OUT|STAR STORE|LEFT)\b',
      caseSensitive: false,
    ).hasMatch(upper);
  }

  static String _cleanProductName(String raw) {
    var value = raw
        .replaceAll(RegExp(r'^[*#•\-\s]+'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    value = value.replaceAll(
      RegExp(
        r'\s+(?:-\s*)?\d{1,2}%\s*(?:OFF)?\s*$',
        caseSensitive: false,
      ),
      '',
    );
    if (value.length > 140) {
      value = value.substring(0, 140).trim();
    }
    return value;
  }

  static bool _isProductName(String value, String store) {
    if (value.length < 4) return false;
    final upper = value.toUpperCase();
    if (_isStructuralLine(upper)) return false;
    if (RegExp(r'^[\d\s.,:$%\-]+$').hasMatch(value)) return false;
    if (upper.startsWith('COLOR:') ||
        upper.startsWith('LABEL SIZE:') ||
        upper.startsWith('STANDARD SHIPPING') ||
        upper.startsWith('FASTEST DELIVERY')) {
      return false;
    }

    if (const {'Temu', 'SHEIN', 'AliExpress', 'Amazon'}.contains(store)) {
      final words = value
          .split(RegExp(r'\s+'))
          .where((e) => e.trim().isNotEmpty)
          .toList();

      if (words.length == 1 && value.length < 12) return false;

      if (RegExp(
        r'^(STAR\s+STORE|APPLIED|ALMOST\s+SOLD\s+OUT)(\s+.*)?$',
        caseSensitive: false,
      ).hasMatch(value)) {
        return false;
      }
    }

    return RegExp(r'[A-ZÁÉÍÓÚÑa-záéíóúñ]').hasMatch(value);
  }

  static double _quantityNear(List<String> lines, int index) {
    final from = index > 0 ? index - 1 : 0;
    final to =
        index + 2 < lines.length ? index + 2 : lines.length - 1;
    final qtyPattern = RegExp(
      r'\b(?:QTY|QUANTITY|CANT(?:IDAD)?)\s*[:xX\-]?\s*(\d{1,3})\b',
      caseSensitive: false,
    );
    for (var i = from; i <= to; i++) {
      final match = qtyPattern.firstMatch(lines[i]);
      if (match == null) continue;
      final qty = double.tryParse(match.group(1) ?? '');
      if (qty != null && qty > 0 && qty <= 99) return qty;
    }
    return 1.0;
  }

  static List<_OcrMoneyToken> _moneyTokens(String line) {
    final out = <_OcrMoneyToken>[];
    for (final match in _money.allMatches(line)) {
      final raw = match.group(1);
      if (raw == null) continue;
      final value = _parseMoney(raw);
      if (value == null) continue;
      out.add(_OcrMoneyToken(value, match.start, match.end));
    }
    return out;
  }

  static double? _parseMoney(String raw) {
    var value = raw.replaceAll(RegExp(r'[^0-9,.\-]'), '');
    if (value.contains(',') && !value.contains('.')) {
      if (RegExp(r',\d{2}$').hasMatch(value)) {
        value = value.replaceAll(',', '.');
      } else {
        value = value.replaceAll(',', '');
      }
    } else {
      value = value.replaceAll(',', '');
    }
    return double.tryParse(value);
  }
}
