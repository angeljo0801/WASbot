import json
import os
import re
import sqlite3
import uuid
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Body

DATA_DIR = Path(os.getenv("DATA_DIR", "./data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA_DIR / "whatsbot.db"
router = APIRouter()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def normalize_phone(value: Any) -> str:
    digits = re.sub(r"[^0-9]", "", str(value or "").replace("whatsapp:", ""))
    return f"+{digits}" if digits else ""


def init_combo_db() -> None:
    with closing(db()) as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS business_snapshot (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                payload_json TEXT NOT NULL DEFAULT '{}',
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS pending_purchase_requests (
                sender TEXT PRIMARY KEY,
                draft_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sync_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                action TEXT NOT NULL,
                source TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            """
        )
        conn.commit()


init_combo_db()


def snapshot() -> dict[str, Any]:
    with closing(db()) as conn:
        row = conn.execute(
            "SELECT payload_json, updated_at FROM business_snapshot WHERE id = 1"
        ).fetchone()
    if row is None:
        return {"payload": {}, "updated_at": ""}
    try:
        payload = json.loads(row["payload_json"] or "{}")
        if not isinstance(payload, dict):
            payload = {}
    except Exception:
        payload = {}
    return {"payload": payload, "updated_at": row["updated_at"]}


@router.put("/api/paqueteria/snapshot")
def put_snapshot(payload: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    now = utc_now()
    with closing(db()) as conn:
        conn.execute(
            """
            INSERT INTO business_snapshot(id, payload_json, updated_at)
            VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                payload_json=excluded.payload_json,
                updated_at=excluded.updated_at
            """,
            (json.dumps(payload, ensure_ascii=False), now),
        )
        conn.execute(
            """
            INSERT INTO sync_events(entity_type, entity_id, action, source, created_at)
            VALUES ('snapshot', 'paqueteria', 'upsert', 'paqueteria', ?)
            """,
            (now,),
        )
        conn.commit()
    return {
        "ok": True,
        "updated_at": now,
        "counts": {k: len(v) for k, v in payload.items() if isinstance(v, list)},
    }


@router.get("/api/paqueteria/snapshot")
def get_snapshot() -> dict[str, Any]:
    return snapshot()


@router.get("/api/combo/status")
def combo_status() -> dict[str, Any]:
    snap = snapshot()
    with closing(db()) as conn:
        pending = conn.execute(
            "SELECT COUNT(*) AS n FROM pending_purchase_requests"
        ).fetchone()["n"]
    return {
        "ok": True,
        "snapshot_updated_at": snap["updated_at"],
        "snapshot_counts": {
            k: len(v) for k, v in snap["payload"].items() if isinstance(v, list)
        },
        "pending_purchase_conversations": pending,
        "persistent_data_dir": str(DATA_DIR),
    }


def clean_text(value: str) -> str:
    return (
        value.strip().lower()
        .replace("á", "a").replace("é", "e").replace("í", "i")
        .replace("ó", "o").replace("ú", "u")
    )


def yes_no(value: str) -> str:
    clean = re.sub(r"[.!?,;:]+$", "", clean_text(value)).strip()
    if clean in {"si", "yes", "dale", "ok", "confirmar", "confirmo", "guardar", "guardalo"}:
        return "yes"
    if clean in {"no", "cancelar", "cancela", "descartar"}:
        return "no"
    return ""


def num(value: Any) -> float:
    try:
        return float(value or 0)
    except Exception:
        return 0.0


def active(rows: Any) -> list[dict[str, Any]]:
    if not isinstance(rows, list):
        return []
    return [dict(x) for x in rows if isinstance(x, dict) and x.get("deleted") is not True]


def find_client(payload: dict[str, Any], query: str) -> dict[str, Any] | None:
    needle = clean_text(query)
    clients = active(payload.get("clients"))
    for client in clients:
        if clean_text(str(client.get("name") or "")) == needle:
            return client
    for client in clients:
        if needle in clean_text(str(client.get("name") or "")):
            return client
    return None


def purchase_amount_for_client(purchase: dict[str, Any], client_id: str) -> float:
    allocations = purchase.get("allocations")
    if isinstance(allocations, list):
        total = sum(
            num(a.get("total"))
            for a in allocations
            if isinstance(a, dict) and str(a.get("clientId") or "") == client_id
        )
        if total > 0:
            return total
    if str(purchase.get("clientId") or "") == client_id:
        return num(purchase.get("clientTotal"))
    return 0.0


def query_business(text: str) -> str | None:
    clean = clean_text(text)
    payload = snapshot()["payload"]
    if not payload:
        return None

    match = re.search(r"(?:cuanto\s+debe|saldo\s+de|deuda\s+de)\s+(.+)$", clean)
    if match:
        client = find_client(payload, match.group(1))
        if client is None:
            return "No encontré ese cliente en Paquetería."
        cid = str(client.get("id") or "")
        owed = sum(purchase_amount_for_client(p, cid) for p in active(payload.get("purchases")))
        paid = sum(
            num(p.get("amount"))
            for p in active(payload.get("payments"))
            if str(p.get("clientId") or "") == cid
        )
        due = owed - paid
        name = str(client.get("name") or "Cliente")
        return f"{name}: cargos USD {owed:.2f}, pagos USD {paid:.2f}, saldo USD {due:.2f}."

    match = re.search(r"(?:tracking|rastrea|rastrear)\s*[:#-]?\s*([a-z0-9-]{6,})", clean)
    if match:
        needle = re.sub(r"\s+", "", match.group(1)).upper()
        clients = {str(c.get("id") or ""): c for c in active(payload.get("clients"))}
        for package in active(payload.get("packages")):
            code = re.sub(r"\s+", "", str(package.get("tracking") or "")).upper()
            if code == needle or needle in code:
                client = clients.get(str(package.get("clientId") or ""), {})
                return (
                    f"{package.get('tracking')}: {package.get('status') or 'Sin estado'} · "
                    f"{client.get('name') or 'Sin cliente'}."
                )
        return "No encontré ese tracking en Paquetería."

    match = re.search(r"(?:paquetes\s+de|paquete\s+de)\s+(.+)$", clean)
    if match:
        client = find_client(payload, match.group(1))
        if client is None:
            return "No encontré ese cliente en Paquetería."
        cid = str(client.get("id") or "")
        rows = [p for p in active(payload.get("packages")) if str(p.get("clientId") or "") == cid]
        if not rows:
            return f"{client.get('name')} no tiene paquetes registrados."
        lines = [
            f"• {p.get('tracking') or 'Sin tracking'} — {p.get('status') or 'Sin estado'}"
            for p in rows[:8]
        ]
        return f"Paquetes de {client.get('name')}:\n" + "\n".join(lines)

    match = re.search(r"(?:compras\s+de|compra\s+de)\s+(.+)$", clean)
    if match and "crear" not in clean and "nueva" not in clean:
        client = find_client(payload, match.group(1))
        if client is None:
            return "No encontré ese cliente en Paquetería."
        cid = str(client.get("id") or "")
        rows = [p for p in active(payload.get("purchases")) if purchase_amount_for_client(p, cid) > 0]
        if not rows:
            return f"{client.get('name')} no tiene compras registradas."
        lines = [
            f"• {p.get('store') or 'Compra'} — USD {purchase_amount_for_client(p, cid):.2f}"
            for p in rows[:8]
        ]
        return f"Compras de {client.get('name')}:\n" + "\n".join(lines)

    if "listos para cuba" in clean or "listo para cuba" in clean:
        clients = {str(c.get("id") or ""): c for c in active(payload.get("clients"))}
        rows = [
            p for p in active(payload.get("packages"))
            if clean_text(str(p.get("status") or "")) == "listo para cuba"
        ]
        if not rows:
            return "No hay paquetes marcados como Listo para Cuba."
        lines = []
        for p in rows[:10]:
            client = clients.get(str(p.get("clientId") or ""), {})
            lines.append(
                f"• {p.get('tracking') or 'Sin tracking'} — {client.get('name') or 'Sin cliente'}"
            )
        return f"Paquetes listos para Cuba ({len(rows)}):\n" + "\n".join(lines)

    return None


def pending_purchase(sender: str) -> dict[str, Any] | None:
    with closing(db()) as conn:
        row = conn.execute(
            "SELECT draft_json FROM pending_purchase_requests WHERE sender = ?",
            (normalize_phone(sender),),
        ).fetchone()
    if row is None:
        return None
    try:
        value = json.loads(row["draft_json"])
        return value if isinstance(value, dict) else None
    except Exception:
        return None


def save_pending_purchase(sender: str, draft: dict[str, Any]) -> None:
    now = utc_now()
    with closing(db()) as conn:
        conn.execute(
            """
            INSERT INTO pending_purchase_requests(sender, draft_json, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(sender) DO UPDATE SET draft_json=excluded.draft_json, updated_at=excluded.updated_at
            """,
            (normalize_phone(sender), json.dumps(draft, ensure_ascii=False), now, now),
        )
        conn.commit()


def clear_pending_purchase(sender: str) -> None:
    with closing(db()) as conn:
        conn.execute(
            "DELETE FROM pending_purchase_requests WHERE sender = ?",
            (normalize_phone(sender),),
        )
        conn.commit()


def parse_purchase_text(text: str, base: dict[str, Any] | None = None) -> dict[str, Any]:
    draft = dict(base or {})
    clean = " ".join(text.strip().split())
    lowered = clean_text(clean)

    for store in ["Amazon", "Walmart", "Shein", "Temu", "Target", "Costco", "eBay"]:
        if clean_text(store) in lowered:
            draft["store"] = store
            break

    amounts = re.findall(r"(?:usd\s*)?(\d+(?:[.,]\d{1,2})?)", lowered)
    if amounts:
        try:
            draft["total"] = float(amounts[-1].replace(",", "."))
        except Exception:
            pass

    phone = re.search(r"(\+?\d[\d\s().-]{7,}\d)", clean)
    if phone:
        draft["customer_phone"] = normalize_phone(phone.group(1))

    customer = re.search(
        r"\bpara\s+(.+?)(?=\s*(?:,|\ben\b|\bde\b|\bpor\b|\busd\b|\d+(?:[.,]\d{1,2})?\b))",
        clean,
        flags=re.IGNORECASE,
    )
    if customer:
        draft["customer_name"] = customer.group(1).strip(" ,.-")

    draft.setdefault("store", "WhatsBot")
    draft.setdefault("customer_name", "")
    draft.setdefault("customer_phone", "")
    draft.setdefault("total", 0.0)
    draft.setdefault("photo_files", [])
    draft.setdefault("created_at", utc_now())
    draft["description"] = clean
    return draft


def purchase_summary(draft: dict[str, Any]) -> str:
    total = num(draft.get("total"))
    total_text = f"USD {total:.2f}" if total > 0 else "sin total"
    phone = str(draft.get("customer_phone") or "")
    phone_text = f", número {phone}" if phone else ""
    return (
        f"Cliente: {draft.get('customer_name') or 'sin cliente'}{phone_text}. "
        f"Tienda: {draft.get('store') or 'WhatsBot'}. Total: {total_text}. "
        f"Fotos: {len(draft.get('photo_files') or [])}."
    )


def missing_purchase_fields(draft: dict[str, Any]) -> list[str]:
    missing = []
    if not str(draft.get("customer_name") or "").strip():
        missing.append("nombre del cliente")
    if num(draft.get("total")) <= 0:
        missing.append("total")
    return missing


def commit_purchase(sender: str, draft: dict[str, Any]) -> None:
    external_id = str(draft.get("external_id") or "").strip()
    if not external_id:
        external_id = f"whatsapp-chat-{re.sub(r'[^0-9]', '', sender)}-{uuid.uuid4().hex[:12]}"
    now = utc_now()
    with closing(db()) as conn:
        conn.execute(
            """
            INSERT INTO purchase_sync(
                external_id, customer_name, customer_phone, title, description,
                store, total, photo_files, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(external_id) DO UPDATE SET
                customer_name=excluded.customer_name,
                customer_phone=excluded.customer_phone,
                title=excluded.title,
                description=excluded.description,
                store=excluded.store,
                total=excluded.total,
                photo_files=excluded.photo_files,
                updated_at=excluded.updated_at
            """,
            (
                external_id,
                str(draft.get("customer_name") or "").strip(),
                normalize_phone(draft.get("customer_phone")),
                str(draft.get("store") or "Compra"),
                str(draft.get("description") or ""),
                str(draft.get("store") or "WhatsBot"),
                num(draft.get("total")),
                json.dumps(draft.get("photo_files") or []),
                str(draft.get("created_at") or now),
                now,
            ),
        )
        conn.execute(
            """
            INSERT INTO sync_events(entity_type, entity_id, action, source, created_at)
            VALUES ('purchase', ?, 'upsert', 'whatsapp', ?)
            """,
            (external_id, now),
        )
        conn.commit()
    clear_pending_purchase(sender)


def looks_like_purchase(text: str) -> bool:
    clean = clean_text(text)
    return (
        any(x in clean for x in ("compra", "comprar", "compre", "pedido", "amazon", "walmart", "shein", "temu"))
        and ("para " in clean or bool(re.search(r"\b\d+(?:[.,]\d{1,2})?\b", clean)))
    )


def process_operator_message(
    sender: str,
    body: str,
    photo_files: list[str],
    message_sid: str | None,
) -> str | None:
    sender = normalize_phone(sender)
    pending = pending_purchase(sender)

    if pending is not None:
        if photo_files:
            files = list(pending.get("photo_files") or [])
            for name in photo_files:
                if name and name not in files:
                    files.append(name)
            pending["photo_files"] = files
            save_pending_purchase(sender, pending)
            return (
                f"Añadí {len(photo_files)} foto(s). {purchase_summary(pending)} "
                "Puedes seguir enviando fotos o responder Sí para guardarla."
            )

        answer = yes_no(body)
        if answer == "no":
            clear_pending_purchase(sender)
            return "Compra descartada."
        if answer == "yes":
            missing = missing_purchase_fields(pending)
            if missing:
                return "Antes de guardarla me falta: " + " y ".join(missing) + "."
            commit_purchase(sender, pending)
            return "Compra guardada. Se sincronizará automáticamente con Paquetería."

        pending = parse_purchase_text(body, pending)
        save_pending_purchase(sender, pending)
        missing = missing_purchase_fields(pending)
        if missing:
            return (
                f"Actualicé la compra. {purchase_summary(pending)} "
                "Me falta: " + " y ".join(missing) + "."
            )
        return f"Actualicé la compra. {purchase_summary(pending)} ¿La guardo? Responde Sí o No."

    answer = query_business(body)
    if answer:
        return answer

    if looks_like_purchase(body):
        draft = parse_purchase_text(body)
        draft["external_id"] = (
            f"whatsapp-chat-{re.sub(r'[^0-9]', '', sender)}-"
            f"{message_sid or uuid.uuid4().hex[:12]}"
        )
        draft["photo_files"] = [x for x in photo_files if x]
        save_pending_purchase(sender, draft)
        missing = missing_purchase_fields(draft)
        if missing:
            return (
                f"Preparé una compra. {purchase_summary(draft)} "
                "Me falta: " + " y ".join(missing) + "."
            )
        return (
            f"Entendí esta compra: {purchase_summary(draft)} "
            "¿La guardo en Paquetería? Responde Sí o No. "
            "También puedes enviarme más fotos antes de confirmar."
        )

    return None
