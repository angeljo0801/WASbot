import 'package:flutter_test/flutter_test.dart';
import 'package:whatsbot/services/remittance_ocr.dart';

void main() {
  test('detects Zelle payment detail without inventing sender name', () {
    final parsed = RemittanceOcrParser.parse('''
Success
Your payment is sent
To
ANGEL J ESCOBEDO GUIA
772-200-5778
Enrolled as ANGEL J ESCOBEDO GUIA
From
Adv SafeBalance Banking - 2926
Amount
$55.00
Date
Sep 24, 2026
Confirmation Number
efhbxtu3g
''');

    expect(parsed.isRemittance, isTrue);
    expect(parsed.source, 'Zelle');
    expect(parsed.name, isEmpty);
    expect(parsed.amount, 55.00);
    expect(parsed.date, '09/24/2026');
  });

  test('detects BECU Zelle sent screen', () {
    final parsed = RemittanceOcrParser.parse('''
Zelle
BECU
Payment Sent
$110.00 Sent
to Angel Escobedo
Enrolled as ANGEL J ESCOBEDO GUIA
The money will typically be available in Angel's account in minutes.
Confirmation #: 6192422279
All Done
''');

    expect(parsed.isRemittance, isTrue);
    expect(parsed.source, 'Zelle');
    expect(parsed.name, isEmpty);
    expect(parsed.amount, 110.00);
    expect(parsed.date, isEmpty);
  });

  test('detects Spanish Zelle confirmation', () {
    final parsed = RemittanceOcrParser.parse('''
¡Listo! Enviaste $145.00 a Angel Escobedo Loreta.
El dinero generalmente estará disponible en unos minutos.
Enviado a
Angel Escobedo Loreta
Inscrito(a) como
ANGEL J ESCOBEDO GUIA
Cantidad
$145.00
Código de confirmación
COFU74HBKX7E
Enviar otro pago
''');

    expect(parsed.isRemittance, isTrue);
    expect(parsed.source, 'Zelle');
    expect(parsed.name, isEmpty);
    expect(parsed.amount, 145.00);
  });

  test('detects PayPal sender amount and transaction date', () {
    final parsed = RemittanceOcrParser.parse('''
PayPal
Alexandre Adam-tremblay sent you $158.99 USD
Amount
$158.99 USD
Transaction date
September 23, 2026
Transaction ID
1RE69330C8626300T
Go to PayPal
''');

    expect(parsed.isRemittance, isTrue);
    expect(parsed.source, 'PayPal');
    expect(parsed.name, 'Alexandre Adam-tremblay');
    expect(parsed.amount, 158.99);
    expect(parsed.date, '09/23/2026');
  });

  test('does not classify a normal purchase screenshot as remittance', () {
    final parsed = RemittanceOcrParser.parse('''
Amazon
Order total: $42.15
Ship to
Angel Escobedo
Place your order
''');

    expect(parsed.isRemittance, isFalse);
  });
}
