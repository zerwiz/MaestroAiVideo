#!/usr/bin/env bash
# render-viking.sh — the 4 clips of pipeline e9acf252 ("a viking telling about
# multi-agent orchestration") on the resident ltx2_22B_distilled_1_1.
#
# The Director's own prompts are ~500 words with 3-4 conflicting camera moves
# and TTS dialogue tags. Per assets/video-prompts.md: ONE camera instruction
# per shot. These are the distilled versions; wardrobe and screen-direction
# blocking are byte-identical across all four so the Viking reads as one
# character (the asset's consistency mechanism).
#
# Sequential, not parallel: one generate slot, one resident model.
set -uo pipefail
API=http://127.0.0.1:7860
MODEL=ltx2_22B_distilled_1_1
RES=1280x720
FRAMES=145          # ~5.8s at 25fps; VO rides in post via piper (house rule 3)
LOG=/tmp/render-viking.log
: > "$LOG"

declare -a P=(
"INT. ESTABLISHED STORY LOCATION. Medium close-up, eye-level. A rugged viking man in his 40s, weathered face, intense blue eyes, heavy dark brown tunic over a worn grey linen shirt, thick leather belt, simple iron torque around his neck, stands center foreground facing screen-right, leaning slightly forward over an unseen surface. Behind him a large rough-hewn stone hall with wooden support beams in muted earthen tones. Dramatic single-source overhead lighting casting deep shadows, low-key. Slow, subtle push in. He shifts his weight and raises one gauntleted hand, palm open, as if presenting a concept for judgment, then holds the pose with his gaze steady. Slight film grain. No readable text."
"INT. ESTABLISHED STORY LOCATION. Medium shot, eye-level. The same rugged viking man, weathered face, intense blue eyes, heavy dark brown tunic over a worn grey linen shirt, thick leather belt, simple iron torque around his neck, stands center midground facing screen-right, leaning forward, gesturing with both hands. The same rough stone hall with wooden beams behind him. The overhead light intensifies slightly, casting sharper highlights on his brow and hands. Slight lateral pan left to right. He spreads both hands outward, palms up, then drops them firmly downward. Slight film grain. No readable text."
"INT. ESTABLISHED STORY LOCATION. Medium shot, slightly low angle. The same rugged viking man, weathered face, intense blue eyes, heavy dark brown tunic over a worn grey linen shirt, thick leather belt, simple iron torque around his neck, stands center foreground facing screen-right, feet planted wide. The massive stone hall behind him, dark wooden support beams heavy in the frame. Warm firelight washes in from the right, matching his gesture. Slow vertical tilt up. He sweeps his arm out toward the right edge of the frame, then brings his hand down, cupping the air. Slight film grain. No readable text."
"INT. ESTABLISHED STORY LOCATION. Medium close-up, eye-level. The same rugged viking man, weathered face, intense blue eyes, heavy dark brown tunic over a worn grey linen shirt, thick leather belt, simple iron torque around his neck, stands center foreground facing the camera directly. The immense stone hall recedes behind him. Soft, encompassing warm firelight. Slow, steady dolly in. He lowers his outstretched arm, takes a deliberate half-step toward the camera, and settles his gaze onto the lens, a small wry smirk crossing his face. Slight film grain. No readable text."
)

for i in 0 1 2 3; do
  echo "=== clip $i  $(date +%H:%M:%S) ===" >> "$LOG"
  R=$(curl -s -m 60 -X POST "$API/api/v1/generate" -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys;print(json.dumps({'model_type':'$MODEL','prompt':sys.argv[1],'resolution':'$RES','frames':$FRAMES,'seed':42}))" "${P[$i]}")")
  JOB=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null)
  echo "job=$JOB" >> "$LOG"
  [ -z "$JOB" ] && { echo "SUBMIT FAILED: $R" >> "$LOG"; continue; }
  for _ in $(seq 1 220); do
    sleep 15
    S=$(curl -s -m 10 "$API/api/v1/status/$JOB" 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin); print(d.get('status',''),d.get('progress',''),(d.get('phase') or '')[:34],str(d.get('error') or '')[:60])
except Exception: print('unreachable','','','')" 2>/dev/null)
    case "$S" in completed*|failed*|error*|cancelled*) echo "  -> $S" >> "$LOG"; break;; esac
  done
  F=$(ls -t ${MAESTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}/app/outputs/*.mp4 2>/dev/null | head -1)
  [ -n "$F" ] && { echo "  file: $(basename "$F")" >> "$LOG"
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$F" >> "$LOG" 2>&1; }
done
echo "ALL DONE $(date +%H:%M:%S)" >> "$LOG"
