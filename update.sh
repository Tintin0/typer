#!/usr/bin/env bash
# Typer updater (macOS). The install.sh counterpart for staying current: fast-forwards
# this checkout to the latest upstream commits, rebuilds + re-signs the app, and relaunches
# it. Safe to run any time.
#
#   ./update.sh           update if behind, then rebuild + relaunch
#   ./update.sh --check   print how many commits behind upstream (no changes), then exit
#   ./update.sh --force   rebuild + relaunch even when already up to date
#
# The menu-bar "Check for updates" button runs this in the background (with --check first
# to count commits, then a plain run to install). Progress goes to stderr so that --check's
# single stdout line is a clean integer the app can parse.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/Typer.app"

cd "$ROOT_DIR"
say() { echo "==> $*" >&2; }   # progress on stderr; stdout is reserved for --check's count

[ "$(uname -s)" = "Darwin" ] || { echo "Typer is macOS-only." >&2; exit 1; }
command -v git >/dev/null || { echo "git not found." >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not a git checkout: $ROOT_DIR" >&2; exit 1; }

MODE="${1:-}"

# Upstream tracking branch (falls back to origin/main if none is configured).
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo origin/main)"
REMOTE="${UPSTREAM%%/*}"

say "fetching $UPSTREAM"
git fetch --quiet "$REMOTE" 2>/dev/null || git fetch --quiet

BEHIND="$(git rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)"
AHEAD="$(git rev-list --count "$UPSTREAM..HEAD" 2>/dev/null || echo 0)"

if [ "$MODE" = "--check" ]; then
  echo "$BEHIND"            # the one clean line on stdout the app parses
  exit 0
fi

if [ "$BEHIND" = "0" ] && [ "$MODE" != "--force" ]; then
  say "already up to date"
  exit 0
fi

if [ "$BEHIND" != "0" ]; then
  # Only fast-forward. If the local checkout has its own commits, don't risk an auto-merge —
  # leave it for the user to reconcile by hand.
  if [ "$AHEAD" != "0" ]; then
    echo "Local checkout is $AHEAD commit(s) ahead of $UPSTREAM; refusing to auto-merge." >&2
    echo "Reconcile manually (e.g. 'git pull --rebase') then re-run." >&2
    exit 1
  fi
  say "updating $BEHIND commit(s) from $UPSTREAM"
  git merge --ff-only "$UPSTREAM"
fi

# build.sh compiles, re-signs, then kills the running app at the very end. This script is a
# separate process (not matched by build.sh's pkill), so it survives that and relaunches.
say "rebuilding"
bash "$ROOT_DIR/scripts/build.sh" >&2

say "relaunching"
open "$APP"
say "update complete"
