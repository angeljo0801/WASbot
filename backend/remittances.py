import hashlib
import json
import os
import re
import secrets
import sqlite3
import unicodedata
from contextlib import closing
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from assistant_features import log_activity

DATA_DIR = Path(os.getenv("DATA_DIR", "./data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA_DIR / "whatsbot.db"
REMIt_TZ = ZoneInfo("America/New_York")


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_phone(value: str | None) -> str:
    if not value:
        return ""
    value = value.replace("whatsapp:", "").strip()
    digits = re.sub(r"[^0-9]", "", value)
    return f"+{digits}" if digits else ""


def init_schema() -> None:
    with closing(db()) as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS config (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS remittances (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sender_name TEXT NOT NULL,
                normalized_name TEXT NOT NULL,
                amount_cents INTEGER NOT NULL,
                source TEXT NOT NULL DEFAULT 'bofa_sms',
                received_at TEXT NOT NULL,
                raw_text TEXT NOT NULL DEFAULT '',
                source_key TEXT NOT NULL UNIQUE,
                dedupe_fingerprint TEXT NOT NULL DEFAULT '',
                duplicate_of INTEGER,
                status TEXT NOT NULL DEFAULT 'Pendiente',
                note_id INTEGER,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS remittance_agent_sessions (
                sender TEXT PRIMARY KEY,
                auth_date TEXT NOT NULL,
                authenticated_at TEXT NOT NULL
            );
            """
        )
        columns = {
            row["name"]
            for row in conn.execute("PRAGMA table_info(remittances)").fetchall()
        }
        if "dedupe_fingerprint" not in columns:
            conn.execute(
                "ALTER TABLE remittances ADD COLUMN dedupe_fingerprint TEXT NOT NULL DEFAULT ''"
            )
        if "duplicate_of" not in columns:
            conn.execute(
                "ALTER TABLE remittances ADD COLUMN duplicate_of INTEGER"
            )
        if "status" not in columns:
            conn.execute(
                "ALTER TABLE remittances ADD COLUMN status TEXT NOT NULL DEFAULT 'Pendiente'"
            )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_remittance_dedupe "
            "ON remittances(dedupe_fingerprint)"
        )
        conn.execute(
            "INSERT OR IGNORE INTO config(key, value) VALUES('remittance_agents', '[]')"
        )
        conn.commit()


init_schema()


def remittance_day() -> str:
    return datetime.now(REMIt_TZ).date().isoformat()


def normalize_person_name(value: str) -> str:
    folded = unicodedata.normalize("NFKD", value or "")
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch))
    folded = folded.lower()
    return " ".join(re.findall(r"[a-z0-9]+", folded))


def get_agents() -> list[str]:
    with closing(db()) as conn:
        row = conn.execute(
            "SELECT value FROM config WHERE key = 'remittance_agents'"
        ).fetchone()
    try:
        raw = json.loads(row["value"] if row else "[]")
    except Exception:
        raw = []
    return sorted({normalize_phone(x) for x in raw if normalize_phone(x)})


def set_agents(values: list[str]) -> list[str]:
    agents = sorted({normalize_phone(x) for x in values if normalize_phone(x)})
    with closing(db()) as conn:
        conn.execute(
            "INSERT INTO config(key, value) VALUES('remittance_agents', ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (json.dumps(agents),),
        )
        if agents:
            placeholders = ",".join("?" for _ in agents)
            conn.execute(
                f"DELETE FROM remittance_agent_sessions WHERE sender NOT IN ({placeholders})",
                agents,
            )
        else:
            conn.execute("DELETE FROM remittance_agent_sessions")
        conn.commit()
    return agents


def _new_code(previous: str = "") -> str:
    code = previous
    while code == previous:
        code = f"{secrets.randbelow(90000) + 10000:05d}"
    return code


def _write_code(conn: sqlite3.Connection, code: str, day: str) -> None:
    for key, value in (("remittance_code", code), ("remittance_code_date", day)):
        conn.execute(
            "INSERT INTO config(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )


def ensure_daily_code() -> tuple[str, str]:
    with closing(db()) as conn:
        rows = conn.execute(
            "SELECT key, value FROM config "
            "WHERE key IN ('remittance_code', 'remittance_code_date')"
        ).fetchall()
        values = {row["key"]: row["value"] for row in rows}
        today = remittance_day()
        code = values.get("remittance_code", "")
        code_date = values.get("remittance_code_date", "")
        if not re.fullmatch(r"\d{5}", code) or code_date != today:
            code = _new_code(code)
            _write_code(conn, code, today)
            conn.execute("DELETE FROM remittance_agent_sessions")
            conn.commit()
        return code, today


def regenerate_code() -> tuple[str, str]:
    with closing(db()) as conn:
        today = remittance_day()
        row = conn.execute(
            "SELECT value FROM config WHERE key = 'remittance_code'"
        ).fetchone()
        previous = row["value"] if row else ""
        code = _new_code(previous)
        _write_code(conn, code, today)
        conn.execute("DELETE FROM remittance_agent_sessions")
        conn.commit()
        return code, today


def is_agent(sender: str) -> bool:
    return normalize_phone(sender) in set(get_agents())


def _authenticated_today(sender: str) -> bool:
    with closing(db()) as conn:
        row = conn.execute(
            "SELECT auth_date FROM remittance_agent_sessions WHERE sender = ?",
            (normalize_phone(sender),),
        ).fetchone()
    return row is not None and row["auth_date"] == remittance_day()


def _authenticate(sender: str) -> None:
    with closing(db()) as conn:
        conn.execute(
            """
            INSERT INTO remittance_agent_sessions(sender, auth_date, authenticated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(sender) DO UPDATE SET
                auth_date=excluded.auth_date,
                authenticated_at=excluded.authenticated_at
            """,
            (normalize_phone(sender), remittance_day(), utc_now()),
        )
        conn.commit()


def parse_bofa_sms(text: str) -> tuple[str, int] | None:
    match = re.search(
        r"^\s*BofA:\s*(.+?)\s+le\s+ha\s+enviado\s+a\s+usted\s+\$([\d,]+(?:\.\d{1,2})?)\b",
        text or "",
        flags=re.IGNORECASE,
    )
    if not match:
        return None
    name = " ".join(match.group(1).split()).strip(" .,-")
    try:
        amount = Decimal(match.group(2).replace(",", ""))
    except InvalidOperation:
        return None
    cents = int((amount * 100).quantize(Decimal("1")))
    if not name or cents <= 0:
        return None
    return name, cents


def _display_date(received_at: str) -> str:
    try:
        parsed = datetime.fromisoformat(received_at.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        local = parsed.astimezone(REMIt_TZ)
    except Exception:
        local = datetime.now(REMIt_TZ)
    return local.strftime("%m/%d/%Y %I:%M %p")


def _dedupe_fingerprint(name: str, cents: int, received_at: str) -> str:
    normalized = normalize_person_name(name)
    if not normalized or cents <= 0:
        return ""
    try:
        parsed = datetime.fromisoformat((received_at or "").replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        day = parsed.astimezone(REMIt_TZ).date().isoformat()
    except Exception:
        day = ""
    if not day:
        return ""
    return hashlib.sha256(
        f"{normalized}|{cents}|{day}".encode("utf-8")
    ).hexdigest()


def _duplicate_by_fingerprint(
    conn: sqlite3.Connection,
    fingerprint: str,
    *,
    current_source: str,
    exclude_source_key: str = "",
) -> sqlite3.Row | None:
    if not fingerprint:
        return None
    params: list[Any] = [fingerprint, current_source]
    sql = """
        SELECT * FROM remittances
        WHERE dedupe_fingerprint = ?
          AND source != ?
    """
    if exclude_source_key:
        sql += " AND source_key != ?"
        params.append(exclude_source_key)
    sql += " ORDER BY id ASC LIMIT 1"
    return conn.execute(sql, params).fetchone()


def ingest_bofa_sms(text: str, received_at: str, sms_id: str = "") -> dict[str, Any] | None:
    parsed = parse_bofa_sms(text)
    if parsed is None:
        return None
    name, cents = parsed
    received_at = (received_at or utc_now()).strip()
    stable_key = sms_id.strip() or hashlib.sha256(
        f"{text}|{received_at}".encode("utf-8")
    ).hexdigest()
    amount_text = "$" + f"{cents / 100:.2f}"
    date_text = _display_date(received_at)
    content = f"Nombre: {name}\nMonto: {amount_text}\nFecha: {date_text}"
    fingerprint = _dedupe_fingerprint(name, cents, received_at)

    with closing(db()) as conn:
        existing = conn.execute(
            "SELECT * FROM remittances WHERE source_key = ?",
            (stable_key,),
        ).fetchone()
        if existing is not None:
            return {
                "id": existing["id"],
                "name": existing["sender_name"],
                "amount": existing["amount_cents"] / 100,
                "received_at": existing["received_at"],
                "duplicate": True,
                "duplicate_of": existing["id"],
            }

        duplicate = _duplicate_by_fingerprint(
            conn,
            fingerprint,
            current_source="bofa_sms",
            exclude_source_key=stable_key,
        )
        if duplicate is not None:
            log_activity(
                "remittance_duplicate",
                status="blocked",
                detail={
                    "source": "bofa_sms",
                    "duplicate_of": duplicate["id"],
                    "name": name,
                    "amount": cents / 100,
                },
            )
            return {
                "id": duplicate["id"],
                "name": duplicate["sender_name"],
                "amount": duplicate["amount_cents"] / 100,
                "received_at": duplicate["received_at"],
                "duplicate": True,
                "duplicate_of": duplicate["id"],
                "duplicate_reason": "same_name_amount_day",
            }

        cur = conn.execute(
            """
            INSERT INTO notes(
                title, content, original_text, category, tags, source,
                message_type, status, ai_source, created_at
            ) VALUES (?, ?, ?, 'Remesas', ?, 'sms_bofa', 'remittance', 'ready', 'rules', ?)
            """,
            (
                f"{name} · {amount_text}",
                content,
                content,
                json.dumps(["remesa"]),
                received_at,
            ),
        )
        note_id = int(cur.lastrowid)
        rem = conn.execute(
            """
            INSERT INTO remittances(
                sender_name, normalized_name, amount_cents, source, received_at,
                raw_text, source_key, dedupe_fingerprint, note_id, created_at
            ) VALUES (?, ?, ?, 'bofa_sms', ?, ?, ?, ?, ?, ?)
            """,
            (
                name,
                normalize_person_name(name),
                cents,
                received_at,
                text,
                stable_key,
                fingerprint,
                note_id,
                utc_now(),
            ),
        )
        conn.commit()
        return {
            "id": int(rem.lastrowid),
            "note_id": note_id,
            "name": name,
            "amount": cents / 100,
            "received_at": received_at,
            "duplicate": False,
        }


def parse_paypal_email(subject: str, body: str = "") -> tuple[str, int, str] | None:
    candidates = [subject or ""]
    candidates.extend((body or "").replace("\r", "\n").split("\n"))
    match = None
    for candidate in candidates:
        clean = " ".join(candidate.split()).strip()
        if not clean:
            continue
        match = re.search(
            r"^(.+?)\s+sent\s+you\s+\$([\d,]+(?:\.\d{1,2})?)\s+USD\b",
            clean,
            flags=re.IGNORECASE,
        )
        if match:
            break
    if not match:
        return None

    name = " ".join(match.group(1).split()).strip(" .,-")
    name = re.sub(
        r"^(?:paypal\s*[-:|]\s*)",
        "",
        name,
        flags=re.IGNORECASE,
    ).strip()
    try:
        cents = int(
            (Decimal(match.group(2).replace(",", "")) * 100).quantize(Decimal("1"))
        )
    except InvalidOperation:
        return None
    if not name or cents <= 0:
        return None

    combined = "\n".join(x for x in [subject or "", body or ""] if x)
    date_match = re.search(
        r"Transaction\s+date\s*[:\-]?\s*([A-Za-z]+\s+\d{1,2},\s+\d{4})",
        combined,
        flags=re.IGNORECASE,
    )
    transaction_date = date_match.group(1).strip() if date_match else ""
    return name, cents, transaction_date

def _paypal_received_at(transaction_date: str, fallback: str) -> tuple[str, str]:
    if transaction_date:
        try:
            parsed = datetime.strptime(transaction_date, "%B %d, %Y")
            local = parsed.replace(
                hour=12,
                minute=0,
                second=0,
                microsecond=0,
                tzinfo=REMIt_TZ,
            )
            return local.astimezone(timezone.utc).isoformat(), local.strftime("%m/%d/%Y")
        except ValueError:
            pass
    fallback = (fallback or utc_now()).strip()
    return fallback, _display_date(fallback).split(" ")[0]


def ingest_paypal_email(
    subject: str,
    body: str = "",
    received_at: str = "",
    email_id: str = "",
) -> dict[str, Any] | None:
    parsed = parse_paypal_email(subject, body)
    if parsed is None:
        return None
    name, cents, transaction_date = parsed
    stored_at, display_date = _paypal_received_at(transaction_date, received_at)
    stable_key = email_id.strip() or hashlib.sha256(
        f"paypal|{normalize_person_name(name)}|{cents}|{display_date}|{subject}".encode("utf-8")
    ).hexdigest()
    amount_text = "$" + f"{cents / 100:.2f}"
    content = f"Nombre: {name}\nMonto: {amount_text}\nFecha: {display_date}"
    raw = "\n".join(x for x in [subject, body] if x).strip()
    fingerprint = _dedupe_fingerprint(name, cents, stored_at)

    with closing(db()) as conn:
        existing = conn.execute(
            "SELECT * FROM remittances WHERE source_key = ?",
            (stable_key,),
        ).fetchone()
        if existing is not None:
            return {
                "id": existing["id"],
                "name": existing["sender_name"],
                "amount": existing["amount_cents"] / 100,
                "received_at": existing["received_at"],
                "duplicate": True,
                "duplicate_of": existing["id"],
            }

        duplicate = _duplicate_by_fingerprint(
            conn,
            fingerprint,
            current_source="paypal_email",
            exclude_source_key=stable_key,
        )
        if duplicate is not None:
            log_activity(
                "remittance_duplicate",
                status="blocked",
                detail={
                    "source": "paypal_email",
                    "duplicate_of": duplicate["id"],
                    "name": name,
                    "amount": cents / 100,
                },
            )
            return {
                "id": duplicate["id"],
                "name": duplicate["sender_name"],
                "amount": duplicate["amount_cents"] / 100,
                "received_at": duplicate["received_at"],
                "duplicate": True,
                "duplicate_of": duplicate["id"],
                "duplicate_reason": "same_name_amount_day",
            }

        cur = conn.execute(
            """
            INSERT INTO notes(
                title, content, original_text, category, tags, source,
                message_type, status, ai_source, created_at
            ) VALUES (?, ?, ?, 'Remesas', ?, 'email_paypal', 'remittance', 'ready', 'rules', ?)
            """,
            (
                f"{name} · {amount_text}",
                content,
                content,
                json.dumps(["remesa", "paypal"]),
                stored_at,
            ),
        )
        note_id = int(cur.lastrowid)
        rem = conn.execute(
            """
            INSERT INTO remittances(
                sender_name, normalized_name, amount_cents, source, received_at,
                raw_text, source_key, dedupe_fingerprint, note_id, created_at
            ) VALUES (?, ?, ?, 'paypal_email', ?, ?, ?, ?, ?, ?)
            """,
            (
                name,
                normalize_person_name(name),
                cents,
                stored_at,
                raw,
                stable_key,
                fingerprint,
                note_id,
                utc_now(),
            ),
        )
        conn.commit()
        return {
            "id": int(rem.lastrowid),
            "note_id": note_id,
            "name": name,
            "amount": cents / 100,
            "received_at": stored_at,
            "duplicate": False,
        }

def upsert_ocr_remittance(
    note_id: int,
    source: str,
    name: str = "",
    amount: float = 0,
    date_text: str = "",
    ocr_text: str = "",
) -> dict[str, Any]:
    source_clean = (source or "").strip().lower()
    if source_clean not in {"zelle", "paypal"}:
        raise ValueError("Unsupported remittance source")

    clean_name = " ".join((name or "").split()).strip()
    try:
        cents = int((Decimal(str(amount or 0)) * 100).quantize(Decimal("1")))
    except InvalidOperation:
        cents = 0
    cents = max(cents, 0)

    received_at = utc_now()
    display_date = (date_text or "").strip()
    if display_date:
        parsed = None
        for pattern in ("%m/%d/%Y", "%m-%d-%Y"):
            try:
                parsed = datetime.strptime(display_date, pattern)
                break
            except ValueError:
                continue
        if parsed is not None:
            local = parsed.replace(
                hour=12,
                minute=0,
                second=0,
                microsecond=0,
                tzinfo=REMIt_TZ,
            )
            received_at = local.astimezone(timezone.utc).isoformat()
            display_date = local.strftime("%m/%d/%Y")

    fingerprint = _dedupe_fingerprint(clean_name, cents, received_at)
    amount_text = "$" + f"{cents / 100:.2f}" if cents > 0 else ""
    source_label = "PayPal" if source_clean == "paypal" else "Zelle"
    lines = [f"Origen: {source_label}"]
    if clean_name:
        lines.append(f"Nombre: {clean_name}")
    if amount_text:
        lines.append(f"Monto: {amount_text}")
    if display_date:
        lines.append(f"Fecha: {display_date}")
    content = "\n".join(lines)
    title_parts = ["Remesa", source_label]
    if amount_text:
        title_parts.append(amount_text)
    title = " · ".join(title_parts)
    source_key = f"ocr:{note_id}" if note_id > 0 else hashlib.sha256(
        f"ocr|{source_clean}|{clean_name}|{cents}|{display_date}|{ocr_text}".encode("utf-8")
    ).hexdigest()

    with closing(db()) as conn:
        if note_id > 0:
            conn.execute(
                """
                UPDATE notes
                SET title = ?, content = ?, original_text = ?, category = 'Remesas',
                    tags = ?, status = 'ready', ai_source = 'rules'
                WHERE id = ?
                """,
                (
                    title,
                    content,
                    content,
                    json.dumps(["remesa", "ocr", source_clean]),
                    note_id,
                ),
            )

        existing = conn.execute(
            "SELECT id FROM remittances WHERE source_key = ?",
            (source_key,),
        ).fetchone()
        duplicate = _duplicate_by_fingerprint(
            conn,
            fingerprint,
            current_source=f"ocr_{source_clean}",
            exclude_source_key=source_key,
        )
        if existing is None and duplicate is not None:
            if note_id > 0:
                duplicate_content = content + (
                    f"\nPosible duplicado de remesa #{duplicate['id']}."
                )
                conn.execute(
                    """
                    UPDATE notes
                    SET title = ?, content = ?, original_text = ?, tags = ?
                    WHERE id = ?
                    """,
                    (
                        title + " · DUPLICADO",
                        duplicate_content,
                        duplicate_content,
                        json.dumps(["remesa", "ocr", source_clean, "duplicado"]),
                        note_id,
                    ),
                )
            conn.commit()
            log_activity(
                "remittance_duplicate",
                status="blocked",
                note_id=note_id if note_id > 0 else None,
                detail={
                    "source": f"ocr_{source_clean}",
                    "duplicate_of": duplicate["id"],
                    "name": clean_name,
                    "amount": cents / 100,
                },
            )
            return {
                "id": int(duplicate["id"]),
                "note_id": note_id,
                "source": source_clean,
                "name": clean_name,
                "amount": cents / 100,
                "date": display_date,
                "duplicate": True,
                "duplicate_of": int(duplicate["id"]),
                "duplicate_reason": "same_name_amount_day",
            }
        if existing is None:
            cur = conn.execute(
                """
                INSERT INTO remittances(
                    sender_name, normalized_name, amount_cents, source, received_at,
                    raw_text, source_key, dedupe_fingerprint, note_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    clean_name,
                    normalize_person_name(clean_name),
                    cents,
                    f"ocr_{source_clean}",
                    received_at,
                    ocr_text,
                    source_key,
                    fingerprint,
                    note_id if note_id > 0 else None,
                    utc_now(),
                ),
            )
            remittance_id = int(cur.lastrowid)
        else:
            remittance_id = int(existing["id"])
            conn.execute(
                """
                UPDATE remittances
                SET sender_name = ?, normalized_name = ?, amount_cents = ?,
                    source = ?, received_at = ?, raw_text = ?,
                    dedupe_fingerprint = ?, note_id = ?
                WHERE id = ?
                """,
                (
                    clean_name,
                    normalize_person_name(clean_name),
                    cents,
                    f"ocr_{source_clean}",
                    received_at,
                    ocr_text,
                    fingerprint,
                    note_id if note_id > 0 else None,
                    remittance_id,
                ),
            )
        conn.commit()

    return {
        "id": remittance_id,
        "note_id": note_id,
        "source": source_clean,
        "name": clean_name,
        "amount": cents / 100,
        "date": display_date,
        "duplicate": False,
        "duplicate_of": None,
    }

def set_remittance_status(remittance_id: int, status: str) -> bool:
    allowed = {"Pendiente", "Identificada", "Entregada", "Liquidada"}
    clean_status = str(status or "").strip()
    if clean_status not in allowed:
        return False
    with closing(db()) as conn:
        cur = conn.execute(
            "UPDATE remittances SET status = ? WHERE id = ?",
            (clean_status, int(remittance_id)),
        )
        if cur.rowcount:
            row = conn.execute(
                "SELECT note_id FROM remittances WHERE id = ?",
                (int(remittance_id),),
            ).fetchone()
            if row is not None and row["note_id"]:
                conn.execute(
                    "UPDATE notes SET status = ? WHERE id = ?",
                    (clean_status.lower(), row["note_id"]),
                )
        conn.commit()
    if cur.rowcount:
        log_activity(
            "remittance_status",
            detail={"remittance_id": int(remittance_id), "status": clean_status},
        )
    return cur.rowcount > 0


def _parse_agent_query(text: str) -> tuple[str, int] | None:
    raw = " ".join((text or "").split())
    amount_match = re.search(
        r"(?:USD\s*)?\$\s*([\d,]+(?:\.\d{1,2})?)"
        r"|(?:USD\s+)([\d,]+(?:\.\d{1,2})?)"
        r"|(?:\b(?:por|monto)?\s*)([\d,]+(?:\.\d{1,2})?)\s*(?:dólares|dolares)?\s*$",
        raw,
        flags=re.IGNORECASE,
    )
    if amount_match is None:
        return None
    amount_raw = (
        amount_match.group(1)
        or amount_match.group(2)
        or amount_match.group(3)
        or ""
    )
    try:
        cents = int((Decimal(amount_raw.replace(",", "")) * 100).quantize(Decimal("1")))
    except InvalidOperation:
        return None
    if cents <= 0:
        return None

    without_amount = (raw[:amount_match.start()] + " " + raw[amount_match.end():]).strip()
    name_match = re.search(
        r"\bremesa\s+de\s+(.+?)(?:\s+(?:por|de)\s*)?$",
        without_amount,
        flags=re.IGNORECASE,
    )
    if name_match:
        name = name_match.group(1)
    else:
        name_match = re.search(
            r"\bde\s+([A-Za-zÁÉÍÓÚÜÑáéíóúüñ' -]{3,})$",
            without_amount,
            flags=re.IGNORECASE,
        )
        name = name_match.group(1) if name_match else without_amount

    normalized = normalize_person_name(name)
    stop = {
        "quiero", "saber", "si", "llego", "la", "una", "remesa",
        "cuanto", "fue", "por", "de", "el", "monto", "pago"
    }
    tokens = [x for x in normalized.split() if x not in stop]
    if len(tokens) < 2:
        return None
    return " ".join(tokens), cents


def _find_remittance(query_name: str, cents: int) -> dict[str, Any] | None:
    query_tokens = set(normalize_person_name(query_name).split())
    if len(query_tokens) < 2:
        return None
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT sender_name, normalized_name, amount_cents, received_at
            FROM remittances
            WHERE amount_cents = ?
            ORDER BY datetime(received_at) DESC, id DESC
            LIMIT 50
            """,
            (cents,),
        ).fetchall()
    for row in rows:
        stored_tokens = set(str(row["normalized_name"]).split())
        if query_tokens.issubset(stored_tokens):
            return {
                "name": row["sender_name"],
                "amount_cents": row["amount_cents"],
                "received_at": row["received_at"],
            }
    return None


def handle_agent_message(sender: str, body: str) -> str:
    code, _ = ensure_daily_code()
    if not _authenticated_today(sender):
        candidate = re.sub(r"\D", "", body or "")
        if re.fullmatch(r"\d{5}", candidate) and candidate == code:
            _authenticate(sender)
            return "Acceso a Remesas activado por hoy."
        if re.fullmatch(r"\d{5}", candidate):
            return "Código incorrecto."
        return "Introduce el código de 5 dígitos para acceder a Remesas."

    query = _parse_agent_query(body)
    if query is None:
        return "Para consultar una remesa indica el nombre y el monto exacto."
    query_name, cents = query
    match = _find_remittance(query_name, cents)
    if match is None:
        return "No encontré una remesa que coincida con esos datos."
    amount_text = "$" + f"{match['amount_cents'] / 100:.2f}"
    return f"Sí, esa remesa llegó por {amount_text}."
