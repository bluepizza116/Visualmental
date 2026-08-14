#!/usr/bin/env bash
#
# Deploy Prism to a server running Caddy.
#
# From your own machine, over SSH:
#   ./deploy/deploy.sh                 # upload index.html only
#   ./deploy/deploy.sh --with-caddy    # also install the site config + reload Caddy
#
# Already logged into the server? Skip SSH entirely:
#   ./deploy/deploy.sh --local --with-caddy
#
#   ./deploy/deploy.sh --dry-run       # show what would happen, change nothing
#
# Put the whole site behind a password (needed before enabling auto-token, or
# anyone who loads the page holds working download credentials):
#   ./deploy/deploy.sh --local --with-caddy --protect=me:mypassword
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
LOCAL=0
PROTECT=""          # user:password — puts the whole site behind basic auth
NEED_PROTECT=0
for arg in "$@"; do
  case "$arg" in
    --with-caddy) WITH_CADDY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --local)      LOCAL=1 ;;
    --protect)    NEED_PROTECT=1 ;;
    --protect=*)  PROTECT="${arg#*=}" ;;
    -h|--help)    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# Runs a shell command on the target — over SSH, or right here under --local.
remote() {
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$LOCAL" -eq 1 ]; then printf '   \033[90m[dry-run] sh -c\033[0m %s\n' "$*"
    else printf '   \033[90m[dry-run] ssh %s\033[0m %s\n' "$SSH_HOST" "$*"; fi
    return 0
  fi
  if [ "$LOCAL" -eq 1 ]; then bash -c "$*"; else ssh $SSH_OPTS "$SSH_HOST" "$@"; fi
}

say "target    $([ "$LOCAL" -eq 1 ] && echo 'this machine (--local)' || echo "$SSH_HOST")"
say "domain    $DOMAIN"
say "web root  $WEB_ROOT"
[ "$DRY_RUN" -eq 1 ] && warn "dry run — nothing will be changed"

# --- 1. sanity-check access up front, so we fail before touching anything
if [ "$DRY_RUN" -eq 0 ] && [ "$LOCAL" -eq 0 ]; then
  command -v ssh >/dev/null 2>&1 \
    || { echo "error: no ssh client found." >&2
         echo "       If you are already logged into the server, run with --local instead." >&2; exit 1; }
  ssh $SSH_OPTS -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" true 2>/dev/null \
    || { echo "error: cannot SSH to $SSH_HOST non-interactively." >&2
         echo "       Check the host, your key, and that the agent is loaded." >&2
         echo "       If you are already ON that server, run with --local instead." >&2; exit 1; }
fi

# --- 2. upload the page
say "creating $WEB_ROOT"
remote "mkdir -p '$WEB_ROOT'"

if [ "$LOCAL" -eq 1 ]; then
  say "installing index.html"
  run install -m 644 "$SRC" "$WEB_ROOT/index.html"
elif command -v rsync >/dev/null 2>&1 && remote "command -v rsync >/dev/null 2>&1"; then
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
  # Check Caddy exists before editing any config — failing at the validate step
  # would leave the main Caddyfile already modified.
  remote "command -v caddy >/dev/null 2>&1" \
    || { echo "error: caddy is not installed on the target." >&2
         echo "       Install it first: https://caddyserver.com/docs/install" >&2; exit 1; }

  if [ "$NEED_PROTECT" -eq 1 ] && [ -z "$PROTECT" ]; then
    echo "error: use --protect=user:password (not a bare --protect)" >&2; exit 2
  fi

  # Basic auth block, rendered only when a credential was given.
  AUTH_BLOCK=""
  if [ -n "$PROTECT" ]; then
    PU="${PROTECT%%:*}"; PP="${PROTECT#*:}"
    if [ -z "$PU" ] || [ -z "$PP" ] || [ "$PU" = "$PROTECT" ]; then
      echo "error: --protect wants user:password" >&2; exit 2
    fi
    say "hashing the site password"
    HASH="$( (command -v caddy >/dev/null 2>&1 && caddy hash-password --plaintext "$PP") \
             || { echo "error: caddy not found, cannot hash the password" >&2; exit 1; } )"
    # Caddy renamed basicauth -> basic_auth; validate below picks the one that works.
    AUTH_BLOCK=$'\tbasic_auth {\n\t\t'"$PU"' '"$HASH"$'\n\t}\n'
  fi

  say "rendering Caddyfile for $DOMAIN"
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__WEB_ROOT__|$WEB_ROOT|g" "$REPO/deploy/Caddyfile" > "$TMP"
  # Substitute the auth block (or remove the placeholder line entirely).
  if [ -n "$AUTH_BLOCK" ]; then
    printf '%s' "$AUTH_BLOCK" > "$TMP.auth"
    sed -i -e "/__AUTH__/r $TMP.auth" -e "/__AUTH__/d" "$TMP"
    rm -f "$TMP.auth"
  else
    sed -i "/__AUTH__/d" "$TMP"
  fi

  remote "mkdir -p '$SITES_DIR' /var/log/caddy"
  say "installing $SITES_DIR/visualmental.caddyfile"
  if [ "$LOCAL" -eq 1 ]; then
    run install -m 644 "$TMP" "$SITES_DIR/visualmental.caddyfile"
  else
    run scp $SSH_OPTS "$TMP" "$SSH_HOST:$SITES_DIR/visualmental.caddyfile"
  fi

  # Only wire up the import if it isn't already there, and back up first.
  say "ensuring $MAIN_CADDYFILE imports $SITES_DIR"
  # Timestamp is computed here rather than remotely: inside the single-quoted
  # remote argument a $(date) would never expand, silently producing a backup
  # file named after the literal command substitution.
  STAMP="$(date +%Y%m%d%H%M%S)"
  remote "set -e
    if ! grep -qF '$SITES_DIR/' '$MAIN_CADDYFILE' 2>/dev/null; then
      cp -a '$MAIN_CADDYFILE' '$MAIN_CADDYFILE.bak.$STAMP'
      printf '\nimport %s/*.caddyfile\n' '$SITES_DIR' >> '$MAIN_CADDYFILE'
      echo '   added import line (original backed up)'
    else
      echo '   import already present'
    fi"

  # Validate before reloading — a bad config should never take the site down.
  say "validating config"
  if ! remote "caddy validate --adapter caddyfile --config '$MAIN_CADDYFILE'"; then
    if [ -n "$PROTECT" ]; then
      # Older Caddy spells it basicauth; retry once before giving up.
      say "retrying with the older basicauth directive"
      remote "sed -i 's/basic_auth {/basicauth {/' '$SITES_DIR/visualmental.caddyfile'"
      remote "caddy validate --adapter caddyfile --config '$MAIN_CADDYFILE'" \
        || { echo "error: caddy validate failed — NOT reloading. Restore from the .bak file if needed." >&2; exit 1; }
    else
      echo "error: caddy validate failed — NOT reloading. Restore from the .bak file if needed." >&2
      exit 1
    fi
  fi

  say "reloading caddy"
  remote "systemctl reload caddy || systemctl restart caddy"
fi

say "done → https://$DOMAIN/"
if [ "$WITH_CADDY" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "   First request may take a few seconds while Let's Encrypt issues the cert."
  if [ "$LOCAL" -eq 1 ]; then echo "   Watch it with: journalctl -u caddy -f"
  else echo "   Watch it with: ssh $SSH_HOST journalctl -u caddy -f"; fi
fi
