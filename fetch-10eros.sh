#!/usr/bin/env bash
# fetch-10eros.sh — pull the LTX-2.3 mature line-up onto this machine.
#
# Two independent routes:
#   lora   adrepale/LTX2.3-10Eros-LoRA   (11.5 GiB) layers onto the base
#          LTX-2.3 22B already on disk — no second backbone.
#   full   TenStrip/LTX2.3-10Eros v1.4    (27.2 GiB FP8) + the abliterated
#          Gemma text encoder (11.9 GiB) that the checkpoint expects.
#
#   ./fetch-10eros.sh lora
#   ./fetch-10eros.sh full
#   ./fetch-10eros.sh lora full
#
# Uses curl range-resume with a stall watchdog rather than hf_hub_download:
# hf_xet freezes these transfers on this box (3 of 4 chunks stuck at ~200 MiB
# with the process alive and mtime moving). See ~/CodeP/MAESTRO-SETUP.md §6.
set -u

APP=${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app
LORA_DIR="$APP/loras"
FULL_DIR="$APP/ckpts"
LOG=/tmp/fetch-10eros.log

fetch() {  # url dest
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  for i in $(seq 1 400); do
    if curl -L -C - --fail --silent --show-error \
          --speed-limit 20480 --speed-time 30 \
          --retry 5 --retry-delay 5 -o "$dest" "$url"; then
      echo "DONE  $(stat -c%s "$dest")  $(basename "$dest")"
      return 0
    fi
    echo "  attempt $i stalled at $(stat -c%s "$dest" 2>/dev/null || echo 0) — resuming"
    sleep 3
  done
  echo "GAVE UP on $url"
  return 1
}

run_lora() {
  fetch "https://huggingface.co/adrepale/LTX2.3-10Eros-LoRA/resolve/main/10Eros_v1_Delta.safetensors" \
        "$LORA_DIR/10Eros_v1_Delta.safetensors"
}

run_full() {
  fetch "https://huggingface.co/TenStrip/LTX2.3-10Eros/resolve/main/text_encoders/gemma-3-12b-it-ablit-norms-biproj-fp8mixed.safetensors" \
        "$FULL_DIR/gemma-3-12b-it-ablit-norms-biproj-fp8mixed.safetensors"
  fetch "https://huggingface.co/TenStrip/LTX2.3-10Eros/resolve/main/10Eros_v1.4_fp8mixed_learned.safetensors" \
        "$FULL_DIR/10Eros_v1.4_fp8mixed_learned.safetensors"
}

echo "=== $(date +%T) fetch-10eros ===" | tee -a "$LOG"
for what in "$@"; do
  case "$what" in
    lora) echo "-- LoRA route (11.5 GiB)" | tee -a "$LOG"; run_lora   | tee -a "$LOG" ;;
    full) echo "-- full checkpoint route (39 GiB)" | tee -a "$LOG"; run_full | tee -a "$LOG" ;;
    *)    echo "unknown target: $what (use lora|full)" >&2; exit 2 ;;
  esac
done
echo "=== $(date +%T) finished ===" | tee -a "$LOG"
