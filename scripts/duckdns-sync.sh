#!/usr/bin/env bash
#
# duckdns-sync.sh — keep the DuckDNS record pointing at this connection.
#
# Sends the update with an EMPTY ip parameter, which makes DuckDNS record the
# source address of the request itself. So this script never needs to discover
# its own public IP — but it MUST run on the home connection. Run it from
# anywhere else and it will publish that network's address instead.

set -euo pipefail

CONFIG="${DUCKDNS_CONFIG:-/etc/duckdns.env}"

log() { printf '%s duckdns: %s\n' "$(date -Is)" "$*"; }
die() { printf '%s duckdns: ERROR: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

[[ -r "$CONFIG" ]] || die "cannot read $CONFIG (are you root?)"
# shellcheck source=/dev/null
. "$CONFIG"

[[ -n "${DUCKDNS_DOMAINS:-}" ]] || die "DUCKDNS_DOMAINS not set in $CONFIG"
[[ -n "${DUCKDNS_TOKEN:-}"   ]] || die "DUCKDNS_TOKEN not set in $CONFIG"

response="$(curl -fsS --max-time 20 --get \
  --data-urlencode "domains=${DUCKDNS_DOMAINS}" \
  --data-urlencode "token=${DUCKDNS_TOKEN}" \
  --data-urlencode "ip=" \
  https://www.duckdns.org/update)" || die "request to duckdns failed"

case "$response" in
  OK*) log "ok: ${DUCKDNS_DOMAINS}.duckdns.org -> this connection" ;;
  KO*) die "duckdns returned KO — check DUCKDNS_TOKEN and DUCKDNS_DOMAINS" ;;
  *)   die "unexpected response: ${response:0:100}" ;;
esac
