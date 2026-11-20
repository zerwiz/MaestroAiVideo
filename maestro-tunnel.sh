#!/usr/bin/env bash
# maestro-tunnel.sh — private HTTPS access to the forge over the tailnet.
#
# This is Tailscale **Serve**, not Funnel: the route exists only for devices on
# your tailnet and is never published to the public internet. It is the same
# mechanism Maestro ships (tailscale_setup.js) — `tailscale serve --bg --yes
# --https=443 http://127.0.0.1:<port>` plus app/settings/remote_access.json so
# launch.py restores the route after every restart.
#
# sudo is required: `tailscale serve` reconfigures tailscaled. This box has no
# passwordless sudo, so run it as:
#
#     sudo ./maestro-tunnel.sh on      # create/refresh the route
#     sudo ./maestro-tunnel.sh off     # remove it
#     ./maestro-tunnel.sh status       # no sudo needed
#
set -uo pipefail

APP=${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app
SETTINGS="$APP/settings/remote_access.json"
MODE="${1:-status}"

# Read the port Maestro is actually on — never assume 7860.
detect_port() {
  ss -tln 2>/dev/null | grep -oE ':78[0-9]{2}' | head -1 | tr -d ':'
}

write_settings() {
  local port="$1"
  mkdir -p "$APP/settings"
  cat > "$SETTINGS" <<EOF
{
  "version": 3,
  "enabled": true,
  "target_port": "$port",
  "pinokio_port_lock": true,
  "windows_restore_task": false,
  "windows_restore_task_name": null
}
EOF
  echo "wrote $SETTINGS (target_port=$port, launch.py will keep this alive)"
}

case "$MODE" in
  on)
    PORT="$(detect_port)"
    if [ -z "$PORT" ]; then
      echo "Maestro is not listening on any 78xx port. Start it first:" >&2
      echo "  ./start-maestro.sh" >&2
      exit 1
    fi
    command -v tailscale >/dev/null || { echo "tailscale not installed" >&2; exit 1; }
    if [ "$(id -u)" -ne 0 ]; then
      echo "needs sudo: sudo $0 on" >&2; exit 1
    fi
    echo "serving 127.0.0.1:$PORT over tailnet HTTPS (:443) ..."
    tailscale serve --bg --yes --https=443 "http://127.0.0.1:$PORT" || exit 1
    write_settings "$PORT"
    echo
    tailscale serve status
    echo
    echo "Open on any tailnet device:  https://$(tailscale status --json 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null)/"
    ;;

  off)
    [ "$(id -u)" -eq 0 ] || { echo "needs sudo: sudo $0 off" >&2; exit 1; }
    tailscale serve --https=443 off || exit 1
    if [ -f "$SETTINGS" ]; then
      python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["enabled"] = False
json.dump(d, open(p, "w"), indent=2)
print(f"{p}: enabled=false (launch.py will no longer restore the route)")
PY
    fi
    tailscale serve status
    ;;

  status)
    echo "listening    : $(detect_port | sed 's/^/port /' || echo none)"
    echo "settings     : $([ -f "$SETTINGS" ] && echo "$SETTINGS (enabled=$(python3 -c "import json;print(json.load(open('$SETTINGS')).get('enabled'))"))" || echo 'not written')"
    echo "tailscale serve:"
    tailscale serve status 2>&1 | sed 's/^/  /'
    echo
    echo "no route?  sudo $0 on"
    ;;

  *) echo "usage: $0 {on|off|status}" >&2; exit 2 ;;
esac
