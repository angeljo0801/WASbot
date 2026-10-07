import base64
import hashlib
import io
import json
import os
import threading
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException, Query
from PIL import Image
from fastapi.responses import FileResponse

from gmail_oauth import active_account_tokens, require_key, request_json
from gmail_parser import (
    carrier_for,
    estimated_delivery,
    items,
    money_field,
    order_number,
    purchase_status,
    remote_images,
    ship_to,
    store_name,
    strip_html,
    tracking_numbers,
)

DATA_DIR = Path(os.getenv('DATA_DIR', './data'))
MEDIA_DIR = DATA_DIR / 'gmail_media'
MEDIA_DIR.mkdir(parents=True, exist_ok=True)
JOB_DIR = DATA_DIR / 'gmail_jobs'
JOB_DIR.mkdir(parents=True, exist_ok=True)
JOB_EXECUTOR = ThreadPoolExecutor(max_workers=max(2, int(os.getenv('GMAIL_JOB_WORKERS', '3'))))
JOB_LOCK = threading.Lock()
router = APIRouter()


def gmail_json(path: str, token: str) -> dict[str, Any]:
    return request_json(
        'https://gmail.googleapis.com/gmail/v1/users/me/' + path,
        headers={'Authorization': f'Bearer {token}'},
    )


def decode_urlsafe(value: str | None) -> bytes:
    raw = (value or '').encode('ascii')
    if not raw:
        return b''
    raw += b'=' * ((4 - len(raw) % 4) % 4)
    try:
        return base64.urlsafe_b64decode(raw)
    except Exception:
        return b''


def header(payload: dict[str, Any], name: str) -> str:
    for row in payload.get('headers') or []:
        if str(row.get('name', '')).lower() == name.lower():
            return str(row.get('value') or '')
    return ''


def save_image(data: bytes, account_id: int, message_id: str, suffix: str, mime: str) -> dict[str, Any] | None:
    if not data:
        return None
    extension = mime.split('/')[-1].lower().replace('jpeg', 'jpg')
    if extension not in {'jpg', 'png', 'webp', 'gif'}:
        extension = 'jpg'
    safe_suffix = ''.join(x for x in suffix if x.isalnum())[:18] or 'image'
    name = f'a{account_id}_{message_id}_{safe_suffix}.{extension}'
    path = MEDIA_DIR / name
    if not path.exists():
        path.write_bytes(data)
    return {'name': name, 'url': f'/api/gmail/media/{name}', 'accountId': account_id}



def _job_path(job_id: str) -> Path:
    safe = ''.join(ch for ch in job_id if ch.isalnum() or ch in {'-', '_'})[:96]
    return JOB_DIR / f'{safe}.json'


def _write_job(job_id: str, value: dict[str, Any]) -> None:
    path = _job_path(job_id)
    tmp = path.with_suffix('.tmp')
    payload = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    with JOB_LOCK:
        tmp.write_text(payload, encoding='utf-8')
        tmp.replace(path)


def _read_job(job_id: str) -> dict[str, Any] | None:
    path = _job_path(job_id)
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
        return value if isinstance(value, dict) else None
    except Exception:
        return None


def _media_extension(content_type: str, url: str) -> str:
    lower = f'{content_type} {url}'.lower()
    if 'png' in lower:
        return 'png'
    if 'webp' in lower:
        return 'webp'
    if 'gif' in lower:
        return 'gif'
    return 'jpg'


def _thumbnail_for(path: Path, digest: str) -> str:
    thumb_name = f'thumb_{digest}.jpg'
    thumb_path = MEDIA_DIR / thumb_name
    if thumb_path.exists() and thumb_path.stat().st_size > 0:
        return f'/api/gmail/media/{thumb_name}'
    try:
        with Image.open(path) as image:
            image = image.convert('RGB')
            image.thumbnail((480, 480))
            image.save(thumb_path, format='JPEG', quality=64, optimize=True)
        return f'/api/gmail/media/{thumb_name}'
    except Exception:
        return ''


def _obvious_nonproduct_url(url: str) -> bool:
    lower = urllib.parse.unquote(url).lower()
    obvious = (
        '1x1', 'spacer', 'tracking-pixel', 'tracking_pixel', '/pixel',
        'open.gif', 'beacon', 'facebook', 'instagram', 'twitter',
        'youtube', 'google-play', 'googleplay', 'app-store', 'appstore',
    )
    return any(token in lower for token in obvious)


def _image_dimensions(path: Path) -> tuple[int, int]:
    try:
        with Image.open(path) as image:
            return int(image.width or 0), int(image.height or 0)
    except Exception:
        return 0, 0


def _cache_remote_image(url: str) -> dict[str, Any]:
    # Railway downloads each remote email image once. The phone can then use a
    # small thumbnail for OCR/filtering and fetch the original only if accepted.
    digest = hashlib.sha256(url.encode('utf-8', errors='ignore')).hexdigest()[:28]
    existing = next(MEDIA_DIR.glob(f'cache_{digest}.*'), None)
    if existing and existing.is_file() and existing.stat().st_size > 0:
        width, height = _image_dimensions(existing)
        return {
            'url': f'/api/gmail/media/{existing.name}',
            'thumbnailUrl': _thumbnail_for(existing, digest),
            'originalUrl': url,
            'width': width,
            'height': height,
        }

    request = urllib.request.Request(
        url,
        headers={
            'User-Agent': 'Mozilla/5.0 (Android) Paqueteria/1.0',
            'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        },
    )
    with urllib.request.urlopen(request, timeout=7) as response:
        content_type = str(response.headers.get('Content-Type') or '')
        data = response.read(12 * 1024 * 1024 + 1)
    if not data or len(data) > 12 * 1024 * 1024:
        raise ValueError('remote image unavailable or too large')
    ext = _media_extension(content_type, url)
    name = f'cache_{digest}.{ext}'
    path = MEDIA_DIR / name
    if not path.exists():
        path.write_bytes(data)
    width, height = _image_dimensions(path)
    return {
        'url': f'/api/gmail/media/{name}',
        'thumbnailUrl': _thumbnail_for(path, digest),
        'originalUrl': url,
        'width': width,
        'height': height,
    }


def _prepare_media_candidates(result: dict[str, Any]) -> list[dict[str, Any]]:
    # Keep the phone fast: eliminate unmistakable tracking/social assets before
    # any download, then prepare the remaining remote images concurrently.
    remote_urls: list[str] = []
    seen: set[str] = set()
    for raw in list(result.get('emailPhotoUrls') or []):
        url = str(raw or '').strip()
        if not url or url in seen or _obvious_nonproduct_url(url):
            continue
        seen.add(url)
        remote_urls.append(url)
        if len(remote_urls) >= 40:
            break

    remote_rows: list[dict[str, Any]] = []
    workers = max(1, min(10, len(remote_urls)))
    if remote_urls:
        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = {executor.submit(_cache_remote_image, url): url for url in remote_urls}
            prepared_by_url: dict[str, dict[str, Any]] = {}
            for future in as_completed(futures):
                url = futures[future]
                row: dict[str, Any] = {
                    'kind': 'remote',
                    'url': url,
                    'originalUrl': url,
                    'thumbnailUrl': '',
                }
                try:
                    row.update(future.result())
                except Exception:
                    # A slow/broken CDN image must never block the reconstruction.
                    pass
                prepared_by_url[url] = row
            # Preserve Gmail order even though downloads completed in parallel.
            remote_rows = [prepared_by_url[url] for url in remote_urls if url in prepared_by_url]

    candidates: list[dict[str, Any]] = []
    for row in remote_rows:
        width = int(row.get('width') or 0)
        height = int(row.get('height') or 0)
        if width and height:
            shortest = min(width, height)
            longest = max(width, height)
            if shortest < 70 or (shortest > 0 and longest / shortest > 6.5):
                continue
        candidates.append(row)
        if len(candidates) >= 20:
            break

    # Gmail MIME attachments are already local on Railway, so thumbnailing them
    # is cheap and they are kept ahead of the final cap when useful.
    for raw in list(result.get('emailAttachmentImages') or [])[:20]:
        if not isinstance(raw, dict):
            continue
        row = dict(raw)
        url = str(row.get('url') or '').strip()
        if not url or url in seen:
            continue
        seen.add(url)
        row['kind'] = 'attachment'
        row['originalUrl'] = url
        name = Path(str(row.get('name') or Path(url).name)).name
        path = MEDIA_DIR / name
        if path.exists() and path.is_file():
            width, height = _image_dimensions(path)
            if width and height:
                shortest = min(width, height)
                longest = max(width, height)
                if shortest < 70 or (shortest > 0 and longest / shortest > 6.5):
                    continue
            digest = hashlib.sha256(path.read_bytes()[:262144]).hexdigest()[:28]
            row['thumbnailUrl'] = _thumbnail_for(path, digest)
            row['width'] = width
            row['height'] = height
        else:
            row['thumbnailUrl'] = ''
        candidates.append(row)
        if len(candidates) >= 24:
            break

    return candidates


def _run_reconstruction_job(job_id: str, order: str, tracking: str) -> None:
    started = datetime.now(timezone.utc).isoformat()
    _write_job(job_id, {
        'jobId': job_id,
        'status': 'running',
        'orderNumber': order,
        'tracking': tracking,
        'startedAt': started,
        'updatedAt': started,
    })
    try:
        result = reconstruct(order, tracking)
        result['emailPhotoCandidates'] = _prepare_media_candidates(result)
        completed = datetime.now(timezone.utc).isoformat()
        _write_job(job_id, {
            'jobId': job_id,
            'status': 'completed',
            'orderNumber': order,
            'tracking': tracking,
            'startedAt': started,
            'completedAt': completed,
            'updatedAt': completed,
            'result': result,
        })
    except Exception as exc:
        completed = datetime.now(timezone.utc).isoformat()
        detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
        _write_job(job_id, {
            'jobId': job_id,
            'status': 'failed',
            'orderNumber': order,
            'tracking': tracking,
            'startedAt': started,
            'completedAt': completed,
            'updatedAt': completed,
            'error': str(detail),
        })


def _ensure_job(job_id: str, order: str, tracking: str) -> dict[str, Any]:
    existing = _read_job(job_id)
    if existing and existing.get('status') in {'queued', 'running', 'completed'}:
        return existing
    queued = {
        'jobId': job_id,
        'status': 'queued',
        'orderNumber': order,
        'tracking': tracking,
        'createdAt': datetime.now(timezone.utc).isoformat(),
        'updatedAt': datetime.now(timezone.utc).isoformat(),
    }
    _write_job(job_id, queued)
    JOB_EXECUTOR.submit(_run_reconstruction_job, job_id, order, tracking)
    return queued


def walk_parts(
    part: dict[str, Any],
    *,
    account_id: int,
    message_id: str,
    token: str,
    plain: list[str],
    html_parts: list[str],
    images: list[dict[str, Any]],
) -> None:
    mime = str(part.get('mimeType') or '').lower()
    body = part.get('body') or {}
    encoded = body.get('data')
    if encoded:
        data = decode_urlsafe(str(encoded))
        if mime == 'text/plain':
            plain.append(data.decode('utf-8', errors='replace'))
        elif mime == 'text/html':
            html_parts.append(data.decode('utf-8', errors='replace'))
        elif mime.startswith('image/'):
            saved = save_image(data, account_id, message_id, str(len(images)), mime)
            if saved and saved not in images:
                images.append(saved)
    attachment_id = body.get('attachmentId')
    if attachment_id and mime.startswith('image/'):
        try:
            payload = gmail_json(
                f"messages/{urllib.parse.quote(message_id)}/attachments/{urllib.parse.quote(str(attachment_id))}",
                token,
            )
            saved = save_image(
                decode_urlsafe(str(payload.get('data') or '')),
                account_id,
                message_id,
                str(attachment_id),
                mime,
            )
            if saved and saved not in images:
                images.append(saved)
        except Exception:
            pass
    for child in part.get('parts') or []:
        walk_parts(
            child,
            account_id=account_id,
            message_id=message_id,
            token=token,
            plain=plain,
            html_parts=html_parts,
            images=images,
        )


def record(message: dict[str, Any], token: str, account_id: int, source_email: str) -> dict[str, Any]:
    payload = message.get('payload') or {}
    plain: list[str] = []
    html_parts: list[str] = []
    images: list[dict[str, Any]] = []
    walk_parts(
        payload,
        account_id=account_id,
        message_id=str(message.get('id') or ''),
        token=token,
        plain=plain,
        html_parts=html_parts,
        images=images,
    )

    # Keep both representations. Many store emails include a very short plain
    # version while product names/quantities live only in HTML table cells or
    # image alt/title attributes. gmail_parser.strip_html preserves those image
    # labels so the reconstruction can identify the actual products.
    plain_text = '\n'.join(plain).strip()
    html_text = strip_html('\n'.join(html_parts)).strip() if html_parts else ''
    body_parts: list[str] = []
    if plain_text:
        body_parts.append(plain_text)
    if html_text:
        plain_compact = recompact(plain_text)
        html_compact = recompact(html_text)
        if not plain_compact or html_compact not in plain_compact:
            body_parts.append(html_text)
    body = '\n'.join(body_parts).strip()

    for image in images:
        image['sourceEmail'] = source_email
    return {
        'id': str(message.get('id') or ''),
        'accountId': account_id,
        'sourceEmail': source_email,
        'internalDate': int(message.get('internalDate') or 0),
        'subject': header(payload, 'Subject'),
        'from': header(payload, 'From'),
        'date': header(payload, 'Date'),
        'body': body,
        'remoteImages': remote_images(html_parts),
        'attachmentImages': images,
    }


def recompact(value: str) -> str:
    return ' '.join(value.lower().split())


def search_account(account_id: int, source_email: str, token: str, seed: str) -> list[dict[str, Any]]:
    safe_seed = seed.replace('"', '')
    query = urllib.parse.urlencode({'q': f'"{safe_seed}"', 'maxResults': '15'})
    listing = gmail_json('messages?' + query, token)
    message_ids = [
        str(item.get('id') or '')
        for item in (listing.get('messages') or [])
        if str(item.get('id') or '')
    ][:15]
    if not message_ids:
        return []

    def fetch_one(message_id: str) -> dict[str, Any] | None:
        try:
            full = gmail_json(f'messages/{urllib.parse.quote(message_id)}?format=full', token)
            return record(full, token, account_id, source_email)
        except Exception:
            return None

    records: list[dict[str, Any]] = []
    workers = max(1, min(8, len(message_ids)))
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(fetch_one, message_id) for message_id in message_ids]
        for future in as_completed(futures):
            row = future.result()
            if row:
                records.append(row)
    return records


def reconstruct(order: str = '', tracking: str = '') -> dict[str, Any]:
    seed = order.strip() or tracking.strip()
    if not seed:
        raise HTTPException(status_code=422, detail='Provide order_number or tracking')

    accounts = active_account_tokens()
    if not accounts:
        raise HTTPException(status_code=409, detail='No enabled Gmail accounts are connected')

    records: list[dict[str, Any]] = []
    account_errors: list[dict[str, Any]] = []
    workers = max(1, min(4, len(accounts)))
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(search_account, account_id, email, token, seed): (account_id, email)
            for account_id, email, token in accounts
        }
        for future in as_completed(futures):
            account_id, email = futures[future]
            try:
                records.extend(future.result())
            except Exception as exc:
                detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
                account_errors.append({'accountId': account_id, 'email': email, 'error': str(detail)})

    # Gmail message IDs are only unique inside an account.
    unique: dict[tuple[int, str], dict[str, Any]] = {}
    for row in records:
        unique[(int(row.get('accountId') or 0), str(row.get('id') or ''))] = row
    records = list(unique.values())
    records.sort(key=lambda x: int(x.get('internalDate') or 0))

    combined = '\n'.join(
        f"{r.get('subject','')}\n{r.get('from','')}\n{r.get('body','')}"
        for r in records
    )
    tracks = tracking_numbers(combined)
    if tracking.strip() and all(x.upper() != tracking.strip().upper() for x in tracks):
        tracks.insert(0, tracking.strip())
    carriers: list[str] = []
    for value in tracks:
        carrier = carrier_for(value, combined)
        if carrier not in carriers:
            carriers.append(carrier)

    urls: list[str] = []
    attachments: list[dict[str, Any]] = []
    source_emails: list[str] = []
    for row in reversed(records):
        source_email = str(row.get('sourceEmail') or '')
        if source_email and source_email not in source_emails:
            source_emails.append(source_email)
        for url in row.get('remoteImages') or []:
            if url not in urls:
                urls.append(url)
        for image in row.get('attachmentImages') or []:
            if image not in attachments:
                attachments.append(image)

    return {
        'found': bool(records),
        'query': seed,
        'store': store_name(records),
        'orderNumber': order_number(combined, order),
        'trackingNumbers': tracks,
        'carrier': carriers[0] if carriers else carrier_for(tracking, combined),
        'carriers': carriers,
        'status': purchase_status(combined) if records else '',
        'estimatedDelivery': estimated_delivery(combined),
        'shipToName': ship_to(combined),
        'subtotal': money_field(combined, ['subtotal']),
        'tax': money_field(combined, ['tax', 'sales tax', 'impuesto']),
        'shipping': money_field(combined, ['shipping', 'delivery', 'envío', 'envio']),
        'discount': money_field(combined, ['discount', 'savings', 'descuento']),
        'total': money_field(combined, ['order total', 'grand total', 'total', 'total del pedido']),
        'currency': 'USD',
        'items': items(combined),
        'emailPhotoUrls': urls[:60],
        'emailAttachmentImages': attachments[:60],
        'emailSubjects': [str(r.get('subject') or '') for r in records if r.get('subject')],
        'emailFrom': [str(r.get('from') or '') for r in records if r.get('from')],
        'lastEmailDate': str(records[-1].get('date') or '') if records else '',
        'messageIds': [f"{r.get('accountId')}:{r.get('id')}" for r in records],
        'sourceEmails': source_emails,
        'accountsSearched': [
            {'id': account_id, 'email': email}
            for account_id, email, _token in accounts
        ],
        'accountErrors': account_errors,
        'syncedAt': datetime.now(timezone.utc).isoformat(),
    }


@router.post('/api/gmail/reconstruct/jobs')
def api_start_reconstruction_job(
    order_number: str = Query(default=''),
    tracking: str = Query(default=''),
    client_token: str = Query(default=''),
    x_api_key: str | None = Header(default=None),
) -> dict[str, Any]:
    require_key(x_api_key)
    order = order_number.strip()
    track = tracking.strip()
    if not order and not track:
        raise HTTPException(status_code=422, detail='Provide order_number or tracking')
    if client_token.strip():
        job_id = 'c_' + hashlib.sha256(client_token.strip().encode('utf-8')).hexdigest()[:32]
    else:
        job_id = uuid.uuid4().hex
    job = _ensure_job(job_id, order, track)
    return {
        'jobId': job_id,
        'status': str(job.get('status') or 'queued'),
        'createdAt': job.get('createdAt') or job.get('startedAt') or '',
    }


@router.get('/api/gmail/reconstruct/jobs/{job_id}')
def api_get_reconstruction_job(
    job_id: str,
    x_api_key: str | None = Header(default=None),
) -> dict[str, Any]:
    require_key(x_api_key)
    job = _read_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail='Gmail reconstruction job not found')
    # If Railway restarted while a queued/running job was in memory, resume it
    # automatically from its durable descriptor.
    if job.get('status') in {'queued', 'running'}:
        updated = str(job.get('updatedAt') or job.get('startedAt') or '')
        try:
            then = datetime.fromisoformat(updated.replace('Z', '+00:00'))
            age = (datetime.now(timezone.utc) - then).total_seconds()
        except Exception:
            age = 999
        if age > 120:
            JOB_EXECUTOR.submit(
                _run_reconstruction_job,
                job_id,
                str(job.get('orderNumber') or ''),
                str(job.get('tracking') or ''),
            )
    return job


@router.get('/api/gmail/reconstruct')
def api_reconstruct(
    order_number: str = Query(default=''),
    tracking: str = Query(default=''),
    x_api_key: str | None = Header(default=None),
) -> dict[str, Any]:
    require_key(x_api_key)
    return reconstruct(order_number, tracking)


@router.get('/api/gmail/media/{name}')
def api_gmail_media(name: str, x_api_key: str | None = Header(default=None)) -> FileResponse:
    require_key(x_api_key)
    path = MEDIA_DIR / Path(name).name
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=404, detail='Gmail image not found')
    return FileResponse(path)
