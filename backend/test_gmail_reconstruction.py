"""Offline Gmail tracking regression checks (no credentials / live inbox required)."""
import ast
import base64
import html
import re
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

source = Path(__file__).with_name("gmail_reconstruction.py").read_text(encoding="utf-8")
parsed = ast.parse(source)
names = {
    "_compact_identifier", "_identifier_in_record",
    "_gmail_search_queries", "_message_contains_identifier", "search_account",
}
functions = [node for node in parsed.body if isinstance(node, ast.FunctionDef)
             and node.name in names]
assert len(functions) == len(names)

class StubHTTPException(Exception):
    def __init__(self, status_code, detail):
        self.status_code = status_code
        self.detail = detail

class StubLogger:
    def info(self, *args):
        pass

def decode_urlsafe(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))

def encode_mail(text):
    return base64.urlsafe_b64encode(text.encode("utf-8")).decode("ascii")

scope = {
    "re": re, "urllib": urllib, "html": html,
    "time": time, "GMAIL_SEARCH_BUDGET_SECONDS": 85,
    "GMAIL_SEARCH_MAX_MESSAGES": 100,
    "ThreadPoolExecutor": ThreadPoolExecutor, "as_completed": as_completed,
    "Any": object, "decode_urlsafe": decode_urlsafe, "strip_html": lambda x: x,
    "HTTPException": StubHTTPException, "logger": StubLogger(),
}
exec(compile(ast.Module(body=functions, type_ignores=[]), "<gmail-tests>", "exec"), scope)
compact = scope["_compact_identifier"]
matches = scope["_identifier_in_record"]
query_list = scope["_gmail_search_queries"]
contains = scope["_message_contains_identifier"]
search = scope["search_account"]

tracking = "GFUS01073037638977"
assert compact("GFUS-0107 3037 638977") == tracking
assert query_list(tracking)[0] == (f'"{tracking}"', True)
assert any("from:temuemail.com" in q for q, _ in query_list(tracking))

linked = {
    "id": "linked", "subject": "Temu - Your package is delivered",
    "body": "Your order is on its way.",
    "linkTargets": ["https://gofo.example/track?number=GFUS01073037638977"],
}
unrelated = {
    "id": "unrelated", "subject": "Other delivered order",
    "body": "Delivered to your address.",
    "linkTargets": ["https://gofo.example/track?number=GFUS99999999999999"],
}
assert matches(linked, tracking)
assert not matches(unrelated, tracking)

def mime_row(id, code):
    # The code is only in href, not visible plain text. Double encoded href
    # must still be recognized after decoding MIME and URL values.
    markup = f'<a href="https://ship.example/?tracking={urllib.parse.quote(urllib.parse.quote(code))}">Track</a>'
    return {"id": id, "payload": {"headers": [
        {"name": "Subject", "value": "Your Temu order"}],
        "body": {"data": encode_mail(markup)},
    }}
assert contains(mime_row("linked", tracking), tracking)
assert not contains(mime_row("unrelated", "GFUS99999999999999"), tracking)

queries_seen = []
def fake_gmail_json(path, token):
    if path.startswith("messages?"):
        args = urllib.parse.parse_qs(path.split("?", 1)[1])
        q = args.get("q", [""])[0]
        queries_seen.append(q)
        assert args.get("includeSpamTrash") == ["true"]
        if "from:temuemail.com" in q:
            if args.get("pageToken", [""])[0] == "second":
                return {"messages": [{"id": "linked"}]}
            return {"messages": [{"id": "unrelated"}], "nextPageToken": "second"}
        return {"messages": []}
    name = path.split("/", 1)[1].split("?", 1)[0]
    return mime_row(name, tracking if name == "linked" else "GFUS99999999999999")

def fake_record(msg, token, account_id, source_email):
    return linked if msg["id"] == "linked" else unrelated

scope["gmail_json"] = fake_gmail_json
scope["record"] = fake_record
found = search(1, "connected@example.com", "fake-token", tracking)
assert [x["id"] for x in found] == ["linked"], found
assert queries_seen[0] == f'"{tracking}"'
assert queries_seen.count(next(q for q in queries_seen if "from:temuemail.com" in q)) == 2

# No broad fallback can pass an unrelated email off as a valid tracking.
scope["gmail_json"] = lambda path, token: (
    {"messages": [{"id": "unrelated"}]} if path.startswith("messages?")
    else mime_row("unrelated", "GFUS99999999999999")
)
assert search(1, "connected@example.com", "fake-token", tracking) == []

# Message fetch failures should not become a false "No encontrado".
def failed_gmail_json(path, token):
    if path.startswith("messages?"):
        return {"messages": [{"id": "unavailable"}]}
    raise RuntimeError("read failed")
scope["gmail_json"] = failed_gmail_json
try:
    search(1, "connected@example.com", "fake-token", tracking)
    raise AssertionError("Expected retryable Gmail read error")
except StubHTTPException as exc:
    assert exc.status_code == 503

oauth_src = Path(__file__).with_name("gmail_oauth.py").read_text(encoding="utf-8")
oauth_ast = ast.parse(oauth_src)
scoped = next(n for n in oauth_ast.body if isinstance(n, ast.FunctionDef)
              and n.name == "active_account_tokens")
accounts = [
    {"id": 1, "client_id": "", "email": "shared@example.com",
     "refresh_token": "a", "access_token": ""},
    {"id": 2, "client_id": "client-1", "email": "one@example.com",
     "refresh_token": "b", "access_token": ""},
    {"id": 3, "client_id": "client-2", "email": "two@example.com",
     "refresh_token": "c", "access_token": ""},
]
auth_scope = {
    "accounts_rows": lambda enabled_only: accounts,
    "access_token_for_account": lambda id: f"token-{id}",
    "HTTPException": StubHTTPException,
}
exec(compile(ast.Module(body=[scoped], type_ignores=[]), "<oauth-tests>", "exec"), auth_scope)
assert [a[0] for a in auth_scope["active_account_tokens"]("client-1")] == [1, 2]
assert [a[0] for a in auth_scope["active_account_tokens"]("client-2")] == [1, 3]
assert [a[0] for a in auth_scope["active_account_tokens"]("")] == [1, 2, 3]

# Cache keys must not be re-used for an unscoped versus scoped search.
reconstruction_function = next(node for node in parsed.body
    if isinstance(node, ast.FunctionDef) and node.name == "reconstruct")
body = ast.get_source_segment(source, reconstruction_function)
assert "seed = tracking.strip() or order.strip()" in body
assert "if account_errors and not records:" in body
assert "[client_token.strip(), client_id.strip(), order, track]" in source

print("Gmail tracking/search scope regression tests passed.")
