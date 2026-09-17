#!/usr/bin/env python3
"""One-time GitHub consent for one user.

    ./enroll.py alice

The name matters: it must be what {{user.sub}} resolves to for that person —
the `user_claim` on Warden's user auth role, which here is Keycloak's
preferred_username. Nothing validates the match until the first real request,
which then fails with "no credentials returned for '<name>' on mount 'github'".

The refresh token never leaves OpenBao. Warden is not involved in this step at
all: enrollment is between the person, GitHub, and the OAuth app engine.
"""

import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

if os.path.exists(".env"):
    for line in open(".env"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

BAO = f"http://127.0.0.1:{os.environ.get('BAO_PORT', '8200')}"
# Must match the OAuth App's registered callback URL exactly.
PORT = int(os.environ.get("ENROLL_PORT", "8765"))
REDIRECT = f"http://127.0.0.1:{PORT}/callback"


def bao(method, path, payload=None):
    req = urllib.request.Request(
        f"{BAO}/v1/{path}",
        data=json.dumps(payload).encode() if payload is not None else None,
        method=method,
    )
    req.add_header("X-Vault-Token", "root")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode()
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"\n{method} {path} failed ({e.code}): {e.read().decode()[:400]}\n")


def wait_for_code(state):
    """Catch the redirect GitHub sends back, checking state to bind the flow."""
    result = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            ok = q.get("state", [""])[0] == state and "code" in q
            body = (b"Enrolled. You can close this tab."
                    if ok else b"Unexpected callback: state mismatch or no code.")
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            if ok:
                result["code"] = q["code"][0]

        def log_message(self, *a):
            pass  # keep the terminal quiet

    server = HTTPServer(("127.0.0.1", PORT), Handler)
    while "code" not in result:
        server.handle_request()
    return result["code"]


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: ./enroll.py <username>   (e.g. alice)")
    user = sys.argv[1]
    state = secrets.token_hex(8)

    url = bao("PUT", "github/auth-code-url", {
        "server": "github",
        "state": state,
        "scopes": ["repo", "read:user"],
        "redirect_url": REDIRECT,
    })["data"]["url"]

    print(f"\n\033[1mOpen this and approve as {user}:\033[0m\n\n  {url}\n")
    try:
        webbrowser.open(url)
    except Exception:
        pass

    print(f"Waiting for the redirect on {REDIRECT} ...")
    code = wait_for_code(state)

    # redirect_url must match the one used to build the authorization URL.
    bao("PUT", f"github/creds/{user}", {
        "server": "github",
        "code": code,
        "redirect_url": REDIRECT,
    })

    print(f"\n\033[1m{user} enrolled.\033[0m The refresh token is in OpenBao at "
          f"github/creds/{user};\neach read there mints a current access token. "
          "Nothing was written to Warden.\n")
    print(f"Try it:  ./mcp-config.sh {user}")


if __name__ == "__main__":
    main()
