#!/usr/bin/env bash
# fix-h3-offline-fetch.sh — make the MiniMax H3 chain loadable on a pre-filled forge.
#
# THE FAILURE (measured 2026-10-05, heimdall, RTX A5000 16 GiB):
#   A H3 job holds at "Loading model H3 Omni — Pruned..." for FORTY MINUTES with
#   286 MiB on the card and rchar at 0.0 GB. Nothing errors. The job never starts.
#
#   It is not a load. py-spy on the live process says exactly what it is doing:
#
#     xet_get (huggingface_hub/file_download.py:633)
#     _hf_hub_download_to_local_dir -> hf_hub_download
#     hf_download_with_public_fallback (wgp.py:3951) -> download_models
#     -> load_models -> generate_video
#
#   Every checkpoint is already on disk under app/ckpts/. The forge's "do I have
#   this file?" check fails, so it re-fetches a multi-GB file and hangs in
#   huggingface_hub's Xet backend. This network serves range requests and refuses
#   long single GETs — the same wall a 19.6 GB manual fetch hit for two days.
#
# THE FIX, two parts:
#   1. HF_HUB_OFFLINE=1 — the shelves are pre-filled, so it must not fetch. As a
#      systemd drop-in, so the vendor's unit is never edited.
#   2. The Qwen3-VL text encoder where hf_hub_download actually looks. It ships at
#      ckpts/qwen3vl-32b-minimax-h3/ and is resolved as
#      ckpts/<folder>/Qwen3-VL-32B-Instruct/<file>. Hardlinks, so no disk.
#
# WHAT THIS DOES NOT FIX: output that completes as full-frame RGB noise. That is a
# separate bug — the vendored WanGP predates Wan2GP #2071 and #2178 — and this
# script is not a claim about it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKPT="${1:-$HERE/app/ckpts}"
DEST="$CKPT/qwen3vl-32b-minimax-h3"
FILE="qwen3vl-32B-MiniMax-H3-Q2_K.gguf"

if [ ! -f "$DEST/$FILE" ]; then
  echo "text encoder not found: $DEST/$FILE" >&2
  echo "pass the ckpts dir as \$1 if it is elsewhere" >&2
  exit 1
fi

for d in "$DEST" "$DEST/Qwen3-VL-32B-Instruct" "$CKPT" "$CKPT/Qwen3-VL-32B-Instruct" "$(dirname "$CKPT")"; do
  mkdir -p "$d"
  [ -e "$d/$FILE" ] || ln "$DEST/$FILE" "$d/$FILE"
done

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/maestro.service.d"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/10-offline-hf.conf" <<'CONF'
# Why: a H3 job hung forever re-downloading a checkpoint already on disk.
# The stack is in fix-h3-offline-fetch.sh beside this file.
[Service]
Environment=HF_HUB_OFFLINE=1
Environment=HF_HUB_DISABLE_TELEMETRY=1
CONF

echo "linked the text encoder into every path hf_hub_download resolves"
echo "wrote $UNIT_DIR/10-offline-hf.conf"
echo "activate with: systemctl --user daemon-reload && systemctl --user restart maestro"
