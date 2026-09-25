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

from assistant_features import log_activity, sync_snapshot_clients
from remittances import set_remittance_status

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
            CREATE TABLE IF NOT EXISTS pending_operator_actions (
                sender TEXT PRIMARY KEY,
                action_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS paqueteria_actions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                action_type TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                source TEXT NOT NULL DEFAULT 'whatsapp',
                created_at TEXT NOT NULL,
                completed_at TEXT
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
    synced_clients = sync_snapshot_clients(payload)
    return {
        "ok": True,
        "updated_at": now,
        "synced_clients": synced_clients,
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
        pending_actions = conn.execute(
            "SELECT COUNT(*) AS n FROM paqueteria_actions WHERE status = 'pending'"
        ).fetchone()["n"]
    return {
        "ok": True,
        "snapshot_updated_at": snap["updated_at"],
        "snapshot_counts": {
            k: len(v) for k, v in snap["payload"].items() if isinstance(v, list)
        },
        "pending_purchase_conversations": pending,
        "pending_paqueteria_actions": pending_actions,
        "persistent_data_dir": str(DATA_DIR),
    }


@router.get("/api/paqueteria/actions")
def list_paqueteria_actions() -> list[dict[str, Any]]:
    with closing(db()) as conn:
        rows = conn.execute(
            """
            SELECT id, action_type, payload_json, status, source, created_at, completed_at
            FROM paqueteria_actions
            WHERE status = 'pending'
            ORDER BY id ASC
            """
        ).fetchall()
    result = []
    for row in rows:
        try:
            payload = json.loads(row["payload_json"] or "{}")
        except Exception:
            payload = {}
        result.append(
            {
                "id": row["id"],
                "action_type": row["action_type"],
                "payload": payload,
                "status": row["status"],
                "source": row["source"],
                "created_at": row["created_at"],
            }
        )
    return result


@router.post("/api/paqueteria/actions/{action_id}/complete")
def complete_paqueteria_action(action_id: int) -> dict[str, Any]:
    with closing(db()) as conn:
        cur = conn.execute(
            """
            UPDATE paqueteria_actions
            SET status = 'completed', completed_at = ?
            WHERE id = ? AND status = 'pending'
            """,
            (utc_now(), action_id),
        )
        conn.commit()
    return {"ok": cur.rowcount > 0}


def pending_operator_action(sender: str) -> dict[str, Any] | None:
    with closing(db()) as conn:
        row = conn.execute(
            "SELECT action_json FROM pending_operator_actions WHERE sender = ?",
            (normalize_phone(sender),),
        ).fetchone()
    if row is None:
        return None
    try:
        value = json.loads(row["action_json"])
        return value if isinstance(value, dict) else None
    except Exception:
        return None


def save_pending_operator_action(sender: str, action: dict[str, Any]) -> None:
    now = utc_now()
    with closing(db()) as conn:
        conn.execute(
            """
            INSERT INTO pending_operator_actions(sender, action_json, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(sender) DO UPDATE SET
                action_json = excluded.action_json,
                updated_at = excluded.updated_at
            """,
            (normalize_phone(sender), json.dumps(action, ensure_ascii=False), now, now),
        )
        conn.commit()


def clear_pending_operator_action(sender: str) -> None:
    with closing(db()) as conn:
        conn.execute(
            "DELETE FROM pending_operator_actions WHERE sender = ?",
            (normalize_phone(sender),),
        )
        conn.commit()


def enqueue_paqueteria_action(action: dict[str, Any]) -> int:
    now = utc_now()
    action_type = str(action.get("action_type") or "").strip()
    payload = action.get("payload")
    if not action_type or not isinstance(payload, dict):
        raise ValueError("Invalid action")
    with closing(db()) as conn:
        cur = conn.execute(
            """
            INSERT INTO paqueteria_actions(
                action_type, payload_json, status, source, created_at
            ) VALUES (?, ?, 'pending', 'whatsapp', ?)
            """,
            (action_type, json.dumps(payload, ensure_ascii=False), now),
        )
        conn.execute(
            """
            INSERT INTO sync_events(entity_type, entity_id, action, source, created_at)
            VALUES ('paqueteria_action', ?, ?, 'whatsapp', ?)
            """,
            (str(cur.lastrowid), action_type, now),
        )
        conn.commit()
        return int(cur.lastrowid)


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

    pending_action = pending_operator_action(sender)
    if pending_action is not None:
        answer = yes_no(body)
        if answer == "no":
            log_activity(
                "business_action",
                status="cancelled",
                sender=sender,
                detail=pending_action,
            )
            clear_pending_operator_action(sender)
            return "Acción cancelada."
        if answer == "yes":
            if pending_action.get("action_type") == "remittance_status":
                payload = pending_action.get("payload") or {}
                remittance_id = int(payload.get("remittanceId") or 0)
                status = str(payload.get("status") or "")
                ok = set_remittance_status(remittance_id, status)
                log_activity(
                    "business_action",
                    status="completed" if ok else "failed",
                    sender=sender,
                    detail=pending_action,
                )
                clear_pending_operator_action(sender)
                return (
                    f"Remesa #{remittance_id} cambiada a “{status}”."
                    if ok
                    else "No pude encontrar esa remesa para actualizarla."
                )

            action_id = enqueue_paqueteria_action(pending_action)
            log_activity(
                "business_action",
                status="queued",
                sender=sender,
                detail={"action_id": action_id, **pending_action},
            )
            clear_pending_operator_action(sender)
            return f"Acción #{action_id} enviada a Paquetería. Se aplicará en la próxima sincronización."
        return "Tengo una acción pendiente. Responde Sí para confirmarla o No para cancelarla."

    clean = clean_text(body)

    create_client_action = re.search(
        r"(?:crea|crear|agrega|añade)\s+(?:un\s+)?cliente\s+(?:llamado\s+|que\s+se\s+llama\s+)?(.+?)(?:\s+(?:telefono|tel|phone)\s*[:#-]?\s*([+\d ()-]{7,}))?$",
        body.strip(),
        flags=re.IGNORECASE,
    )
    if create_client_action:
        name = " ".join((create_client_action.group(1) or "").split()).strip(" ,.-")
        phone = normalize_phone(create_client_action.group(2) or "")
        if name:
            action = {
                "action_type": "create_client",
                "payload": {"name": name, "phone": phone},
            }
            save_pending_operator_action(sender, action)
            summary = f"Voy a crear el cliente “{name}”"
            if phone:
                summary += f" con teléfono {phone}"
            return summary + ". ¿Confirmas? Responde Sí o No."

    associate_action = re.search(
        r"(?:asocia|asociar|vincula|vincular)\s+(?:la\s+)?compra\s+([^\s,]+)\s+(?:a|con)\s+(.+)$",
        clean,
    )
    if associate_action:
        purchase_query = associate_action.group(1).strip()
        client_query = associate_action.group(2).strip()
        payload = snapshot()["payload"]
        client = find_client(payload, client_query)
        if client is None:
            return "No encontré ese cliente en Paquetería."
        purchase = None
        for row in active(payload.get("purchases")):
            candidates = {
                clean_text(str(row.get("id") or "")),
                clean_text(str(row.get("orderNumber") or row.get("order_number") or "")),
                clean_text(str(row.get("externalId") or row.get("external_id") or "")),
            }
            if clean_text(purchase_query) in candidates:
                purchase = row
                break
        if purchase is None:
            return "No encontré esa compra en Paquetería."
        action = {
            "action_type": "associate_purchase_client",
            "payload": {
                "purchaseId": str(purchase.get("id") or ""),
                "purchaseExternalId": str(
                    purchase.get("externalId") or purchase.get("external_id") or ""
                ),
                "clientId": str(client.get("id") or ""),
                "clientName": str(client.get("name") or client_query),
            },
        }
        save_pending_operator_action(sender, action)
        return (
            f"Voy a asociar la compra {purchase_query} con "
            f"{client.get('name')}. ¿Confirmas? Responde Sí o No."
        )

    remittance_action = re.search(
        r"(?:marca|cambia)\s+(?:la\s+)?remesa\s+#?([0-9]+)\s+(?:como|a)\s+(.+)$",
        clean,
    )
    if remittance_action:
        remittance_id = int(remittance_action.group(1))
        requested = remittance_action.group(2).strip()
        status_map = {
            "pendiente": "Pendiente",
            "identificada": "Identificada",
            "entregada": "Entregada",
            "liquidada": "Liquidada",
        }
        status = status_map.get(requested)
        if status:
            action = {
                "action_type": "remittance_status",
                "payload": {"remittanceId": remittance_id, "status": status},
            }
            save_pending_operator_action(sender, action)
            return (
                f"Voy a cambiar la remesa #{remittance_id} a “{status}”. "
                "¿Confirmas? Responde Sí o No."
            )

    package_action = re.search(
        r"(?:marca|cambia)\s+(?:el\s+)?(?:paquete\s+)?([a-z0-9-]{6,})\s+(?:como|a)\s+(.+)$",
        clean,
    )
    if package_action:
        tracking = package_action.group(1).upper()
        requested = package_action.group(2).strip()
        status_map = {
            "recibido": "Recibido",
            "verificado": "Verificado",
            "listo para cuba": "Listo para Cuba",
            "asignado a viaje": "Asignado a viaje",
            "en transito a cuba": "En tránsito a Cuba",
            "llego a cuba": "Llegó a Cuba",
            "entregado": "Entregado",
            "problema": "Problema",
        }
        status = status_map.get(requested)
        if status:
            action = {
                "action_type": "package_status",
                "payload": {"tracking": tracking, "status": status},
            }
            save_pending_operator_action(sender, action)
            return f"Voy a cambiar {tracking} a “{status}”. ¿Confirmas? Responde Sí o No."

    payment_action = re.search(
        r"(?:registra|registrar|anota|añade|agrega)\s+(?:un\s+)?pago\s+(?:de\s+)?(?:usd\s*)?(\d+(?:[.,]\d{1,2})?)\s+(?:para|de)\s+(.+)$",
        clean,
    )
    if payment_action:
        amount = float(payment_action.group(1).replace(",", "."))
        client_query = payment_action.group(2).strip()
        client = find_client(snapshot()["payload"], client_query)
        if client is None:
            return "No encontré ese cliente en Paquetería."
        action = {
            "action_type": "payment",
            "payload": {
                "clientId": str(client.get("id") or ""),
                "clientName": str(client.get("name") or client_query),
                "amount": amount,
            },
        }
        save_pending_operator_action(sender, action)
        return (
            f"Voy a registrar un pago de USD {amount:.2f} para "
            f"{client.get('name')}. ¿Confirmas? Responde Sí o No."
        )

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

    if clean in {"ayuda", "help", "/ayuda", "/help"}:
        return (
            "Puedo trabajar con Paquetería desde aquí. Ejemplos:\n"
            "• saldo de María\n"
            "• tracking 1Z...\n"
            "• paquetes de Juan\n"
            "• compras de Ana\n"
            "• listos para Cuba\n"
            "• compra para María, Amazon, 82.50\n"
            "• registra un pago de 50 para María\n"
            "• marca 1Z... como Recibido\n"
            "• crea cliente Pedro teléfono +1...\n"
            "• asocia compra 12345 a María\n"
            "• marca remesa 42 como Entregada"
        )

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
