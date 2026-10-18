"""Regression: SHEIN and Temu use the SAME general verified Gmail search.

No live Gmail credentials or private mailbox access are needed.
"""
import ast
import re
from pathlib import Path
from typing import Any

code = Path(__file__).with_name("gmail_reconstruction.py").read_text(encoding="utf-8")
tree = ast.parse(code)
wanted = {
    "_rank_product_photo_messages",
    "_select_primary_product_photo_source",
    "_source_photo_fields",
    "_photo_merchant_from_verified_records",
}
nodes = [
    node for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name in wanted
]
assert len(nodes) == len(wanted)
scope = {
    "Any": Any,
    "re": re,
    "_COURIER_SENDER": re.compile(
        r"(?i)(?:gofo|speedx|fedex|ontrac|ups\.com|usps|dhl)"
    ),
    "_merchant_family": lambda sender: next(
        (shop for shop in ("shein", "temu") if shop in sender.lower()), ""
    ),
    "_delivery_proof_message": lambda row: row.get("isProof") is True,
    "store_name": lambda rows: "Amazon",
}
exec(
    compile(ast.Module(body=nodes, type_ignores=[]), "general_email_photos", "exec"),
    scope,
)
rank = scope["_rank_product_photo_messages"]
select = scope["_select_primary_product_photo_source"]
fields = scope["_source_photo_fields"]
merchant = scope["_photo_merchant_from_verified_records"]


def mail(identifier, shop, millis, subject, urls=(), proof=False):
    return {
        "id": identifier,
        "accountId": 1,
        "internalDate": millis,
        "from": f"{shop} <support@{shop.lower()}.com>",
        "subject": subject,
        "remoteImages": list(urls),
        "attachmentImages": [],
        "isProof": proof,
    }


shein = [
    mail("shein-early", "SHEIN", 100, "Order placed", ["watch.jpg"]),
    mail("shein-pre", "SHEIN", 200,
         "Notificación previa a la entrega de Pedido de SHEIN",
         ["dress.jpg"]),
    mail("shein-latest", "SHEIN", 300, "Order shipped", ["shoes.jpg"]),
    mail("shein-no-photos", "SHEIN", 400, "Delivered", []),
]
temu = [
    mail("temu-early", "Temu", 100, "Order placed", ["shirt.jpg"]),
    mail("temu-latest", "Temu", 300,
         "Your Temu order delivered notification",
         ["house.jpg", "door.jpg", "package_info_shirt.jpg"]),
    mail("temu-courier", "GOFO", 400, "Proof of delivery", ["porch.jpg"], True),
]

for shop, rows, images, expected in (
    ("SHEIN", shein, ["shoes.jpg", "dress.jpg", "watch.jpg"],
     ["shein-latest", "shein-pre", "shein-early"]),
    ("Temu", temu,
     ["porch.jpg", "house.jpg", "door.jpg", "package_info_shirt.jpg", "shirt.jpg"],
     ["temu-courier", "temu-latest", "temu-early"]),
):
    ranked, ranking = rank(rows, shop)
    selected, backup, rule = select(rows, shop)
    assert ranking == "recent_first", (shop, ranking)
    assert rule == "all_verified_order_emails", (shop, rule)
    assert backup == [], (shop, backup)
    assert [row["id"] for row in selected] == expected, (shop, selected)
    assert fields(selected)[0] == images, (shop, fields(selected))

# The SHEIN pre-delivery mail is NOT specially prioritized and never excludes
# other matching messages. Images from all related verified messages survive.
selected, backup, rule = select(
    [shein[1], shein[0], shein[2]], "SHEIN"
)
assert [row["id"] for row in selected] == [
    "shein-latest", "shein-pre", "shein-early"
]
assert fields(selected)[0] == ["shoes.jpg", "dress.jpg", "watch.jpg"]

# Removing special rules does not break store identification from verified
# merchant senders when an email body mentions unrelated online retailers.
assert merchant([{
    **shein[0], "body": "Amazon Temu Walmart promotional text",
}]) == "SHEIN"
assert merchant([{
    **temu[0], "body": "Amazon SHEIN promotional text",
}]) == "Temu"

# Strict regression: these old settings must no longer appear in the backend.
assert "_shein_predelivery_notice" not in code
assert "shein_predelivery_first" not in code
assert "shein_subject_photo_fallback" not in code
assert "'single_priority_email'" not in code
assert "'photoSearchScope': 'all_verified_order_emails'" in code
assert "result.pop('_photoFallbackGroups', None)" in code
assert "'emailPhotoUrls': urls[:60]" in code
print("General verified Gmail photo search passed for SHEIN and Temu.")
