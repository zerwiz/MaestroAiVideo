#!/usr/bin/env bash
# start-maestro.sh — start the Maestro video forge on this machine.
#
# Normal path: the systemd user unit (systemctl --user start maestro), which is
# enabled at login. This script is the friendly front door to it, with the
# preflight checks that stop a "hung" forge from being really a wrong setup.
#
#   ./start-maestro.sh              # start on 7860
#   ./start-maestro.sh 7860 0.0.0.0 # explicit port / bind
#   ./start-maestro.sh --status     # just report
#
# Environment overrides (all optional):
#   MAESTRO_PORT=7860              default port
#   MAESTRO_BIND=0.0.0.0           default bind (0.0.0.0 = LAN + tailnet)
#   MAESTRO_LOG=/tmp/maestro.log   where stdout/stderr are appended
set -uo pipefail

PORT="${MAESTRO_PORT:-${2:-7860}}"
BIND="${MAESTRO_BIND:-${3:-0.0.0.0}}"
LOG="${MAESTRO_LOG:-/tmp/maestro.log}"
UNIT=maestro.service
export MAESTRO_LLAMA_BIN="${MAESTRO_LLAMA_BIN:-/usr/local/bin}"
# Addresses are read from the machine at run time, never written here.
LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
TS_IP=$(tailscale ip -4 2>/dev/null | head -1)

status() {
  local active enabled port
  active=$(systemctl --user is-active "$UNIT" 2>/dev/null || echo inactive)
  enabled=$(systemctl --user is-enabled "$UNIT" 2>/dev/null || echo disabled)
  port=$(ss -tln 2>/dev/null | grep -oE ':78[0-9]{2}' | head -1 | tr -d ':')
  echo "  unit    : $UNIT ($active, $enabled at login)"
  echo "  port    : ${port:-none}"
  echo "  log     : $LOG   (journalctl --user -u maestro -f)"
  if [ "$active" = "active" ]; then
    echo "  url     : http://127.0.0.1:${port:-?}/"
    [ -n "$LAN_IP" ] && echo "            http://${LAN_IP}:${port:-?}/   (LAN)"
    [ -n "$TS_IP" ]  && echo "            http://${TS_IP}:${port:-?}/    (tailnet)"
  fi
}

if [ "${1:-}" = "--status" ]; then status; exit 0; fi

# --- preflight 1: the planner's llama-server -------------------------------
if [ ! -x "$MAESTRO_LLAMA_BIN/llama-server" ]; then
  cat >&2 <<EOF
FATAL: no llama-server in MAESTRO_LLAMA_BIN=$MAESTRO_LLAMA_BIN
       Without it Maestro COMPILES llama.cpp from source (355 nvcc objects,
       ~15 min) on the first LLM planning call, which looks like a hang.
       Fix: export MAESTRO_LLAMA_BIN=/usr/local/bin
EOF
  exit 1
fi
if ! "$MAESTRO_LLAMA_BIN/llama-server" --list-devices 2>/dev/null | grep -q CUDA; then
  echo "FATAL: $MAESTRO_LLAMA_BIN/llama-server reports no CUDA device." >&2
  echo "       GPU LLM planning needs a CUDA build." >&2
  exit 1
fi

# --- preflight 2: the port must actually be free ---------------------------
# launch.py probes the port and silently falls forward (7860 -> 7861) when it
# is busy, so a busy port silently moves the address out from under you.
if ss -tln 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
  holder=$(ss -tlnp 2>/dev/null | grep ":${PORT}[[:space:]]" | head -1)
  echo "NOTE: port ${PORT} is already in use — Maestro will fall forward to ${PORT}+1."
  echo "      ${holder}" | sed 's/users:.*pid=\([0-9]*\).*/held by pid \1/'
fi

# --- start -----------------------------------------------------------------
if systemctl --user is-active --quiet "$UNIT"; then
  echo "Maestro is already running. Use ./stop-maestro.sh first, or --status."
  status; exit 0
fi

echo "llama-server: $MAESTRO_LLAMA_BIN/llama-server (CUDA verified)"
echo "starting $UNIT ..."
systemctl --user start "$UNIT"

# --- wait for the socket, and report where it ACTUALLY landed --------------
port=""
for _ in $(seq 1 60); do
  sleep 2
  port=$(ss -tln 2>/dev/null | grep -oE ':78[0-9]{2}' | head -1 | tr -d ':')
  [ -n "$port" ] && break
done

if [ -z "$port" ]; then
  echo >&2
  echo "FAILED: no listener after 120 s. Last 25 log lines:" >&2
  journalctl --user -u "$UNIT" -n 25 --no-pager 2>/dev/null | sed 's/^/  /' >&2
  echo "  (full log: $LOG)" >&2
  exit 1
fi

if [ "$port" != "$PORT" ]; then
  echo "NOTE: bound to ${port}, not ${PORT} (fall-forward — the old process"
  echo "      was still holding ${PORT} when this one probed)."
fi

cat <<EOF

  Maestro UI:  http://127.0.0.1:${port}/
  Classic UI:  http://127.0.0.1:${port}/classic/
  API docs:    http://127.0.0.1:${port}/docs
  LAN:         http://${LAN_IP:-<no LAN address>}:${port}/
  tailnet:     http://${TS_IP:-<no tailnet address>}:${port}/

  log: journalctl --user -u maestro -f   (also ${LOG})
EOF
