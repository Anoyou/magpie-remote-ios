#!/usr/bin/env bash
# run-magpie-fixture.sh — build magpie from source, start it headless with a mock
# OpenAI-compatible upstream, seed provider / routing group / gateway keys, turn on
# "Share on local network", and print the env vars a contract test needs.
#
# Usage:  run-magpie-fixture.sh <magpie-source-dir> [work-dir]
#   Needs: go (matching go.mod; actions/setup-go with go-version-file: <src>/go.mod),
#          python3, curl. Linux or macOS.
#   Env knobs: GATEWAY_PORT (3425) WEB_PORT (3430) MOCK_PORT (18080)
#              MAGPIE_WEB_KEY (random if unset; >=16 chars, [A-Za-z0-9._~-])
#              MAGPIE_VERSION (default: git describe of the source, else "dev")
#              HOST_IP (address clients use; default first non-loopback IPv4, else 127.0.0.1)
#              MAGPIE_BIN (use this prebuilt binary instead of building; then <src> may be any dir)
#
# Prints KEY=VALUE lines on stdout (also written to <work-dir>/fixture.env, and
# appended to $GITHUB_ENV when that is set). Everything else goes to stderr.
# Processes keep running in the background; stop with:  kill $(cat <work-dir>/pids)
set -euo pipefail

SRC=$(cd "${1:?usage: $0 <magpie-source-dir> [work-dir]}" && pwd)
WORK=${2:-${RUNNER_TEMP:-/tmp}/magpie-fixture}
HERE=$(cd "$(dirname "$0")" && pwd)
GATEWAY_PORT=${GATEWAY_PORT:-3425}
WEB_PORT=${WEB_PORT:-3430}
MOCK_PORT=${MOCK_PORT:-18080}
log() { echo "[fixture] $*" >&2; }

rm -rf "$WORK"; mkdir -p "$WORK/home" "$WORK/bin"
: > "$WORK/pids"

# ---------------------------------------------------------------- build
VERSION=${MAGPIE_VERSION:-$(git -C "$SRC" describe --tags --always --dirty 2>/dev/null | tr -cd 'A-Za-z0-9._+-' || true)}
VERSION=${VERSION:-dev}
if [ -n "${MAGPIE_BIN:-}" ]; then
  log "using prebuilt $MAGPIE_BIN"
  M="$MAGPIE_BIN"
else
  log "building magpie $VERSION (nogui, CGO_ENABLED=0, as Makefile 'cli' / Dockerfile)"
  ( cd "$SRC" && CGO_ENABLED=0 go build -tags nogui -trimpath \
      -ldflags "-s -w -X main.version=$VERSION" -o "$WORK/bin/magpie" . ) >&2
  M="$WORK/bin/magpie"
fi
log "$("$M" --version 2>&1 || true)"

# ---------------------------------------------------------------- isolated home
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
export MAGPIE_NO_ACCOUNTS=1            # never read real agents' sign-ins
# The gateway port comes from settings.json, NOT MAGPIE_ADDR: MAGPIE_ADDR=127.0.0.1:<p>
# pins the host, and then turning sharing on never re-listens beyond loopback.
unset MAGPIE_ADDR
mkdir -p "$XDG_CONFIG_HOME/magpie"
echo "{\"port\":$GATEWAY_PORT}" > "$XDG_CONFIG_HOME/magpie/settings.json"
export MAGPIE_WEB_KEY=${MAGPIE_WEB_KEY:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}
# two agent configs so /api/state lists agents and /api/agent-models/<id> has a subject
mkdir -p "$HOME/.codex" "$HOME/.claude"
echo 'model = "gpt-5"' > "$HOME/.codex/config.toml"
echo '{"model":"opus"}' > "$HOME/.claude/settings.json"

# ---------------------------------------------------------------- mock upstream
MOCK="$HERE/mock_openai.py"
if [ ! -f "$MOCK" ]; then log "mock_openai.py must sit next to this script"; exit 1; fi
MOCK_LOG="$WORK/mock.log" nohup python3 "$MOCK" "$MOCK_PORT" > "$WORK/mock.out" 2>&1 &
echo $! >> "$WORK/pids"

# ---------------------------------------------------------------- magpie serve + web page
nohup "$M" serve --web="0.0.0.0:$WEB_PORT" > "$WORK/serve.log" 2>&1 &
echo $! >> "$WORK/pids"

wait_http() { local u=$1; shift; for _ in $(seq 1 60); do curl -fsS -o /dev/null "$@" "$u" 2>/dev/null && return 0; sleep 0.5; done; log "timeout waiting for $1"; cat "$WORK/serve.log" >&2 || true; return 1; }
wait_http "http://127.0.0.1:$MOCK_PORT/v1/models"
wait_http "http://127.0.0.1:$GATEWAY_PORT/api/hello"
log "gateway up: $(curl -fsS "http://127.0.0.1:$GATEWAY_PORT/api/hello")"

# ---------------------------------------------------------------- seed
"$M" provider add Mock "url=http://127.0.0.1:$MOCK_PORT/v1" key=sk-mock-upstream-EXAMPLE id=mock >&2
"$M" group add fast models=mock/mock-gpt-1,mock/mock-gpt-mini routing=order >&2
# `gateway-key add` prints the full key as its last stdout line
GW_KEY=$("$M" gateway-key add "Contract client" | grep -o 'sk-magpie-key-[A-Za-z0-9]*' | tail -1)
ISSUER_KEY=$("$M" gateway-key add "Contract issuer" | grep -o 'sk-magpie-key-[A-Za-z0-9]*' | tail -1)
RO_KEY=$("$M" gateway-key add "Contract readonly" --read-only | grep -o 'sk-magpie-key-[A-Za-z0-9]*' | tail -1)
ISSUER_ID=$("$M" gateway-key list | awk '$2=="Contract" && $3=="issuer"{print $1}')
"$M" gateway-key issuer "$ISSUER_ID" on >&2

# Share on local network: only the web page's API does it (POST /api/settings/lan).
# The gateway re-listens on all interfaces. Cookie name is magpie_web_<webport>.
WEB_COOKIE="magpie_web_$WEB_PORT=$MAGPIE_WEB_KEY"
curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' -H "Cookie: $WEB_COOKIE" \
  -d '{"On":true}' "http://127.0.0.1:$WEB_PORT/api/settings/lan"
curl -fsS -o /dev/null -X POST -H "Cookie: $WEB_COOKIE" "http://127.0.0.1:$WEB_PORT/api/agents/rescan" || true

# ---------------------------------------------------------------- address clients use
if [ -z "${HOST_IP:-}" ]; then
  HOST_IP=$( (hostname -I 2>/dev/null || true) | awk '{print $1}')
  [ -z "$HOST_IP" ] && HOST_IP=$( (ipconfig getifaddr en0 2>/dev/null || true) )
  HOST_IP=${HOST_IP:-127.0.0.1}
fi
GW_URL="http://$HOST_IP:$GATEWAY_PORT"
WEB_URL="http://$HOST_IP:$WEB_PORT"
# from loopback, add  -H 'X-Forwarded-For: 192.0.2.9'  to be judged as a remote caller
REMOTE_HINT=""
[ "$HOST_IP" = 127.0.0.1 ] && REMOTE_HINT="loopback-only host: send X-Forwarded-For to exercise the shared path"

wait_http "$GW_URL/api/hello" -H "Authorization: Bearer $GW_KEY"   # a non-loopback caller needs a key, even for /api/hello
# one streaming + one plain call so usage / requests / limit have data
curl -fsS -N -H "Authorization: Bearer $GW_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"mock/mock-gpt-1","stream":true,"messages":[{"role":"user","content":"seed"}]}' \
  "$GW_URL/v1/chat/completions" > /dev/null
curl -fsS -H "Authorization: Bearer $GW_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"group/fast","messages":[{"role":"user","content":"seed"}]}' \
  "$GW_URL/v1/chat/completions" > /dev/null
log "seeded; magpie $(curl -fsS -H "Authorization: Bearer $GW_KEY" "$GW_URL/api/hello")"
[ -n "$REMOTE_HINT" ] && log "$REMOTE_HINT"

if [ -n "${GITHUB_ACTIONS:-}" ]; then   # throwaway keys, but keep them out of logs anyway
  for v in "$GW_KEY" "$ISSUER_KEY" "$RO_KEY" "$MAGPIE_WEB_KEY"; do echo "::add-mask::$v"; done
fi
{
  echo "MAGPIE_GATEWAY_URL=$GW_URL"
  echo "MAGPIE_GATEWAY_PORT=$GATEWAY_PORT"
  echo "MAGPIE_WEB_PORT=$WEB_PORT"
  echo "MAGPIE_GATEWAY_KEY=$GW_KEY"
  echo "MAGPIE_ISSUER_KEY=$ISSUER_KEY"
  echo "MAGPIE_READONLY_KEY=$RO_KEY"
  echo "MAGPIE_WEB_URL=$WEB_URL"
  echo "MAGPIE_WEB_KEY=$MAGPIE_WEB_KEY"
  echo "MAGPIE_WEB_COOKIE=$WEB_COOKIE"
  echo "MAGPIE_VERSION=$VERSION"
  echo "MAGPIE_FIXTURE_DIR=$WORK"
} | tee "$WORK/fixture.env"
[ -n "${GITHUB_ENV:-}" ] && cat "$WORK/fixture.env" >> "$GITHUB_ENV"
exit 0
