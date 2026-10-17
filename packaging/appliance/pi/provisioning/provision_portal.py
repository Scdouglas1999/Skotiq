#!/usr/bin/env python3
"""Skotiq Pi appliance -- captive Wi-Fi provisioning portal.

A deliberately tiny, stdlib-only HTTP server run by
skotiq-netprovision.sh while the fallback hotspot is up.

Contract with the shell script:
  * serve the credentials form on 0.0.0.0:80 (every GET path gets the form
    -- combined with the dnsmasq-shared.d wildcard DNS this triggers the
    phone OS captive-portal sheet);
  * answer the common captive-portal probe URLs with a 302 to / so iOS /
    Android open the sheet instead of silently marking the network dead;
  * on POST /connect, write "<ssid>\n<psk>" to --creds-file and exit 0.
    The SHELL script owns all nmcli state changes (tearing down the AP
    here would cut our own response off mid-flight);
  * --status-file, when present, holds a one-line error from the previous
    join attempt and is rendered above the form.

No TLS, no auth: this runs only on the isolated 10.42.0.x hotspot whose
WPA2 password is on the device label, for the seconds it takes to enter
home Wi-Fi credentials. Keep it boring.
"""

import argparse
import html
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CREDS_FILE = None
STATUS_FILE = None

# Probe paths used by phone OSes to detect captive portals.
_PROBE_PATHS = (
    "/generate_204", "/gen_204",            # Android
    "/hotspot-detect.html",                  # iOS/macOS
    "/connecttest.txt", "/ncsi.txt",         # Windows
    "/canonical.html", "/success.txt",       # Firefox/NM
)

_PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Skotiq setup</title>
<style>
  body {{ font-family: -apple-system, system-ui, sans-serif; margin: 0;
         background: #0d1117; color: #e6edf3; }}
  .card {{ max-width: 26rem; margin: 8vh auto; padding: 1.5rem;
           background: #161b22; border-radius: 12px; }}
  h1 {{ font-size: 1.3rem; margin-top: 0; }}
  label {{ display: block; margin: .8rem 0 .25rem; font-size: .9rem; }}
  input, select {{ width: 100%; padding: .6rem; border-radius: 8px;
           border: 1px solid #30363d; background: #0d1117; color: inherit;
           box-sizing: border-box; font-size: 1rem; }}
  button {{ width: 100%; margin-top: 1.2rem; padding: .7rem;
            border: none; border-radius: 8px; background: #7c5cff;
            color: white; font-size: 1rem; }}
  .err {{ background: #3d1d20; border: 1px solid #f85149; padding: .6rem;
          border-radius: 8px; font-size: .9rem; }}
  .hint {{ color: #8b949e; font-size: .8rem; }}
</style></head><body>
<div class="card">
  <h1>Skotiq &mdash; connect to your Wi-Fi</h1>
  {error}
  <form method="post" action="/connect">
    <label for="ssid">Network</label>
    {ssid_input}
    <label for="psk">Password</label>
    <input id="psk" name="psk" type="password" autocomplete="off">
    <p class="hint">Leave the password empty for an open network.</p>
    <button type="submit">Join network</button>
  </form>
  <p class="hint">After joining, this hotspot disappears and the
  Skotiq app will find the device on your home network.</p>
</div></body></html>"""

_SUBMITTED = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Skotiq setup</title></head>
<body style="font-family: system-ui; background:#0d1117; color:#e6edf3">
<div style="max-width:26rem; margin:8vh auto; padding:1.5rem">
<h1>Joining &ldquo;{ssid}&rdquo;&hellip;</h1>
<p>The setup hotspot is shutting down. Reconnect your phone to your own
Wi-Fi. If the device cannot join (wrong password / out of range), the
<b>Skotiq-…</b> hotspot will reappear within a minute &mdash; join it
again to retry.</p>
</div></body></html>"""


def _scan_ssids():
    """Best-effort SSID list for a dropdown; falls back to a text input.

    `--rescan no`: the interface is in AP mode, a rescan would fail or
    bounce the hotspot. NM serves its pre-hotspot scan cache instead.
    """
    try:
        out = subprocess.run(
            ["nmcli", "-t", "-f", "SSID", "device", "wifi", "list",
             "--rescan", "no"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        seen, ssids = set(), []
        for line in out.splitlines():
            s = line.strip()
            if s and not s.startswith("Skotiq-") and s not in seen:
                seen.add(s)
                ssids.append(s)
        return ssids
    except Exception:
        return []


def _form_page():
    error = ""
    if STATUS_FILE:
        try:
            with open(STATUS_FILE, encoding="utf-8") as f:
                msg = f.read().strip()
            if msg:
                error = '<p class="err">%s</p>' % html.escape(msg)
        except OSError:
            pass

    ssids = _scan_ssids()
    if ssids:
        opts = "".join(
            '<option value="%s">%s</option>'
            % (html.escape(s, quote=True), html.escape(s))
            for s in ssids
        )
        ssid_input = (
            '<select id="ssid" name="ssid">%s</select>'
            '<p class="hint">Network missing? Power-cycle the device near '
            "your router and try again.</p>" % opts
        )
    else:
        ssid_input = ('<input id="ssid" name="ssid" type="text" '
                      'placeholder="Your Wi-Fi name" required>')
    return _PAGE.format(error=error, ssid_input=ssid_input)


class Handler(BaseHTTPRequestHandler):
    server_version = "SkotiqSetup/1.0"

    def _send_html(self, body, code=200):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802 (stdlib naming)
        path = urllib.parse.urlsplit(self.path).path
        if path in _PROBE_PATHS:
            # 302 (not 204/success) => OS shows the captive-portal sheet.
            self.send_response(302)
            self.send_header("Location", "http://10.42.0.1/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send_html(_form_page())

    def do_POST(self):  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        if path != "/connect":
            self._send_html(_form_page(), code=404)
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length > 4096:
            self._send_html(_form_page(), code=413)
            return
        fields = urllib.parse.parse_qs(
            self.rfile.read(length).decode("utf-8", "replace"))
        ssid = (fields.get("ssid") or [""])[0].strip()
        psk = (fields.get("psk") or [""])[0]
        if not ssid:
            self._send_html(_form_page(), code=400)
            return

        with open(CREDS_FILE, "w", encoding="utf-8") as f:
            f.write(ssid + "\n" + psk + "\n")

        self._send_html(_SUBMITTED.format(ssid=html.escape(ssid)))
        # Creds handed off; the shell script takes over nmcli. Shut down
        # from another thread (shutdown() from the handler thread blocks).
        import threading
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, fmt, *args):
        sys.stderr.write("portal: %s\n" % (fmt % args))


def main():
    global CREDS_FILE, STATUS_FILE
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--creds-file", required=True)
    ap.add_argument("--status-file", default=None)
    ap.add_argument("--port", type=int, default=80)
    args = ap.parse_args()
    CREDS_FILE = args.creds_file
    STATUS_FILE = args.status_file

    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    sys.stderr.write("portal: serving on port %d\n" % args.port)
    srv.serve_forever()  # returns after shutdown() in do_POST
    srv.server_close()


if __name__ == "__main__":
    main()
