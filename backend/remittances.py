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
            code = f"{secrets.randbelow(90000) + 10000:05d}"
            _write_code(conn, code, today)
            conn.execute("DELETE FROM remittance_agent_sessions")
            conn.commit()
        return code, today


def regenerate_code() -> tuple[str, str]:
    with closing(db()) as conn:
        today = remittance_day()
        code = f"{secrets.randbelow(90000) + 10000:05d}"
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
                raw_text, source_key, note_id, created_at
            ) VALUES (?, ?, ?, 'bofa_sms', ?, ?, ?, ?, ?)
            """,
            (
                name,
                normalize_person_name(name),
                cents,
                received_at,
                text,
                stable_key,
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
