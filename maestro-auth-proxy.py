"""Login page + reverse proxy in front of the Maestro forge.

Why this exists
---------------
A Cloudflare tunnel may publish the forge to the internet, and Maestro
has **no authentication of its own**: /api/v1/generate drives the GPU,
/api/v1/outputs lists every clip, /docs documents the whole API. This proxy is
the only thing between the public internet and the forge.

It serves a real HTML login page (not the browser's native basic-auth dialog),
issues a signed HttpOnly session cookie, and proxies everything else through
to the forge.

    public  ->  cloudflared  ->  127.0.0.1:7861 (this)  ->  127.0.0.1:7860 (Maestro)

Credentials come from the environment only — never from this file, which is
published. Keep them in a 0600 env file outside the repository and point the
systemd unit at it with EnvironmentFile=. The proxy binds loopback only.

    MAESTRO_PROXY_USER   default: maestro
    MAESTRO_PROXY_PASS   required — no default; the proxy refuses to start without it
    MAESTRO_PROXY_TARGET default: http://127.0.0.1:7860
    MAESTRO_SESSION_HOURS default: 168 (7 days)

Fails closed: no password -> refuse to start.
HTTP Basic still works alongside the cookie, so `curl -u maestro:...` keeps
working for scripts and for the CLI checks in the smoke tests.
"""

import base64
import hashlib
import hmac
import html
import os
import sys
import time

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response, StreamingResponse

# --- login (from the environment only) --------------------------------------
# This is the ONLY thing between the public internet and an unauthenticated
# GPU + API. Set both in the unit's EnvironmentFile, then:
#     systemctl --user restart maestro-auth-proxy
USER = os.environ.get("MAESTRO_PROXY_USER") or "maestro"
PASSWORD = os.environ.get("MAESTRO_PROXY_PASS", "")
TARGET = os.environ.get("MAESTRO_PROXY_TARGET", "http://127.0.0.1:7860")
LISTEN_PORT = int(os.environ.get("MAESTRO_PROXY_PORT", "7861"))
SESSION_HOURS = int(os.environ.get("MAESTRO_SESSION_HOURS", "168"))
COOKIE = "maestro_session"
LOGIN_PATH = "/__login"

# Signing key derived from the password, so rotating the password
# invalidates every outstanding session automatically.
_SECRET = hashlib.sha256(f"maestro-proxy:{USER}:{PASSWORD}".encode()).digest()

TIMEOUT = httpx.Timeout(connect=15.0, read=None, write=30.0, pool=30.0)

if not PASSWORD or PASSWORD == "REPLACE_ME":
    sys.exit(
        "No password configured.\n"
        "Set MAESTRO_PROXY_PASS (an EnvironmentFile outside the repo).\n"
        "Refusing to start: the tunnel points here, so an empty password\n"
        "would publish an unauthenticated GPU + API to the internet."
    )

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
_client = httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=False)


# --- session token ---------------------------------------------------------
def _sign(payload: bytes) -> str:
    return base64.urlsafe_b64encode(hmac.new(_SECRET, payload, hashlib.sha256).digest()).rstrip(b"=").decode()


def _b64d(s: str) -> bytes:
    """urlsafe base64 decode, restoring the '=' padding we stripped on encode."""
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def _make_token() -> str:
    """Token = base64url(user:expiry) . HMAC-SHA256 over the *raw body*.

    Sign the same bytes in both directions — signing the base64 text here and
    the decoded body in _token_valid is a silent, permanent mismatch.
    """
    body = f"{USER}:{int(time.time()) + SESSION_HOURS * 3600}".encode()
    b64 = base64.urlsafe_b64encode(body).rstrip(b"=").decode()
    return f"{b64}.{_sign(body)}"


def _token_valid(token: str) -> bool:
    try:
        blob_b64, sig = token.split(".", 1)
        blob = _b64d(blob_b64)
        if not hmac.compare_digest(_sign(blob), sig):
            return False
        user, _, exp = blob.decode().partition(":")
        return hmac.compare_digest(user, USER) and int(exp) > time.time()
    except Exception:
        return False


def _basic_ok(request: Request) -> bool:
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("basic "):
        return False
    try:
        raw = base64.b64decode(header.split(None, 1)[1]).decode("utf-8", "replace")
    except Exception:
        return False
    name, _, secret = raw.partition(":")
    return hmac.compare_digest(name, USER) and hmac.compare_digest(secret, PASSWORD)


def _authed(request: Request) -> bool:
    cookie = request.cookies.get(COOKIE, "")
    if cookie and _token_valid(cookie):
        return True
    return _basic_ok(request)


# --- the login page --------------------------------------------------------
_LOGIN_CSS = """
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;
  background:#0b0b0e radial-gradient(1100px 620px at 50% -12%,#1a1410 0%,#0b0b0e 62%);
  font:15px/1.5 ui-sans-serif,-apple-system,'Segoe UI',Inter,system-ui,sans-serif;color:#e8e2d8}
.card{width:min(400px,92vw);padding:38px 34px 30px;border-radius:16px;
  background:rgba(20,18,16,.92);border:1px solid #2c2622;
  box-shadow:0 28px 70px rgba(0,0,0,.6),0 0 0 1px rgba(255,150,40,.05) inset}
.mark{width:52px;height:52px;margin:0 auto 18px;border-radius:13px;display:grid;place-items:center;
  background:linear-gradient(150deg,#ff8c1a,#c2410c);color:#160c04;font-weight:800;font-size:20px;
  letter-spacing:.5px;box-shadow:0 8px 26px rgba(255,120,20,.28)}
h1{margin:0 0 5px;font-size:20px;font-weight:650;text-align:center;letter-spacing:-.2px}
.sub{margin:0 0 26px;text-align:center;color:#8b8177;font-size:13px}
label{display:block;margin:0 0 7px;font-size:12px;font-weight:600;color:#a99e92;
  text-transform:uppercase;letter-spacing:.7px}
input{width:100%;padding:11px 13px;margin:0 0 17px;border-radius:9px;font-size:15px;
  background:#141210;border:1px solid #302925;color:#f2ece2;outline:none;transition:.15s}
input:focus{border-color:#ff8c1a;box-shadow:0 0 0 3px rgba(255,140,26,.16)}
button{width:100%;padding:12px;border:0;border-radius:9px;font-size:15px;font-weight:650;cursor:pointer;
  color:#1a0d02;background:linear-gradient(150deg,#ff9d2e,#ea6a0c);transition:.15s}
button:hover{filter:brightness(1.08)}
.err{margin:0 0 17px;padding:10px 13px;border-radius:8px;font-size:13.5px;
  background:rgba(220,38,38,.13);border:1px solid rgba(220,38,38,.4);color:#fca5a5}
.foot{margin:24px 0 0;padding-top:17px;border-top:1px solid #241f1c;
  text-align:center;font-size:11.5px;color:#6b625a;line-height:1.6}
"""


def _login_page(error: str = "", next_url: str = "/") -> HTMLResponse:
    err = f'<p class="err">{html.escape(error)}</p>' if error else ""
    nxt = html.escape(next_url or "/", quote=True)
    return HTMLResponse(
        f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Maestro — sign in</title><style>{_LOGIN_CSS}</style></head><body>
<form class="card" method="post" action="{LOGIN_PATH}?next={nxt}">
  <div class="mark">M</div>
  <h1>Maestro</h1>
  <p class="sub">Video forge</p>
  {err}
  <label for="u">Username</label>
  <input id="u" name="username" autocomplete="username" autofocus required
         value="{html.escape(USER, quote=True)}">
  <label for="p">Password</label>
  <input id="p" name="password" type="password" autocomplete="current-password" required>
  <button type="submit">Sign in</button>
  <p class="foot">Private tool. Access is logged.</p>
</form></body></html>"""
    )


# --- auth gate -------------------------------------------------------------
@app.middleware("http")
async def guard(request: Request, call_next):
    path = request.url.path

    # The login endpoints are reachable without a session, obviously.
    if path == LOGIN_PATH or path == "/__logout":
        return await call_next(request)
    # The tunnel's own health probes and the service worker must not be gated,
    # or the browser never gets a chance to render the login page.
    if path == "/healthz":
        return Response("ok", media_type="text/plain")

    if _authed(request):
        return await call_next(request)

    wants_html = "text/html" in (request.headers.get("accept") or "")
    if wants_html:
        target = request.url.path + (f"?{request.url.query}" if request.url.query else "")
        return RedirectResponse(f"{LOGIN_PATH}?next={target}", status_code=302)
    return Response(
        b"unauthorized\n", status_code=401, media_type="text/plain",
        headers={"WWW-Authenticate": 'Basic realm="Maestro"'},
    )


@app.get("/healthz")
async def healthz():
    return Response("ok", media_type="text/plain")


@app.get(LOGIN_PATH)
async def login_form(request: Request):
    if _authed(request):
        return RedirectResponse(request.query_params.get("next") or "/", status_code=302)
    return _login_page(next_url=request.query_params.get("next", "/"))


@app.post(LOGIN_PATH)
async def login_submit(request: Request):
    form = await request.form()
    name = str(form.get("username", ""))
    secret = str(form.get("password", ""))
    nxt = str(form.get("next") or request.query_params.get("next") or "/")
    if not nxt.startswith("/"):
        nxt = "/"  # never redirect off-site

    ok = hmac.compare_digest(name, USER) and hmac.compare_digest(secret, PASSWORD)
    if not ok:
        return _login_page("Wrong username or password.", next_url=nxt)

    response = RedirectResponse(nxt, status_code=302)
    response.set_cookie(
        COOKIE, _make_token(), max_age=SESSION_HOURS * 3600,
        httponly=True, samesite="lax", path="/", secure=False,
    )
    return response


@app.get("/__logout")
async def logout():
    response = RedirectResponse(LOGIN_PATH, status_code=302)
    response.delete_cookie(COOKIE, path="/")
    return response


# --- proxy -----------------------------------------------------------------
@app.api_route(
    "/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"],
)
async def forward(path: str, request: Request):
    url = f"{TARGET}/{path}"
    if request.url.query:
        url = f"{url}?{request.url.query}"

    body = await request.body()
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower()
        not in ("host", "authorization", "content-length", "connection", "cookie")
    }
    headers["host"] = "127.0.0.1:7860"

    req = _client.build_request(
        request.method, url, headers=headers, content=body or None
    )
    upstream = await _client.send(req, stream=True)

    async def relay():
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await upstream.aclose()

    # Pass Content-Range / Accept-Ranges through untouched, or the <video>
    # element cannot seek. Strip only the hop-by-hop and re-encoding headers.
    response_headers = {
        k: v
        for k, v in upstream.headers.items()
        if k.lower()
        not in ("content-encoding", "content-length", "transfer-encoding", "connection")
    }
    return StreamingResponse(
        relay(), status_code=upstream.status_code, headers=response_headers
    )


@app.on_event("shutdown")
async def _close():
    await _client.aclose()


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=LISTEN_PORT, log_level="warning")
