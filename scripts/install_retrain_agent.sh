#!/usr/bin/env bash
# Install (or remove) the launchd agent that retrains typer-1 in the background.
#
# It runs `training/train.sh retrain-if-ready` on a timer. That guard only actually trains
# when it won't bother you — enough new captured samples (RETRAIN_EVERY), on AC power, you've
# been idle a while (RETRAIN_IDLE), and there's disk to spare. Training itself is the same
# <1 GB, resumable path the cold-start uses, and a freshly retrained model is promoted over
# the live one only if it doesn't regress on your real accepts (a rollback copy is kept).
#
#   scripts/install_retrain_agent.sh            install + start the agent
#   scripts/install_retrain_agent.sh --uninstall   stop + remove it
#
# Tune cadence/thresholds by editing the env vars in the generated plist, or override per the
# defaults in train.sh (RETRAIN_EVERY, RETRAIN_IDLE, RETRAIN_MIN_FREE_GB, INTERVAL).
set -euo pipefail

LABEL="xyz.frgmt.typer.retrain"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/typer-retrain.log"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAINING_DIR="$ROOT_DIR/training"
INTERVAL="${INTERVAL:-1800}"   # seconds between condition checks (default 30 min)

uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed $LABEL"
  exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

[ -x "$TRAINING_DIR/train.sh" ] || { echo "train.sh not found/executable at $TRAINING_DIR" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"

# A login shell so the agent inherits the user's PATH (uv, etc.); Background process type +
# Nice keep it off the user's toes; StartInterval re-checks on a timer (the guard exits fast
# when conditions aren't met). RunAtLoad does one check shortly after login.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>cd "$TRAINING_DIR" && ./train.sh retrain-if-ready</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

# Reload cleanly whether or not a previous copy is running.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"

echo "installed $LABEL"
echo "  checks every ${INTERVAL}s; trains only on AC + idle with >= \$RETRAIN_EVERY new samples"
echo "  log:  $LOG"
echo "  stop: scripts/install_retrain_agent.sh --uninstall"
