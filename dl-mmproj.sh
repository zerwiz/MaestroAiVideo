#!/usr/bin/env bash
# dl-mmproj.sh — fetch the gemma-4 planner's vision projector into the exact
# path Maestro resolves (llm_service.py:1828 -> cache_dir = base/<model_stem>,
# model_stem = repo basename with "-GGUF" stripped). Same stall-resistant curl
# approach as dl-gguf.sh: hf_xet freezes these transfers on this machine.
set -u
D=${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app/ckpts/llm/gemma-4-E4B-it-heretic
URL="https://huggingface.co/Abiray/gemma-4-E4B-it-heretic-GGUF/resolve/main/mmproj-F16.gguf"
OUT="$D/mmproj-F16.gguf"
mkdir -p "$D"
for i in $(seq 1 200); do
  if curl -L -C - --fail --silent --show-error \
        --speed-limit 20480 --speed-time 30 \
        --retry 5 --retry-delay 5 -o "$OUT" "$URL"; then
    echo "DONE $OUT ($(stat -c%s "$OUT") bytes)"
    exit 0
  fi
  echo "attempt $i stalled, resuming from $(stat -c%s "$OUT" 2>/dev/null || echo 0)"
  sleep 3
done
echo "GAVE UP"; exit 1
