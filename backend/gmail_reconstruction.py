import base64
import json
import os
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException, Query
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
    body = '\n'.join(plain).strip()
    if not body and html_parts:
        body = strip_html('\n'.join(html_parts))
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


def search_account(account_id: int, source_email: str, token: str, seed: str) -> list[dict[str, Any]]:
    safe_seed = seed.replace('"', '')
    query = urllib.parse.urlencode({'q': f'"{safe_seed}"', 'maxResults': '25'})
    listing = gmail_json('messages?' + query, token)
    records: list[dict[str, Any]] = []
    for item in listing.get('messages') or []:
        message_id = str(item.get('id') or '')
        if not message_id:
            continue
        try:
            full = gmail_json(f'messages/{urllib.parse.quote(message_id)}?format=full', token)
            records.append(record(full, token, account_id, source_email))
        except Exception:
            continue
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
    for row in records:
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
