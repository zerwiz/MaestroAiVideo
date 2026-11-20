# AGENTS.md — MaestroAiVideo

The contract for any agent working in this repository. Read it before you download a model, start the forge, or
raise a container. It is append-only: correct a section by adding a new dated one below it, never by editing.

## 2026-11-20 — disk, models and containers

Written on the day the machine's root disk filled to 100 %. This repository was the largest single folder on it:
**234 GiB**, of which **209 GiB** is model checkpoints in `app/ckpts/`. When the disk fills, btrfs stops accepting
writes, containers cannot be removed, and the whole machine stalls. These rules exist so this repository never
causes that again.

### Check the disk before you download or build

- Run `df -h /` first. If less than **50 GiB** is free, stop and tell the operator instead of downloading a
  checkpoint, a GGUF, a LoRA or a Python environment.
- Say the size before you fetch. A download of more than 5 GiB is announced with its size and waits for a yes.

### One copy of every model file

- A model lives **once**, in `app/ckpts/`. Never copy a checkpoint into a second folder to satisfy a loader.
- If a loader needs the file under another name or path, use a **hard link** (`ln`), not a copy. On btrfs a hard
  link costs nothing.
- Example of the right way: `qwen3vl-32B-MiniMax-H3-Q2_K.gguf` appears under three paths in `app/`, but all three
  are hard links to one 7.9 GiB file (link count 7, identical checksum). Deleting a path frees nothing. Check
  `ls -l` (the link count) before calling anything a duplicate.
- Before downloading a model, search for it: `find app/ckpts -iname '*<name>*'`. A second download of a model that
  is already present is the commonest way this folder grows.

### Remove what a test leaves behind

- A trial render, a benchmark or a probe writes to a scratch folder and deletes it when done. Rendered output that
  is kept goes to the operator's output folder, never into `app/`.
- Python environments (`app/env`, 13 GiB) are rebuilt in place, not duplicated beside the old one.

### Containers

- The forge runs as a host process, not in a container. Do not wrap it in Docker or Podman.
- If a task truly needs a container, follow the machine's container law in the home folder's `AGENTS.md`: look
  before you raise (`docker ps -a`), no second copy of a running service, `--rm` for one-shot jobs, no restart
  policy for trials, a label naming the owner, and take down what you raised before you report.
- Podman does not work on this machine's btrfs (`overlay is not supported over btrfs`). Use Docker.

### Start and stop

- Start and stop only with `./stop-maestro.sh --purge && ./start-maestro.sh`, then check the socket:
  `ss -tln | grep ':7860'`. A green systemd unit is not proof the forge is reachable — on a busy port it silently
  binds the next one.
