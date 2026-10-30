"""Offline regression tests for complete photo coverage and precise refund flags."""
import ast
import re
from pathlib import Path
from typing import Any

source = Path(__file__).with_name("gmail_reconstruction.py").read_text()
tree = ast.parse(source)
names = {
    "_refund_matches_known_products", "_refund_evidence",
    "_is_refund_or_cancel_notice", "_rank_product_photo_messages",
    "_select_primary_product_photo_source", "_source_photo_fields",
}
nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
assert len(nodes) == len(names)
scope = {"re": re, "Any": Any}
exec(compile(ast.Module(body=nodes, type_ignores=[]), "refund_photos", "exec"), scope)
catalog = [
    {"name": "Rechargeable Tactical LED Flashlight 2000LM"},
    {"name": "Portable Bluetooth Speaker Waterproof"},
]
same_order_refund = {
    "subject": "Your refund was processed for this item",
    "body": "Order #PO-1234567890\nRechargeable Tactical LED Flashlight 2000LM\nRefund $18.99",
    "date": "2026-10-29",
    "remoteImages": ["refund-banner.jpg"],
}
generic = {
    "subject": "Your refund was processed",
    "body": "Order #PO-1234567890 Refund $5.00",
    "date": "2026-10-29",
    "remoteImages": ["refund-banner.jpg"],
}
purchase = {
    "subject": "Your order has shipped",
    "body": "Order #PO-1234567890",
    "remoteImages": [f"product-{i}.jpg" for i in range(125)],
}
notices, matched = scope["_refund_evidence"]([purchase, same_order_refund, generic], catalog)
assert len(notices) == 2
assert matched == ["Rechargeable Tactical LED Flashlight 2000LM"], matched
assert notices[0]["matchedItems"] == matched
assert notices[1]["matchedItems"] == []
assert notices[1]["itemIdentified"] is False
assert scope["_refund_matches_known_products"](
    {"body": "Only your order number appears here"}, catalog
) == []
assert not scope["_is_refund_or_cancel_notice"]({
    "subject": "Your order shipped", "body": "Return policy and refunds"
})
selected, backups, rule = scope["_select_primary_product_photo_source"](
    [purchase, generic, same_order_refund], "Temu"
)
assert len(selected) == 1 and backups == []
assert rule == "all_verified_order_emails"
assert len(scope["_source_photo_fields"](selected)[0]) == 125
assert "'emailPhotoUrls': urls," in source
assert "'emailAttachmentImages': attachments," in source
assert "if len(remote_urls) >= 80:" not in source
assert "if len(candidates) >= 72:" not in source
assert "if len(candidates) >= 80:" not in source
print("All Gmail photos and item-specific refund evidence regressions passed.")
