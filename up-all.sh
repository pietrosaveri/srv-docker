#!/usr/bin/env bash
#
# up-all.sh — bring every Docker Compose stack in this repo up safely.
#
# Each top-level directory containing a compose file is one stack. A stack is
# validated before it is touched, so one broken stack (bad YAML, missing .env,
# unset secret) never blocks the others and never gets started half-configured.
#
# Usage:  ./up-all.sh [options] [stack ...]     (--help for details)

set -euo pipefail

# ---------------------------------------------------------------- configuration
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
NETWORK="homeserver"              # external bridge network every stack joins
START_FIRST=(caddy adguard)       # ingress + DNS before the rest
SKIP_ALWAYS=(_template)           # not a real stack (image: CHANGE_ME)
LOCK_DIR="${TMPDIR:-/tmp}/srv-docker-up-all.lock"

DRY_RUN=0
DO_PULL=0
DO_BUILD=0
TIMEOUT_SECS=600
SETTLE_SECS=8
ONLY=()
SKIP=()

# ------------------------------------------------------------------- formatting
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=
fi

info() { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "  ${C_GREEN}ok${C_RESET}      $*"; }
warn() { printf '%s\n' "  ${C_YELLOW}skip${C_RESET}    $*"; }
fail() { printf '%s\n' "  ${C_RED}FAILED${C_RESET}  $*"; }
die()  { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; exit 1; }

usage() {
  cat <<EOF
${C_BOLD}up-all.sh${C_RESET} — start every Compose stack in $REPO_DIR

  ./up-all.sh [options] [stack ...]

Options:
  -n, --dry-run        show what would run, change nothing
  -p, --pull           pull images before starting each stack
  -b, --build          rebuild images for stacks that build from source
  -s, --skip NAME      skip a stack (repeatable)
  -t, --timeout SECS   per-stack timeout (default: ${TIMEOUT_SECS})
      --no-settle      skip the post-start container state check
  -l, --list           list discovered stacks in start order and exit
  -h, --help           this text

Positional arguments limit the run to the named stacks:
  ./up-all.sh caddy homepage

Safety behaviour:
  * refuses to run twice at once (lock: ${LOCK_DIR})
  * checks the Docker daemon is reachable before doing anything
  * creates the external '${NETWORK}' network only if it is missing
  * validates each compose file and every required .env value first; a stack
    that does not check out is skipped, not started broken
  * 'up -d' is idempotent, so already-running stacks are left alone
  * never stops, removes or prunes anything

Exit status: 0 all good, 1 a stack failed, 2 a stack was skipped.
EOF
}

# ------------------------------------------------------------------ arg parsing
DO_LIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -p|--pull)    DO_PULL=1 ;;
    -b|--build)   DO_BUILD=1 ;;
    -l|--list)    DO_LIST=1 ;;
    -s|--skip)    [[ $# -ge 2 ]] || die "--skip needs a stack name"; SKIP+=("$2"); shift ;;
    -t|--timeout) [[ $# -ge 2 ]] || die "--timeout needs seconds"; TIMEOUT_SECS="$2"; shift ;;
    --no-settle)  SETTLE_SECS=0 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            ONLY+=("$1") ;;
  esac
  shift
done
[[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]] || die "--timeout must be a whole number of seconds"

cd "$REPO_DIR"

# ------------------------------------------------------------- stack discovery
shopt -s nullglob
declare -a ALL_STACKS=()
for f in */compose.yaml */compose.yml */docker-compose.yaml */docker-compose.yml; do
  d="${f%/*}"
  [[ " ${ALL_STACKS[*]-} " == *" $d "* ]] || ALL_STACKS+=("$d")
done
shopt -u nullglob
[[ ${#ALL_STACKS[@]} -gt 0 ]] || die "no compose files found under $REPO_DIR"
IFS=$'\n' ALL_STACKS=($(printf '%s\n' "${ALL_STACKS[@]}" | sort)); unset IFS

in_list() { local needle="$1"; shift; local x; for x in "$@"; do [[ "$x" == "${needle}" ]] && return 0; done; return 1; }

# Ordered work list: infra first, then everything else alphabetically.
declare -a STACKS=()
for s in "${START_FIRST[@]}"; do in_list "$s" "${ALL_STACKS[@]}" && STACKS+=("$s"); done
for s in "${ALL_STACKS[@]}"; do in_list "$s" "${START_FIRST[@]}" || STACKS+=("$s"); done

# Validate positional filters against what actually exists.
for s in "${ONLY[@]-}"; do
  [[ -z "$s" ]] && continue
  in_list "$s" "${ALL_STACKS[@]}" || die "unknown stack '$s' (no compose file in ./$s)"
done

declare -a WORK=()
for s in "${STACKS[@]}"; do
  in_list "$s" "${SKIP_ALWAYS[@]}" && continue
  [[ ${#SKIP[@]} -gt 0 ]] && in_list "$s" "${SKIP[@]}" && continue
  if [[ ${#ONLY[@]} -gt 0 ]]; then in_list "$s" "${ONLY[@]}" || continue; fi
  WORK+=("$s")
done
[[ ${#WORK[@]} -gt 0 ]] || die "nothing to do — every stack was filtered out"

if [[ $DO_LIST -eq 1 ]]; then
  printf '%s\n' "${WORK[@]}"
  exit 0
fi

# --------------------------------------------------------------------- preflight
command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  die "docker compose v2 is not available"
fi

docker info >/dev/null 2>&1 \
  || die "cannot reach the Docker daemon — is it running, and is $(id -un) in the 'docker' group?"

declare -a TIMEOUT_PREFIX=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_PREFIX=(timeout --foreground "$TIMEOUT_SECS")
fi

# Run a compose command inside a stack directory, honouring the timeout.
run_compose() {
  local dir="$1"; shift
  ( cd "$dir" && "${TIMEOUT_PREFIX[@]}" "${COMPOSE[@]}" "$@" )
}

# Only one instance at a time: mkdir is atomic everywhere.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    die "another up-all.sh is already running (pid $lock_pid)"
  fi
  info "clearing stale lock ${C_DIM}${LOCK_DIR}${C_RESET}"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || die "cannot create lock $LOCK_DIR"
fi
echo $$ >"$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

LOG_ROOT="${LOG_DIR:-/var/tmp/srv-docker-up}"
mkdir -p "$LOG_ROOT" 2>/dev/null || LOG_ROOT="${TMPDIR:-/tmp}/srv-docker-up"
RUN_LOG_DIR="$LOG_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_LOG_DIR" || die "cannot create log directory $RUN_LOG_DIR"

# ----------------------------------------------------------------- safety checks
ensure_network() {
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    ok "network '$NETWORK' exists"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    info "would create the missing external network '$NETWORK'"
    return 0
  fi
  info "creating missing external network '$NETWORK'"
  docker network create --driver bridge "$NETWORK" >/dev/null \
    || die "failed to create network '$NETWORK'"
  ok "network '$NETWORK' created"
}

# Every ${VAR} the compose file uses without an inline default must resolve from
# the stack's .env or the environment. Compose otherwise substitutes an empty
# string — which silently means things like a blank database password.
missing_vars() {
  local dir="$1" tok var
  local -a missing=() tokens=()
  while IFS= read -r tok; do
    [[ -n "$tok" ]] && tokens+=("$tok")
  done < <(cat "$dir"/compose.y*ml "$dir"/docker-compose.y*ml 2>/dev/null \
           | grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*[^}]*\}' | sort -u)

  for tok in "${tokens[@]-}"; do
    [[ -z "$tok" ]] && continue
    # ${VAR:-x} ${VAR-x} ${VAR:?x} ${VAR+x} all carry their own fallback
    [[ "$tok" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*[:+?-] ]] && continue
    var="${tok#\$\{}"; var="${var%\}}"
    [[ -n "${!var:-}" ]] && continue
    if [[ -f "$dir/.env" ]] \
       && grep -qE "^[[:space:]]*(export[[:space:]]+)?${var}=[^[:space:]]" "$dir/.env"; then
      continue
    fi
    missing+=("$var")
  done
  [[ ${#missing[@]} -gt 0 ]] && printf '%s ' "${missing[@]}"
  return 0
}

# --------------------------------------------------------------------- the work
declare -a RESULT_OK=() RESULT_SKIP=() RESULT_FAIL=()

start_stack() {
  local dir="$1" log="$RUN_LOG_DIR/$dir.log" rc=0

  # 1. the compose file must parse (catches bad YAML and a missing env_file)
  if ! run_compose "$dir" config -q >"$log" 2>&1; then
    warn "$dir — invalid compose config: $(tr '\n' ' ' <"$log" | tail -c 160)"
    RESULT_SKIP+=("$dir: invalid config")
    return 0
  fi

  # 2. required variables must actually have values
  local miss; miss="$(missing_vars "$dir")"
  if [[ -n "${miss// /}" ]]; then
    warn "$dir — unset variable(s): ${miss% }"
    RESULT_SKIP+=("$dir: unset ${miss% }")
    return 0
  fi

  # 3. start it
  local -a up_args=(up -d)
  [[ $DO_BUILD -eq 1 ]] && up_args+=(--build)

  if [[ $DRY_RUN -eq 1 ]]; then
    [[ $DO_PULL -eq 1 ]] && printf '%s\n' "  would run: (cd $dir && ${COMPOSE[*]} pull)"
    printf '%s\n' "  would run: (cd $dir && ${COMPOSE[*]} ${up_args[*]})"
    RESULT_OK+=("$dir")
    return 0
  fi

  if [[ $DO_PULL -eq 1 ]] && ! run_compose "$dir" pull >>"$log" 2>&1; then
    printf '%s\n' "  ${C_YELLOW}warn${C_RESET}    $dir — pull failed, continuing with the local image"
  fi

  if run_compose "$dir" "${up_args[@]}" >>"$log" 2>&1; then
    ok "$dir"
    RESULT_OK+=("$dir")
  else
    rc=$?
    [[ $rc -eq 124 ]] && fail "$dir — timed out after ${TIMEOUT_SECS}s (log: $log)" \
                      || fail "$dir — exit $rc (log: $log)"
    tail -n 6 "$log" | sed 's/^/          /'
    RESULT_FAIL+=("$dir")
  fi
  return 0
}

info "repo:   $REPO_DIR"
info "stacks: ${WORK[*]}"
info "logs:   $RUN_LOG_DIR"
[[ $DRY_RUN -eq 1 ]] && info "${C_BOLD}dry run — nothing will be started${C_RESET}"
echo

ensure_network
echo

info "starting stacks"
for dir in "${WORK[@]}"; do
  start_stack "$dir"
done
echo

# ---------------------------------------------------------------- settle check
if [[ $DRY_RUN -eq 0 && $SETTLE_SECS -gt 0 && ${#RESULT_OK[@]} -gt 0 ]]; then
  info "waiting ${SETTLE_SECS}s, then checking container state"
  sleep "$SETTLE_SECS"
  bad=0
  while IFS=$'\t' read -r name status; do
    [[ -z "$name" ]] && continue
    case "$status" in
      *unhealthy*|Restarting*|Exited*|Created*|Dead*|Paused*)
        printf '%s\n' "  ${C_YELLOW}warn${C_RESET}    $name — $status"
        bad=1 ;;
    esac
  done < <(docker ps -a --filter 'label=com.docker.compose.project' --format '{{.Names}}\t{{.Status}}')
  [[ $bad -eq 0 ]] && ok "every compose container is running"
  echo
fi

# --------------------------------------------------------------------- summary
printf '%s\n' "${C_BOLD}summary${C_RESET}"
printf '%s\n' "  ${C_GREEN}started${C_RESET} : ${#RESULT_OK[@]}${RESULT_OK+  }${RESULT_OK[*]-}"
[[ ${#RESULT_SKIP[@]} -gt 0 ]] && printf '%s\n' "  ${C_YELLOW}skipped${C_RESET} : ${#RESULT_SKIP[@]}  ($(IFS='; '; echo "${RESULT_SKIP[*]}"))"
[[ ${#RESULT_FAIL[@]} -gt 0 ]] && printf '%s\n' "  ${C_RED}failed${C_RESET}  : ${#RESULT_FAIL[@]}  (${RESULT_FAIL[*]})"
printf '%s\n' "  logs    : $RUN_LOG_DIR"

[[ ${#RESULT_FAIL[@]} -gt 0 ]] && exit 1
[[ ${#RESULT_SKIP[@]} -gt 0 ]] && exit 2
exit 0
