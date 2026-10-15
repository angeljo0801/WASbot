"""Offline regression tests for the on-demand Gmail permission diagnostic."""
import ast
import sqlite3
from pathlib import Path

source = Path(__file__).with_name("gmail_oauth.py").read_text(encoding="utf-8")
parsed = ast.parse(source)
names = {"_classify_gmail_check_error", "_diagnose_gmail_account"}
funcs = [n for n in parsed.body if isinstance(n, ast.FunctionDef) and n.name in names]
assert len(funcs) == len(names)

class StubHTTPException(Exception):
    def __init__(self, status_code, detail):
        self.status_code, self.detail = status_code, detail

requests = []
def fake_json(url, headers=None):
    assert url == "https://gmail.googleapis.com/gmail/v1/users/me/profile"
    assert headers == {"Authorization": "Bearer test-access-token"}
    requests.append(url)
    return {"emailAddress": "not-used@example.test", "messagesTotal": 8}

scope = {
    "Any": object, "sqlite3": sqlite3, "HTTPException": StubHTTPException,
    "CLIENT_ID": "client", "CLIENT_SECRET": "secret",
    "_public_account": lambda r: {
        "id": r["id"], "email": r["email"],
        "enabled": bool(r["enabled"]), "primary": bool(r["is_primary"]),
        "clientId": r.get("client_id", ""), "clientName": r.get("client_name", ""),
    },
    "access_token_for_account": lambda account_id: "test-access-token",
    "request_json": fake_json,
}
exec(compile(ast.Module(body=funcs, type_ignores=[]), "<diagnostics>", "exec"), scope)
diagnose = scope["_diagnose_gmail_account"]
classify = scope["_classify_gmail_check_error"]

account = {
    "id": 1, "email": "example@example.test", "enabled": 1,
    "is_primary": 1, "client_id": "", "client_name": "",
    "refresh_token": "private-secret", "access_token": "private-access",
}
good = diagnose(account)
assert good["status"] == "authorized"
assert good["email"] == account["email"]
assert len(requests) == 1
assert "private" not in str(good)
assert "test-access-token" not in str(good)

requests.clear()
disabled = diagnose({**account, "enabled": 0})
assert disabled["status"] == "disabled" and not requests

not_connected = diagnose({**account, "refresh_token": "", "access_token": ""})
assert not_connected["status"] == "not_connected" and not requests
assert diagnose({**account, "refresh_token": ""})["status"] == "expired"

assert classify('{"error":"invalid_grant"}')[0] == "expired"
assert classify("HTTP 403 insufficientPermissions")[0] == "missing_permissions"
assert classify("API has not been used in project")[0] == "configuration_error"
assert classify("HTTP 429 quota exceeded")[0] == "temporary_error"

for detail, expected in [
    ('{"error":"invalid_grant"}', "expired"),
    ('HTTP 403 insufficientPermissions', "missing_permissions"),
    ('Google API error: timeout', "temporary_error"),
]:
    scope["access_token_for_account"] = lambda account_id, d=detail: (
        (_ for _ in ()).throw(StubHTTPException(502, d))
    )
    result = diagnose(account)
    assert result["status"] == expected, (detail, result)
    assert "private-secret" not in str(result)

scope["access_token_for_account"] = lambda account_id: "test-access-token"
scope["request_json"] = lambda url, headers=None: (
    (_ for _ in ()).throw(StubHTTPException(502, "401 invalid authentication credentials"))
)
assert diagnose(account)["status"] == "expired"

print("Gmail permission diagnostics regression tests passed.")
