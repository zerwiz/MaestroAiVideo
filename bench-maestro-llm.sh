#!/usr/bin/env bash
# bench-maestro-llm.sh — tune Maestro's LLM-planner GGUF for the local GPU.
#
# Follows the modeltesting skill's rules for this host (HOST-RUNBOOK.md §12):
#   * free the card first — the fleet rail parks a resident model on it
#   * never touch the rail's serving config; only POST /models/unload, which the
#     router re-loads on the next request (--models-max 1)
#   * KV q8_0 K==V; iq4_nl silently runs attention on the CPU (llama.cpp #27109)
#   * reasoning off, temp 0, seed 42, flash-attn
#   * real multi-thousand-token prompt, GPU sampled during the run
#   * unload everything at the end; confirm we are back at baseline
#
# Usage: ./bench-maestro-llm.sh [ctx ...]     (default: 32k 64k 128k)
set -u

GGUF=${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app/ckpts/llm/gemma-4-E4B-it-heretic-GGUF/gemma-4-E4B-it-heretic-Q4_K_M.gguf
BENCH=$HOME/.agents/skills/modeltesting/scripts/bench-ctx.sh
RAIL=http://127.0.0.1:8080
CTXS=("${@:-32768 65536 131072}")
read -r -a CTXS <<< "${CTXS[*]}"

KEY=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.pi/agent/auth.json')))['llama-swap']['key'])" 2>/dev/null)

free_mb() { nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits; }
used_mb() { nvidia-smi --query-gpu=memory.used  --format=csv,noheader,nounits; }

echo "=== 0. free the card ==============================================="
MODEL=$(curl -s --max-time 5 "$RAIL/v1/models" -H "Authorization: Bearer $KEY" 2>/dev/null \
        | python3 -c 'import sys,json
d=json.load(sys.stdin)
for m in d.get("data",[]):
    if m.get("status",{}).get("value")=="loaded": print(m["id"]); break' 2>/dev/null)
echo "baseline used: $(used_mb) MiB (free $(free_mb))"
if [ "$(free_mb)" -lt 12000 ]; then
  # Must target the model whose status is "loaded" -- /v1/models lists every
  # alias, so data[0] is arbitrary and the rail answers "model is not running"
  # while its 13.7 GiB child is still holding the card.
  echo "rail resident: ${MODEL:-<detected none but card is full>}"
  [ -n "${MODEL:-}" ] && curl -s --max-time 10 -X POST "$RAIL/models/unload" \
       -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
       -d "{\"model\":\"$MODEL\"}" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    [ "$(free_mb)" -ge 12000 ] && break
    sleep 1
  done
  echo "after unload:  used $(used_mb) MiB (free $(free_mb))"
  if [ "$(free_mb)" -lt 12000 ]; then
    echo "FATAL: only $(free_mb) MiB free. Something outside the rail is"
    echo "       holding VRAM; bench numbers would be wrong. Find it with:"
    echo "       nvidia-smi --query-compute-apps=pid,used_memory --format=csv"
    exit 1
  fi
fi

if [ ! -f "$GGUF" ]; then
  echo "FATAL: $GGUF missing — download not finished?"; exit 1
fi

echo
echo "=== 1. model facts ================================================="
ls -la "$GGUF" | awk '{printf "weights: %.2f GiB\n", $5/1073741824}'
/usr/local/bin/llama-server --version 2>/dev/null | grep -i version | sed 's/^/server:  /'
python3 -c 'import sys; sys.exit(0)' 2>/dev/null && PYBIN=python3 || PYBIN=python3
# The gguf module only exists in Maestro's venv, not in the system python.
GGUF_PY=${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app/env/bin/python
[ -x "$GGUF_PY" ] || { echo "  (venv python missing — skipping metadata)"; exit 0; }
"$GGUF_PY" - "$GGUF" <<'PY' 2>/dev/null || echo "  (metadata read skipped — gguf module unavailable)"
import sys

from gguf import GGUFReader
r = GGUFReader(sys.argv[1], "r")
kv = {}
for f in r.fields.values():
    try: kv[f.name] = f.contents()
    except Exception: pass
arch = kv.get('general.architecture', '?')
print(f"  architecture : {arch}")
print(f"  name         : {kv.get('general.name','?')}")
for k, v in kv.items():
    tail = k.split('.', 1)[1] if '.' in k else k
    if k.startswith(arch + '.') and any(s in tail for s in (
            'context_length','block_count','expert_count','expert_used_count',
            'head_count','feed_forward_length','embedding_length')):
        try: print(f"  {tail:22s}: {int(v):,}")
        except Exception: print(f"  {tail:22s}: {v}")
PY

echo
echo "=== 2. context sweep (pure GPU, KV q8_0/q8_0) ======================"
for CTX in "${CTXS[@]}"; do
  echo "--- ctx $CTX ---"
  "$BENCH" "maestro-e4b-${CTX}" "$GGUF" "$CTX" 0 q8_0 q8_0 2048 2>&1 \
    | grep -E "RESULT|OOM|TIMEOUT" || echo "  (no RESULT line — see /tmp/bench-ctx-maestro-e4b-${CTX}.log)"
done

echo
echo "=== 3. release the card ============================================"
pkill -f "llama-server.*maestro-e4b" 2>/dev/null
pkill -f "port 9099" 2>/dev/null
pkill -f "9099" 2>/dev/null
sleep 3
echo "final used: $(used_mb) MiB (free $(free_mb))"
echo "rail reloads on demand — nothing to restart."
