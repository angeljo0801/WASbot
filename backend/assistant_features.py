import json
import os
import re
import sqlite3
import unicodedata
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DATA_DIR = Path(os.getenv("DATA_DIR", "./data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA_DIR / "whatsbot.db"


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_phone(value: Any) -> str:
    digits = re.sub(r"[^0-9]", "", str(value or "").replace("whatsapp:", ""))
    return f"+{digits}" if digits else ""


def normalize_name(value: Any) -> str:
    folded = unicodedata.normalize("NFKD", str(value or ""))
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch))
    return " ".join(re.findall(r"[a-z0-9]+", folded.lower()))


def init_assistant_db() -> None:
    with closing(db()) as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS assistant_activity (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_type TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'ok',
                sender TEXT NOT NULL DEFAULT '',
                note_id INTEGER,
                detail_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS client_aliases (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                client_external_id TEXT NOT NULL,
                client_name TEXT NOT NULL DEFAULT '',
                alias_type TEXT NOT NULL DEFAULT 'name',
                alias_value TEXT NOT NULL,
                normalized_value TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'whatsbot',
                confidence REAL NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(alias_type, normalized_value)
            );

            CREATE TABLE IF NOT EXISTS ocr_corrections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                field_name TEXT NOT NULL,
                original_value TEXT NOT NULL,
                corrected_value TEXT NOT NULL,
                occurrences INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(source, field_name, original_value, corrected_value)
            );
            """
        )
        conn.commit()


init_assistant_db()


def log_activity(
    event_type: str,
    *,
    status: str = "ok",
    sender: str = "",
    note_id: int | None = None,
    detail: dict[str, Any] | None = None,
) -> None:
    try:
        with closing(db()) as conn:
            conn.execute(
                """
                INSERT INTO assistant_activity(
                    event_type, status, sender, note_id, detail_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    event_type.strip() or "event",
                    status.strip() or "ok",
                    normalize_phone(sender),
                    note_id,
                    json.dumps(detail or {}, ensure_ascii=False),
                    utc_now(),
                ),
            )
            conn.commit()
    except Exception:
        pass


def list_activity(limit: int = 100) -> list[dict[str, Any]]:
    safe = max(1, min(int(limit or 100), 300))
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT id, event_type, status, sender, note_id, detail_json, created_at
            FROM assistant_activity
            ORDER BY id DESC
            LIMIT ?
            """,
            (safe,),
        ).fetchall()
    result: list[dict[str, Any]] = []
    for row in rows:
        try:
            detail = json.loads(row["detail_json"] or "{}")
        except Exception:
            detail = {}
        result.append(
            {
                "id": row["id"],
                "event_type": row["event_type"],
                "status": row["status"],
                "sender": row["sender"],
                "note_id": row["note_id"],
                "detail": detail,
                "created_at": row["created_at"],
            }
        )
    return result


def record_ocr_correction(
    source: str,
    field_name: str,
    original_value: Any,
    corrected_value: Any,
) -> bool:
    src = str(source or "").strip().lower() or "unknown"
    field = str(field_name or "").strip().lower()
    original = str(original_value if original_value is not None else "").strip()
    corrected = str(corrected_value if corrected_value is not None else "").strip()
    if not field or not original or not corrected or original == corrected:
        return False
    now = utc_now()
    with closing(db()) as conn:
        conn.execute(
            """
            INSERT INTO ocr_corrections(
                source, field_name, original_value, corrected_value,
                occurrences, created_at, updated_at
            ) VALUES (?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(source, field_name, original_value, corrected_value)
            DO UPDATE SET
                occurrences = occurrences + 1,
                updated_at = excluded.updated_at
            """,
            (src, field, original, corrected, now, now),
        )
        conn.commit()
    log_activity(
        "ocr_correction",
        detail={
            "source": src,
            "field": field,
            "original": original,
            "corrected": corrected,
        },
    )
    return True


def ocr_hints(source: str, min_occurrences: int = 1) -> list[dict[str, Any]]:
    src = str(source or "").strip().lower()
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT source, field_name, original_value, corrected_value,
                   occurrences, updated_at
            FROM ocr_corrections
            WHERE source = ? AND occurrences >= ?
            ORDER BY occurrences DESC, datetime(updated_at) DESC
            LIMIT 100
            """,
            (src, max(1, int(min_occurrences or 1))),
        ).fetchall()
    return [dict(row) for row in rows]


def _load_snapshot() -> dict[str, Any]:
    with closing(db()) as conn:
        try:
            row = conn.execute(
                "SELECT payload_json FROM business_snapshot WHERE id = 1"
            ).fetchone()
        except sqlite3.OperationalError:
            row = None
    if row is None:
        return {}
    try:
        value = json.loads(row["payload_json"] or "{}")
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def _active(rows: Any) -> list[dict[str, Any]]:
    if not isinstance(rows, list):
        return []
    return [
        dict(item)
        for item in rows
        if isinstance(item, dict) and item.get("deleted") is not True
    ]


def sync_snapshot_clients(payload: dict[str, Any]) -> int:
    clients = _active(payload.get("clients"))
    if not clients:
        return 0
    now = utc_now()
    count = 0
    with closing(db()) as conn:
        for client in clients:
            external_id = str(client.get("id") or client.get("external_id") or "").strip()
            name = str(client.get("name") or "").strip()
            phone = normalize_phone(
                client.get("phone")
                or client.get("phoneNumber")
                or client.get("mobile")
                or ""
            )
            if not external_id:
                external_id = f"snapshot:{normalize_name(name)}:{phone}"
            if not name and not phone:
                continue
            try:
                by_id = conn.execute(
                    "SELECT * FROM client_sync WHERE external_id = ?",
                    (external_id,),
                ).fetchone()
                by_phone = None
                if phone:
                    by_phone = conn.execute(
                        "SELECT * FROM client_sync WHERE phone = ? ORDER BY id LIMIT 1",
                        (phone,),
                    ).fetchone()

                if by_id is not None:
                    conn.execute(
                        """
                        UPDATE client_sync
                        SET name = ?,
                            phone = CASE WHEN ? != '' THEN ? ELSE phone END,
                            source = 'paqueteria_snapshot',
                            updated_at = ?
                        WHERE id = ?
                        """,
                        (name or by_id["name"], phone, phone, now, by_id["id"]),
                    )
                elif by_phone is not None:
                    old_external = by_phone["external_id"]
                    conn.execute(
                        """
                        UPDATE client_sync
                        SET external_id = ?, name = ?, phone = ?,
                            source = 'paqueteria_snapshot', updated_at = ?
                        WHERE id = ?
                        """,
                        (
                            external_id,
                            name or by_phone["name"],
                            phone or by_phone["phone"],
                            now,
                            by_phone["id"],
                        ),
                    )
                    conn.execute(
                        """
                        UPDATE client_aliases
                        SET client_external_id = ?, client_name = ?, updated_at = ?
                        WHERE client_external_id = ?
                        """,
                        (
                            external_id,
                            name or by_phone["name"],
                            now,
                            old_external,
                        ),
                    )
                else:
                    conn.execute(
                        """
                        INSERT INTO client_sync(
                            external_id, name, phone, source, created_at, updated_at
                        ) VALUES (?, ?, ?, 'paqueteria_snapshot', ?, ?)
                        """,
                        (external_id, name, phone, now, now),
                    )
            except sqlite3.OperationalError:
                continue

            aliases = [("name", name)]
            if phone:
                aliases.append(("phone", phone))
            for alias_type, alias in aliases:
                normalized = normalize_phone(alias) if alias_type == "phone" else normalize_name(alias)
                if not normalized:
                    continue
                conn.execute(
                    """
                    INSERT INTO client_aliases(
                        client_external_id, client_name, alias_type, alias_value,
                        normalized_value, source, confidence, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, 'paqueteria_snapshot', 1, ?, ?)
                    ON CONFLICT(alias_type, normalized_value) DO UPDATE SET
                        client_external_id=excluded.client_external_id,
                        client_name=excluded.client_name,
                        alias_value=excluded.alias_value,
                        source=excluded.source,
                        confidence=1,
                        updated_at=excluded.updated_at
                    """,
                    (
                        external_id,
                        name,
                        alias_type,
                        alias,
                        normalized,
                        now,
                        now,
                    ),
                )
            count += 1
        conn.commit()
    if count:
        log_activity("clients_unified", detail={"count": count})
    return count


def remember_client_alias(
    client_external_id: str,
    client_name: str,
    alias_type: str,
    alias_value: str,
    *,
    source: str = "whatsbot",
    confidence: float = 1,
) -> bool:
    kind = alias_type.strip().lower()
    value = alias_value.strip()
    if kind not in {"name", "phone"} or not value:
        return False
    normalized = normalize_phone(value) if kind == "phone" else normalize_name(value)
    if not normalized:
        return False
    now = utc_now()
    with closing(db()) as conn:
        conn.execute(
            """
            INSERT INTO client_aliases(
                client_external_id, client_name, alias_type, alias_value,
                normalized_value, source, confidence, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(alias_type, normalized_value) DO UPDATE SET
                client_external_id=excluded.client_external_id,
                client_name=excluded.client_name,
                alias_value=excluded.alias_value,
                source=excluded.source,
                confidence=MAX(client_aliases.confidence, excluded.confidence),
                updated_at=excluded.updated_at
            """,
            (
                client_external_id,
                client_name,
                kind,
                value,
                normalized,
                source,
                float(confidence),
                now,
                now,
            ),
        )
        conn.commit()
    return True


def upsert_local_client(name: str, phone: str = "") -> dict[str, Any]:
    clean_name = " ".join(str(name or "").split()).strip()
    clean_phone = normalize_phone(phone)
    if not clean_name and not clean_phone:
        raise ValueError("Client name or phone is required")
    identity = clean_phone or normalize_name(clean_name).replace(" ", "-")
    external_id = "whatsbot-client-" + identity.lstrip("+")
    now = utc_now()
    with closing(db()) as conn:
        existing = None
        if clean_phone:
            existing = conn.execute(
                "SELECT * FROM client_sync WHERE phone = ? ORDER BY id LIMIT 1",
                (clean_phone,),
            ).fetchone()
        if existing is None:
            existing = conn.execute(
                "SELECT * FROM client_sync WHERE external_id = ?",
                (external_id,),
            ).fetchone()
        if existing is None:
            conn.execute(
                """
                INSERT INTO client_sync(
                    external_id, name, phone, source, created_at, updated_at
                ) VALUES (?, ?, ?, 'whatsbot_action', ?, ?)
                """,
                (external_id, clean_name, clean_phone, now, now),
            )
        else:
            external_id = existing["external_id"]
            conn.execute(
                """
                UPDATE client_sync
                SET name = ?, phone = ?, source = 'whatsbot_action', updated_at = ?
                WHERE id = ?
                """,
                (
                    clean_name or existing["name"],
                    clean_phone or existing["phone"],
                    now,
                    existing["id"],
                ),
            )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM client_sync WHERE external_id = ?",
            (external_id,),
        ).fetchone()
    remember_client_alias(
        external_id,
        row["name"],
        "name",
        row["name"],
        source="whatsbot_action",
    )
    if row["phone"]:
        remember_client_alias(
            external_id,
            row["name"],
            "phone",
            row["phone"],
            source="whatsbot_action",
        )
    result = {
        "external_id": external_id,
        "name": row["name"],
        "phone": row["phone"],
    }
    log_activity("client_created", detail=result)
    return result


def resolve_client(sender: str) -> dict[str, Any] | None:
    phone = normalize_phone(sender)
    if not phone:
        return None
    with closing(db()) as conn:
        try:
            row = conn.execute(
                """
                SELECT external_id, name, phone, source
                FROM client_sync
                WHERE phone = ?
                ORDER BY datetime(updated_at) DESC
                LIMIT 1
                """,
                (phone,),
            ).fetchone()
        except sqlite3.OperationalError:
            row = None
        if row is not None:
            return {
                "id": row["external_id"],
                "name": row["name"],
                "phone": row["phone"],
                "source": row["source"],
            }
        alias = conn.execute(
            """
            SELECT client_external_id, client_name, alias_value, source
            FROM client_aliases
            WHERE alias_type = 'phone' AND normalized_value = ?
            LIMIT 1
            """,
            (phone,),
        ).fetchone()
    if alias is not None:
        return {
            "id": alias["client_external_id"],
            "name": alias["client_name"],
            "phone": alias["alias_value"],
            "source": alias["source"],
        }
    return None


def business_context_for_sender(sender: str) -> dict[str, Any]:
    client = resolve_client(sender)
    if client is None:
        return {"client": None}
    payload = _load_snapshot()
    cid = str(client.get("id") or "")
    packages = [
        p
        for p in _active(payload.get("packages"))
        if str(p.get("clientId") or p.get("client_id") or "") == cid
    ]
    purchases = [
        p
        for p in _active(payload.get("purchases"))
        if str(p.get("clientId") or p.get("client_id") or "") == cid
        or any(
            str(a.get("clientId") or "") == cid
            for a in (p.get("allocations") or [])
            if isinstance(a, dict)
        )
    ]
    payments = [
        p
        for p in _active(payload.get("payments"))
        if str(p.get("clientId") or p.get("client_id") or "") == cid
    ]
    return {
        "client": client,
        "packages": [
            {
                "tracking": p.get("tracking"),
                "status": p.get("status"),
                "weight": p.get("weight") or p.get("pounds"),
            }
            for p in packages[-10:]
        ],
        "purchases": [
            {
                "id": p.get("id"),
                "store": p.get("store"),
                "total": p.get("clientTotal") or p.get("total"),
                "status": p.get("status"),
            }
            for p in purchases[-8:]
        ],
        "payments": [
            {
                "amount": p.get("amount"),
                "date": p.get("date") or p.get("createdAt"),
            }
            for p in payments[-8:]
        ],
    }


def conversation_context(sender: str, limit: int = 8) -> str:
    phone = normalize_phone(sender)
    if not phone:
        return ""
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT original_text, content, reply_text, created_at
            FROM notes
            WHERE source = 'whatsapp' AND sender = ?
            ORDER BY datetime(created_at) DESC, id DESC
            LIMIT ?
            """,
            (phone, max(1, min(int(limit or 8), 20))),
        ).fetchall()
    lines: list[str] = []
    for row in reversed(rows):
        inbound = str(row["original_text"] or row["content"] or "").strip()
        if inbound:
            lines.append("Cliente: " + inbound[:900])
        reply = str(row["reply_text"] or "").strip()
        if reply:
            lines.append("WhatsBot: " + reply[:900])
    business = business_context_for_sender(phone)
    if business.get("client"):
        lines.append(
            "Datos actuales de Paquetería: "
            + json.dumps(business, ensure_ascii=False)[:5000]
        )
    return "\n".join(lines)[-9000:]


def list_conversations(limit: int = 100) -> list[dict[str, Any]]:
    safe = max(1, min(int(limit or 100), 300))
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT sender,
                   MAX(id) AS latest_id,
                   MAX(created_at) AS updated_at,
                   SUM(CASE WHEN reply_status = 'pending' THEN 1 ELSE 0 END) AS pending_count,
                   SUM(CASE WHEN reply_status = 'failed' THEN 1 ELSE 0 END) AS failed_count,
                   COUNT(*) AS message_count
            FROM notes
            WHERE source = 'whatsapp' AND sender IS NOT NULL AND sender != ''
            GROUP BY sender
            ORDER BY datetime(updated_at) DESC
            LIMIT ?
            """,
            (safe,),
        ).fetchall()
        result = []
        for row in rows:
            note = conn.execute(
                """
                SELECT original_text, content, reply_text, message_type, reply_status
                FROM notes WHERE id = ?
                """,
                (row["latest_id"],),
            ).fetchone()
            client = resolve_client(row["sender"])
            result.append(
                {
                    "sender": row["sender"],
                    "display_name": (client or {}).get("name") or row["sender"],
                    "client_id": (client or {}).get("id") or "",
                    "last_message": str(
                        note["original_text"] or note["content"] or ""
                    )[:240],
                    "last_reply": str(note["reply_text"] or "")[:240],
                    "message_type": note["message_type"],
                    "reply_status": note["reply_status"],
                    "pending_count": int(row["pending_count"] or 0),
                    "failed_count": int(row["failed_count"] or 0),
                    "message_count": int(row["message_count"] or 0),
                    "updated_at": row["updated_at"],
                }
            )
    return result


def conversation_messages(sender: str, limit: int = 100) -> list[dict[str, Any]]:
    phone = normalize_phone(sender)
    if not phone:
        return []
    safe = max(1, min(int(limit or 100), 300))
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT id, original_text, content, message_type, reply_status,
                   reply_text, reply_error, created_at, replied_at
            FROM notes
            WHERE source = 'whatsapp' AND sender = ?
            ORDER BY datetime(created_at) DESC, id DESC
            LIMIT ?
            """,
            (phone, safe),
        ).fetchall()
    result: list[dict[str, Any]] = []
    for row in reversed(rows):
        inbound = str(row["original_text"] or row["content"] or "").strip()
        result.append(
            {
                "id": f"in:{row['id']}",
                "note_id": row["id"],
                "direction": "in",
                "text": inbound,
                "message_type": row["message_type"],
                "status": "received",
                "created_at": row["created_at"],
            }
        )
        reply = str(row["reply_text"] or "").strip()
        if reply or row["reply_status"] in {"failed", "sending"}:
            result.append(
                {
                    "id": f"out:{row['id']}",
                    "note_id": row["id"],
                    "direction": "out",
                    "text": reply,
                    "message_type": "text",
                    "status": row["reply_status"],
                    "error": row["reply_error"] or "",
                    "created_at": row["replied_at"] or row["created_at"],
                }
            )
    return result
