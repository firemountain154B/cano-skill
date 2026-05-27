#!/bin/bash
# Reference template: batched GPU-pool sweep dispatcher.
# Lives at .claude/skills/run-experiment/batched_run_experiments.sh.
#
# Use as-is for the standard case (configs dir → one job per GPU). Copy +
# adapt only if your sweep needs custom dispatch (dependency-ordered cells,
# multi-host, non-GPU resources). Keep the SIGINT trap and per-cell log
# layout — they are part of the contract every cell-author depends on.
#
# Walks <configs_dir>/*.json, expands any sweep templates into concrete cells
# under <exp>/sweep_runs/<ts>/, and dispatches each cell through run_experiment.sh
# (sibling of the caller, or fallback to the skill's reference template) — one
# job per GPU in $GPU_LIST (default "0"), parallel up to |GPU_LIST|.
# Files starting with "_" (e.g. _template.json) are skipped.
#
# Sweep declaration (at the top of a template config). Three forms:
#
#   single axis:
#     "sweep": { "axis": "seed", "path": ".eval.seed_start",
#                "values": [42, 43, 44] }
#
#   zipped multi-axis (N parameters move together — 1 cell per tuple):
#     "sweep": { "axis":  ["model", "spec_model"],
#                "path":  [".server.model", ".server.speculative_config.model"],
#                "values": [["Qwen/Qwen3-8B",  "Tengyunw/qwen3_8b_eagle3"],
#                           ["Qwen/Qwen3-32B", "AngelSlim/Qwen3-32B_eagle3"]] }
#
#   Cartesian (sweep = array of axis specs — product across all):
#     "sweep": [
#       { "axis": "topk", "path": ".server.compression_config.topk",
#         "values": [50, 100, 200] },
#       { "axis": "seed", "path": ".eval.seed_start",
#         "values": [42, 43, 44, 45] }
#     ]
#
# Templates without `.sweep` pass through as-is. Single-cell mode
# (run_experiment.sh) treats `.sweep` as inert metadata — it ignores it
# and runs the template's default values.
#
# When invoked from a local copy at <exp>/batched_run_experiments.sh with
# no arg, defaults to <exp>/configs. From the skill folder, pass <configs_dir>
# explicitly.
#
# Usage:
#   <exp>/batched_run_experiments.sh                       # defaults to ./configs
#   <exp>/batched_run_experiments.sh <configs_dir>
#   GPU_LIST="0 1 2 3" <exp>/batched_run_experiments.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

CFG_DIR="${1:-$SCRIPT_DIR/configs}"
[ -d "$CFG_DIR" ] || { echo "Not a directory: $CFG_DIR"; echo "Usage: $0 [configs_dir]"; exit 1; }
CFG_DIR="$(cd "$CFG_DIR" && pwd)"

# Experiment dir = parent of configs/. Logs land under <exp>/logs/, not at repo root.
EXP_DIR="$(dirname "$CFG_DIR")"

# Where expanded sweep cells land (one file per axis value).
TS=$(date +%Y%m%d_%H%M%S)
SWEEP_DIR="$EXP_DIR/sweep_runs/$TS"

# Expand a template into one or more cell files printed on stdout.
#
# `.sweep` may be:
#   (a) one axis spec (object), or
#   (b) an array of axis specs — Cartesian product across them.
# Each axis spec is one of:
#   single:  { axis: "seed",            path: ".eval.seed_start",  values: [42, 43, …] }
#   zipped:  { axis: ["model","spec"],  path: [".a", ".b"],         values: [["m1","s1"], ["m2","s2"]] }
#
# Cell count = product over axis specs of len(values). Templates without
# `.sweep` pass through unchanged.
expand_template() {
  local tpl=$1
  if [ "$(jq 'has("sweep")' "$tpl")" != "true" ]; then
    echo "$tpl"; return
  fi
  mkdir -p "$SWEEP_DIR"
  jq -c '
    . as $tpl
    | ($tpl.sweep | if type == "array" then . else [.] end) as $sweeps
    | ($sweeps | map({
        axes:  (.axis  | if type == "array" then . else [.] end),
        paths: (.path  | if type == "array" then . else [.] end),
        rows:  (.values | if (length > 0) and (.[0] | type == "array") then .
                          else map([.]) end)
      })) as $sw
    | [$sw[].rows] | combinations as $picked
    | $tpl
    | reduce range(0; $sw | length) as $i (.;
        reduce range(0; $sw[$i].axes | length) as $j (.;
          setpath(($sw[$i].paths[$j] | ltrimstr(".") | split(".")); $picked[$i][$j])))
    | del(.sweep)
    | .note = ($tpl.note + "_" +
        ([range(0; $sw | length) as $i
          | range(0; $sw[$i].axes | length) as $j
          | "\($sw[$i].axes[$j])\($picked[$i][$j] | tostring | gsub("[^A-Za-z0-9.]"; "_"))"]
          | join("_")))
  ' "$tpl" | while IFS= read -r cell; do
    local tag out
    tag=$(echo "$cell" | jq -r '.note')
    out="$SWEEP_DIR/${tag}.json"
    echo "$cell" | jq . > "$out"
    echo "$out"
  done
}

# Collect cells. Expand any template with a top-level .sweep declaration;
# concrete configs (no .sweep) pass through unchanged. _*.json is skipped.
CONFIGS=()
for f in "$CFG_DIR"/*.json; do
  [ -f "$f" ] || continue
  bn=$(basename "$f")
  [[ "$bn" == _* ]] && continue
  while IFS= read -r line; do
    [ -n "$line" ] && CONFIGS+=("$line")
  done < <(expand_template "$f")
done
[ ${#CONFIGS[@]} -eq 0 ] && { echo "No runnable cells in $CFG_DIR (excluding _*.json)"; exit 1; }

# GPU pool
GPU_LIST=(${GPU_LIST:-0})
MAX_CONCURRENT=${#GPU_LIST[@]}

LOG_DIR="$EXP_DIR/logs/batched_${TS}"
mkdir -p "$LOG_DIR"

echo "=========================================="
echo " Batched run | $(basename "$CFG_DIR")"
echo " Configs:    ${#CONFIGS[@]}"
echo " GPU pool:   ${GPU_LIST[*]}  (max concurrent: $MAX_CONCURRENT)"
echo " Logs:       $LOG_DIR"
echo "=========================================="
for f in "${CONFIGS[@]}"; do
  echo "  - $(basename "$f")"
done
echo ""

declare -A running_jobs gpu_status
for gpu in "${GPU_LIST[@]}"; do gpu_status[$gpu]=""; done

job_index=0
completed=0
failed=0
declare -a results  # "rc|gpu|note|logfile"

cleanup() {
  echo ""
  echo ">>> Interrupted, killing ${#running_jobs[@]} running job(s)..."
  for pid in "${!running_jobs[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM -- -"$pid" 2>/dev/null || pkill -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  sleep 2
  for pid in "${!running_jobs[@]}"; do
    kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  echo "completed=$completed failed=$failed cancelled=${#running_jobs[@]} not_started=$(( ${#CONFIGS[@]} - job_index ))"
  exit 130
}
trap cleanup SIGINT SIGTERM

find_free_gpu() {
  for gpu in "${GPU_LIST[@]}"; do
    [ -z "${gpu_status[$gpu]}" ] && { echo "$gpu"; return 0; }
  done
  return 1
}

start_job() {
  local gpu=$1 cfg=$2
  local note
  note=$(jq -r '.note' "$cfg")
  local logfile="$LOG_DIR/${note}.log"
  echo "[$(date +%H:%M:%S)] start | gpu=$gpu | $note"
  # Prefer a sibling run_experiment.sh (local copy in $EXP_DIR), fall back to
  # the one alongside this dispatcher (e.g. the skill template).
  local runner="$EXP_DIR/run_experiment.sh"
  [ -f "$runner" ] || runner="$SCRIPT_DIR/run_experiment.sh"
  CUDA_VISIBLE_DEVICES=$gpu setsid bash "$runner" "$cfg" \
    > "$logfile" 2>&1 &
  local pid=$!
  running_jobs[$pid]="$gpu|$note|$logfile"
  gpu_status[$gpu]=$pid
  echo "             pid=$pid  log=$logfile"
}

check_completed() {
  for pid in "${!running_jobs[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      IFS='|' read -r gpu note logfile <<< "${running_jobs[$pid]}"
      wait "$pid"; rc=$?
      if [ $rc -eq 0 ]; then
        echo "[$(date +%H:%M:%S)] done  | gpu=$gpu | $note"
        ((completed++))
      else
        echo "[$(date +%H:%M:%S)] FAIL  | gpu=$gpu | $note  (rc=$rc)  log=$logfile"
        ((failed++))
      fi
      results+=("$rc|$gpu|$note|$logfile")
      gpu_status[$gpu]=""
      unset 'running_jobs[$pid]'
    fi
  done
}

while [ $job_index -lt ${#CONFIGS[@]} ] || [ ${#running_jobs[@]} -gt 0 ]; do
  check_completed
  while [ $job_index -lt ${#CONFIGS[@]} ]; do
    free_gpu=$(find_free_gpu) || break
    start_job "$free_gpu" "${CONFIGS[$job_index]}"
    ((job_index++))
  done
  sleep 5
done

echo ""
echo "=========================================="
echo " Done. completed=$completed  failed=$failed  total=${#CONFIGS[@]}"
echo " Logs: $LOG_DIR"
echo "=========================================="
for line in "${results[@]}"; do
  IFS='|' read -r rc gpu note logfile <<< "$line"
  status=$([ "$rc" -eq 0 ] && echo "OK" || echo "FAIL(rc=$rc)")
  printf "  %-6s gpu=%-2s  %-40s  %s\n" "$status" "$gpu" "$note" "$logfile"
done
