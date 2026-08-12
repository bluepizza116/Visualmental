#!/usr/bin/env bash
#
# Deploy Prism to a VPS running Caddy.
#
#   ./deploy/deploy.sh                 # upload index.html only
#   ./deploy/deploy.sh --with-caddy    # also install the site config + reload Caddy
#   ./deploy/deploy.sh --dry-run       # show what would happen, change nothing
#
# Override anything via the environment:
#   SSH_HOST=deploy@1.2.3.4 DOMAIN=example.com ./deploy/deploy.sh
#
# Uses your existing SSH access — no credentials are stored in this repo.

set -euo pipefail

SSH_HOST="${SSH_HOST:-root@163.245.220.226}"
DOMAIN="${DOMAIN:-visualmental.163-245-220-226.nip.io}"
WEB_ROOT="${WEB_ROOT:-/var/www/visualmental}"
SITES_DIR="${SITES_DIR:-/etc/caddy/sites}"
MAIN_CADDYFILE="${MAIN_CADDYFILE:-/etc/caddy/Caddyfile}"
SSH_OPTS="${SSH_OPTS:-}"

WITH_CADDY=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --with-caddy) WITH_CADDY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/index.html"
[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!! \033[0m%s\n' "$*" >&2; }

# In dry-run, print commands instead of running them.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '   \033[90m[dry-run]\033[0m %s\n' "$*"; else "$@"; fi
}
remote() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '   \033[90m[dry-run] ssh %s\033[0m %s\n' "$SSH_HOST" "$*";
  else ssh $SSH_OPTS "$SSH_HOST" "$@"; fi
}

say "host      $SSH_HOST"
say "domain    $DOMAIN"
say "web root  $WEB_ROOT"
[ "$DRY_RUN" -eq 1 ] && warn "dry run — nothing will be changed"

# --- 1. sanity-check the connection up front, so we fail before touching anything
if [ "$DRY_RUN" -eq 0 ]; then
  ssh $SSH_OPTS -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" true 2>/dev/null \
    || { echo "error: cannot SSH to $SSH_HOST non-interactively." >&2
         echo "       Check the host, your key, and that the agent is loaded." >&2; exit 1; }
fi

# --- 2. upload the page
say "creating $WEB_ROOT"
remote "mkdir -p '$WEB_ROOT'"

if command -v rsync >/dev/null 2>&1 && remote "command -v rsync >/dev/null 2>&1"; then
  say "uploading index.html (rsync)"
  run rsync -az --checksum -e "ssh $SSH_OPTS" "$SRC" "$SSH_HOST:$WEB_ROOT/index.html"
else
  warn "rsync unavailable on one side — falling back to scp"
  run scp $SSH_OPTS "$SRC" "$SSH_HOST:$WEB_ROOT/index.html"
fi

# Caddy runs as its own user and must be able to read the tree.
remote "chmod 755 '$WEB_ROOT' && chmod 644 '$WEB_ROOT/index.html'"

# --- 3. optionally install the site config
if [ "$WITH_CADDY" -eq 1 ]; then
  say "rendering Caddyfile for $DOMAIN"
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__WEB_ROOT__|$WEB_ROOT|g" "$REPO/deploy/Caddyfile" > "$TMP"

  remote "mkdir -p '$SITES_DIR' /var/log/caddy"
  say "installing $SITES_DIR/visualmental.caddyfile"
  run scp $SSH_OPTS "$TMP" "$SSH_HOST:$SITES_DIR/visualmental.caddyfile"

  # Only wire up the import if it isn't already there, and back up first.
  say "ensuring $MAIN_CADDYFILE imports $SITES_DIR"
  remote "set -e
    if ! grep -qF '$SITES_DIR/' '$MAIN_CADDYFILE' 2>/dev/null; then
      cp -a '$MAIN_CADDYFILE' '$MAIN_CADDYFILE.bak.\$(date +%Y%m%d%H%M%S)'
      printf '\nimport %s/*.caddyfile\n' '$SITES_DIR' >> '$MAIN_CADDYFILE'
      echo '   added import line (original backed up)'
    else
      echo '   import already present'
    fi"

  # Validate before reloading — a bad config should never take the site down.
  say "validating config"
  remote "caddy validate --adapter caddyfile --config '$MAIN_CADDYFILE'" \
    || { echo "error: caddy validate failed — NOT reloading. Restore from the .bak file if needed." >&2; exit 1; }

  say "reloading caddy"
  remote "systemctl reload caddy || systemctl restart caddy"
fi

say "done → https://$DOMAIN/"
if [ "$WITH_CADDY" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "   First request may take a few seconds while Let's Encrypt issues the cert."
  echo "   Watch it with: ssh $SSH_HOST journalctl -u caddy -f"
fi
