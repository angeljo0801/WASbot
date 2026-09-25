import os
import tempfile
from pathlib import Path

tmp = tempfile.TemporaryDirectory()
os.environ['DATA_DIR'] = tmp.name

import remittances


def create_notes_table():
    with remittances.db() as conn:
        conn.execute(
            '''
            CREATE TABLE IF NOT EXISTS notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                content TEXT NOT NULL DEFAULT '',
                original_text TEXT NOT NULL DEFAULT '',
                category TEXT NOT NULL DEFAULT 'Inbox',
                tags TEXT NOT NULL DEFAULT '[]',
                source TEXT NOT NULL DEFAULT 'manual',
                message_type TEXT NOT NULL DEFAULT 'text',
                status TEXT NOT NULL DEFAULT 'ready',
                ai_source TEXT NOT NULL DEFAULT 'rules',
                media_path TEXT,
                sender TEXT,
                message_sid TEXT UNIQUE,
                created_at TEXT NOT NULL
            )
            '''
        )
        conn.commit()


create_notes_table()

sms = (
    'BofA: Eusebio Duran Carrion le ha enviado a usted $110.00. '
    'STOP para excl. mensaj. texto de cuenta'
)

parsed = remittances.parse_bofa_sms(sms)
assert parsed == ('Eusebio Duran Carrion', 11000), parsed

saved = remittances.ingest_bofa_sms(
    sms,
    '2026-09-24T22:58:00Z',
    'test-sms-1',
)
assert saved is not None
assert saved['amount'] == 110.0

with remittances.db() as conn:
    note = conn.execute('SELECT * FROM notes WHERE id = ?', (saved['note_id'],)).fetchone()
    record = conn.execute('SELECT * FROM remittances WHERE id = ?', (saved['id'],)).fetchone()

assert note['category'] == 'Remesas'
assert note['message_type'] == 'remittance'
assert 'Nombre: Eusebio Duran Carrion' in note['content']
assert 'Monto: $110.00' in note['content']
assert 'Fecha:' in note['content']
assert 'STOP' not in note['content']
assert note['original_text'] == note['content']
assert record['raw_text'] == sms

duplicate = remittances.ingest_bofa_sms(
    sms,
    '2026-09-24T22:58:00Z',
    'test-sms-1',
)
assert duplicate is not None and duplicate['duplicate'] is True

paypal_subject = 'Alexandre Adam-tremblay sent you $158.99 USD'
paypal_body = '''
Hello, Ana Escobedo

Alexandre Adam-tremblay sent you $158.99 USD

Amount
$158.99 USD
Transaction date
September 23, 2026
Transaction ID
1RE69330C8626300T

Smart money tip
Now earn 5% cash back in a monthly category you choose with PayPal Debit.
'''

paypal_parsed = remittances.parse_paypal_email(paypal_subject, paypal_body)
assert paypal_parsed == (
    'Alexandre Adam-tremblay',
    15899,
    'September 23, 2026',
), paypal_parsed

paypal_saved = remittances.ingest_paypal_email(
    paypal_subject,
    paypal_body,
    '2026-09-24T14:00:00Z',
    'paypal-test-1',
)
assert paypal_saved is not None
assert paypal_saved['amount'] == 158.99

with remittances.db() as conn:
    paypal_note = conn.execute(
        'SELECT * FROM notes WHERE id = ?',
        (paypal_saved['note_id'],),
    ).fetchone()
    paypal_record = conn.execute(
        'SELECT * FROM remittances WHERE id = ?',
        (paypal_saved['id'],),
    ).fetchone()

assert paypal_note['category'] == 'Remesas'
assert paypal_note['source'] == 'email_paypal'
assert paypal_note['message_type'] == 'remittance'
assert 'Nombre: Alexandre Adam-tremblay' in paypal_note['content']
assert 'Monto: $158.99' in paypal_note['content']
assert 'Fecha: 09/23/2026' in paypal_note['content']
assert 'Transaction ID' not in paypal_note['content']
assert 'Smart money tip' not in paypal_note['content']
assert paypal_record['source'] == 'paypal_email'
assert '1RE69330C8626300T' in paypal_record['raw_text']

paypal_duplicate = remittances.ingest_paypal_email(
    paypal_subject,
    paypal_body,
    '2026-09-24T14:00:00Z',
    'paypal-test-1',
)
assert paypal_duplicate is not None and paypal_duplicate['duplicate'] is True
ocr_zelle = remittances.upsert_ocr_remittance(
    note_id=0,
    source='Zelle',
    name='',
    amount=55.00,
    date_text='09/24/2026',
    ocr_text='Your payment is sent\nAmount $55.00\nDate Sep 24, 2026',
)
assert ocr_zelle['source'] == 'zelle'
assert ocr_zelle['name'] == ''
assert ocr_zelle['amount'] == 55.0
assert ocr_zelle['date'] == '09/24/2026'

ocr_paypal = remittances.upsert_ocr_remittance(
    note_id=0,
    source='PayPal',
    name='Alexandre Adam-tremblay',
    amount=158.99,
    date_text='09/23/2026',
    ocr_text='Alexandre Adam-tremblay sent you $158.99 USD',
)
assert ocr_paypal['source'] == 'paypal'
assert ocr_paypal['name'] == 'Alexandre Adam-tremblay'
assert ocr_paypal['amount'] == 158.99
assert ocr_paypal['date'] == '09/23/2026'
agents = remittances.set_agents(['+1 (772) 555-0123'])
assert agents == ['+17725550123']
code, day = remittances.ensure_daily_code()
assert len(code) == 5 and code.isdigit()

reply = remittances.handle_agent_message('+17725550123', code)
assert 'activado' in reply.lower()

reply = remittances.handle_agent_message(
    '+17725550123',
    '¿Llegó la remesa de Eusebio Durán por $110?',
)
assert 'sí' in reply.lower() and '$110.00' in reply
assert 'Carrion' not in reply

reply = remittances.handle_agent_message(
    '+17725550123',
    'Eusebio Duran 120',
)
assert 'no encontré' in reply.lower()

reply = remittances.handle_agent_message(
    '+17725550123',
    '¿Cuánto mandó Eusebio Duran?',
)
assert 'nombre y el monto' in reply.lower()

print('remittance tests passed')
