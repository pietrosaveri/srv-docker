#!/usr/bin/env bash
#
# dns-sync.sh — keep AdGuard's *.home.arpa rewrite pointing at this host's
# real LAN address, so a DHCP lease change repairs itself.
#
# Config lives in /etc/dns-sync.env (root-only, holds the AdGuard password).
# Run with --dry-run to see what it would change without changing it.

set -euo pipefail

CONFIG="${DNS_SYNC_CONFIG:-/etc/dns-sync.env}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { printf '%s dns-sync: %s\n' "$(date -Is)" "$*"; }
die() { printf '%s dns-sync: ERROR: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- config
[[ -r "$CONFIG" ]] || die "cannot read $CONFIG (are you root?)"
# shellcheck source=/dev/null
. "$CONFIG"

: "${ADGUARD_URL:=http://127.0.0.1:3000}"
: "${MANAGED_DOMAIN:=*.home.arpa}"
[[ -n "${ADGUARD_USER:-}" ]] || die "ADGUARD_USER not set in $CONFIG"
[[ -n "${ADGUARD_PASS:-}" ]] || die "ADGUARD_PASS not set in $CONFIG"

# ------------------------------------------- 1. our real LAN address
route_field() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk -v key="$1" '{for (i=1;i<=NF;i++) if ($i==key) {print $(i+1); exit}}'
}

IFACE="$(route_field dev)"
LAN_IP="$(route_field src)"
[[ -n "$IFACE" && -n "$LAN_IP" ]] || die "could not determine the outbound route"

case "$IFACE" in
  tailscale0|docker0|br-*|veth*|lo)
    die "outbound route is via '$IFACE' — refusing to publish that as a LAN address" ;;
esac

case "$LAN_IP" in
  10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) : ;;
  *) die "'$LAN_IP' is not a private address — refusing to publish it" ;;
esac

# ------------------------------------------- 2. talk to AdGuard
API_BODY=""
api() {
  local method="$1" path="$2" body="${3:-}" out code
  local -a args=(-sS --max-time 15 -w '\n%{http_code}'
                 -u "${ADGUARD_USER}:${ADGUARD_PASS}" -X "$method")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  out="$(curl "${args[@]}" "${ADGUARD_URL}${path}")" || die "curl failed for $path"
  code="${out##*$'\n'}"
  API_BODY="${out%$'\n'*}"
  [[ "$code" == 2* ]] || die "AdGuard returned HTTP $code for $path: ${API_BODY:0:200}"
}

json_pair() {
  python3 -c 'import json,sys; print(json.dumps({"domain":sys.argv[1],"answer":sys.argv[2]}))' \
    "$1" "$2"
}

# ------------------------------------------- 3. compare
api GET /control/rewrite/list

declare -a ANSWERS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ANSWERS+=("$line")
done < <(printf '%s' "$API_BODY" | python3 -c '
import json, sys
target = sys.argv[1]
for r in json.load(sys.stdin):
    if r.get("domain") == target:
        print(r.get("answer", ""))
' "$MANAGED_DOMAIN")

need_add=1
declare -a stale=()
for a in "${ANSWERS[@]}"; do
  if [[ "$a" == "$LAN_IP" ]]; then need_add=0; else stale+=("$a"); fi
done

if [[ $need_add -eq 0 && ${#stale[@]} -eq 0 ]]; then
  log "ok: $MANAGED_DOMAIN -> $LAN_IP (no change)"
  exit 0
fi

# ------------------------------------------- 4. repair: add, then delete
if [[ $need_add -eq 1 ]]; then
  log "adding $MANAGED_DOMAIN -> $LAN_IP"
  if [[ $DRY_RUN -eq 0 ]]; then
    api POST /control/rewrite/add "$(json_pair "$MANAGED_DOMAIN" "$LAN_IP")"
  fi
fi

for a in "${stale[@]}"; do
  log "removing stale $MANAGED_DOMAIN -> $a"
  if [[ $DRY_RUN -eq 0 ]]; then
    api POST /control/rewrite/delete "$(json_pair "$MANAGED_DOMAIN" "$a")"
  fi
done

log "synced: $MANAGED_DOMAIN -> $LAN_IP"

