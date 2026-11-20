#!/usr/bin/env bash
# dl-gguf.sh — resumable download of Maestro's default LLM planner GGUF.
# hf_xet chunks this file and stalls on this machine (3 of 4 chunks hung at
# ~200 MiB), so plain curl with --speed-limit/--speed-time watchdog + range
# resume is the reliable path. 200 attempts covers a 5 GiB file on this link.
set -u
D=${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app/ckpts/llm/gemma-4-E4B-it-heretic-GGUF
URL="https://huggingface.co/Abiray/gemma-4-E4B-it-heretic-GGUF/resolve/main/gemma-4-E4B-it-heretic-Q4_K_M.gguf"
OUT="$D/gemma-4-E4B-it-heretic-Q4_K_M.gguf"
mkdir -p "$D"
for i in $(seq 1 200); do
  if curl -L -C - --fail --silent --show-error \
        --speed-limit 20480 --speed-time 30 \
        --retry 5 --retry-delay 5 -o "$OUT" "$URL"; then
    echo "DONE $OUT"
    exit 0
  fi
  echo "attempt $i stalled, resuming from $(stat -c%s "$OUT" 2>/dev/null || echo 0) bytes"
  sleep 3
done
echo "GAVE UP"
exit 1
