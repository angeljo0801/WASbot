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
