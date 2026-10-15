"""Offline regression checks for Gmail tracking lookup (no API keys needed)."""
import ast
import re
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

source = Path(__file__).with_name("gmail_reconstruction.py").read_text(encoding="utf-8")
parsed = ast.parse(source)
names = {
    "_compact_identifier", "_identifier_in_record",
    "_gmail_search_queries", "search_account",
}
functions = [node for node in parsed.body
             if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
             and node.name in names]
assert len(functions) == len(names)
scope = {
    "re": re, "urllib": urllib, "ThreadPoolExecutor": ThreadPoolExecutor,
    "as_completed": as_completed, "Any": object,
}
exec(compile(ast.Module(body=functions, type_ignores=[]), "<gmail-tests>", "exec"), scope)
compact = scope["_compact_identifier"]
matches = scope["_identifier_in_record"]
search = scope["search_account"]
queries = scope["_gmail_search_queries"]

tracking = "GFUS01072480941760"
assert compact("GFUS-0107 2480 941760") == tracking
assert queries(tracking)[0] == (f'"{tracking}"', False)

link_message = {
    "id": "linked", "subject": "SHEIN shipped your order",
    "body": "Your order is on its way.",
    "linkTargets": ["https://gofo.example/track?number=GFUS01072480941760"],
}
noise_message = {
    "id": "unrelated", "subject": "Other delivered order",
    "body": "Delivered to your address.",
    "linkTargets": ["https://gofo.example/track?number=GFUS99999999999999"],
}
assert matches(link_message, tracking)
assert not matches(noise_message, tracking)

queries_seen = []

def fake_gmail_json(path, token):
    if path.startswith("messages?"):
        params = urllib.parse.parse_qs(urllib.parse.urlsplit("https://fake/?" + path.split("?", 1)[1]).query)
        q = params.get("q", [""])[0]
        queries_seen.append(q)
        if q == f'"{tracking}"' or q == tracking:
            return {"messages": []}
        return {"messages": [{"id": "unrelated"}, {"id": "linked"}]}
    return {"id": path.split("/", 1)[1].split("?", 1)[0]}

def fake_record(msg, token, account_id, source_email):
    return link_message if msg["id"] == "linked" else noise_message

scope["gmail_json"] = fake_gmail_json
scope["record"] = fake_record
found = search(1, "connected@example.com", "fake-token", tracking)
assert [p["id"] for p in found] == ["linked"], found
assert queries_seen[0] == f'"{tracking}"'
assert any(tracking[-11:] in q for q in queries_seen)
assert len(queries_seen) <= 4

# A hit from a broad fallback is not enough: verify the full tracking.
scope["record"] = lambda msg, token, account_id, source_email: noise_message
not_found = search(1, "connected@example.com", "fake-token", tracking)
assert not_found == [], not_found

# A storefront label in the order field must not override a real tracking.
reconstruct = next(node for node in parsed.body
                   if isinstance(node, ast.FunctionDef)
                   and node.name == "reconstruct")
body = ast.get_source_segment(source, reconstruct)
assert "seed = tracking.strip() or order.strip()" in body
assert "if account_errors and not records:" in body

print("Gmail reconstruction regression tests passed.")
