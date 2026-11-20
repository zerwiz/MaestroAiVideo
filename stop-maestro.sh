#!/usr/bin/env bash
# stop-maestro.sh — stop the Maestro video forge on this machine.
#
#   ./stop-maestro.sh            # stop the service
#   ./stop-maestro.sh --purge    # stop, and also stop the planner llama-server
#   ./stop-maestro.sh --free-vram # stop, then unload the model rail's model too
#
# Stopping the unit releases the video model. The planner's llama-server is a
# separate child process that can outlive it, which is the usual reason VRAM
# stays "used" after a stop — hence --purge.
set -uo pipefail

UNIT=maestro.service
PURGE=0
FREE_RAIL=0

for arg in "$@"; do
  case "$arg" in
    --purge)     PURGE=1 ;;
    --free-vram) PURGE=1; FREE_RAIL=1 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

vram_used() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1; }

if ! systemctl --user is-active --quiet "$UNIT"; then
  echo "Maestro is not running (already stopped)."
else
  echo "stopping $UNIT ..."
  systemctl --user stop "$UNIT"
  for _ in $(seq 1 30); do
    systemctl --user is-active --quiet "$UNIT" || break
    sleep 1
  done
  if systemctl --user is-active --quiet "$UNIT"; then
    echo "did not stop in 30 s; sending SIGKILL"
    systemctl --user kill --signal=SIGKILL "$UNIT" 2>/dev/null
    sleep 2
  fi
  echo "stopped."
fi

if [ "$PURGE" = "1" ]; then
  # The planner runs on its own port with a --models-preset-free argv, so match
  # on the model file rather than on the rail's preset flag.
  mapfile -t PIDS < <(pgrep -f "llama-server.*MaestroAiVideo" 2>/dev/null)
  if [ "${#PIDS[@]}" -gt 0 ]; then
    echo "killing planner llama-server: ${PIDS[*]}"
    kill "${PIDS[@]}" 2>/dev/null
    sleep 3
    kill -9 "${PIDS[@]}" 2>/dev/null
  else
    echo "no planner llama-server running."
  fi
fi

if [ "$FREE_RAIL" = "1" ]; then
  KEY=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.pi/agent/auth.json')))['llama-swap']['key'])" 2>/dev/null)
  M=$(curl -s -m 5 http://127.0.0.1:8080/v1/models -H "Authorization: Bearer $KEY" 2>/dev/null \
      | python3 -c 'import sys,json
d=json.load(sys.stdin)
for m in d.get("data",[]):
    if m.get("status",{}).get("value")=="loaded": print(m["id"]); break' 2>/dev/null)
  if [ -n "${M:-}" ]; then
    curl -s -m 10 -X POST http://127.0.0.1:8080/models/unload \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
      -d "{\"model\":\"$M\"}" >/dev/null 2>&1 \
      && echo "unloaded rail model: $M"
  else
    echo "rail: nothing resident."
  fi
fi

echo
echo "VRAM now: $(vram_used) MiB used"
ss -tln 2>/dev/null | grep -oE ':78[0-9]{2}' | head -1 | sed 's/^/port still listening: /' || echo "port 786x: free"
echo
echo "Anything still holding the card:"
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null | sed 's/^/  /' || echo "  (nvidia-smi unavailable)"
