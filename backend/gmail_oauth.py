import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
import urllib.parse
import urllib.request
from contextlib import closing
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException, Query
from fastapi.responses import HTMLResponse, RedirectResponse

APP_API_KEY = os.getenv('APP_API_KEY', 'dev-mobile-key').strip()
CLIENT_ID = os.getenv('GMAIL_CLIENT_ID', '').strip()
CLIENT_SECRET = os.getenv('GMAIL_CLIENT_SECRET', '').strip()
PUBLIC_BASE_URL = os.getenv('PUBLIC_BASE_URL', 'https://wasbot-backend-production.up.railway.app').strip().rstrip('/')
REDIRECT_URI = os.getenv('GMAIL_REDIRECT_URI', f'{PUBLIC_BASE_URL}/api/gmail/callback').strip()
DATA_DIR = Path(os.getenv('DATA_DIR', './data'))
DB_PATH = DATA_DIR / 'whatsbot.db'
STATE_TTL_SECONDS = 1800
STATE_SECRET = os.getenv('GMAIL_STATE_SECRET', APP_API_KEY or CLIENT_SECRET or 'dev-mobile-key').encode()
router = APIRouter()


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_gmail_auth() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with closing(db()) as conn:
        conn.executescript('''
        CREATE TABLE IF NOT EXISTS gmail_auth(
          id INTEGER PRIMARY KEY CHECK(id=1),
          access_token TEXT NOT NULL DEFAULT '',
          refresh_token TEXT NOT NULL DEFAULT '',
          expires_at REAL NOT NULL DEFAULT 0,
          email TEXT NOT NULL DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS gmail_accounts(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL DEFAULT '',
          access_token TEXT NOT NULL DEFAULT '',
          refresh_token TEXT NOT NULL DEFAULT '',
          expires_at REAL NOT NULL DEFAULT 0,
          enabled INTEGER NOT NULL DEFAULT 1,
          is_primary INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL DEFAULT 0
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_gmail_accounts_email_nonempty
          ON gmail_accounts(email) WHERE email != '';
        ''')

        # One-time migration from the old singleton table. Keep the legacy table
        # for backward compatibility, but all new logic uses gmail_accounts.
        count = int(conn.execute('SELECT COUNT(*) FROM gmail_accounts').fetchone()[0])
        legacy = conn.execute('SELECT * FROM gmail_auth WHERE id=1').fetchone()
        if count == 0 and legacy and (legacy['refresh_token'] or legacy['access_token']):
            now = time.time()
            conn.execute('''
            INSERT INTO gmail_accounts(
              email,access_token,refresh_token,expires_at,enabled,is_primary,created_at,updated_at
            ) VALUES(?,?,?,?,1,1,?,?)
            ''', (
                str(legacy['email'] or ''),
                str(legacy['access_token'] or ''),
                str(legacy['refresh_token'] or ''),
                float(legacy['expires_at'] or 0),
                now,
                now,
            ))
        columns = {str(row['name']) for row in conn.execute('PRAGMA table_info(gmail_accounts)').fetchall()}
        if 'client_id' not in columns:
            conn.execute("ALTER TABLE gmail_accounts ADD COLUMN client_id TEXT NOT NULL DEFAULT ''")
        if 'client_name' not in columns:
            conn.execute("ALTER TABLE gmail_accounts ADD COLUMN client_name TEXT NOT NULL DEFAULT ''")
        conn.commit()


init_gmail_auth()


def require_key(value: str | None) -> None:
    if not APP_API_KEY or value != APP_API_KEY:
        raise HTTPException(status_code=401, detail='Invalid API key')


def _b64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip('=')


def _b64url_decode(value: str) -> bytes:
    padding = '=' * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def create_oauth_state(
    account_id: int | None = None,
    *,
    client_id: str = '',
    client_name: str = '',
) -> str:
    payload = json.dumps({
        'ts': int(time.time()),
        'nonce': secrets.token_urlsafe(18),
        'account_id': account_id,
        'client_id': client_id.strip(),
        'client_name': client_name.strip()[:160],
    }, separators=(',', ':')).encode()
    signature = hmac.new(STATE_SECRET, payload, hashlib.sha256).digest()
    return f'{_b64url_encode(payload)}.{_b64url_encode(signature)}'


def decode_oauth_state(value: str) -> dict[str, Any] | None:
    try:
        encoded_payload, encoded_signature = value.split('.', 1)
        payload = _b64url_decode(encoded_payload)
        signature = _b64url_decode(encoded_signature)
        expected = hmac.new(STATE_SECRET, payload, hashlib.sha256).digest()
        if not hmac.compare_digest(signature, expected):
            return None
        parsed = json.loads(payload.decode())
        age = time.time() - int(parsed.get('ts') or 0)
        if not (-60 <= age <= STATE_TTL_SECONDS):
            return None
        return parsed
    except Exception:
        return None


def validate_oauth_state(value: str) -> bool:
    return decode_oauth_state(value) is not None


def request_json(url: str, *, method: str = 'GET', headers: dict[str, str] | None = None, form: dict[str, str] | None = None) -> dict[str, Any]:
    body = None
    h = dict(headers or {})
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
        h['Content-Type'] = 'application/x-www-form-urlencoded'
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode()
            return json.loads(raw) if raw else {}
    except Exception as exc:
        detail = str(exc)
        try:
            detail = exc.read().decode()
        except Exception:
            pass
        raise HTTPException(status_code=502, detail=f'Google API error: {detail}') from exc


def account_row(account_id: int) -> sqlite3.Row | None:
    with closing(db()) as conn:
        return conn.execute('SELECT * FROM gmail_accounts WHERE id=?', (account_id,)).fetchone()


def accounts_rows(*, enabled_only: bool = False) -> list[sqlite3.Row]:
    with closing(db()) as conn:
        where = 'WHERE enabled=1' if enabled_only else ''
        return conn.execute(
            f'''SELECT * FROM gmail_accounts {where}
                ORDER BY is_primary DESC, enabled DESC, lower(email), id'''
        ).fetchall()


def auth_row() -> sqlite3.Row | None:
    # Backward-compatible helper: primary account first, otherwise first account.
    rows = accounts_rows()
    return rows[0] if rows else None


def _public_account(row: sqlite3.Row) -> dict[str, Any]:
    return {
        'id': int(row['id']),
        'email': str(row['email'] or ''),
        'enabled': bool(row['enabled']),
        'primary': bool(row['is_primary']),
        'connected': bool(row['refresh_token'] or row['access_token']),
        'clientId': str(row['client_id'] or '') if 'client_id' in row.keys() else '',
        'clientName': str(row['client_name'] or '') if 'client_name' in row.keys() else '',
    }


def save_tokens(
    data: dict[str, Any],
    email: str = '',
    account_id: int | None = None,
    *,
    client_id: str = '',
    client_name: str = '',
) -> int:
    access = str(data.get('access_token') or '')
    expires = time.time() + max(60, int(data.get('expires_in') or 3600) - 60)
    email = email.strip()
    client_id = client_id.strip()
    client_name = client_name.strip()[:160]
    now = time.time()

    with closing(db()) as conn:
        target = None
        if account_id is not None:
            target = conn.execute('SELECT * FROM gmail_accounts WHERE id=?', (account_id,)).fetchone()

        # If Google returned an email already connected in a different row, use
        # that row instead of creating a duplicate account.
        by_email = None
        if email:
            by_email = conn.execute('SELECT * FROM gmail_accounts WHERE lower(email)=lower(?)', (email,)).fetchone()
        if by_email is not None and (target is None or int(by_email['id']) != int(target['id'])):
            target = by_email

        if target is None:
            count = int(conn.execute('SELECT COUNT(*) FROM gmail_accounts').fetchone()[0])
            refresh = str(data.get('refresh_token') or '')
            cur = conn.execute('''
            INSERT INTO gmail_accounts(
              email,access_token,refresh_token,expires_at,enabled,is_primary,created_at,updated_at,
              client_id,client_name
            ) VALUES(?,?,?,?,1,?,?,?,?,?)
            ''', (
                email, access, refresh, expires, 1 if count == 0 else 0, now, now,
                client_id, client_name,
            ))
            saved_id = int(cur.lastrowid)
        else:
            saved_id = int(target['id'])
            refresh = str(data.get('refresh_token') or target['refresh_token'] or '')
            conn.execute('''
            UPDATE gmail_accounts SET
              email=CASE WHEN ?!='' THEN ? ELSE email END,
              access_token=?,
              refresh_token=?,
              expires_at=?,
              enabled=1,
              updated_at=?,
              client_id=CASE WHEN ?!='' THEN ? ELSE client_id END,
              client_name=CASE WHEN ?!='' THEN ? ELSE client_name END
            WHERE id=?
            ''', (
                email, email, access, refresh, expires, now,
                client_id, client_id, client_name, client_name, saved_id,
            ))

        # Guarantee exactly one primary account whenever at least one exists.
        primary_count = int(conn.execute('SELECT COUNT(*) FROM gmail_accounts WHERE is_primary=1').fetchone()[0])
        if primary_count == 0:
            conn.execute('UPDATE gmail_accounts SET is_primary=CASE WHEN id=? THEN 1 ELSE 0 END', (saved_id,))

        # Keep legacy singleton data synchronized with the primary account for
        # any older code path that still reads gmail_auth.
        primary = conn.execute('SELECT * FROM gmail_accounts ORDER BY is_primary DESC,id LIMIT 1').fetchone()
        if primary is not None:
            conn.execute('''
            INSERT INTO gmail_auth(id,access_token,refresh_token,expires_at,email)
            VALUES(1,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              access_token=excluded.access_token,
              refresh_token=excluded.refresh_token,
              expires_at=excluded.expires_at,
              email=excluded.email
            ''', (
                str(primary['access_token'] or ''),
                str(primary['refresh_token'] or ''),
                float(primary['expires_at'] or 0),
                str(primary['email'] or ''),
            ))
        conn.commit()
        return saved_id


def access_token_for_account(account_id: int) -> str:
    row = account_row(account_id)
    if row is None:
        raise HTTPException(status_code=404, detail='Gmail account not found')
    if row['access_token'] and float(row['expires_at'] or 0) > time.time() + 30:
        return str(row['access_token'])
    refresh = str(row['refresh_token'] or '')
    if not refresh:
        raise HTTPException(status_code=409, detail=f'Reconnect Gmail account {row["email"] or account_id}')
    if not CLIENT_ID or not CLIENT_SECRET:
        raise HTTPException(status_code=503, detail='Gmail OAuth is not configured')
    data = request_json('https://oauth2.googleapis.com/token', method='POST', form={
        'client_id': CLIENT_ID,
        'client_secret': CLIENT_SECRET,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
    })
    save_tokens(data, str(row['email'] or ''), account_id)
    return str(data.get('access_token') or '')


def access_token() -> str:
    rows = [r for r in accounts_rows(enabled_only=True) if r['refresh_token'] or r['access_token']]
    if not rows:
        raise HTTPException(status_code=409, detail='Gmail is not connected')
    return access_token_for_account(int(rows[0]['id']))


def active_account_tokens(client_id: str = '') -> list[tuple[int, str, str]]:
    rows = accounts_rows(enabled_only=True)
    client_id = client_id.strip()
    if client_id:
        linked = [
            row for row in rows
            if str(row['client_id'] or '').strip() == client_id
        ]
        if linked:
            rows = linked
    out: list[tuple[int, str, str]] = []
    for row in rows:
        if not (row['refresh_token'] or row['access_token']):
            continue
        account_id = int(row['id'])
        try:
            token = access_token_for_account(account_id)
        except HTTPException:
            continue
        if token:
            out.append((account_id, str(row['email'] or ''), token))
    return out


@router.get('/api/gmail/status')
def status(x_api_key: str | None = Header(default=None)) -> dict[str, Any]:
    require_key(x_api_key)
    rows = accounts_rows()
    connected = [r for r in rows if r['refresh_token'] or r['access_token']]
    enabled = [r for r in connected if r['enabled']]
    primary = rows[0] if rows else None
    return {
        'configured': bool(CLIENT_ID and CLIENT_SECRET),
        'connected': bool(connected),
        'email': str(primary['email'] or '') if primary else '',
        'accountCount': len(connected),
        'enabledAccountCount': len(enabled),
        'accounts': [_public_account(r) for r in rows],
        'redirectUri': REDIRECT_URI,
    }


@router.get('/api/gmail/accounts')
def gmail_accounts(x_api_key: str | None = Header(default=None)) -> dict[str, Any]:
    require_key(x_api_key)
    rows = accounts_rows()
    return {
        'configured': bool(CLIENT_ID and CLIENT_SECRET),
        'redirectUri': REDIRECT_URI,
        'accounts': [_public_account(r) for r in rows],
    }


@router.post('/api/gmail/client-invite')
def create_client_invite(
    client_id: str = Query(...),
    client_name: str = Query(default=''),
    x_api_key: str | None = Header(default=None),
) -> dict[str, str]:
    require_key(x_api_key)
    clean_id = client_id.strip()
    if not clean_id:
        raise HTTPException(status_code=422, detail='client_id is required')
    state = create_oauth_state(
        None,
        client_id=clean_id,
        client_name=client_name,
    )
    return {
        'url': f'{PUBLIC_BASE_URL}/api/gmail/client-connect?invite={urllib.parse.quote(state)}',
        'expiresInSeconds': str(STATE_TTL_SECONDS),
    }


@router.get('/api/gmail/client-connect')
def client_connect(invite: str = Query(...)) -> RedirectResponse:
    state_data = decode_oauth_state(invite)
    if state_data is None or not str(state_data.get('client_id') or '').strip():
        raise HTTPException(status_code=400, detail='Invitation is invalid or expired')
    if not CLIENT_ID or not CLIENT_SECRET:
        raise HTTPException(status_code=503, detail='Gmail OAuth is not configured')
    params = {
        'client_id': CLIENT_ID,
        'redirect_uri': REDIRECT_URI,
        'response_type': 'code',
        'scope': 'openid email https://www.googleapis.com/auth/gmail.readonly',
        'access_type': 'offline',
        'include_granted_scopes': 'true',
        'prompt': 'consent select_account',
        'state': invite,
    }
    return RedirectResponse(
        'https://accounts.google.com/o/oauth2/v2/auth?' + urllib.parse.urlencode(params),
        status_code=302,
    )


@router.get('/api/gmail/auth-url')
def auth_url(
    account_id: int | None = Query(default=None),
    x_api_key: str | None = Header(default=None),
) -> dict[str, str]:
    require_key(x_api_key)
    if not CLIENT_ID or not CLIENT_SECRET:
        raise HTTPException(status_code=503, detail='Configure GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET on Railway')
    login_hint = ''
    if account_id is not None:
        row = account_row(account_id)
        if row is None:
            raise HTTPException(status_code=404, detail='Gmail account not found')
        login_hint = str(row['email'] or '')
    state = create_oauth_state(account_id)
    params = {
        'client_id': CLIENT_ID,
        'redirect_uri': REDIRECT_URI,
        'response_type': 'code',
        'scope': 'openid email https://www.googleapis.com/auth/gmail.readonly',
        'access_type': 'offline',
        'include_granted_scopes': 'true',
        'prompt': 'consent select_account',
        'state': state,
    }
    if login_hint:
        params['login_hint'] = login_hint
    return {'url': 'https://accounts.google.com/o/oauth2/v2/auth?' + urllib.parse.urlencode(params)}


@router.post('/api/gmail/accounts/{account_id}/enabled')
def set_account_enabled(
    account_id: int,
    enabled: bool = Query(...),
    x_api_key: str | None = Header(default=None),
) -> dict[str, Any]:
    require_key(x_api_key)
    with closing(db()) as conn:
        row = conn.execute('SELECT * FROM gmail_accounts WHERE id=?', (account_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail='Gmail account not found')
        conn.execute('UPDATE gmail_accounts SET enabled=?,updated_at=? WHERE id=?', (1 if enabled else 0, time.time(), account_id))
        conn.commit()
    fresh = account_row(account_id)
    return _public_account(fresh) if fresh is not None else {'id': account_id}


@router.post('/api/gmail/accounts/{account_id}/primary')
def set_primary_account(account_id: int, x_api_key: str | None = Header(default=None)) -> dict[str, Any]:
    require_key(x_api_key)
    with closing(db()) as conn:
        row = conn.execute('SELECT * FROM gmail_accounts WHERE id=?', (account_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail='Gmail account not found')
        conn.execute('UPDATE gmail_accounts SET is_primary=CASE WHEN id=? THEN 1 ELSE 0 END', (account_id,))
        conn.execute('UPDATE gmail_accounts SET enabled=1,updated_at=? WHERE id=?', (time.time(), account_id))
        conn.commit()
    fresh = account_row(account_id)
    return _public_account(fresh) if fresh is not None else {'id': account_id}


@router.delete('/api/gmail/accounts/{account_id}')
def delete_account(account_id: int, x_api_key: str | None = Header(default=None)) -> dict[str, Any]:
    require_key(x_api_key)
    with closing(db()) as conn:
        row = conn.execute('SELECT * FROM gmail_accounts WHERE id=?', (account_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail='Gmail account not found')
        was_primary = bool(row['is_primary'])
        conn.execute('DELETE FROM gmail_accounts WHERE id=?', (account_id,))
        if was_primary:
            replacement = conn.execute('SELECT id FROM gmail_accounts ORDER BY enabled DESC,id LIMIT 1').fetchone()
            if replacement is not None:
                conn.execute('UPDATE gmail_accounts SET is_primary=CASE WHEN id=? THEN 1 ELSE 0 END', (int(replacement['id']),))
        conn.commit()
    return {'ok': True, 'deletedId': account_id}


@router.get('/api/gmail/callback', response_class=HTMLResponse)
def callback(code: str = '', state: str = '', error: str = '') -> HTMLResponse:
    if error:
        return HTMLResponse('<h2>Gmail no se conectó.</h2>', status_code=400)
    state_data = decode_oauth_state(state)
    if state_data is None:
        return HTMLResponse('<h2>Autorización inválida o vencida.</h2>', status_code=400)
    data = request_json('https://oauth2.googleapis.com/token', method='POST', form={
        'code': code,
        'client_id': CLIENT_ID,
        'client_secret': CLIENT_SECRET,
        'redirect_uri': REDIRECT_URI,
        'grant_type': 'authorization_code',
    })
    email = ''
    token = str(data.get('access_token') or '')
    if token:
        try:
            profile = request_json('https://www.googleapis.com/oauth2/v2/userinfo', headers={'Authorization': f'Bearer {token}'})
            email = str(profile.get('email') or '')
        except Exception:
            pass
    raw_id = state_data.get('account_id')
    account_id = int(raw_id) if raw_id not in (None, '') else None
    client_id = str(state_data.get('client_id') or '').strip()
    client_name = str(state_data.get('client_name') or '').strip()
    saved_id = save_tokens(
        data,
        email,
        account_id,
        client_id=client_id,
        client_name=client_name,
    )
    label = email or f'Cuenta #{saved_id}'
    owner = (
        f'<p>Vinculado a: <strong>{client_name}</strong></p>'
        if client_name else ''
    )
    return HTMLResponse(
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<div style="font-family:Arial,sans-serif;max-width:560px;margin:48px auto;padding:24px">'
        '<h2>Gmail conectado con Paquetería.</h2>'
        f'<p>{label}</p>'
        f'{owner}'
        '<p>Ya puedes cerrar esta página. La cuenta quedó autorizada para buscar compras y tracking.</p>'
        '</div>'
    )
