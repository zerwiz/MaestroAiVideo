#!/usr/bin/env bash
# watch-job.sh JOB — poll a Maestro job until it leaves queued/running, then ffprobe the output.
JOB="${1:?usage: watch-job.sh JOB_ID}"
OUT=/tmp/watch-$JOB.log
: > "$OUT"
for i in $(seq 1 200); do
  S=$(curl -s -m 10 "http://127.0.0.1:7860/api/v1/status/$JOB" 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  print(d.get('status'),d.get('progress'),(d.get('phase') or '')[:40],str(d.get('error'))[:80])
except Exception: print('unreachable')" 2>/dev/null)
  echo "$(date +%H:%M:%S) $S" >> "$OUT"
  case "$S" in
    completed*|done*|success*|failed*|error*|cancelled*) echo "TERMINAL: $S" >> "$OUT"; break;;
  esac
  sleep 20
done
F=$(ls -t ${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app/outputs/*.mp4 2>/dev/null | head -1)
[ -n "$F" ] && { echo "=== newest: $F" >> "$OUT"
  ffprobe -v error -show_entries stream=codec_name,width,height,nb_frames,r_frame_rate \
          -show_entries format=duration,size -of default=nw=1 "$F" >> "$OUT" 2>&1
  ffmpeg -v error -i "$F" -f null - >>"$OUT" 2>&1 && echo "decode: clean" >> "$OUT"; }
echo "WATCH DONE" >> "$OUT"
