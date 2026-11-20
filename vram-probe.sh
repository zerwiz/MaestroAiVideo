#!/usr/bin/env bash
# vram-probe.sh — load the planner GGUF at a given ctx and read real VRAM.
#   ./vram-probe.sh 131072 [kvtype]
# Frees the card, loads, samples peak VRAM, kills. Prints one line.
set -u
CTX="${1:-131072}"
KVT="${2:-q8_0}"
G=${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app/ckpts/llm/gemma-4-E4B-it-heretic-GGUF/gemma-4-E4B-it-heretic-Q4_K_M.gguf
RAIL=http://127.0.0.1:8080
KEY=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.pi/agent/auth.json')))['llama-swap']['key'])" 2>/dev/null)

free_mb() { nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits; }

M=$(curl -s --max-time 5 "$RAIL/v1/models" -H "Authorization: Bearer $KEY" 2>/dev/null \
    | python3 -c 'import sys,json
d=json.load(sys.stdin)
for m in d.get("data",[]):
    if m.get("status",{}).get("value")=="loaded": print(m["id"]); break' 2>/dev/null)
if [ "$(free_mb)" -lt 12000 ] && [ -n "${M:-}" ]; then
  curl -s --max-time 10 -X POST "$RAIL/models/unload" -H "Authorization: Bearer $KEY" \
       -H "Content-Type: application/json" -d "{\"model\":\"$M\"}" >/dev/null 2>&1
  for _ in $(seq 1 30); do [ "$(free_mb)" -ge 12000 ] && break; sleep 1; done
fi
BASE=$(free_mb)
echo "baseline free: ${BASE} MiB"

setsid /usr/local/bin/llama-server -m "$G" -ngl 999 -c "$CTX" -b 2048 -ub 2048 \
  -lv 5 -t 8 --parallel 1 --cache-type-k "$KVT" --cache-type-v "$KVT" --flash-attn 1 --reasoning off --seed 42 \
  --port 9098 --host 127.0.0.1 > /tmp/vram-probe.log 2>&1 < /dev/null &

PEAK=0
for _ in $(seq 1 90); do
  sleep 2
  curl -s -o /dev/null --max-time 2 http://127.0.0.1:9098/health 2>/dev/null && break
  F=$(free_mb); [ "$F" -lt "$PEAK" ] && PEAK=$F
done
sleep 2
F=$(free_mb); [ "$F" -lt "$PEAK" ] && PEAK=$F
echo "VRAM_VRAM ctx=$CTX kv=$KVT baseline_free=${BASE} peak_free=${PEAK} used=$(( 16384 - PEAK ))"
pkill -f "port 9098" 2>/dev/null
sleep 3
echo "after: free $(free_mb) MiB"
