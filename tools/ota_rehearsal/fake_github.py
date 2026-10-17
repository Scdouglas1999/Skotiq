#!/usr/bin/env python3
"""A stand-in for the parts of GitHub the updater talks to.

Answers the three hosts a shipped build contacts during an update, on one
TLS port, with the same shapes GitHub uses:

  api.github.com                 GET /repos/<o>/<r>/releases/latest
                                 GET /repos/<o>/<r>/releases?per_page=N
  github.com                     GET /<o>/<r>/releases/download/<tag>/<asset>
                                     -> 302 to objects.githubusercontent.com
  objects.githubusercontent.com  GET /<tag>/<asset>  (the bytes)

What it serves is read from a scenario JSON file on EVERY request, so the
driver switches scenarios by rewriting that file; the server never restarts.

  {
    "owner": "Scdouglas1999", "repo": "Skotiq",
    "releases": [                      # newest first, as GitHub lists them
      {"tag_name": "v7.1.91", "name": "...", "body": "...",
       "prerelease": false, "draft": false,
       "assets": [{"name": "manifest-linux-x64.json", "path": "/abs/file"},
                  {"name": "skotiq-7.1.91-linux-x64.zip", "path": "..."}]}
    ],
    "latest_status": 200,              # e.g. 404 for "no release"
    "download_mode": {"<asset name>": "truncate" | "drop" | "stall"}
  }

download_mode:
  truncate  Content-Length says the full size, half the bytes are sent,
            then the connection is closed.
  drop      the first 64 KiB are sent, then the socket is shut down hard.
  stall     headers and 64 KiB are sent, then nothing until the client goes.

Every request is appended to --log as one JSON line, which is the evidence
trail the rehearsal report cites.
"""

import argparse
import json
import os
import socket
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ARGS = None
LOG_LOCK = threading.Lock()


def load_scenario():
    with open(ARGS.scenario, "r", encoding="utf-8") as fh:
        return json.load(fh)


def log(entry):
    entry["t"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    with LOG_LOCK:
        with open(ARGS.log, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")


def release_json(scn, rel):
    owner, repo = scn["owner"], scn["repo"]
    tag = rel["tag_name"]
    assets = []
    for i, a in enumerate(rel.get("assets", [])):
        size = os.path.getsize(a["path"]) if os.path.exists(a["path"]) else 0
        assets.append({
            "id": 1000 + i,
            "name": a["name"],
            "size": size,
            "content_type": "application/octet-stream",
            "state": "uploaded",
            "browser_download_url":
                f"https://github.com/{owner}/{repo}/releases/download/{tag}/{a['name']}",
        })
    return {
        "url": f"https://api.github.com/repos/{owner}/{repo}/releases/1",
        "html_url": f"https://github.com/{owner}/{repo}/releases/tag/{tag}",
        "id": 1,
        "tag_name": tag,
        "name": rel.get("name", tag),
        "body": rel.get("body", ""),
        "draft": rel.get("draft", False),
        "prerelease": rel.get("prerelease", False),
        "created_at": rel.get("published_at", "2026-09-26T00:00:00Z"),
        "published_at": rel.get("published_at", "2026-09-26T00:00:00Z"),
        "assets": assets,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _host(self):
        return (self.headers.get("Host") or "").split(":")[0].lower()

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        host = self._host()
        url = urlparse(self.path)
        scn = load_scenario()
        entry = {"host": host, "path": self.path}
        try:
            if host == "api.github.com":
                self._api(scn, url, entry)
            elif host == "github.com":
                self._redirect(scn, url, entry)
            elif host == "objects.githubusercontent.com":
                self._asset(scn, url, entry)
            else:
                entry["status"] = 421
                self._json(421, {"message": "unknown host"})
        finally:
            log(entry)

    def _api(self, scn, url, entry):
        prefix = f"/repos/{scn['owner']}/{scn['repo']}/releases"
        releases = [r for r in scn.get("releases", [])]
        if url.path == prefix + "/latest":
            status = scn.get("latest_status", 200)
            stable = [r for r in releases
                      if not r.get("draft") and not r.get("prerelease")]
            if status != 200 or not stable:
                entry["status"] = 404
                self._json(404, {"message": "Not Found"})
                return
            entry["status"] = 200
            entry["tag"] = stable[0]["tag_name"]
            self._json(200, release_json(scn, stable[0]))
        elif url.path == prefix:
            per_page = int(parse_qs(url.query).get("per_page", ["30"])[0])
            entry["status"] = 200
            self._json(200, [release_json(scn, r) for r in releases[:per_page]])
        else:
            entry["status"] = 404
            self._json(404, {"message": "Not Found"})

    def _redirect(self, scn, url, entry):
        # /<owner>/<repo>/releases/download/<tag>/<asset>
        parts = url.path.strip("/").split("/")
        if len(parts) != 6 or parts[2:4] != ["releases", "download"]:
            entry["status"] = 404
            self._json(404, {"message": "Not Found"})
            return
        tag, name = parts[4], parts[5]
        entry["status"] = 302
        location = f"https://objects.githubusercontent.com/{tag}/{name}"
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _find_asset(self, scn, tag, name):
        for rel in scn.get("releases", []):
            if rel["tag_name"] != tag:
                continue
            for a in rel.get("assets", []):
                if a["name"] == name:
                    return a["path"]
        return None

    def _asset(self, scn, url, entry):
        parts = url.path.strip("/").split("/")
        path = self._find_asset(scn, parts[0], parts[1]) if len(parts) == 2 else None
        if path is None or not os.path.exists(path):
            entry["status"] = 404
            self._json(404, {"message": "Not Found"})
            return
        size = os.path.getsize(path)
        mode = scn.get("download_mode", {}).get(parts[1], "normal")
        # The release CDN honors single open-ended ranges, and the updater
        # resumes a partial download with one, so answer them the same way.
        start = 0
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes=") and rng.endswith("-"):
            try:
                start = int(rng[len("bytes="):-1])
            except ValueError:
                start = 0
        if start >= size:
            start = 0
        entry.update({"size": size, "mode": mode, "range_start": start})
        if start:
            entry["status"] = 206
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        else:
            entry["status"] = 200
            self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(size - start))
        self.end_headers()
        sent = 0
        body = size - start
        limit = {"truncate": body // 2, "drop": 65536,
                 "stall": 65536}.get(mode, body)
        with open(path, "rb") as fh:
            fh.seek(start)
            while sent < limit:
                chunk = fh.read(min(1 << 16, limit - sent))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    entry["client_went_away_at"] = sent
                    return
                sent += len(chunk)
        entry["sent"] = sent
        self.wfile.flush()
        if mode == "stall":
            # Hold the connection open until the client gives up.
            time.sleep(ARGS.stall_seconds)
        if mode in ("truncate", "drop", "stall"):
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--port", type=int, default=443)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--stall-seconds", type=int, default=120)
    ARGS = ap.parse_args()

    server = ThreadingHTTPServer((ARGS.bind, ARGS.port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(ARGS.cert, ARGS.key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print(f"fake GitHub listening on {ARGS.bind}:{ARGS.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
