#!/usr/bin/env python3
"""
Prism download daemon — a small authenticated HTTP API in front of yt-dlp.

Runs on the VPS behind Caddy, which serves the page and reverse-proxies /api
to this process. Binds to localhost by default: it is not meant to face the
internet directly.

Two things keep this from being an open proxy that strangers can point at
arbitrary URLs to burn your bandwidth:
  * every request needs the bearer token from PRISM_TOKEN_FILE
  * URLs must be on the PRISM_ALLOW_HOSTS allowlist (YouTube by default)

Environment:
  PRISM_MEDIA        where audio lands            (default /var/lib/prism/media)
  PRISM_TOKEN_FILE   shared secret                (default /etc/prism/token)
  PRISM_HOST/PORT    bind address                 (default 127.0.0.1:8770)
  PRISM_WORKERS      concurrent downloads         (default 2)
  PRISM_MAX_ITEMS    cap on one playlist request  (default 200)
  PRISM_MAX_QUEUE    cap on pending jobs          (default 500)
  PRISM_ALLOW_HOSTS  comma-separated host suffixes, or "*" to allow anything
"""

import json
import os
import queue
import secrets
import shutil
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, unquote

MEDIA = Path(os.environ.get("PRISM_MEDIA", "/var/lib/prism/media"))
TOKEN_FILE = Path(os.environ.get("PRISM_TOKEN_FILE", "/etc/prism/token"))
HOST = os.environ.get("PRISM_HOST", "127.0.0.1")
PORT = int(os.environ.get("PRISM_PORT", "8770"))
WORKERS = int(os.environ.get("PRISM_WORKERS", "2"))
MAX_ITEMS = int(os.environ.get("PRISM_MAX_ITEMS", "200"))
MAX_QUEUE = int(os.environ.get("PRISM_MAX_QUEUE", "500"))
ALLOW_HOSTS = [h.strip().lower() for h in os.environ.get(
    "PRISM_ALLOW_HOSTS",
    "youtube.com,youtu.be,music.youtube.com").split(",") if h.strip()]

JOBS = {}
JOBS_LOCK = threading.Lock()
WORK = queue.Queue()


# ----------------------------------------------------------------- helpers --

def load_token() -> str:
    """Read the shared secret, generating one on first run."""
    if TOKEN_FILE.exists():
        tok = TOKEN_FILE.read_text().strip()
        if tok:
            return tok
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    tok = secrets.token_urlsafe(32)
    TOKEN_FILE.write_text(tok + "\n")
    try:
        TOKEN_FILE.chmod(0o600)
    except OSError:
        pass
    print(f"[prismd] generated new token at {TOKEN_FILE}", flush=True)
    return tok


TOKEN = load_token()


def host_allowed(url: str) -> bool:
    if ALLOW_HOSTS == ["*"]:
        return True
    try:
        p = urlparse(url)
    except ValueError:
        return False
    if p.scheme not in ("http", "https"):
        return False
    host = (p.hostname or "").lower()
    # Suffix match so www. and m. variants are covered without listing each.
    return any(host == h or host.endswith("." + h) for h in ALLOW_HOSTS)


def new_job(url: str, title: str = "") -> dict:
    job = {
        "id": uuid.uuid4().hex[:12],
        "url": url,
        "title": title or url,
        "uploader": "",
        "state": "queued",     # queued | running | done | error | cancelled
        "pct": 0.0,
        "error": "",
        "file": "",
        "ext": "",
        "thumb": "",
        "duration": 0,
        "bytes": 0,
        "added": time.time(),
    }
    with JOBS_LOCK:
        JOBS[job["id"]] = job
    return job


def set_job(jid: str, **kw):
    with JOBS_LOCK:
        j = JOBS.get(jid)
        if j:
            j.update(kw)


# ------------------------------------------------------------------ yt-dlp --

def ydl_base_opts() -> dict:
    return {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "noplaylist": False,
        "ignoreerrors": True,
        "retries": 3,
        "socket_timeout": 30,
    }


def resolve(url: str) -> list:
    """List a URL's entries without downloading. Flat, so playlists are cheap."""
    from yt_dlp import YoutubeDL

    opts = ydl_base_opts()
    opts.update({"extract_flat": "in_playlist", "skip_download": True})
    with YoutubeDL(opts) as y:
        info = y.extract_info(url, download=False)
    if not info:
        return []
    entries = info.get("entries")
    if entries is None:
        entries = [info]
    out = []
    for e in entries:
        if not e:
            continue
        vid = e.get("id") or ""
        link = e.get("url") or e.get("webpage_url") or ""
        # Flat playlist entries often carry a bare id rather than a full URL.
        if vid and not link.startswith("http"):
            link = f"https://www.youtube.com/watch?v={vid}"
        out.append({
            "id": vid,
            "url": link,
            "title": e.get("title") or vid or "(untitled)",
            "uploader": e.get("uploader") or e.get("channel") or "",
            "duration": int(e.get("duration") or 0),
        })
        if len(out) >= MAX_ITEMS:
            break
    return out


def download(job: dict):
    from yt_dlp import YoutubeDL

    jid = job["id"]

    def hook(d):
        if d.get("status") == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            got = d.get("downloaded_bytes") or 0
            pct = (got / total * 100.0) if total else 0.0
            # Leave headroom: extraction and tagging still have to run.
            set_job(jid, state="running", pct=min(95.0, pct * 0.95), bytes=got)
        elif d.get("status") == "finished":
            set_job(jid, pct=96.0)

    opts = ydl_base_opts()
    opts.update({
        "noplaylist": True,
        "format": "bestaudio/best",
        "outtmpl": str(MEDIA / "%(id)s.%(ext)s"),
        "writethumbnail": True,
        "progress_hooks": [hook],
        "postprocessors": [
            {"key": "FFmpegExtractAudio", "preferredcodec": "m4a", "preferredquality": "0"},
            {"key": "FFmpegMetadata"},
            {"key": "EmbedThumbnail", "already_have_thumbnail": False},
        ],
    })

    with YoutubeDL(opts) as y:
        info = y.extract_info(job["url"], download=True)
    if not info:
        raise RuntimeError("nothing was returned for that URL")
    if info.get("entries"):
        info = next((e for e in info["entries"] if e), None)
        if not info:
            raise RuntimeError("no downloadable entry")

    vid = info.get("id") or ""
    # The postprocessor renames the file, so find whatever landed for this id.
    audio = None
    for p in sorted(MEDIA.glob(f"{vid}.*")):
        if p.suffix.lower() in (".m4a", ".mp3", ".opus", ".ogg", ".webm", ".aac", ".flac", ".wav"):
            audio = p
            break
    if audio is None:
        raise RuntimeError("download finished but no audio file was produced")

    thumb = ""
    for p in MEDIA.glob(f"{vid}.*"):
        if p.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp"):
            thumb = p.name
            break

    set_job(jid,
            state="done", pct=100.0,
            file=audio.name, ext=audio.suffix.lstrip("."),
            thumb=thumb,
            title=info.get("title") or job["title"],
            uploader=info.get("uploader") or info.get("channel") or "",
            duration=int(info.get("duration") or 0),
            bytes=audio.stat().st_size)


def worker():
    while True:
        jid = WORK.get()
        try:
            with JOBS_LOCK:
                job = JOBS.get(jid)
            if not job or job["state"] == "cancelled":
                continue
            set_job(jid, state="running")
            download(job)
        except Exception as e:                                  # noqa: BLE001
            set_job(jid, state="error", error=str(e)[:400])
        finally:
            WORK.task_done()


# -------------------------------------------------------------------- HTTP --

class Handler(BaseHTTPRequestHandler):
    server_version = "prismd"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[prismd] {self.address_string()} {fmt % args}", flush=True)

    # -- plumbing --
    def _send(self, code, body=b"", ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def _authed(self) -> bool:
        got = self.headers.get("Authorization", "")
        if got.startswith("Bearer "):
            got = got[7:]
        else:
            got = self.headers.get("X-Prism-Token", "")
        return secrets.compare_digest(got.strip(), TOKEN)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > 1_000_000:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, OSError):
            return {}

    # -- routes --
    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/api/health":
            return self._json(200, {"ok": True, "service": "prismd",
                                    "allow": ALLOW_HOSTS, "workers": WORKERS})
        if not self._authed():
            return self._json(401, {"error": "bad or missing token"})

        if path == "/api/jobs":
            with JOBS_LOCK:
                jobs = sorted(JOBS.values(), key=lambda j: j["added"])
            return self._json(200, {"jobs": jobs})

        if path.startswith("/api/media/") or path.startswith("/api/art/"):
            name = unquote(path.rsplit("/", 1)[-1])
            return self._serve_file(name)

        return self._json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._authed():
            return self._json(401, {"error": "bad or missing token"})
        data = self._body()

        if path == "/api/resolve":
            url = (data.get("url") or "").strip()
            if not host_allowed(url):
                return self._json(400, {"error": f"host not allowed (permitted: {', '.join(ALLOW_HOSTS)})"})
            try:
                return self._json(200, {"items": resolve(url)})
            except Exception as e:                              # noqa: BLE001
                return self._json(500, {"error": str(e)[:400]})

        if path == "/api/jobs":
            urls = data.get("urls") or ([data["url"]] if data.get("url") else [])
            urls = [u.strip() for u in urls if isinstance(u, str) and u.strip()]
            if not urls:
                return self._json(400, {"error": "no urls given"})
            if len(urls) > MAX_ITEMS:
                return self._json(400, {"error": f"too many at once (max {MAX_ITEMS})"})
            if WORK.qsize() + len(urls) > MAX_QUEUE:
                return self._json(429, {"error": "queue is full, try again later"})
            bad = [u for u in urls if not host_allowed(u)]
            if bad:
                return self._json(400, {"error": f"host not allowed: {bad[0]}"})

            made = []
            for u in urls:
                j = new_job(u, data.get("titles", {}).get(u, ""))
                WORK.put(j["id"])
                made.append(j)
            return self._json(200, {"jobs": made})

        if path == "/api/clear":
            with JOBS_LOCK:
                for jid in [k for k, v in JOBS.items() if v["state"] in ("done", "error", "cancelled")]:
                    del JOBS[jid]
            return self._json(200, {"ok": True})

        if path == "/api/forget":
            # Drop a finished job and its files once the browser has stored it.
            jid = data.get("id") or ""
            with JOBS_LOCK:
                j = JOBS.pop(jid, None)
            if j:
                for nm in (j.get("file"), j.get("thumb")):
                    if nm:
                        try:
                            (MEDIA / nm).unlink()
                        except OSError:
                            pass
            return self._json(200, {"ok": True})

        return self._json(404, {"error": "not found"})

    # -- static media --
    def _serve_file(self, name: str):
        # Resolve inside MEDIA and reject anything that escapes it.
        target = (MEDIA / name).resolve()
        try:
            target.relative_to(MEDIA.resolve())
        except ValueError:
            return self._json(403, {"error": "forbidden"})
        if not target.is_file():
            return self._json(404, {"error": "not found"})

        ctype = {
            ".m4a": "audio/mp4", ".mp3": "audio/mpeg", ".opus": "audio/opus",
            ".ogg": "audio/ogg", ".webm": "audio/webm", ".flac": "audio/flac",
            ".wav": "audio/wav", ".aac": "audio/aac",
            ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".png": "image/png", ".webp": "image/webp",
        }.get(target.suffix.lower(), "application/octet-stream")

        size = target.stat().st_size
        rng = self.headers.get("Range", "")
        start, end = 0, size - 1
        partial = False
        if rng.startswith("bytes="):
            try:
                a, _, b = rng[6:].partition("-")
                start = int(a) if a else 0
                end = int(b) if b else size - 1
                start = max(0, start)
                end = min(size - 1, end)
                partial = start > 0 or end < size - 1
            except ValueError:
                partial = False
        if start > end:
            return self._json(416, {"error": "bad range"})

        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with target.open("rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(262144, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)


def main():
    MEDIA.mkdir(parents=True, exist_ok=True)
    try:
        import yt_dlp                                            # noqa: F401
    except ImportError:
        raise SystemExit("yt-dlp is not installed:  pip install yt-dlp")
    if not shutil.which("ffmpeg"):
        print("[prismd] WARNING: ffmpeg not found — audio extraction will fail", flush=True)

    for _ in range(max(1, WORKERS)):
        threading.Thread(target=worker, daemon=True).start()

    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[prismd] listening on http://{HOST}:{PORT}", flush=True)
    print(f"[prismd] media {MEDIA}  allow {ALLOW_HOSTS}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
