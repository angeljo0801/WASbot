import base64
import json
import os
from pathlib import Path
from typing import Any

import jwt
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

DATA_DIR = Path(os.getenv('DATA_DIR', './data'))
DATA_DIR.mkdir(parents=True, exist_ok=True)
KEYSTORE_PATH = DATA_DIR / 'paqueteria-release.p12'
META_PATH = DATA_DIR / 'paqueteria-release-meta.json'

GITHUB_OIDC_ISSUER = 'https://token.actions.githubusercontent.com'
GITHUB_JWKS = 'https://token.actions.githubusercontent.com/.well-known/jwks'
GITHUB_AUDIENCE = 'paqueteria-signing'
ALLOWED_REPOSITORY = 'angeljo0801/Negocio'
ALLOWED_REPOSITORY_ID = '1368764279'
ALLOWED_REF = 'refs/heads/paqueteria-v1'

router = APIRouter()
_jwk_client = jwt.PyJWKClient(GITHUB_JWKS, cache_keys=True)


class SigningPayload(BaseModel):
    keystoreB64: str
    password: str
    alias: str = 'paqueteria'
    storeType: str = 'PKCS12'


def _bearer(value: str | None) -> str:
    raw = (value or '').strip()
    if not raw.lower().startswith('bearer '):
        raise HTTPException(status_code=401, detail='Missing GitHub OIDC bearer token')
    token = raw.split(' ', 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail='Missing GitHub OIDC bearer token')
    return token


def _verify_github_oidc(authorization: str | None) -> dict[str, Any]:
    token = _bearer(authorization)
    try:
        key = _jwk_client.get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            key,
            algorithms=['RS256'],
            audience=GITHUB_AUDIENCE,
            issuer=GITHUB_OIDC_ISSUER,
            options={'require': ['exp', 'iat', 'iss', 'aud']},
        )
    except Exception as exc:
        raise HTTPException(status_code=401, detail=f'Invalid GitHub OIDC token: {exc}') from exc

    repository = str(claims.get('repository') or '')
    repository_id = str(claims.get('repository_id') or '')
    ref = str(claims.get('ref') or '')
    event_name = str(claims.get('event_name') or '')
    actor = str(claims.get('actor') or '')

    if repository != ALLOWED_REPOSITORY:
        raise HTTPException(status_code=403, detail='OIDC repository not allowed')
    if repository_id and repository_id != ALLOWED_REPOSITORY_ID:
        raise HTTPException(status_code=403, detail='OIDC repository id not allowed')
    if ref != ALLOWED_REF:
        raise HTTPException(status_code=403, detail='OIDC branch not allowed')
    if event_name not in {'push', 'workflow_dispatch'}:
        raise HTTPException(status_code=403, detail='OIDC event not allowed')
    return {
        'repository': repository,
        'repositoryId': repository_id,
        'ref': ref,
        'eventName': event_name,
        'actor': actor,
        'runId': str(claims.get('run_id') or ''),
        'sha': str(claims.get('sha') or ''),
    }


def _read_meta() -> dict[str, Any]:
    if not META_PATH.exists():
        return {}
    try:
        value = json.loads(META_PATH.read_text(encoding='utf-8'))
        return dict(value) if isinstance(value, dict) else {}
    except Exception:
        return {}


@router.get('/api/ci/paqueteria-signing')
def get_paqueteria_signing(authorization: str | None = Header(default=None)) -> dict[str, Any]:
    identity = _verify_github_oidc(authorization)
    meta = _read_meta()
    if not KEYSTORE_PATH.exists() or not meta.get('password') or not meta.get('alias'):
        raise HTTPException(status_code=404, detail='Paqueteria signing key not initialized')
    return {
        'initialized': True,
        'keystoreB64': base64.b64encode(KEYSTORE_PATH.read_bytes()).decode('ascii'),
        'password': str(meta['password']),
        'alias': str(meta['alias']),
        'storeType': str(meta.get('storeType') or 'PKCS12'),
        'createdBy': str(meta.get('createdBy') or ''),
        'createdRunId': str(meta.get('createdRunId') or ''),
        'request': identity,
    }


@router.post('/api/ci/paqueteria-signing')
def put_paqueteria_signing(
    payload: SigningPayload,
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    identity = _verify_github_oidc(authorization)
    if KEYSTORE_PATH.exists() and META_PATH.exists():
        raise HTTPException(status_code=409, detail='Paqueteria signing key is already initialized')
    if len(payload.password) < 24:
        raise HTTPException(status_code=422, detail='Signing password is too short')
    if not payload.alias.strip():
        raise HTTPException(status_code=422, detail='Signing alias is empty')
    try:
        raw = base64.b64decode(payload.keystoreB64, validate=True)
    except Exception as exc:
        raise HTTPException(status_code=422, detail='Invalid keystore base64') from exc
    if len(raw) < 1000 or len(raw) > 1024 * 1024:
        raise HTTPException(status_code=422, detail='Unexpected keystore size')

    tmp = KEYSTORE_PATH.with_suffix('.tmp')
    tmp.write_bytes(raw)
    os.chmod(tmp, 0o600)
    tmp.replace(KEYSTORE_PATH)
    meta = {
        'password': payload.password,
        'alias': payload.alias.strip(),
        'storeType': payload.storeType.strip() or 'PKCS12',
        'createdBy': identity['actor'],
        'createdRunId': identity['runId'],
        'createdSha': identity['sha'],
    }
    META_PATH.write_text(json.dumps(meta), encoding='utf-8')
    os.chmod(META_PATH, 0o600)
    return {'ok': True, 'initialized': True, 'createdRunId': identity['runId']}
