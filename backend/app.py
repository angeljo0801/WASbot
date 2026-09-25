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
from remittances import (
    ensure_daily_code,
    get_agents as get_remittance_agents,
    handle_agent_message as handle_remittance_agent_message,
    ingest_bofa_sms,
    is_agent as is_remittance_agent,
    regenerate_code as regenerate_remittance_code,
    set_agents as set_remittance_agents,
)


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
MEDIA_DIR = DATA_DIR / "whatsapp_media"
MEDIA_DIR.mkdir(parents=True, exist_ok=True)

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
                reply_status TEXT NOT NULL DEFAULT 'none',
                reply_text TEXT NOT NULL DEFAULT '',
                reply_error TEXT NOT NULL DEFAULT '',
                reply_attempts INTEGER NOT NULL DEFAULT 0,
                reply_updated_at TEXT,
                replied_at TEXT,
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
        note_columns = {
            row["name"]
            for row in conn.execute("PRAGMA table_info(notes)").fetchall()
        }
        note_migrations = {
            "reply_status": "TEXT NOT NULL DEFAULT 'none'",
            "reply_text": "TEXT NOT NULL DEFAULT ''",
            "reply_error": "TEXT NOT NULL DEFAULT ''",
            "reply_attempts": "INTEGER NOT NULL DEFAULT 0",
            "reply_updated_at": "TEXT",
            "replied_at": "TEXT",
        }
        for column, definition in note_migrations.items():
            if column not in note_columns:
                conn.execute(
                    f"ALTER TABLE notes ADD COLUMN {column} {definition}"
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
        purchase_columns = {
            row["name"] for row in conn.execute("PRAGMA table_info(purchase_sync)").fetchall()
        }
        purchase_migrations = {
            "order_number": "TEXT NOT NULL DEFAULT ''",
            "items_json": "TEXT NOT NULL DEFAULT '[]'",
            "ocr_text": "TEXT NOT NULL DEFAULT ''",
            "ocr_meta_json": "TEXT NOT NULL DEFAULT '{}'",
        }
        for column, definition in purchase_migrations.items():
            if column not in purchase_columns:
                conn.execute(
                    f"ALTER TABLE purchase_sync ADD COLUMN {column} {definition}"
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
        remittance_agents = get_remittance_agents()
        return {
            "processing_mode": raw.get("processing_mode", "local"),
            "whatsapp_provider": raw.get("whatsapp_provider", "twilio"),
            "bot_number": raw.get("bot_number", normalize_phone(TWILIO_WHATSAPP_FROM)),
            "allowed_senders": allowed,
            "remittance_agents": remittance_agents,
            "whatsapp_connected": bool(
                TWILIO_ACCOUNT_SID
                and (
                    (TWILIO_API_KEY_SID and TWILIO_API_SECRET)
                    or TWILIO_AUTH_TOKEN
                )
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
        "sender": row["sender"] or "",
        "message_sid": row["message_sid"] or "",
        "reply_status": row["reply_status"] or "none",
        "reply_text": row["reply_text"] or "",
        "reply_error": row["reply_error"] or "",
        "reply_attempts": int(row["reply_attempts"] or 0),
        "reply_updated_at": row["reply_updated_at"],
        "replied_at": row["replied_at"],
        "created_at": row["created_at"],
    }


def twilio_client() -> Client:
    if not TWILIO_ACCOUNT_SID:
        raise HTTPException(status_code=503, detail="Twilio Account SID is not configured")
    if TWILIO_API_KEY_SID and TWILIO_API_SECRET:
        return Client(
            TWILIO_API_KEY_SID,
            TWILIO_API_SECRET,
            TWILIO_ACCOUNT_SID,
        )
    if TWILIO_AUTH_TOKEN:
        return Client(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
    raise HTTPException(
        status_code=503,
        detail="Twilio API key or Auth Token is not configured",
    )


def send_whatsapp_direct(to_number: str, body: str) -> dict[str, str]:
    config = get_config()
    from_number = normalize_phone(config.get("bot_number") or TWILIO_WHATSAPP_FROM)
    to_number = normalize_phone(to_number)
    if not from_number or not to_number:
        raise RuntimeError("Missing WhatsApp phone number")
    msg = twilio_client().messages.create(
        from_=f"whatsapp:{from_number}",
        to=f"whatsapp:{to_number}",
        body=body,
        status_callback="https://wasbot-backend-production.up.railway.app/webhooks/twilio/status",
    )
    print(
        "WHATSAPP_DIAG direct_send "
        f"sid_tail={str(getattr(msg, 'sid', ''))[-6:]} "
        f"to=***{to_number[-4:]} status={getattr(msg, 'status', '')}"
    )
    return {
        "sid": str(getattr(msg, "sid", "") or ""),
        "status": str(getattr(msg, "status", "") or ""),
    }


@app.post("/webhooks/twilio/status")
async def twilio_message_status(request: Request) -> Response:
    form = await request.form()
    status = str(form.get("MessageStatus") or "")
    sid = str(form.get("MessageSid") or "")
    error_code = str(form.get("ErrorCode") or "")
    error_message = str(form.get("ErrorMessage") or "")
    to_number = normalize_phone(str(form.get("To") or ""))
    print(
        "WHATSAPP_STATUS "
        f"sid_tail={sid[-6:]} to=***{to_number[-4:] if to_number else ''} "
        f"status={status} error_code={error_code or '-'} "
        f"error={error_message[:160] if error_message else '-'}"
    )
    return Response(status_code=204)


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


def persist_note_media(url: str, content_type: str, stem: str) -> str:
    if not url:
        return ""
    raw = download_twilio_media(url)
    if len(raw) > 12 * 1024 * 1024:
        return ""
    c = (content_type or "").lower()
    if "png" in c:
        ext = ".png"
    elif "webp" in c:
        ext = ".webp"
    elif "pdf" in c:
        ext = ".pdf"
    elif "audio" in c:
        ext = ".m4a"
    elif "video" in c:
        ext = ".mp4"
    else:
        ext = ".jpg"
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", stem)[:80] or "whatsapp"
    name = f"{safe}_{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')}{ext}"
    (MEDIA_DIR / name).write_bytes(raw)
    return f"/api/media/{name}"


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


def save_contact_notes(
    sender: str,
    contacts: list[dict[str, str]],
    message_sid: str | None,
) -> int:
    now = utc_now()
    saved = 0
    with closing(db()) as conn:
        for i, contact in enumerate(contacts):
            name = str(contact.get("name", "")).strip() or "Cliente WhatsApp"
            phone = normalize_phone(str(contact.get("phone", "")))
            content = f"Nombre: {name}"
            if phone:
                content += f"\nTeléfono: {phone}"
            contact_sid = (
                f"{message_sid}:contact:{i}"
                if message_sid
                else f"contact:{normalize_phone(sender)}:{name}:{phone}:{i}"
            )
            cur = conn.execute(
                """
                INSERT OR IGNORE INTO notes(
                    title, content, original_text, category, tags, source,
                    message_type, status, ai_source, sender, message_sid, created_at
                ) VALUES (?, ?, ?, 'Clientes', ?, 'whatsapp',
                          'contact', 'ready', 'rules', ?, ?, ?)
                """,
                (
                    f"Cliente: {name}",
                    content,
                    content,
                    json.dumps(["contacto", "cliente", "whatsapp"]),
                    normalize_phone(sender),
                    contact_sid,
                    now,
                ),
            )
            if cur.rowcount:
                saved += 1
        conn.commit()
    return saved


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


class RemittanceAgentsUpdate(BaseModel):
    agents: list[str] = Field(default_factory=list)


class RemittanceSmsCreate(BaseModel):
    text: str
    received_at: str = ""
    sms_id: str = ""


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


class AiReplyRequest(BaseModel):
    body: str


class ClientSyncCreate(BaseModel):
    external_id: str
    name: str
    phone: str = ""
    source: str = "paqueteria"


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
    order_number: str = ""
    items: list[dict[str, Any]] = Field(default_factory=list)
    ocr_text: str = ""
    ocr_meta: dict[str, Any] = Field(default_factory=dict)
    photos: list[PurchasePhoto] = Field(default_factory=list)
    created_at: str = ""


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "WhatsBot",
        "twilio_configured": bool(
            TWILIO_ACCOUNT_SID
            and (
                (TWILIO_API_KEY_SID and TWILIO_API_SECRET)
                or TWILIO_AUTH_TOKEN
            )
        ),
    }


@app.get("/api/media/{name}", dependencies=[Depends(require_api_key)])
def api_media(name: str) -> FileResponse:
    safe = Path(name).name
    path = MEDIA_DIR / safe
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=404, detail="Media not found")
    return FileResponse(path)


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


@app.get("/api/remittances/settings", dependencies=[Depends(require_api_key)])
def remittance_settings() -> dict[str, Any]:
    code, code_date = ensure_daily_code()
    return {
        "agents": get_remittance_agents(),
        "daily_code": code,
        "code_date": code_date,
    }


@app.put("/api/remittances/agents", dependencies=[Depends(require_api_key)])
def remittance_agents_update(payload: RemittanceAgentsUpdate) -> dict[str, Any]:
    agents = set_remittance_agents(payload.agents)
    code, code_date = ensure_daily_code()
    return {
        "agents": agents,
        "daily_code": code,
        "code_date": code_date,
    }


@app.post("/api/remittances/code/regenerate", dependencies=[Depends(require_api_key)])
def remittance_code_regenerate() -> dict[str, Any]:
    code, code_date = regenerate_remittance_code()
    return {
        "daily_code": code,
        "code_date": code_date,
    }


@app.post("/api/remittances/sms", status_code=201, dependencies=[Depends(require_api_key)])
def remittance_sms_create(payload: RemittanceSmsCreate) -> dict[str, Any]:
    saved = ingest_bofa_sms(
        payload.text,
        payload.received_at or utc_now(),
        payload.sms_id,
    )
    if saved is None:
        raise HTTPException(
            status_code=422,
            detail="SMS does not match the Bank of America remittance format",
        )
    return saved


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
    with closing(db()) as lookup:
        existing = lookup.execute(
            "SELECT message_type FROM notes WHERE id = ?",
            (note_id,),
        ).fetchone()
    if existing is None:
        raise HTTPException(status_code=404, detail="Note not found")
    is_contact = existing["message_type"] == "contact"

    fields: list[str] = []
    values: list[Any] = []
    for key in ("title", "content", "category", "status", "ai_source"):
        value = getattr(payload, key)
        if key == "category" and value is not None and is_contact:
            value = "Clientes"
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


@app.post("/api/clients", dependencies=[Depends(require_api_key)])
def upsert_synced_client(payload: ClientSyncCreate) -> dict[str, Any]:
    external_id = payload.external_id.strip()
    if not external_id:
        raise HTTPException(status_code=400, detail="external_id is required")
    name = payload.name.strip()
    phone = normalize_phone(payload.phone)
    source = payload.source.strip() or "paqueteria"
    now = utc_now()

    with closing(db()) as conn:
        existing = None
        if phone:
            existing = conn.execute(
                "SELECT * FROM client_sync WHERE phone = ? ORDER BY id LIMIT 1",
                (phone,),
            ).fetchone()
        if existing is None:
            existing = conn.execute(
                "SELECT * FROM client_sync WHERE external_id = ?",
                (external_id,),
            ).fetchone()

        if existing is not None:
            canonical_external = existing["external_id"]
            conn.execute(
                """
                UPDATE client_sync
                SET name = ?, phone = ?, source = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    name or existing["name"],
                    phone or existing["phone"],
                    source,
                    now,
                    existing["id"],
                ),
            )
        else:
            canonical_external = external_id
            conn.execute(
                """
                INSERT INTO client_sync(
                    external_id, name, phone, source, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (canonical_external, name, phone, source, now, now),
            )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM client_sync WHERE external_id = ?",
            (canonical_external,),
        ).fetchone()
        return {
            "id": row["id"],
            "external_id": row["external_id"],
            "name": row["name"],
            "phone": row["phone"],
            "source": row["source"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }


def purchase_row(row: sqlite3.Row) -> dict[str, Any]:
    try:
        files = json.loads(row["photo_files"] or "[]")
    except Exception:
        files = []
    try:
        items = json.loads(row["items_json"] or "[]")
    except Exception:
        items = []
    try:
        ocr_meta = json.loads(row["ocr_meta_json"] or "{}")
    except Exception:
        ocr_meta = {}
    return {
        "id": row["id"],
        "external_id": row["external_id"],
        "customer_name": row["customer_name"],
        "customer_phone": row["customer_phone"],
        "title": row["title"],
        "description": row["description"],
        "store": row["store"],
        "total": row["total"],
        "order_number": row["order_number"],
        "items": items,
        "ocr_text": row["ocr_text"],
        "ocr_meta": ocr_meta,
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
            payload.order_number.strip(),
            json.dumps(payload.items, ensure_ascii=False),
            payload.ocr_text,
            json.dumps(payload.ocr_meta, ensure_ascii=False),
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
                    store=?, total=?, order_number=?, items_json=?, ocr_text=?,
                    ocr_meta_json=?, photo_files=?, created_at=?, updated_at=?
                WHERE external_id=?
                """,
                values,
            )
        else:
            conn.execute(
                """
                INSERT INTO purchase_sync(
                    customer_name, customer_phone, title, description, store,
                    total, order_number, items_json, ocr_text, ocr_meta_json,
                    photo_files, created_at, updated_at, external_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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


@app.get(
    "/api/whatsapp/replies/pending",
    dependencies=[Depends(require_api_key)],
)
def pending_ai_replies(limit: int = 10) -> list[dict[str, Any]]:
    safe_limit = max(1, min(int(limit or 10), 20))
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT *
            FROM notes
            WHERE source = 'whatsapp'
              AND message_type = 'text'
              AND sender IS NOT NULL
              AND sender != ''
              AND (
                    reply_status = 'pending'
                    OR (reply_status = 'failed' AND reply_attempts < 3)
                  )
            ORDER BY datetime(created_at) ASC, id ASC
            LIMIT ?
            """,
            (safe_limit,),
        ).fetchall()
        return [note_row(row) for row in rows]


@app.post(
    "/api/whatsapp/replies/{note_id}",
    dependencies=[Depends(require_api_key)],
)
def send_ai_reply(note_id: int, payload: AiReplyRequest) -> dict[str, Any]:
    body = payload.body.strip()
    if not body:
        raise HTTPException(status_code=400, detail="Reply body is empty")

    with closing(db()) as conn:
        row = conn.execute(
            "SELECT * FROM notes WHERE id = ?",
            (note_id,),
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Note not found")
        if row["source"] != "whatsapp" or not normalize_phone(row["sender"]):
            raise HTTPException(
                status_code=400,
                detail="Note is not an inbound WhatsApp message",
            )
        if (row["reply_status"] or "") == "sent":
            return {
                "ok": True,
                "already_sent": True,
                "reply_status": "sent",
                "replied_at": row["replied_at"],
            }
        if (row["reply_status"] or "") == "sending":
            raise HTTPException(status_code=409, detail="Reply is already being sent")

        now = utc_now()
        conn.execute(
            """
            UPDATE notes
            SET reply_status = 'sending',
                reply_error = '',
                reply_attempts = COALESCE(reply_attempts, 0) + 1,
                reply_updated_at = ?
            WHERE id = ?
            """,
            (now, note_id),
        )
        conn.commit()
        sender = normalize_phone(row["sender"])

    try:
        sent = send_whatsapp_direct(sender, body)
    except Exception as exc:
        with closing(db()) as conn:
            conn.execute(
                """
                UPDATE notes
                SET reply_status = 'failed',
                    reply_error = ?,
                    reply_updated_at = ?
                WHERE id = ?
                """,
                (str(exc)[:500], utc_now(), note_id),
            )
            conn.commit()
        raise HTTPException(
            status_code=502,
            detail="Twilio could not send the WhatsApp reply",
        ) from exc

    replied_at = utc_now()
    with closing(db()) as conn:
        conn.execute(
            """
            UPDATE notes
            SET reply_status = 'sent',
                reply_text = ?,
                reply_error = '',
                reply_updated_at = ?,
                replied_at = ?
            WHERE id = ?
            """,
            (body, replied_at, replied_at, note_id),
        )
        conn.commit()

    return {
        "ok": True,
        "already_sent": False,
        "sid": sent.get("sid", ""),
        "status": sent.get("status", ""),
        "reply_status": "sent",
        "replied_at": replied_at,
    }


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
    allowed_now = allowed_sender(sender, config)
    operator = operator_sender(sender, config)
    remittance_agent = is_remittance_agent(sender)
    masked_sender = f"***{sender[-4:]}" if sender else "(empty)"
    masked_allowed = [
        f"***{normalize_phone(x)[-4:]}"
        for x in config.get("allowed_senders", [])
        if normalize_phone(x)
    ]
    print(
        "WHATSAPP_DIAG "
        f"sender={masked_sender} allowed={allowed_now} operator={operator} "
        f"agent={remittance_agent} allowed_list={masked_allowed}"
    )
    if not allowed_now and not remittance_agent:
        return Response(content=str(MessagingResponse()), media_type="application/xml")

    if remittance_agent:
        response = MessagingResponse()
        response.message(handle_remittance_agent_message(sender, body))
        return Response(content=str(response), media_type="application/xml")

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

    # An authorized operator can share one or more phone contacts directly.
    # Convert them to synced clients immediately; no outgoing WhatsApp
    # confirmation is required, so this also works while outbound messaging
    # is unavailable.
    if operator:
        contacts: list[dict[str, str]] = []

        if "BEGIN:VCARD" in body.upper():
            contacts.extend(parse_vcards(body))

        for i in range(num_media):
            item_type = (data.get(f"MediaContentType{i}") or "").lower()
            item_url = data.get(f"MediaUrl{i}") or ""
            if not item_url:
                continue
            likely_contact = (
                "vcard" in item_type
                or "x-vcard" in item_type
                or item_type in {
                    "text/directory",
                    "text/x-vcard",
                    "application/vcard",
                    "application/octet-stream",
                }
            )
            if not likely_contact:
                continue
            try:
                raw = download_twilio_media(item_url)
                contact_text = raw.decode("utf-8-sig", errors="replace")
                if "BEGIN:VCARD" in contact_text.upper():
                    contacts.extend(parse_vcards(contact_text))
            except Exception:
                pass

        if contacts:
            deduped: list[dict[str, str]] = []
            seen_contacts: set[str] = set()
            for contact in contacts:
                name = str(contact.get("name", "")).strip() or "Cliente WhatsApp"
                phone = normalize_phone(str(contact.get("phone", "")))
                key = phone or re.sub(r"[^a-z0-9]+", "", name.lower())
                if not key or key in seen_contacts:
                    continue
                seen_contacts.add(key)
                deduped.append({"name": name, "phone": phone})

            if deduped:
                count = approve_contacts_for_paqueteria(sender, deduped)
                save_contact_notes(sender, deduped, message_sid)
                print(
                    "WHATSAPP_CONTACT "
                    f"sender={masked_sender} clients_saved={count}"
                )
                return Response(
                    content=str(MessagingResponse()),
                    media_type="application/xml",
                )

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
            print(
                "WHATSAPP_DIAG "
                f"reply=twiml kind=combo sender={masked_sender}"
            )
            return Response(
                content=str(response),
                media_type="application/xml",
            )

    media_type = infer_message_type(content_type, num_media)
    persisted_media = media_url
    if num_media > 0 and media_url:
        try:
            persisted_media = persist_note_media(
                media_url,
                content_type,
                message_sid or "whatsapp",
            )
        except Exception:
            persisted_media = media_url
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

        cur = conn.execute(
            """
            INSERT INTO notes(
                title, content, original_text, category, tags, source,
                message_type, status, ai_source, media_path, sender,
                message_sid, reply_status, created_at
            ) VALUES (?, ?, ?, 'Inbox', '[]', 'whatsapp', ?, 'new', 'rules', ?, ?, ?, ?, ?)
            """,
            (
                title,
                content,
                body,
                media_type,
                persisted_media,
                sender,
                message_sid,
                "pending" if body and media_type == "text" else "none",
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
