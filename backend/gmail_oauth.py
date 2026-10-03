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

from fastapi import APIRouter, Header, HTTPException
from fastapi.responses import HTMLResponse

APP_API_KEY = os.getenv('APP_API_KEY', 'dev-mobile-key').strip()
CLIENT_ID = os.getenv('GMAIL_CLIENT_ID', '').strip()
CLIENT_SECRET = os.getenv('GMAIL_CLIENT_SECRET', '').strip()
PUBLIC_BASE_URL = os.getenv('PUBLIC_BASE_URL', 'https://wasbot-backend-production.up.railway.app').strip().rstrip('/')
REDIRECT_URI = os.getenv('GMAIL_REDIRECT_URI', f'{PUBLIC_BASE_URL}/api/gmail/callback').strip()
DATA_DIR = Path(os.getenv('DATA_DIR', './data'))
DB_PATH = DATA_DIR / 'whatsbot.db'
router = APIRouter()


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_gmail_auth() -> None:
    with closing(db()) as conn:
        conn.executescript('''
        CREATE TABLE IF NOT EXISTS gmail_auth(
          id INTEGER PRIMARY KEY CHECK(id=1),
          access_token TEXT NOT NULL DEFAULT '',
          refresh_token TEXT NOT NULL DEFAULT '',
          expires_at REAL NOT NULL DEFAULT 0,
          email TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS gmail_oauth_state(
          state TEXT PRIMARY KEY,
          created_at REAL NOT NULL
        );
        ''')
        conn.commit()


init_gmail_auth()


def require_key(value: str | None) -> None:
    if not APP_API_KEY or value != APP_API_KEY:
        raise HTTPException(status_code=401, detail='Invalid API key')


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


def auth_row() -> sqlite3.Row | None:
    with closing(db()) as conn:
        return conn.execute('SELECT * FROM gmail_auth WHERE id=1').fetchone()


def save_tokens(data: dict[str, Any], email: str = '') -> None:
    old = auth_row()
    refresh = str(data.get('refresh_token') or (old['refresh_token'] if old else ''))
    access = str(data.get('access_token') or '')
    expires = time.time() + max(60, int(data.get('expires_in') or 3600) - 60)
    with closing(db()) as conn:
        conn.execute('''
        INSERT INTO gmail_auth(id,access_token,refresh_token,expires_at,email)
        VALUES(1,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          access_token=excluded.access_token,
          refresh_token=excluded.refresh_token,
          expires_at=excluded.expires_at,
          email=CASE WHEN excluded.email!='' THEN excluded.email ELSE gmail_auth.email END
        ''', (access, refresh, expires, email))
        conn.commit()


def access_token() -> str:
    row = auth_row()
    if row is None:
        raise HTTPException(status_code=409, detail='Gmail is not connected')
    if row['access_token'] and float(row['expires_at'] or 0) > time.time() + 30:
        return str(row['access_token'])
    refresh = str(row['refresh_token'] or '')
    if not refresh:
        raise HTTPException(status_code=409, detail='Reconnect Gmail')
    if not CLIENT_ID or not CLIENT_SECRET:
        raise HTTPException(status_code=503, detail='Gmail OAuth is not configured')
    data = request_json('https://oauth2.googleapis.com/token', method='POST', form={
        'client_id': CLIENT_ID,
        'client_secret': CLIENT_SECRET,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
    })
    save_tokens(data)
    return str(data.get('access_token') or '')


@router.get('/api/gmail/status')
def status(x_api_key: str | None = Header(default=None)) -> dict[str, Any]:
    require_key(x_api_key)
    row = auth_row()
    return {
        'configured': bool(CLIENT_ID and CLIENT_SECRET),
        'connected': bool(row and (row['refresh_token'] or row['access_token'])),
        'email': str(row['email'] or '') if row else '',
        'redirectUri': REDIRECT_URI,
    }


@router.get('/api/gmail/auth-url')
def auth_url(x_api_key: str | None = Header(default=None)) -> dict[str, str]:
    require_key(x_api_key)
    if not CLIENT_ID or not CLIENT_SECRET:
        raise HTTPException(status_code=503, detail='Configure GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET on Railway')
    state = secrets.token_urlsafe(24)
    with closing(db()) as conn:
        conn.execute('DELETE FROM gmail_oauth_state WHERE created_at < ?', (time.time() - 1800,))
        conn.execute('INSERT INTO gmail_oauth_state(state,created_at) VALUES(?,?)', (state, time.time()))
        conn.commit()
    params = {
        'client_id': CLIENT_ID,
        'redirect_uri': REDIRECT_URI,
        'response_type': 'code',
        'scope': 'openid email https://www.googleapis.com/auth/gmail.readonly',
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
    }
    return {'url': 'https://accounts.google.com/o/oauth2/v2/auth?' + urllib.parse.urlencode(params)}


@router.get('/api/gmail/callback', response_class=HTMLResponse)
def callback(code: str = '', state: str = '', error: str = '') -> HTMLResponse:
    if error:
        return HTMLResponse('<h2>Gmail no se conectó.</h2>', status_code=400)
    with closing(db()) as conn:
        valid = conn.execute('SELECT 1 FROM gmail_oauth_state WHERE state=?', (state,)).fetchone()
        conn.execute('DELETE FROM gmail_oauth_state WHERE state=?', (state,))
        conn.commit()
    if not valid:
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
    save_tokens(data, email)
    return HTMLResponse('<h2>Gmail conectado con Paquetería.</h2><p>Ya puedes volver a la app.</p>')
