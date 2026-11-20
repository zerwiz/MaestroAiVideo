# Maestro — local setup, see the home vault

The full setup document lives in the home vault (the canonical copy):

```
$YMIR_HOME/hodd/docs/developer-setup/maestro-video-forge.md
```

It records what Maestro v2.4.2 is, the hand install (no Pinokio),
the `MAESTRO_LLAMA_BIN=/usr/local/bin` fix that avoids a 15-minute llama.cpp
rebuild, every model on disk, the **verified** planner-LLM tuning numbers, and
the traps hit along the way (xet download stalls, bursty progress meters, the
`status.value == "loaded"` unload rule).

Operating rules and the **smoke-test ladder** live in the skill:

```
$YMIR_HOME/.agents/skills/maestro-video/SKILL.md
```

Machine-setup record: `~/CHANGELOG.md`.
Bench results, per the modeltesting skill's own ledgers:
`~/.agents/skills/modeltesting/backends-benchmark.md` §10.5.15 and
`~/.agents/skills/modeltesting/llamacpp/TESTING.md` §8.6.

## Quick reference

```bash
systemctl --user {start,stop,status} maestro     # the service
journalctl --user -u maestro -f                  # its log
./start-maestro.sh [port] [host]            # manual, emergency only
./bench-maestro-llm.sh 32768 65536 131072  # planner-LLM context sweep
./dl-gguf.sh                               # resumable HF downloader
./vram-probe.sh <ctx> [kvtype]             # load and read real VRAM
```

The one load-bearing env var is `MAESTRO_LLAMA_BIN=/usr/local/bin`. Without it
Maestro finds no `llama-server` in `app/ckpts/llm/bin` and **compiles llama.cpp
from source** — which reads exactly like a hung planner.
