import base64
import json
import os
import re
import sqlite3
import urllib.request
import quopri
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Form, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel, Field
from twilio.request_validator import RequestValidator
from twilio.rest import Client
from twilio.twiml.messaging_response import MessagingResponse

from combo import router as combo_router, looks_like_purchase, pending_purchase, process_operator_message


APP_API_KEY = os.getenv("APP_API_KEY", "dev-mobile-key").strip()
TWILIO_ACCOUNT_SID = os.getenv("TWILIO_ACCOUNT_SID", "").strip()
TWILIO_API_KEY_SID = os.getenv("TWILIO_API_KEY_SID", "").strip()
TWILIO_API_SECRET = os.getenv("TWILIO_API_SECRET", "").strip()
TWILIO_AUTH_TOKEN = os.getenv("TWILIO_AUTH_TOKEN", "").strip()
TWILIO_WHATSAPP_FROM = os.getenv("TWILIO_WHATSAPP_FROM", "").strip()
ACK_ENABLED = os.getenv("ACK_ENABLED", "false").lower() in {"1", "true", "yes", "on"}

DATA_DIR = Path(os.getenv("DATA_DIR", "./data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA_DIR / "whatsbot.db"

app = FastAPI(title="WhatsBot Backend", version="1.0.0")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_phone(value: str | None) -> str:
    if not value:
        return ""
    value = value.replace("whatsapp:", "").strip()
    digits = re.sub(r"[^0-9]", "", value)
    return f"+{digits}" if digits else ""


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with closing(db()) as conn:
        conn.executescript(
            """
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
            );

            CREATE TABLE IF NOT EXISTS config (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS purchase_sync (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                external_id TEXT NOT NULL UNIQUE,
                customer_name TEXT NOT NULL DEFAULT '',
                customer_phone TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                store TEXT NOT NULL DEFAULT 'WhatsBot',
                total REAL NOT NULL DEFAULT 0,
                photo_files TEXT NOT NULL DEFAULT '[]',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS pending_contact_requests (
                sender TEXT PRIMARY KEY,
                contacts_json TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS client_sync (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                external_id TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL DEFAULT '',
                phone TEXT NOT NULL DEFAULT '',
                source TEXT NOT NULL DEFAULT 'whatsapp',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """
        )
        defaults = {
            "processing_mode": "local",
            "whatsapp_provider": "twilio",
            "bot_number": normalize_phone(TWILIO_WHATSAPP_FROM),
            "allowed_senders": json.dumps(
                [
                    normalize_phone(x)
                    for x in os.getenv("ALLOWED_SENDERS", "").split(",")
                    if normalize_phone(x)
                ]
            ),
        }
        for key, value in defaults.items():
            conn.execute(
                "INSERT OR IGNORE INTO config(key, value) VALUES (?, ?)",
                (key, value),
            )
        conn.commit()


init_db()


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if not APP_API_KEY or x_api_key != APP_API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


app.include_router(combo_router, dependencies=[Depends(require_api_key)])


def get_config(conn: sqlite3.Connection | None = None) -> dict[str, Any]:
    owns = conn is None
    conn = conn or db()
    try:
        rows = conn.execute("SELECT key, value FROM config").fetchall()
        raw = {row["key"]: row["value"] for row in rows}
        try:
            allowed = json.loads(raw.get("allowed_senders", "[]"))
        except Exception:
            allowed = []
        return {
            "processing_mode": raw.get("processing_mode", "local"),
            "whatsapp_provider": raw.get("whatsapp_provider", "twilio"),
            "bot_number": raw.get("bot_number", normalize_phone(TWILIO_WHATSAPP_FROM)),
            "allowed_senders": allowed,
            "whatsapp_connected": bool(
                TWILIO_ACCOUNT_SID
                and TWILIO_API_KEY_SID
                and TWILIO_API_SECRET
                and (raw.get("bot_number") or TWILIO_WHATSAPP_FROM)
            ),
        }
    finally:
        if owns:
            conn.close()


def note_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "title": row["title"],
        "content": row["content"],
        "original_text": row["original_text"],
        "category": row["category"],
        "tags": json.loads(row["tags"] or "[]"),
        "source": row["source"],
        "message_type": row["message_type"],
        "status": row["status"],
        "ai_source": row["ai_source"],
        "ai_provider": row["ai_source"],
        "media_path": row["media_path"],
        "created_at": row["created_at"],
    }


def twilio_client() -> Client:
    if not (TWILIO_ACCOUNT_SID and TWILIO_API_KEY_SID and TWILIO_API_SECRET):
        raise HTTPException(status_code=503, detail="Twilio credentials are not configured")
    return Client(
        TWILIO_API_KEY_SID,
        TWILIO_API_SECRET,
        TWILIO_ACCOUNT_SID,
    )


def validate_twilio_request(request: Request, form_data: dict[str, str]) -> bool:
    if not TWILIO_AUTH_TOKEN:
        return False
    signature = request.headers.get("X-Twilio-Signature", "")
    if not signature:
        return False

    # Twilio signs the exact public URL. X-Forwarded-Proto is important behind proxies.
    proto = request.headers.get("x-forwarded-proto") or request.url.scheme
    host = request.headers.get("x-forwarded-host") or request.headers.get("host")
    path = request.url.path
    query = f"?{request.url.query}" if request.url.query else ""
    public_url = f"{proto}://{host}{path}{query}" if host else str(request.url)

    validator = RequestValidator(TWILIO_AUTH_TOKEN)
    return validator.validate(public_url, form_data, signature)


def allowed_sender(sender: str, config: dict[str, Any]) -> bool:
    allowed = [normalize_phone(x) for x in config.get("allowed_senders", [])]
    allowed = [x for x in allowed if x]
    return not allowed or normalize_phone(sender) in allowed



def operator_sender(sender: str, config: dict[str, Any]) -> bool:
    allowed = [normalize_phone(x) for x in config.get("allowed_senders", [])]
    allowed = [x for x in allowed if x]
    return bool(allowed) and normalize_phone(sender) in allowed


def infer_message_type(content_type: str | None, num_media: int) -> str:
    if num_media <= 0:
        return "text"
    content_type = (content_type or "").lower()
    if content_type.startswith("image/"):
        return "image"
    if content_type.startswith("audio/"):
        return "audio"
    if content_type.startswith("video/"):
        return "video"
    return "document"


def make_title(body: str, message_type: str) -> str:
    clean = " ".join(body.split()).strip()
    if clean:
        return clean[:70] + ("…" if len(clean) > 70 else "")
    labels = {
        "image": "Imagen de WhatsApp",
        "audio": "Audio de WhatsApp",
        "video": "Video de WhatsApp",
        "document": "Documento de WhatsApp",
    }
    return labels.get(message_type, "Nota de WhatsApp")



def _unfold_vcard(text: str) -> list[str]:
    lines: list[str] = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw.startswith((" ", "\t")) and lines:
            lines[-1] += raw[1:]
        else:
            lines.append(raw)
    return lines


def _decode_vcard_value(raw: str, header: str) -> str:
    value = raw.strip()
    if "QUOTED-PRINTABLE" in header.upper():
        try:
            value = quopri.decodestring(value).decode("utf-8", errors="replace")
        except Exception:
            pass
    return value.replace("\\n", " ").replace("\\N", " ").strip()


def parse_vcards(text: str) -> list[dict[str, str]]:
    blocks = re.findall(
        r"BEGIN:VCARD.*?END:VCARD",
        text,
        flags=re.IGNORECASE | re.DOTALL,
    )
    contacts: list[dict[str, str]] = []
    for block in blocks:
        name = ""
        fallback_name = ""
        phones: list[str] = []
        for line in _unfold_vcard(block):
            if ":" not in line:
                continue
            header, raw_value = line.split(":", 1)
            key = header.split(";", 1)[0].upper()
            value = _decode_vcard_value(raw_value, header)
            if key == "FN" and value:
                name = value
            elif key == "N" and value and not fallback_name:
                parts = [part.strip() for part in value.split(";")]
                ordered: list[str] = []
                if len(parts) > 3 and parts[3]:
                    ordered.append(parts[3])
                if len(parts) > 1 and parts[1]:
                    ordered.append(parts[1])
                if len(parts) > 2 and parts[2]:
                    ordered.append(parts[2])
                if parts and parts[0]:
                    ordered.append(parts[0])
                if len(parts) > 4 and parts[4]:
                    ordered.append(parts[4])
                fallback_name = " ".join(ordered).strip()
            elif key == "TEL" and value:
                phone = normalize_phone(value)
                if phone and phone not in phones:
                    phones.append(phone)
        contact_name = name or fallback_name or "Contacto de WhatsApp"
        if phones:
            contacts.append({"name": contact_name, "phone": phones[0]})
        elif contact_name != "Contacto de WhatsApp":
            contacts.append({"name": contact_name, "phone": ""})
    return contacts


def download_twilio_media(url: str) -> bytes:
    request = urllib.request.Request(url)
    if TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN:
        token = base64.b64encode(
            f"{TWILIO_ACCOUNT_SID}:{TWILIO_AUTH_TOKEN}".encode("utf-8")
        ).decode("ascii")
        request.add_header("Authorization", f"Basic {token}")
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.read(12 * 1024 * 1024 + 1)


def persist_purchase_media(url: str, content_type: str, stem: str) -> str:
    if not url:
        return ""
    raw = download_twilio_media(url)
    if len(raw) > 12 * 1024 * 1024:
        return ""
    c = (content_type or "").lower()
    ext = ".png" if "png" in c else ".webp" if "webp" in c else ".jpg"
    folder = DATA_DIR / "purchase_media"
    folder.mkdir(parents=True, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", stem)[:80] or "whatsapp"
    name = f"{safe}_{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')}{ext}"
    (folder / name).write_bytes(raw)
    return name


def normalize_yes_no(value: str) -> str:
    clean = value.strip().lower()
    clean = (
        clean.replace("í", "i")
        .replace("á", "a")
        .replace("é", "e")
        .replace("ó", "o")
        .replace("ú", "u")
    )
    clean = re.sub(r"[.!?,;:]+$", "", clean).strip()
    if clean in {"si", "yes", "guardar", "guardalo", "guardarlos", "ok", "dale", "claro"}:
        return "yes"
    if clean in {"no", "cancelar", "cancela", "no guardar"}:
        return "no"
    return ""


def save_pending_contacts(sender: str, contacts: list[dict[str, str]]) -> None:
    with closing(db()) as conn:
        conn.execute(
            """
            INSERT INTO pending_contact_requests(sender, contacts_json, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(sender) DO UPDATE SET
                contacts_json=excluded.contacts_json,
                created_at=excluded.created_at
            """,
            (normalize_phone(sender), json.dumps(contacts), utc_now()),
        )
        conn.commit()


def get_pending_contacts(sender: str) -> list[dict[str, str]]:
    with closing(db()) as conn:
        row = conn.execute(
            "SELECT contacts_json FROM pending_contact_requests WHERE sender = ?",
            (normalize_phone(sender),),
        ).fetchone()
    if row is None:
        return []
    try:
        raw = json.loads(row["contacts_json"] or "[]")
        return [
            {
                "name": str(x.get("name", "")).strip(),
                "phone": normalize_phone(str(x.get("phone", ""))),
            }
            for x in raw
            if isinstance(x, dict)
        ]
    except Exception:
        return []


def clear_pending_contacts(sender: str) -> None:
    with closing(db()) as conn:
        conn.execute(
            "DELETE FROM pending_contact_requests WHERE sender = ?",
            (normalize_phone(sender),),
        )
        conn.commit()


def approve_contacts_for_paqueteria(
    sender: str,
    contacts: list[dict[str, str]],
) -> int:
    now = utc_now()
    saved = 0
    with closing(db()) as conn:
        for i, contact in enumerate(contacts):
            name = str(contact.get("name", "")).strip() or "Cliente WhatsApp"
            phone = normalize_phone(str(contact.get("phone", "")))
            identity = phone or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
            external_id = f"whatsapp-contact-{identity}"
            if not identity:
                external_id = f"whatsapp-contact-{normalize_phone(sender)}-{i}"
            conn.execute(
                """
                INSERT INTO client_sync(
                    external_id, name, phone, source, created_at, updated_at
                ) VALUES (?, ?, ?, 'whatsapp', ?, ?)
                ON CONFLICT(external_id) DO UPDATE SET
                    name=excluded.name,
                    phone=excluded.phone,
                    updated_at=excluded.updated_at
                """,
                (external_id, name, phone, now, now),
            )
            saved += 1
        conn.execute(
            "DELETE FROM pending_contact_requests WHERE sender = ?",
            (normalize_phone(sender),),
        )
        conn.commit()
    return saved


class ConfigUpdate(BaseModel):
    processing_mode: str = "local"
    whatsapp_provider: str = "twilio"
    bot_number: str = ""
    allowed_senders: list[str] = Field(default_factory=list)


class NoteCreate(BaseModel):
    title: str
    content: str = ""
    original_text: str = ""
    category: str = "Inbox"
    tags: list[str] = Field(default_factory=list)


class NotePatch(BaseModel):
    title: str | None = None
    content: str | None = None
    category: str | None = None
    tags: list[str] | None = None
    status: str | None = None
    ai_source: str | None = None


class SendMessage(BaseModel):
    to: str
    body: str


class PurchasePhoto(BaseModel):
    name: str = "photo.jpg"
    data: str


class PurchaseSyncCreate(BaseModel):
    external_id: str
    customer_name: str
    customer_phone: str = ""
    title: str = ""
    description: str = ""
    store: str = "WhatsBot"
    total: float = 0
    photos: list[PurchasePhoto] = Field(default_factory=list)
    created_at: str = ""


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "WhatsBot",
        "twilio_configured": bool(
            TWILIO_ACCOUNT_SID and TWILIO_API_KEY_SID and TWILIO_API_SECRET
        ),
    }


@app.get("/api/config", dependencies=[Depends(require_api_key)])
def api_config_get() -> dict[str, Any]:
    return get_config()


@app.put("/api/config", dependencies=[Depends(require_api_key)])
def api_config_put(payload: ConfigUpdate) -> dict[str, Any]:
    mode = payload.processing_mode if payload.processing_mode in {"local", "server", "rules"} else "local"
    provider = payload.whatsapp_provider if payload.whatsapp_provider in {"twilio", "meta"} else "twilio"
    allowed = sorted({normalize_phone(x) for x in payload.allowed_senders if normalize_phone(x)})
    values = {
        "processing_mode": mode,
        "whatsapp_provider": provider,
        "bot_number": normalize_phone(payload.bot_number),
        "allowed_senders": json.dumps(allowed),
    }
    with closing(db()) as conn:
        for key, value in values.items():
            conn.execute(
                "INSERT INTO config(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, value),
            )
        conn.commit()
    return get_config()


@app.get("/api/notes", dependencies=[Depends(require_api_key)])
def list_notes(q: str = "", category: str = "") -> list[dict[str, Any]]:
    sql = "SELECT * FROM notes WHERE 1=1"
    params: list[Any] = []
    if q.strip():
        sql += " AND (title LIKE ? OR content LIKE ? OR tags LIKE ?)"
        term = f"%{q.strip()}%"
        params.extend([term, term, term])
    if category and category != "Todas":
        sql += " AND category = ?"
        params.append(category)
    sql += " ORDER BY datetime(created_at) DESC, id DESC"

    with closing(db()) as conn:
        rows = conn.execute(sql, params).fetchall()
        return [note_row(row) for row in rows]


@app.post("/api/notes", status_code=201, dependencies=[Depends(require_api_key)])
def create_note(payload: NoteCreate) -> dict[str, Any]:
    with closing(db()) as conn:
        cur = conn.execute(
            """
            INSERT INTO notes(
                title, content, original_text, category, tags, source,
                message_type, status, ai_source, created_at
            ) VALUES (?, ?, ?, ?, ?, 'manual', 'text', 'ready', 'rules', ?)
            """,
            (
                payload.title.strip() or "Nota",
                payload.content,
                payload.original_text or payload.content,
                payload.category or "Inbox",
                json.dumps(payload.tags),
                utc_now(),
            ),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM notes WHERE id = ?", (cur.lastrowid,)).fetchone()
        return note_row(row)


@app.patch("/api/notes/{note_id}", dependencies=[Depends(require_api_key)])
def patch_note(note_id: int, payload: NotePatch) -> dict[str, Any]:
    fields: list[str] = []
    values: list[Any] = []
    for key in ("title", "content", "category", "status", "ai_source"):
        value = getattr(payload, key)
        if value is not None:
            fields.append(f"{key} = ?")
            values.append(value)
    if payload.tags is not None:
        fields.append("tags = ?")
        values.append(json.dumps(payload.tags))

    if not fields:
        raise HTTPException(status_code=400, detail="No fields to update")

    with closing(db()) as conn:
        values.append(note_id)
        cur = conn.execute(
            f"UPDATE notes SET {', '.join(fields)} WHERE id = ?",
            values,
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Note not found")
        conn.commit()
        row = conn.execute("SELECT * FROM notes WHERE id = ?", (note_id,)).fetchone()
        return note_row(row)


@app.delete("/api/notes/{note_id}", status_code=204, dependencies=[Depends(require_api_key)])
def delete_note(note_id: int) -> Response:
    with closing(db()) as conn:
        conn.execute("DELETE FROM notes WHERE id = ?", (note_id,))
        conn.commit()
    return Response(status_code=204)



@app.get("/api/clients", dependencies=[Depends(require_api_key)])
def list_synced_clients() -> list[dict[str, Any]]:
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT id, external_id, name, phone, source, created_at, updated_at
            FROM client_sync
            ORDER BY datetime(updated_at) DESC, id DESC
            """
        ).fetchall()
        return [
            {
                "id": row["id"],
                "external_id": row["external_id"],
                "name": row["name"],
                "phone": row["phone"],
                "source": row["source"],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
            }
            for row in rows
        ]


def purchase_row(row: sqlite3.Row) -> dict[str, Any]:
    try:
        files = json.loads(row["photo_files"] or "[]")
    except Exception:
        files = []
    return {
        "id": row["id"],
        "external_id": row["external_id"],
        "customer_name": row["customer_name"],
        "customer_phone": row["customer_phone"],
        "title": row["title"],
        "description": row["description"],
        "store": row["store"],
        "total": row["total"],
        "photo_urls": [
            f"/api/purchases/{row['id']}/photos/{i}" for i in range(len(files))
        ],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


@app.post("/api/purchases", status_code=201, dependencies=[Depends(require_api_key)])
def create_or_update_purchase(payload: PurchaseSyncCreate) -> dict[str, Any]:
    external_id = payload.external_id.strip()
    if not external_id:
        raise HTTPException(status_code=400, detail="external_id is required")
    media_dir = DATA_DIR / "purchase_media"
    media_dir.mkdir(parents=True, exist_ok=True)
    now = utc_now()
    with closing(db()) as conn:
        existing = conn.execute(
            "SELECT * FROM purchase_sync WHERE external_id = ?",
            (external_id,),
        ).fetchone()
        purchase_id = existing["id"] if existing else None
        previous_files: list[str] = []
        if existing:
            try:
                previous_files = json.loads(existing["photo_files"] or "[]")
            except Exception:
                previous_files = []

        new_files: list[str] = []
        for i, photo in enumerate(payload.photos):
            try:
                raw = base64.b64decode(photo.data, validate=True)
            except Exception as exc:
                raise HTTPException(status_code=400, detail=f"Invalid photo {i}") from exc
            if len(raw) > 8 * 1024 * 1024:
                raise HTTPException(status_code=413, detail="Photo too large")
            suffix = Path(photo.name).suffix.lower()
            if suffix not in {".jpg", ".jpeg", ".png", ".webp"}:
                suffix = ".jpg"
            safe_external = re.sub(r"[^A-Za-z0-9_-]", "_", external_id)[:80]
            filename = f"{safe_external}_{i}{suffix}"
            (media_dir / filename).write_bytes(raw)
            new_files.append(filename)

        if not new_files:
            new_files = previous_files

        values = (
            payload.customer_name.strip(),
            normalize_phone(payload.customer_phone),
            payload.title.strip(),
            payload.description.strip(),
            payload.store.strip() or "WhatsBot",
            float(payload.total or 0),
            json.dumps(new_files),
            payload.created_at.strip() or (existing["created_at"] if existing else now),
            now,
            external_id,
        )
        if existing:
            conn.execute(
                """
                UPDATE purchase_sync
                SET customer_name=?, customer_phone=?, title=?, description=?,
                    store=?, total=?, photo_files=?, created_at=?, updated_at=?
                WHERE external_id=?
                """,
                values,
            )
        else:
            conn.execute(
                """
                INSERT INTO purchase_sync(
                    customer_name, customer_phone, title, description, store,
                    total, photo_files, created_at, updated_at, external_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values,
            )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM purchase_sync WHERE external_id = ?",
            (external_id,),
        ).fetchone()
        return purchase_row(row)


@app.get("/api/purchases", dependencies=[Depends(require_api_key)])
def list_synced_purchases() -> list[dict[str, Any]]:
    with closing(db()) as conn:
        rows = conn.execute(
            "SELECT * FROM purchase_sync ORDER BY datetime(created_at) DESC, id DESC"
        ).fetchall()
        return [purchase_row(row) for row in rows]


@app.get(
    "/api/purchases/{purchase_id}/photos/{photo_index}",
    dependencies=[Depends(require_api_key)],
)
def get_purchase_photo(purchase_id: int, photo_index: int) -> FileResponse:
    with closing(db()) as conn:
        row = conn.execute(
            "SELECT photo_files FROM purchase_sync WHERE id = ?",
            (purchase_id,),
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Purchase not found")
    try:
        files = json.loads(row["photo_files"] or "[]")
    except Exception:
        files = []
    if photo_index < 0 or photo_index >= len(files):
        raise HTTPException(status_code=404, detail="Photo not found")
    name = Path(str(files[photo_index])).name
    path = DATA_DIR / "purchase_media" / name
    if not path.exists():
        raise HTTPException(status_code=404, detail="Photo not found")
    return FileResponse(path)


@app.post("/api/whatsapp/send", dependencies=[Depends(require_api_key)])
def send_whatsapp(payload: SendMessage) -> dict[str, Any]:
    config = get_config()
    from_number = normalize_phone(config.get("bot_number") or TWILIO_WHATSAPP_FROM)
    to_number = normalize_phone(payload.to)
    if not from_number or not to_number:
        raise HTTPException(status_code=400, detail="Missing WhatsApp phone number")

    msg = twilio_client().messages.create(
        from_=f"whatsapp:{from_number}",
        to=f"whatsapp:{to_number}",
        body=payload.body,
    )
    return {"ok": True, "sid": msg.sid, "status": msg.status}


@app.post("/webhooks/twilio/whatsapp")
async def twilio_whatsapp_webhook(request: Request) -> Response:
    form = await request.form()
    data = {str(k): str(v) for k, v in form.items()}

    if not validate_twilio_request(request, data):
        raise HTTPException(
            status_code=403,
            detail="Invalid Twilio signature. Configure TWILIO_AUTH_TOKEN on the server.",
        )

    sender = normalize_phone(data.get("From"))
    body = data.get("Body", "").strip()
    message_sid = data.get("MessageSid", "").strip() or None

    config = get_config()
    if not allowed_sender(sender, config):
        return Response(content=str(MessagingResponse()), media_type="application/xml")

    operator = operator_sender(sender, config)

    # Only an explicitly authorized operator can create or query business data.
    pending_contacts = get_pending_contacts(sender) if operator else []
    answer = normalize_yes_no(body) if pending_contacts else ""
    if answer:
        response = MessagingResponse()
        if answer == "yes":
            count = approve_contacts_for_paqueteria(sender, pending_contacts)
            if count == 1:
                contact = pending_contacts[0]
                label = contact.get("name") or contact.get("phone") or "El contacto"
                response.message(
                    f"{label} quedó guardado como cliente y se sincronizará con Paquetería."
                )
            else:
                response.message(
                    f"{count} contactos quedaron guardados como clientes y se sincronizarán con Paquetería."
                )
        else:
            clear_pending_contacts(sender)
            response.message("Perfecto, no lo guardaré como cliente.")
        return Response(content=str(response), media_type="application/xml")

    try:
        num_media = int(data.get("NumMedia", "0") or "0")
    except ValueError:
        num_media = 0

    media_url = data.get("MediaUrl0") if num_media > 0 else None
    content_type = (data.get("MediaContentType0") or "").lower()

    # WhatsApp shared contacts arrive as vCard media. Parse them and ask first.
    if operator and num_media > 0 and media_url and (
        "vcard" in content_type
        or "x-vcard" in content_type
        or content_type in {"text/directory", "application/octet-stream"}
    ):
        contacts: list[dict[str, str]] = []
        try:
            raw = download_twilio_media(media_url)
            text = raw.decode("utf-8-sig", errors="replace")
            if "BEGIN:VCARD" in text.upper():
                contacts = parse_vcards(text)
        except Exception:
            contacts = []

        if contacts:
            save_pending_contacts(sender, contacts)
            response = MessagingResponse()
            if len(contacts) == 1:
                contact = contacts[0]
                phone_text = f" ({contact['phone']})" if contact.get("phone") else ""
                response.message(
                    f"Recibí el contacto {contact['name']}{phone_text}. "
                    "¿Quieres guardarlo como cliente en Paquetería? Responde Sí o No."
                )
            else:
                names = ", ".join(c["name"] for c in contacts[:3])
                extra = f" y {len(contacts) - 3} más" if len(contacts) > 3 else ""
                response.message(
                    f"Recibí {len(contacts)} contactos: {names}{extra}. "
                    "¿Quieres guardarlos como clientes en Paquetería? Responde Sí o No."
                )
            return Response(content=str(response), media_type="application/xml")

    if operator:
        purchase_photos: list[str] = []
        if num_media > 0 and (pending_purchase(sender) is not None or looks_like_purchase(body)):
            for i in range(num_media):
                item_type = (data.get(f"MediaContentType{i}") or "").lower()
                item_url = data.get(f"MediaUrl{i}") or ""
                if item_url and item_type.startswith("image/"):
                    try:
                        saved = persist_purchase_media(
                            item_url,
                            item_type,
                            f"{message_sid or 'purchase'}_{i}",
                        )
                        if saved:
                            purchase_photos.append(saved)
                    except Exception:
                        pass

        combo_reply = process_operator_message(
            sender,
            body,
            purchase_photos,
            message_sid,
        )
        if combo_reply:
            response = MessagingResponse()
            response.message(combo_reply)
            return Response(content=str(response), media_type="application/xml")

    media_type = infer_message_type(content_type, num_media)
    title = make_title(body, media_type)
    content = body
    if not content and num_media > 0:
        content = {
            "image": "[Imagen recibida]",
            "audio": "[Audio recibido]",
            "video": "[Video recibido]",
            "document": "[Documento recibido]",
        }.get(media_type, "[Archivo recibido]")

    with closing(db()) as conn:
        if message_sid:
            existing = conn.execute(
                "SELECT id FROM notes WHERE message_sid = ?",
                (message_sid,),
            ).fetchone()
            if existing:
                return Response(content=str(MessagingResponse()), media_type="application/xml")

        conn.execute(
            """
            INSERT INTO notes(
                title, content, original_text, category, tags, source,
                message_type, status, ai_source, media_path, sender,
                message_sid, created_at
            ) VALUES (?, ?, ?, 'Inbox', '[]', 'whatsapp', ?, 'new', 'rules', ?, ?, ?, ?)
            """,
            (
                title,
                content,
                body,
                media_type,
                media_url,
                sender,
                message_sid,
                utc_now(),
            ),
        )
        conn.commit()

    response = MessagingResponse()
    if ACK_ENABLED:
        response.message("Nota guardada.")
    return Response(content=str(response), media_type="application/xml")


@app.exception_handler(Exception)
async def unhandled_exception_handler(_: Request, exc: Exception) -> JSONResponse:
    # Avoid leaking credentials or internals to callers.
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})
