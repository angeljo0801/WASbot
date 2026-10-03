import base64
import json
import os
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException, Query
from fastapi.responses import FileResponse

from gmail_oauth import access_token, require_key, request_json
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


def save_image(data: bytes, message_id: str, suffix: str, mime: str) -> dict[str, str] | None:
    if not data:
        return None
    extension = mime.split('/')[-1].lower().replace('jpeg', 'jpg')
    if extension not in {'jpg', 'png', 'webp', 'gif'}:
        extension = 'jpg'
    safe_suffix = ''.join(x for x in suffix if x.isalnum())[:18] or 'image'
    name = f'{message_id}_{safe_suffix}.{extension}'
    path = MEDIA_DIR / name
    if not path.exists():
        path.write_bytes(data)
    return {'name': name, 'url': f'/api/gmail/media/{name}'}


def walk_parts(
    part: dict[str, Any],
    *,
    message_id: str,
    token: str,
    plain: list[str],
    html_parts: list[str],
    images: list[dict[str, str]],
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
            saved = save_image(data, message_id, str(len(images)), mime)
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
            message_id=message_id,
            token=token,
            plain=plain,
            html_parts=html_parts,
            images=images,
        )


def record(message: dict[str, Any], token: str) -> dict[str, Any]:
    payload = message.get('payload') or {}
    plain: list[str] = []
    html_parts: list[str] = []
    images: list[dict[str, str]] = []
    walk_parts(
        payload,
        message_id=str(message.get('id') or ''),
        token=token,
        plain=plain,
        html_parts=html_parts,
        images=images,
    )
    body = '\n'.join(plain).strip()
    if not body and html_parts:
        body = strip_html('\n'.join(html_parts))
    return {
        'id': str(message.get('id') or ''),
        'internalDate': int(message.get('internalDate') or 0),
        'subject': header(payload, 'Subject'),
        'from': header(payload, 'From'),
        'date': header(payload, 'Date'),
        'body': body,
        'remoteImages': remote_images(html_parts),
        'attachmentImages': images,
    }


def reconstruct(order: str = '', tracking: str = '') -> dict[str, Any]:
    seed = order.strip() or tracking.strip()
    if not seed:
        raise HTTPException(status_code=422, detail='Provide order_number or tracking')
    token = access_token()
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
            records.append(record(full, token))
        except Exception:
            continue
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
    attachments: list[dict[str, str]] = []
    for row in records:
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
        'messageIds': [str(r.get('id') or '') for r in records],
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
