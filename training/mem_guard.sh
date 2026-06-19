#!/usr/bin/env bash
# Run a command under a hard resident-memory cap. Samples the RSS of any mlx_lm training
# worker every few seconds and, if it crosses the cap, kills the run — which is SAFE because
# train.sh's SFT is chunked + checkpointed, so a kill costs at most one WINDOW of iters and
# `./train.sh sft` resumes from the last checkpoint.
#
# Measured peak for the 0.6B distill (8 layers, seq 512, batch 1, grad-checkpoint, 4-bit base)
# is ~1.0 GB, so the default 1900 MB cap is a safety net that should never fire — it exists to
# guarantee the "under 2 GB" requirement even if cache/seq growth pushes memory up.
#
#   MEM_CAP_MB=1900 ./mem_guard.sh ./train.sh sft
set -uo pipefail

CAP_MB="${MEM_CAP_MB:-1900}"
POLL="${MEM_POLL:-3}"
MATCH="${MEM_MATCH:-mlx_lm}"          # which worker process to watch (command-line substring)

"$@" &
cmd=$!

worker_rss_mb() {                      # max RSS (MB) across matching workers; 0 if none
    /bin/ps -axo rss=,command= 2>/dev/null \
      | /usr/bin/grep -i "$MATCH" | /usr/bin/grep -v grep \
      | /usr/bin/awk '{print $1}' | /usr/bin/sort -rn | /usr/bin/head -1 \
      | /usr/bin/awk '{printf "%d", $1/1024}'
}

peak=0
while kill -0 "$cmd" 2>/dev/null; do
    mb="$(worker_rss_mb)"; mb="${mb:-0}"
    [ "$mb" -gt "$peak" ] && peak="$mb"
    if [ "$mb" -gt "$CAP_MB" ]; then
        echo "!! mem_guard: worker RSS ${mb}MB > ${CAP_MB}MB cap — killing (resumable; re-run to continue)" >&2
        /usr/bin/pkill -f "$MATCH" 2>/dev/null
        kill "$cmd" 2>/dev/null
        wait "$cmd" 2>/dev/null
        exit 42
    fi
    sleep "$POLL"
done
wait "$cmd"; rc=$?
echo "mem_guard: peak worker RSS ${peak}MB (cap ${CAP_MB}MB), exit ${rc}" >&2
exit "$rc"
