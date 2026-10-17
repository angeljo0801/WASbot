import base64
import hashlib
import io
import json
import html
import logging
import time
import re
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
JOB_FUTURES_LOCK = threading.Lock()
ACTIVE_JOB_FUTURES: dict[str, Any] = {}
GMAIL_SEARCH_BUDGET_SECONDS = 85
GMAIL_SEARCH_MAX_MESSAGES = 100
router = APIRouter()
logger = logging.getLogger('uvicorn.error')


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


_POD_WORDS = re.compile(
    r'(?i)(?:\bproof\s+of\s+delivery\b|\bdelivery\s+(?:photos?|pictures?|images?)\b|'
    r'\b(?:photos?|pictures?|images?)\s+(?:of|from)\s+(?:your|the)\s+delivery\b|'
    r'\b(?:delivered|drop[- ]?off)\s+(?:photos?|pictures?|images?)\b|'
    r'\bfotos?\s+de\s+(?:la\s+)?entrega\b|\bprueba\s+de\s+entrega\b)'
)
_COURIER_SENDER = re.compile(
    r'(?i)(?:gofo|speedx|ontrac|lasership|fedex|ups\.com|usps|dhl|'
    r'amazonlogistics|amazon\.shipping|shippingcarrier)'
)
_DELIVERED_EVENT = re.compile(
    r'(?i)(?:\bdelivered\b|\bentregado\b|\bdelivery\s+complete\b|'
    r'\bleft\s+(?:at|on|by)\b|\bdelivered\s+to\s+your\s+door\b)'
)


def _delivery_proof_message(row: dict[str, Any]) -> bool:
    """Only proof-photo context or a courier's actually completed delivery."""
    subject = str(row.get('subject') or '')
    body = str(row.get('body') or '')[:4000]
    sender = str(row.get('from') or '')
    evidence = f'{subject}\n{body}'
    if _POD_WORDS.search(evidence):
        return True
    # "Out for delivery"/"not yet delivered" are not photographic proof.
    if re.search(r'(?i)\b(?:out\s+for\s+delivery|not\s+yet\s+delivered|'
                 r'will\s+be\s+delivered|expected\s+to\s+be\s+delivered)\b',
                 subject + '\n' + body[:250]):
        return False
    return bool(_COURIER_SENDER.search(sender)
                and _DELIVERED_EVENT.search(subject + '\n' + body[:1200]))


def _delivery_photo_urls(records: list[dict[str, Any]]) -> list[str]:
    """Keep image-level provenance: never mark all order photos by status."""
    urls: list[str] = []
    for row in records:
        if not _delivery_proof_message(row):
            continue
        for u in row.get('remoteImages') or []:
            value = str(u or '').strip()
            if value and value not in urls:
                urls.append(value)
        for image in row.get('attachmentImages') or []:
            value = str(image.get('url') or '').strip()
            if value and value not in urls:
                urls.append(value)
    return urls


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

    delivery_urls = set(result.get('deliveryPhotoUrls') or [])
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
                row['deliveryProofHint'] = url in delivery_urls
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
        row['deliveryProofHint'] = url in delivery_urls
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


def _run_reconstruction_job(job_id: str, order: str, tracking: str, client_id: str = '') -> None:
    started = datetime.now(timezone.utc).isoformat()
    logger.info('Gmail job start jobId=%s trackingPrefix=%s', job_id, tracking[:4])
    _write_job(job_id, {
        'jobId': job_id,
        'status': 'running',
        'orderNumber': order,
        'tracking': tracking,
        'clientId': client_id,
        'startedAt': started,
        'updatedAt': started,
    })
    try:
        result = reconstruct(order, tracking, client_id)
        logger.info('Gmail job search finished jobId=%s found=%s accounts=%s',
                    job_id, result.get('found'), len(result.get('accountsSearched') or []))
        result['emailPhotoCandidates'] = _prepare_media_candidates(result) if result.get('found') else []
        # If the selected storefront email has no usable images (e.g. all
        # broken URLs/logos), retry ONE other verified storefront message,
        # never combine its photos with the original or courier proof.
        if result.get('found') and not result['emailPhotoCandidates']:
            for fallback in result.pop('_photoFallbackGroups', []):
                candidate = {
                    **result,
                    'emailPhotoUrls': fallback['emailPhotoUrls'],
                    'emailAttachmentImages': fallback['emailAttachmentImages'],
                }
                prepared = _prepare_media_candidates(candidate)
                if prepared:
                    result['emailPhotoUrls'] = fallback['emailPhotoUrls']
                    result['emailAttachmentImages'] = fallback['emailAttachmentImages']
                    result['emailPhotoCandidates'] = prepared
                    result['photoSourceRule'] += '_fallback'
                    break
        else:
            result.pop('_photoFallbackGroups', None)
        result['photoDiagnostics'] = {
            'emails': len(result.get('messageIds') or []),
            'remoteImages': len(result.get('emailPhotoUrls') or []),
            'attachments': len(result.get('emailAttachmentImages') or []),
            'candidates': len(result['emailPhotoCandidates']),
        }
        logger.info(
            'Gmail image extraction jobId=%s emails=%s remote=%s attachments=%s candidates=%s',
            job_id, result['photoDiagnostics']['emails'],
            result['photoDiagnostics']['remoteImages'],
            result['photoDiagnostics']['attachments'],
            result['photoDiagnostics']['candidates'],
        )
        logger.info('Gmail job finished jobId=%s', job_id)
        completed = datetime.now(timezone.utc).isoformat()
        _write_job(job_id, {
            'jobId': job_id,
            'status': 'completed',
            'orderNumber': order,
            'tracking': tracking,
            'clientId': client_id,
            'startedAt': started,
            'completedAt': completed,
            'updatedAt': completed,
            'result': result,
        })
    except Exception as exc:
        completed = datetime.now(timezone.utc).isoformat()
        detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
        logger.warning('Gmail job failed jobId=%s type=%s httpStatus=%s',
                       job_id, type(exc).__name__,
                       exc.status_code if isinstance(exc, HTTPException) else 500)
        _write_job(job_id, {
            'jobId': job_id,
            'status': 'failed',
            'orderNumber': order,
            'tracking': tracking,
            'clientId': client_id,
            'startedAt': started,
            'completedAt': completed,
            'updatedAt': completed,
            'error': str(detail),
        })


def _submit_job_once(job_id: str, order: str, tracking: str, client_id: str) -> None:
    """Prevent a running job from being submitted again on repeated polls."""
    with JOB_FUTURES_LOCK:
        future = ACTIVE_JOB_FUTURES.get(job_id)
        if future is not None and not future.done():
            return
        # Keep only pending jobs; done futures do not need to stay in memory.
        for previous, active in list(ACTIVE_JOB_FUTURES.items()):
            if active.done():
                ACTIVE_JOB_FUTURES.pop(previous, None)
        ACTIVE_JOB_FUTURES[job_id] = JOB_EXECUTOR.submit(
            _run_reconstruction_job, job_id, order, tracking, client_id,
        )


def _ensure_job(job_id: str, order: str, tracking: str, client_id: str = '') -> dict[str, Any]:
    existing = _read_job(job_id)
    # Re-posting the same token must not launch the same failed job again.
    # Deliberate user retries carry a fresh client token.
    if existing and existing.get('status') in {'queued', 'running', 'completed', 'failed'}:
        return existing
    queued = {
        'jobId': job_id,
        'status': 'queued',
        'orderNumber': order,
        'tracking': tracking,
        'clientId': client_id,
        'createdAt': datetime.now(timezone.utc).isoformat(),
        'updatedAt': datetime.now(timezone.utc).isoformat(),
    }
    _write_job(job_id, queued)
    _submit_job_once(job_id, order, tracking, client_id)
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
        'threadId': str(message.get('threadId') or ''),
        'accountId': account_id,
        'sourceEmail': source_email,
        'internalDate': int(message.get('internalDate') or 0),
        'subject': header(payload, 'Subject'),
        'from': header(payload, 'From'),
        'date': header(payload, 'Date'),
        'body': body,
        'remoteImages': remote_images(html_parts),
        # Tracking is sometimes present only inside HTML button/link hrefs.
        # strip_html removes those hrefs, so retain them for match validation.
        'linkTargets': [
            urllib.parse.unquote(html.unescape(value))
            for source in html_parts
            for value in re.findall(r'''(?is)\bhref\s*=\s*["']([^"']+)''', source)
        ][:350],
        'attachmentImages': images,
    }


def recompact(value: str) -> str:
    return ' '.join(value.lower().split())


def _compact_identifier(value: str) -> str:
    """Comparable identifier even when email HTML inserts spaces/dashes."""
    return re.sub(r'[^A-Z0-9]', '', value.upper())


def _identifier_in_record(row: dict[str, Any], identifier: str) -> bool:
    needle = _compact_identifier(identifier)
    if len(needle) < 8:
        return False
    haystack = '\n'.join(str(row.get(key) or '') for key in ('subject', 'body'))
    haystack += '\n' + '\n'.join(str(x) for x in row.get('linkTargets') or [])
    return needle in _compact_identifier(haystack)


def _gmail_search_queries(seed: str) -> list[tuple[str, bool]]:
    """Exact tracking first; fallbacks must verify the full tracking locally."""
    clean = seed.strip().strip('"')
    compact = _compact_identifier(clean)
    # Even Gmail's indexed hits must match the actual decoded message, not
    # just a quoted code appearing in an unrelated notification.
    queries: list[tuple[str, bool]] = [(f'"{clean}"', len(compact) >= 8)]
    if compact != clean.upper():
        queries.append((compact, True))
    else:
        queries.append((clean, True))
    if len(compact) >= 13:
        # A tracking number can be split by HTML or Gmail punctuation indexing.
        queries.append((f'"{compact[-11:]}"', True))
    # Tracking from Temu/GOFO is sometimes only present inside URLs. Gmail
    # does not reliably index href values, so enumerate merchant email safely,
    # and verify the complete identifier in the actual decoded MIME body.
    if len(compact) >= 14:
        queries.append((
            'newer_than:2y {from:temuemail.com from:temu.com '
            'from:gofoexpress.com from:gofo.com from:shein.com}', True,
        ))
        queries.append((
            'newer_than:1y {subject:tracking subject:shipped '
            'subject:delivered subject:package}', True,
        ))
    return list(dict.fromkeys(queries))


def _message_contains_identifier(message: dict[str, Any], seed: str) -> bool:
    """Verify the real identifier inside decoded MIME text / HTML / links."""
    needle = _compact_identifier(seed)
    if len(needle) < 8:
        return False
    parts: list[str] = []
    payload = message.get('payload') or {}
    for heading in payload.get('headers') or []:
        if str(heading.get('name') or '').lower() in ('subject', 'from'):
            parts.append(str(heading.get('value') or ''))

    def walk(part: dict[str, Any]) -> None:
        encoded = (part.get('body') or {}).get('data')
        if encoded:
            raw = decode_urlsafe(str(encoded)).decode('utf-8', 'ignore')
            if raw:
                # Shipping websites often URL-encode href values twice.
                decoded = html.unescape(raw)
                for _ in range(2):
                    decoded = html.unescape(urllib.parse.unquote(decoded))
                parts.append(decoded)
                if '<' in decoded:
                    parts.append(strip_html(decoded))
        for sub in part.get('parts') or []:
            if isinstance(sub, dict):
                walk(sub)

    walk(payload)
    return needle in _compact_identifier('\n'.join(parts))


def search_account(account_id: int, source_email: str, token: str, seed: str) -> list[dict[str, Any]]:
    """Bounded Gmail search: no endless requests or false negative on API error."""
    records: dict[str, dict[str, Any]] = {}
    inspected: set[str] = set()
    failed_reads = 0
    started = time.monotonic()
    budget_exhausted = False

    def fetch_one(message_id: str, must_verify: bool) -> dict[str, Any] | None:
        full = gmail_json(
            f'messages/{urllib.parse.quote(message_id)}?format=full', token,
        )
        if must_verify and not _message_contains_identifier(full, seed):
            return None
        row = record(full, token, account_id, source_email)
        if must_verify and not _identifier_in_record(row, seed):
            return None
        return row

    for query_index, (query_text, must_verify) in enumerate(_gmail_search_queries(seed)):
        if time.monotonic() - started >= GMAIL_SEARCH_BUDGET_SECONDS:
            budget_exhausted = True
            break
        # Bound candidate inspection per account, keeping room for merchant URLs.
        remaining = GMAIL_SEARCH_MAX_MESSAGES - len(inspected)
        if remaining <= 0:
            budget_exhausted = True
            break
        merchant_scan = 'from:temuemail.com' in query_text
        next_page = ''
        for _ in range(2 if merchant_scan else 1):
            if time.monotonic() - started >= GMAIL_SEARCH_BUDGET_SECONDS:
                budget_exhausted = True
                break
            remaining = GMAIL_SEARCH_MAX_MESSAGES - len(inspected)
            if remaining <= 0:
                budget_exhausted = True
                break
            requested = min(35 if merchant_scan else (25 if query_index < 3 else 20), remaining)
            params = {
                'q': query_text,
                'maxResults': str(requested),
                'includeSpamTrash': 'true',
            }
            if next_page:
                params['pageToken'] = next_page
            listing = gmail_json('messages?' + urllib.parse.urlencode(params), token)
            message_ids = [
                str(row.get('id') or '').strip()
                for row in (listing.get('messages') or [])
                if str(row.get('id') or '').strip()
            ]
            fresh = [mid for mid in message_ids if mid not in inspected]
            inspected.update(fresh)
            if fresh:
                # Limit simultaneous Gmail API requests to avoid quota throttling.
                with ThreadPoolExecutor(max_workers=min(5, len(fresh))) as executor:
                    futures = [executor.submit(fetch_one, mid, must_verify) for mid in fresh]
                    for future in as_completed(futures):
                        try:
                            row = future.result()
                            if row:
                                records[str(row['id'])] = row
                        except Exception:
                            failed_reads += 1
            if records:
                break
            next_page = str(listing.get('nextPageToken') or '')
            if not next_page:
                break
        if records or budget_exhausted:
            break

    logger.info(
        'Gmail tracking lookup accountId=%s found=%s inspected=%s failedReads=%s elapsed=%.1fs budgetExhausted=%s',
        account_id, len(records), len(inspected), failed_reads,
        time.monotonic() - started, budget_exhausted,
    )
    if not records and (failed_reads or budget_exhausted):
        raise HTTPException(
            status_code=503,
            detail=('Gmail no terminó de revisar todos los correos. '
                    'Intenta de nuevo más tarde; no se marcará como No encontrado.'),
        )
    return list(records.values())


def _order_reference_for_related_messages(rows: list[dict[str, Any]]) -> str:
    """Never treat status words such as 'shipped' as an order identifier."""
    for row in rows:
        candidate = order_number(
            str(row.get('subject') or '') + '\n' +
            str(row.get('body') or '') + '\n' +
            '\n'.join(str(x) for x in row.get('linkTargets') or []),
        ).strip()
        compact = re.sub(r'[^A-Za-z0-9]', '', candidate)
        if 8 <= len(compact) <= 40 and sum(c.isdigit() for c in compact) >= 4:
            return candidate
    return ''


def _merchant_family(sender: str) -> str:
    lower = sender.lower()
    for name in ('temu', 'shein', 'amazon', 'walmart', 'aliexpress', 'ebay'):
        if name in lower:
            return name
    return ''


def _related_purchase_records(
    matched: list[dict[str, Any]], token: str, account_id: int, source_email: str,
) -> list[dict[str, Any]]:
    """Add related purchase receipts without claiming unrelated mail is a match.

    Only mail in an exact-match Gmail thread, or verified to contain the same
    real order reference from the same retailer, is eligible. Uses the SAME
    account token and never scans mailboxes belonging to other clients.
    """
    if not matched:
        return []
    related: dict[str, dict[str, Any]] = {}
    existing = {str(row.get('id') or '') for row in matched}
    family = next(
        (_merchant_family(str(r.get('from') or '')) for r in matched
         if _merchant_family(str(r.get('from') or ''))), '',
    )

    for thread_id in list(dict.fromkeys(
        str(r.get('threadId') or '') for r in matched
        if str(r.get('threadId') or '').strip()
    ))[:5]:
        try:
            thread = gmail_json(
                'threads/' + urllib.parse.quote(thread_id) + '?format=full',
                token,
            )
            for msg in (thread.get('messages') or [])[:18]:
                message_id = str(msg.get('id') or '')
                if not message_id or message_id in existing:
                    continue
                if str(msg.get('threadId') or '') != thread_id:
                    continue
                candidate = record(msg, token, account_id, source_email)
                if family and _merchant_family(str(candidate.get('from') or '')) != family:
                    continue
                related[message_id] = candidate
                if len(related) >= 25:
                    break
        except Exception:
            # A thread retrieval is a best-effort enhancement, not a Gmail
            # failure that can hide valid tracking matches.
            continue

    reference = _order_reference_for_related_messages(matched)
    if reference:
        try:
            listing = gmail_json('messages?' + urllib.parse.urlencode({
                'q': '"' + reference.replace('"', '') + '"',
                'maxResults': '15',
                'includeSpamTrash': 'true',
            }), token)
            for entry in (listing.get('messages') or [])[:15]:
                message_id = str(entry.get('id') or '')
                if not message_id or message_id in existing or message_id in related:
                    continue
                try:
                    msg = gmail_json(
                        'messages/' + urllib.parse.quote(message_id) + '?format=full',
                        token,
                    )
                    if not _message_contains_identifier(msg, reference):
                        continue
                    candidate = record(msg, token, account_id, source_email)
                    if family and _merchant_family(str(candidate.get('from') or '')) != family:
                        continue
                    related[message_id] = candidate
                except Exception:
                    continue
        except Exception:
            pass

    logger.info(
        'Gmail related-order expansion accountId=%s matching=%s added=%s '
        'hasVerifiedOrderRef=%s',
        account_id, len(matched), len(related), bool(reference),
    )
    return list(related.values())



def _shein_predelivery_notice(row: dict[str, Any]) -> bool:
    """SHEIN's pre-delivery notification contains the purchased-item photos."""
    subject = str(row.get('subject') or '').casefold()
    # Spanish accents and Gmail's translation can vary.
    subject = (subject.replace('ó', 'o').replace('í', 'i')
              .replace('á', 'a').replace('é', 'e'))
    return (
        ('notificacion' in subject and 'previa' in subject
         and 'entrega' in subject)
        or ('pre-delivery' in subject and 'notification' in subject)
        or ('before delivery' in subject and 'shein' in subject)
    )


def _rank_product_photo_messages(
    records: list[dict[str, Any]], merchant: str,
) -> tuple[list[dict[str, Any]], str]:
    """Prefer store-specific product emails but retain all verified fallbacks.

    Caller already verified tracking or the same order/thread within an account.
    Never select by merely matching the brand anywhere in an unrelated message.
    """
    rows = [r for r in records
            if r.get('remoteImages') or r.get('attachmentImages')]
    recent = sorted(rows, key=lambda r: int(r.get('internalDate') or 0),
                    reverse=True)
    key = merchant.strip().lower()
    if key not in {'shein', 'temu'}:
        return recent, 'recent_first'

    # Courier photo proofs, even when they contain a brand in the body, are
    # not merchandise sources. Nor is an order-wide delivered status.
    storefront = [
        r for r in rows
        if _merchant_family(str(r.get('from') or '')) == key
        and not _delivery_proof_message(r)
    ]
    if not storefront:
        return recent, 'recent_first_fallback'

    if key == 'shein':
        # Priority 1: the PRE-delivery email in the screenshot.
        # Priority 2: the earliest SHEIN email that actually contains images.
        prioritized = sorted(
            storefront,
            key=lambda r: (
                0 if _shein_predelivery_notice(r) else 1,
                int(r.get('internalDate') or 0),
            ),
        )
        rule = 'shein_predelivery_first'
    else:
        # Temu: prefer the LAST/NEWEST purchase email (not courier POD).
        prioritized = sorted(
            storefront, key=lambda r: int(r.get('internalDate') or 0),
            reverse=True,
        )
        rule = 'temu_latest_first'

    used = {(int(r.get('accountId') or 0), str(r.get('id') or ''))
            for r in prioritized}
    # Failed image URLs or OCR can be rescued from other verified messages.
    remaining = [
        r for r in recent
        if (int(r.get('accountId') or 0), str(r.get('id') or '')) not in used
    ]
    return prioritized + remaining, rule


def _select_primary_product_photo_source(
    records: list[dict[str, Any]], merchant: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], str]:
    """Never merge multiple SHEIN/Temu mail images in a single reconstruction.

    The prior 'ranking' implementation returned every email; iterating them
    collected all their images despite the preferred date ordering.
    Other retailers retain their previous behavior.
    """
    ranked, rule = _rank_product_photo_messages(records, merchant)
    key = merchant.strip().lower()
    if key not in {'shein', 'temu'}:
        return ranked, [], rule

    matching_store = [
        row for row in ranked
        if _merchant_family(str(row.get('from') or '')) == key
        and not _delivery_proof_message(row)
        and (row.get('remoteImages') or row.get('attachmentImages'))
    ]
    if not matching_store:
        # Only courier images or no authenticated storefront photos:
        # keep the order match but do not pretend delivery proof is a product.
        return [], [], f'{key}_no_store_photo'

    # Precisely ONE preferred source. Backup sources remain server-side and
    # are consulted only if the preferred email yields no usable image.
    return matching_store[:1], matching_store[1:], rule


def _source_photo_fields(
    rows: list[dict[str, Any]],
) -> tuple[list[str], list[dict[str, Any]]]:
    urls: list[str] = []
    attachments: list[dict[str, Any]] = []
    for row in rows:
        for url in row.get('remoteImages') or []:
            if url not in urls:
                urls.append(url)
        for image in row.get('attachmentImages') or []:
            if image not in attachments:
                attachments.append(image)
    return urls, attachments


def reconstruct(order: str = '', tracking: str = '', client_id: str = '') -> dict[str, Any]:
    # Never use a storefront label from the optional order field instead of tracking.
    seed = tracking.strip() or order.strip()
    if not seed:
        raise HTTPException(status_code=422, detail='Provide order_number or tracking')

    accounts = active_account_tokens(client_id)
    if not accounts:
        raise HTTPException(
            status_code=409,
            detail='No hay cuentas Gmail autorizadas disponibles. Revisa las cuentas conectadas y vuelve a autorizar si hace falta.',
        )

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

    # Exact tracking search often finds only Temu/GOFO delivery notices;
    # merchandise photos may be in the earlier order-confirmation message.
    # Limit enrichment to the same mailbox and a proven shared thread/order.
    if records:
        for account_id, email, token in accounts:
            matched = [r for r in records if int(r.get('accountId') or 0) == account_id]
            if matched:
                records.extend(_related_purchase_records(matched, token, account_id, email))

    if account_errors and not records:
        raise HTTPException(
            status_code=503,
            detail='La búsqueda en Gmail no pudo completarse en todas las cuentas. '
                   'Revisa la conexión o autorización e inténtalo de nuevo.',
        )

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

    # Restrict product images to the chosen email, not every related email.
    # Keep other verified messages for order metadata and last-email status.
    merchant = store_name(records)
    photo_rows, fallback_rows, photo_rule = _select_primary_product_photo_source(
        records, merchant,
    )
    urls, attachments = _source_photo_fields(photo_rows)
    source_emails: list[str] = []
    for row in reversed(records):
        source_email = str(row.get('sourceEmail') or '')
        if source_email and source_email not in source_emails:
            source_emails.append(source_email)

    return {
        'found': bool(records),
        'query': seed,
        'clientId': client_id.strip(),
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
        'photoSourceRule': photo_rule,
        'photoSourceMessageCount': len(photo_rows),
        # Never expose these alternative images as normal photo candidates.
        # They are considered only if the primary email yielded zero images.
        '_photoFallbackGroups': [
            {
                'emailPhotoUrls': _source_photo_fields([row])[0],
                'emailAttachmentImages': _source_photo_fields([row])[1],
                'messageId': str(row.get('id') or ''),
            }
            for row in fallback_rows
        ],
        'emailPhotoUrls': urls[:60],
        'deliveryPhotoUrls': _delivery_photo_urls(records),
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
    client_id: str = Query(default=''),
    x_api_key: str | None = Header(default=None),
) -> dict[str, Any]:
    require_key(x_api_key)
    order = order_number.strip()
    track = tracking.strip()
    if not order and not track:
        raise HTTPException(status_code=422, detail='Provide order_number or tracking')
    if client_token.strip():
        # Different client scopes must never reuse each other's cached result.
        # Older jobs with the same token only were responsible for cross-scope
        # races between foreground and background scans.
        identity = json.dumps(
            [client_token.strip(), client_id.strip(), order, track],
            separators=(',', ':'),
        )
        job_id = 'c_' + hashlib.sha256(identity.encode('utf-8')).hexdigest()[:32]
    else:
        job_id = uuid.uuid4().hex
    job = _ensure_job(job_id, order, track, client_id.strip())
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
            _submit_job_once(
                job_id,
                str(job.get('orderNumber') or ''),
                str(job.get('tracking') or ''),
                str(job.get('clientId') or ''),
            )
    return job


@router.get('/api/gmail/reconstruct')
def api_reconstruct(
    order_number: str = Query(default=''),
    tracking: str = Query(default=''),
    client_id: str = Query(default=''),
    x_api_key: str | None = Header(default=None),
) -> dict[str, Any]:
    require_key(x_api_key)
    return reconstruct(order_number, tracking, client_id)


@router.get('/api/gmail/media/{name}')
def api_gmail_media(name: str, x_api_key: str | None = Header(default=None)) -> FileResponse:
    require_key(x_api_key)
    path = MEDIA_DIR / Path(name).name
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=404, detail='Gmail image not found')
    return FileResponse(path)
