#!/usr/bin/env bash
# queue-10eros-full.sh — wait for the running LoRA fetch, then pull the full
# NSFW checkpoint stack. Sequential, not parallel: on this ~2 MiB/s link two
# concurrent transfers would each run at half speed and neither would finish.
set -u

echo "queue: waiting for any running fetch-10eros to finish..."
while pgrep -f "fetch-10eros.sh lora" >/dev/null 2>&1; do
  sleep 20
done
echo "queue: lora fetch done at $(date +%T); starting full stack"
"$(dirname "$0")/fetch-10eros.sh" full
echo "queue: full stack done at $(date +%T)"
