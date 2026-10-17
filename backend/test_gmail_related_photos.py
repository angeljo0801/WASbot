"""Offline regression checks for Gmail purchase-photo recovery.

No credentials, user mailboxes, or real Google APIs are accessed.
"""
import ast
import re
import urllib.parse
from pathlib import Path

directory = Path(__file__).parent
parser_source = (directory / "gmail_parser.py").read_text(encoding="utf-8")
parser_tree = ast.parse(parser_source)
parser_fn = [n for n in parser_tree.body if isinstance(n, ast.FunctionDef)
             and n.name in {"order_number", "estimated_delivery"}]
parser_scope = {"re": re}
exec(compile(ast.Module(body=parser_fn, type_ignores=[]), "parser", "exec"), parser_scope)
parse_order = parser_scope["order_number"]
parse_eta = parser_scope["estimated_delivery"]
assert parse_order("Your order shipped today") == ""
assert parse_order("Order #PO-1234567890 shipped") == "PO-1234567890"
assert parse_order("Order ID: 123456789012345") == "123456789012345"
assert parse_eta("Estimated delivery: soon") == ""
assert parse_eta("Estimated delivery: Oct 20, 2026") == "Oct 20, 2026"

source = (directory / "gmail_reconstruction.py").read_text(encoding="utf-8")
tree = ast.parse(source)
fn_names = {"_merchant_family", "_order_reference_for_related_messages",
            "_related_purchase_records"}
nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in fn_names]
assert len(nodes) == len(fn_names)

class Logger:
    def info(self, *args):
        pass

calls = []
messages = {
    "receipt-thread": {
        "id": "receipt-thread", "threadId": "thread-temu",
        "from": "Temu <support@temuemail.com>",
        "subject": "Temu order confirmation", "body": "Order #PO-1234567890",
        "remoteImages": ["https://img.temu.example/product.jpg"],
    },
    "foreign": {
        "id": "foreign", "threadId": "thread-temu",
        "from": "Shein <service@shein.com>", "body": "Order #PO-1234567890",
    },
    "receipt-order": {
        "id": "receipt-order", "threadId": "another-temu-thread",
        "from": "Temu <support@temuemail.com>",
        "body": "Order #PO-1234567890",
        "remoteImages": ["https://img.temu.example/product2.jpg"],
    },
    "other-order": {
        "id": "other-order", "threadId": "a-different-purchase",
        "from": "Temu <support@temuemail.com>",
        "body": "Order #PO-9999999999",
        "remoteImages": ["https://img.temu.example/wrong.jpg"],
    },
}
def gmail_json(path, token):
    assert token == "same-account-token"
    calls.append(path)
    if path.startswith("threads/"):
        return {"messages": [messages["receipt-thread"], messages["foreign"]]}
    if path.startswith("messages?"):
        assert '"PO-1234567890"' in urllib.parse.parse_qs(
            path.split("?", 1)[1])["q"][0]
        return {"messages": [{"id": "receipt-order"}, {"id": "other-order"}]}
    return messages[path.split("/", 1)[1].split("?", 1)[0]]

def record(msg, token, account_id, source_email):
    assert account_id == 1 and source_email == "connected@example.test"
    return dict(msg, accountId=account_id, sourceEmail=source_email)

scope = {
    "re": re, "urllib": urllib, "Any": object,
    "gmail_json": gmail_json, "record": record, "logger": Logger(),
    "order_number": parse_order,
    "_message_contains_identifier": lambda msg, ref: (
        ref.upper().replace("-", "") in
        str(msg.get("body") or "").upper().replace("-", "")
    ),
}
exec(compile(ast.Module(body=nodes, type_ignores=[]), "related", "exec"), scope)
matched = [{
    "id": "tracking-match", "threadId": "thread-temu", "accountId": 1,
    "subject": "Your Temu order has shipped",
    "from": "Temu <service@temuemail.com>",
    "body": "Order #PO-1234567890: tracking GFUS01074120988419",
    "linkTargets": [],
}]
added = scope["_related_purchase_records"](
    matched, "same-account-token", 1, "connected@example.test")
assert {r["id"] for r in added} == {"receipt-thread", "receipt-order"}, added
assert all(r["accountId"] == 1 for r in added)
assert any("threads/" in c for c in calls)
assert any("messages?" in c for c in calls)

# When tracking mail lacks a verified order number, do not search random
# confirmation emails and accidentally attach another customer's products.
calls.clear()
unlinked = [{**matched[0], "threadId": "", "body": "Your order shipped soon"}]
assert scope["_related_purchase_records"](
    unlinked, "same-account-token", 1, "connected@example.test") == []
assert not calls
assert "photoDiagnostics" in source and "Gmail image extraction" in source
print("Related Gmail purchase-photo recovery checks passed.")
