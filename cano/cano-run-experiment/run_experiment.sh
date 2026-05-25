#!/bin/bash
# Reference template: single-cell dispatcher.
# Lives at .claude/skills/run-experiment/run_experiment.sh.
#
# Use as-is for the standard case (one config = one cell). Only copy + adapt
# into a per-experiment directory if your dispatch genuinely deviates from the
# protocol below — and keep the contract identical when you do, so cells stay
# re-runnable through this template.
#
# Reads <config.json>, looks up its `.entrypoint`, and dispatches it as:
#
#   <entrypoint> --config <abs_config_path> [extra args...]
#
# `.entrypoint` is one of:
#   - "<path>.py"  -> python -u <path> --config <cfg> [args...]
#   - "<path>.sh"  -> bash      <path> --config <cfg> [args...]
#   - "<path>"     -> "<path>"        --config <cfg> [args...]   (executable; uses shebang)
#   - "<module>"   -> python -u -m <module> --config <cfg> [args...]   (when no file exists at that path)
#
# Paths in `.entrypoint` are resolved relative to the **experiment directory**
# — i.e. the parent of the directory holding the config file. Convention:
#   <exp>/configs/<note>.json    ← the cell's config
#   <exp>/runner.{py,sh,…}       ← entrypoint (typically just "runner.py")
# This makes the cell self-contained: configs reference siblings of their
# parent dir, not paths relative to the repo root.
#
# Usage:
#   ./.claude/skills/run-experiment/run_experiment.sh <config.json> [extra args]
#
# The contract a runner MUST honour:
#   1. Accept `--config <abs_path>` as the first arg; treat extras as forwarded.
#   2. Snapshot the config into both the result dir and the per-run log dir.
#   3. Handle SIGTERM cleanly (so `kill -TERM` from the batched dispatcher
#      doesn't orphan subprocesses).
set -euo pipefail
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck disable=SC1091
source "$REPO_DIR/.venv/bin/activate"

CFG="${1:-}"
[ -z "$CFG" ] && { echo "Usage: $0 <config.json> [extra args...]"; exit 1; }
[ -f "$CFG" ] || { echo "Config not found: $CFG"; exit 1; }
shift
CFG_ABS="$(realpath "$CFG")"

ENTRYPOINT=$(jq -r '.entrypoint // empty' "$CFG")
[ -z "$ENTRYPOINT" ] && { echo "Config $CFG missing required field .entrypoint"; exit 1; }

# experiment dir = parent of the configs/ dir holding $CFG
EXP_DIR="$(dirname "$(dirname "$CFG_ABS")")"
cd "$EXP_DIR"

ENTRY_PATH="$EXP_DIR/$ENTRYPOINT"
if [ -f "$ENTRY_PATH" ]; then
  case "$ENTRYPOINT" in
    *.py) exec python -u "$ENTRY_PATH" --config "$CFG_ABS" "$@" ;;
    *.sh) exec bash       "$ENTRY_PATH" --config "$CFG_ABS" "$@" ;;
    *)    exec            "$ENTRY_PATH" --config "$CFG_ABS" "$@" ;;
  esac
else
  # No file at that path — treat as a python module path (rooted at $EXP_DIR).
  exec python -u -m "$ENTRYPOINT" --config "$CFG_ABS" "$@"
fi
