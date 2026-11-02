#!/usr/bin/env python3
"""fleet-app-setup.py — create the fleet GitHub App via the manifest flow.

The fleet app is the single machine identity for a whole fleet of server
repos: the self-hosted Renovate runner authenticates as it, the weekly
update-pipeline check mints read tokens from it, and ghcr.io digest lookups
use its installation tokens. Created ONCE per operator, then installed on
each organisation with one click (GitHub provides no API for app creation or
installation — this script automates everything around those two clicks).

Usage:
    python3 scripts/fleet-app-setup.py [--name my-fleet-bot] [--port 8377]

What happens:
 1. Serves a page on localhost with the pre-filled app manifest; your browser
    POSTs it to github.com/settings/apps/new (your session, your review —
    this script never sees GitHub credentials).
 2. You click "Create GitHub App" on GitHub's own confirmation page.
 3. GitHub redirects your browser back to localhost with a one-time code;
    the script exchanges it (POST /app-manifests/{code}/conversions) for the
    app id, slug and private key.
 4. The private key lands in ~/.ssh/<name>.pem (mode 600). Store the id/slug
    in your update-pipeline-state runbook; add the key as an Actions secret
    where workflows need to mint tokens.

Afterwards, install the app per organisation (the one unavoidable click):
    https://github.com/apps/<slug>/installations/new
"""
import argparse
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PAGE = """<!doctype html><meta charset="utf-8">
<title>Create fleet GitHub App</title>
<body style="font-family: system-ui; max-width: 40em; margin: 4em auto;">
<h2>Create the fleet GitHub App</h2>
<p>This posts the manifest below to GitHub. On the next page press
<b>Create GitHub App</b> (rename it there first if you like), and you'll be
redirected back here automatically.</p>
<form action="https://github.com/settings/apps/new" method="post">
  <input type="hidden" name="manifest" id="manifest">
  <button type="submit" style="font-size: 1.2em; padding: .5em 1em;">
    Continue to GitHub &rarr;</button>
</form>
<pre style="background:#f6f8fa; padding:1em; overflow-x:auto;" id="show"></pre>
<script>
  const m = %s;
  document.getElementById('manifest').value = JSON.stringify(m);
  document.getElementById('show').textContent = JSON.stringify(m, null, 2);
</script>
</body>"""


def manifest(name: str, port: int) -> dict:
    return {
        "name": name,
        "url": "https://github.com/uppertoe/vps-base-template",
        # Public so the app can be installed on any organisation you admin;
        # only you hold the private key.
        "public": True,
        "redirect_url": f"http://127.0.0.1:{port}/callback",
        # Renovate needs the four writes; the drift check and GHCR lookups
        # ride the read permissions. Nothing else.
        "default_permissions": {
            "checks": "read",
            "statuses": "read",
            "contents": "write",
            "issues": "write",
            "pull_requests": "write",
            "workflows": "write",
            "actions": "read",
            "packages": "read",
            "metadata": "read",
        },
        "default_events": [],
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="fleet-bot")
    ap.add_argument("--port", type=int, default=8377)
    args = ap.parse_args()

    code_holder: dict = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):  # quiet
            pass

        def _send(self, body, status=200):
            data = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/":
                self._send(PAGE % json.dumps(manifest(args.name, args.port)))
            elif url.path == "/callback":
                code = parse_qs(url.query).get("code", [""])[0]
                if code:
                    code_holder["code"] = code
                    self._send("<h2>Done — app created.</h2>"
                               "<p>Return to the terminal.</p>")
                else:
                    self._send("<h2>Missing ?code param</h2>", 400)
            else:
                self._send("not found", 404)

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Open http://127.0.0.1:{args.port} in your browser and click through.")
    while "code" not in code_holder:
        server.handle_request()

    req = urllib.request.Request(
        f"https://api.github.com/app-manifests/{code_holder['code']}/conversions",
        method="POST", headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req) as r:
        app = json.load(r)

    pem_path = os.path.expanduser(f"~/.ssh/{app['slug']}.pem")
    fd = os.open(pem_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(app["pem"])

    print(json.dumps({k: app[k] for k in ("id", "slug", "html_url")}, indent=2))
    print(f"private key -> {pem_path} (mode 600; add as an Actions secret where needed)")
    print(f"install per org: https://github.com/apps/{app['slug']}/installations/new")
    print("record the id/slug in scripts/update-pipeline-state.json's runbook")


if __name__ == "__main__":
    main()
