#!/usr/bin/env bash
#
# Install the Prism download service on a Debian/Ubuntu server.
# Run as root, on the server:
#
#   ./server/install.sh
#
# Afterwards, deploy the site with --with-caddy so Caddy picks up the /api
# route, then paste the token this prints into the app's Library → Download
# from YouTube panel.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${VENV:-/opt/prism-venv}"
STATE="${STATE:-/var/lib/prism}"
CONF="${CONF:-/etc/prism}"
UNIT=/etc/systemd/system/prism-downloader.service

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

newtoken() {
  # Overwrite in place so ownership and mode survive; the service user can read
  # /etc/prism but not write to it, so the file must never be removed.
  mkdir -p "$CONF"
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$CONF/token"
  chown root:prism "$CONF/token" 2>/dev/null || true
  chmod 640 "$CONF/token"
}

if [ "${1:-}" = "--rotate-token" ]; then
  id -u prism >/dev/null 2>&1 || { echo "service is not installed yet — run without arguments first" >&2; exit 1; }
  newtoken
  systemctl restart prism-downloader 2>/dev/null || true
  say "token rotated — every browser must reconnect with the new one:"
  echo
  echo "      $(cat "$CONF/token")"
  echo
  exit 0
fi

say "installing python venv tooling and ffmpeg"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  # ffmpeg is required: yt-dlp uses it to extract and tag the audio.
  apt-get install -y --no-install-recommends python3 python3-venv ffmpeg >/dev/null
else
  echo "warning: not apt-based — ensure python3, python3-venv and ffmpeg are present" >&2
fi

say "creating service user and directories"
id -u prism >/dev/null 2>&1 || useradd --system --home "$STATE" --shell /usr/sbin/nologin prism
mkdir -p "$STATE/media" "$CONF"
chown -R prism:prism "$STATE"
chown root:prism "$CONF"
chmod 750 "$CONF"

say "creating venv at $VENV"
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet --upgrade yt-dlp
say "yt-dlp $("$VENV/bin/python" -c 'import yt_dlp;print(yt_dlp.version.__version__)')"

say "creating the API token"
# Generated here, as root. The service user can read /etc/prism but not write
# to it, so letting the daemon create this itself would fail on first start.
# Existing tokens are kept, so re-running the installer does not lock out
# browsers that are already connected.
[ -s "$CONF/token" ] || newtoken
chown root:prism "$CONF/token"
chmod 640 "$CONF/token"

say "installing systemd unit"
sed "s|/opt/visualmental|$REPO|g" "$REPO/server/prism-downloader.service" > "$UNIT"
systemctl daemon-reload
systemctl enable --now prism-downloader

sleep 2
if ! systemctl is-active --quiet prism-downloader; then
  echo "service failed to start:" >&2
  journalctl -u prism-downloader -n 30 --no-pager >&2
  exit 1
fi

# The daemon writes the token on first start.
TOKEN="$(cat "$CONF/token" 2>/dev/null || true)"
chown root:prism "$CONF/token" 2>/dev/null || true
chmod 640 "$CONF/token" 2>/dev/null || true

say "service is running on 127.0.0.1:8770"
echo
echo "  Health:  curl -s localhost:8770/api/health"
echo "  Logs:    journalctl -u prism-downloader -f"
echo "  Update:  $VENV/bin/pip install -U yt-dlp && systemctl restart prism-downloader"
echo
echo "  Paste this token into Library → Download from YouTube:"
echo
echo "      $TOKEN"
echo
echo "  Then redeploy so Caddy routes /api to the service:"
echo "      $REPO/deploy/deploy.sh --local --with-caddy"
