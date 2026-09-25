import 'package:flutter_test/flutter_test.dart';
import 'package:whatsbot/services/ocr_natural_correction.dart';

void main() {
  test('parses recent photo batch customer correction', () {
    final parsed = OcrNaturalCorrectionParser.parse(
      'Estas fotos que te acabo de enviar son de una clienta llamada newniurdis',
    );
    expect(parsed, isNotNull);
    expect(parsed!.field, OcrCorrectionField.customerName);
    expect(parsed.value, 'newniurdis');
    expect(parsed.batch, isTrue);
    expect(parsed.targetsPurchases, isTrue);
  });

  test('parses counted photo batch customer correction', () {
    final parsed = OcrNaturalCorrectionParser.parse(
      'Las últimas 3 fotos son de María',
    );
    expect(parsed, isNotNull);
    expect(parsed!.field, OcrCorrectionField.customerName);
    expect(parsed.value, 'María');
    expect(parsed.batch, isTrue);
    expect(parsed.count, 3);
  });

  test('parses total correction', () {
    final parsed = OcrNaturalCorrectionParser.parse(
      'Cambia el total a 125.45',
    );
    expect(parsed, isNotNull);
    expect(parsed!.field, OcrCorrectionField.total);
    expect(parsed.value, '125.45');
  });

  test('parses store correction', () {
    final parsed = OcrNaturalCorrectionParser.parse(
      'Actualiza la tienda a SHEIN',
    );
    expect(parsed, isNotNull);
    expect(parsed!.field, OcrCorrectionField.store);
    expect(parsed.value, 'SHEIN');
  });

  test('parses remittance date correction', () {
    final parsed = OcrNaturalCorrectionParser.parse(
      'Cambia la fecha de la remesa a 09/25/2026',
    );
    expect(parsed, isNotNull);
    expect(parsed!.field, OcrCorrectionField.remittanceDate);
    expect(parsed.targetsRemittances, isTrue);
    expect(parsed.value, '09/25/2026');
  });
}
