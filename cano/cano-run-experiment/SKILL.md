---
name: cano-run-experiment
description: Set up or run experiments using this repo's two-tag self-contained convention. Each experiment lives at `a_<high>/<detailed>/` and contains its own configs, dispatcher scripts, and runner. The skill ships reference templates for the dispatcher scripts; when the user asks Claude to "set up experiment X" or "integrate this convention under a_<something>", read the templates, scaffold the experiment dir, and copy the templates in. Trigger phrases include "set up an experiment", "scaffold experiment under …", "integrate this convention", "跑一个 X 的 row/cell", "sweep over Y", "fill the table", "add a row", "summarise results", "batched run".
---

# run-experiment — self-contained experiment convention

Each experiment is a directory at `a_<high-level>/<detailed>/` that owns
everything needed to run it. The user picks both tags when authoring; the
skill's job is to scaffold the directory using the canonical pattern.

```
a_<high-level>/<detailed>/
├── configs/<note>.json          # one cell per file; .note == filename stem
├── run_experiment.sh            # local copy of the single-cell dispatcher
├── batched_run_experiments.sh   # local copy of the GPU-pool sweep dispatcher
└── runner.{py,sh,…}             # experiment-specific orchestrator
```

`a_<high-level>/` groups experiments by *what they measure*
(`a_accuracy`, `a_throughput`, `a_latency`, …). `<detailed>` is the
specific study within that family
(`a_accuracy/reasoning_qwen3_32b`, `a_throughput/long_context`,
`a_latency/sparse_decode`, …).

## What ships with this skill

- `SKILL.md` — this file.
- `run_experiment.sh` — **reference template** for the single-cell dispatcher.
- `batched_run_experiments.sh` — **reference template** for the sweep dispatcher.

The two `.sh` files are templates, not shared infrastructure. Each
experiment dir gets its own copy at scaffold time. Reasons:

- The experiment dir is then fully self-contained — `cd` into it and
  everything works without remembering paths up to the repo root.
- Per-experiment customisation (e.g. a sweep that needs special
  dependency ordering) is a simple in-place edit, not a fork that
  shadows shared infrastructure.
- The skill's templates remain authoritative reference: when copies drift
  in ways that don't make sense per-experiment, diff against the skill
  template and reconcile.

## The dispatcher contract

Templates assume this layout, and runners must honour it:

- A cell config sits at `<exp>/configs/<note>.json`.
- The cell's "experiment dir" is the **parent of its `configs/` dir**.
  The dispatcher resolves `.entrypoint` relative to that experiment dir.
- The runner accepts `--config <abs_path>` as its first arg and treats
  any further args as forwarded.
- The runner snapshots the config into the result dir AND the per-run
  log dir. Without that, the file is no longer the record.
- The runner handles SIGTERM cleanly so `kill -TERM` from the batched
  dispatcher doesn't strand subprocesses.

## Scaffolding a new experiment

When the user says "set up an experiment for X" or "integrate this
convention under `a_<something>/<...>`":

1. **Clarify both tags.** `<high-level>` is `a_accuracy` / `a_throughput`
   / `a_latency` / etc. — pick from existing siblings if present.
   `<detailed>` describes the specific study; one or two short tokens
   joined with `_`.
2. **Read the templates first.** Open this skill's
   `run_experiment.sh` and `batched_run_experiments.sh`. They define the
   contract every runner must match.
3. **Scaffold:**
   ```bash
   mkdir -p a_<high>/<detailed>/configs
   cp .claude/skills/run-experiment/run_experiment.sh \
      .claude/skills/run-experiment/batched_run_experiments.sh \
      a_<high>/<detailed>/
   chmod +x a_<high>/<detailed>/*.sh
   ```
4. **Author the runner.** `a_<high>/<detailed>/runner.{py,sh,…}`. Read
   `--config <path>` plus forwarded args, snapshot the config, do the
   work, propagate SIGTERM. For multi-experiment families that share
   eval/scoring code, place the shared modules at `a_<high>/eval/`
   (or wherever convenient at the high-level dir) and reach up from
   the runner — `a_accuracy/reasoning_qwen3_32b/runner.py` shows this
   pattern.
5. **Author at least one config.** `a_<high>/<detailed>/configs/<note>.json`
   with at minimum `.note` (== filename stem) and
   `.entrypoint` (typically `"runner.py"`, resolved relative to the
   experiment dir). The rest of the schema is whatever the runner
   needs.
6. **Validate:** `jq -e . a_<high>/<detailed>/configs/<note>.json >/dev/null`.

Reference: `a_accuracy/reasoning_qwen3_32b/` is a working example.

## Running

```bash
# single cell — from inside the experiment dir
cd a_<high>/<detailed>
./run_experiment.sh configs/<note>.json
./run_experiment.sh configs/<note>.json --eval-only           # forwarded extra args

# all cells in this experiment, GPU-parallel
GPU_LIST="0 1 2 3" ./batched_run_experiments.sh               # defaults to ./configs

# from anywhere in the repo
./a_<high>/<detailed>/run_experiment.sh a_<high>/<detailed>/configs/<note>.json
```

The skill's templates can also be invoked directly on any experiment's
configs (since `.entrypoint` is resolved relative to the config's parent
dir, not the dispatcher's). That's mainly for one-off ad-hoc runs;
normally use the local copy.

## Sweep templates (top-level `sweep` field)

Materialising N nearly-identical config files for a parameter sweep
(e.g. 8 seeds) is wasteful. Declare the sweep at the top of the template
config. Two forms:

**Single axis** — N values become N cells:

```json
"sweep": {
  "axis":   "seed",
  "path":   ".eval.seed_start",
  "values": [42, 43, 44, 45, 46, 47, 48, 49]
}
```

**Zipped multi-axis** — N parameters move together; one cell per tuple
(NOT a Cartesian product):

```json
"sweep": {
  "axis":  ["model", "spec_model"],
  "path":  [".server.model", ".server.speculative_config.model"],
  "values": [
    ["Qwen/Qwen3-8B",  "Tengyunw/qwen3_8b_eagle3"],
    ["Qwen/Qwen3-32B", "AngelSlim/Qwen3-32B_eagle3"]
  ]
}
```

Cell count = `len(values)`. Each row sets every paired field at once.
Tag suffix concatenates axis-name + filename-safe value across all axes
(`<base>_modelQwen_Qwen3_8B_spec_modelTengyunw_qwen3_8b_eagle3`).

**Cartesian product** — make `sweep` an array of axis specs. Each entry
is itself a single or zipped axis. Cells = product across all entries.

```json
"sweep": [
  { "axis": "topk", "path": ".server.compression_config.topk",
    "values": [50, 100, 200] },
  { "axis": "seed", "path": ".eval.seed_start",
    "values": [42, 43, 44, 45] }
]
```

→ 3 × 4 = 12 cells, tagged `<base>_topk50_seed42`, … , `<base>_topk200_seed45`.

You can mix forms freely — each entry in the array can be single or
zipped:

```json
"sweep": [
  { "axis":  ["model", "spec_model"],
    "path":  [".server.model", ".server.speculative_config.model"],
    "values": [["Qwen/Qwen3-8B",  "Tengyunw/qwen3_8b_eagle3"],
               ["Qwen/Qwen3-32B", "AngelSlim/Qwen3-32B_eagle3"]] },
  { "axis": "seed", "path": ".eval.seed_start",
    "values": [42, 43, 44, 45] }
]
```

→ 2 (paired model+spec) × 4 seeds = 8 cells.

Reference card:
- `axis` — short name(s) for tag (`<base>_<axis><value>`).
  String for single, array for zipped.
- `path` — jq path(s) to patch. Same shape as `axis`.
- `values` — flat list (single) or list of tuples (zipped).
  Auto-detected by element type.
- `sweep` itself — object for one axis spec (single or zipped),
  array for Cartesian across multiple.

When to split into multiple template files vs put it all in `sweep` —
when the configurations differ STRUCTURALLY (e.g. flash baseline has
`compression_config: null`, dual_cache has a populated object), keep
them in separate template files. When they only differ by leaf values
that all paths can reach, fold them into one template's `sweep`.

The batched dispatcher writes expanded cells to
`<exp>/sweep_runs/<ts>/<base>_<axis><val>.json`, drops the `.sweep`
field on each, and dispatches across the GPU pool. Templates with no
`.sweep` field pass through unchanged. Single-cell
`run_experiment.sh` ignores `.sweep` and runs the template's default
values — useful for smoke testing.

## Hard rules

- **No CLI flags for experiment parameters.** Single positional arg to
  the bash scripts; everything that varies between cells lives in JSON.
- **Config IS the record.** The runner snapshots `<config.json>` to
  `<exp>/results/<note>/_config.json` and `<exp>/logs/<note>_<ts>/_config.json`.
- **`.note` ≡ filename stem ≡ result subdir.** Reusing a note silently
  collides results and logs.
- **One cell per `run_experiment.sh` call.** Sweeps live in
  `batched_run_experiments.sh`. Don't fuse a sweep loop into a runner.
- **`_*.json` is not a runnable config.** The batched dispatcher skips
  these — use them for shared fragments / starter scaffolds (a fully
  populated config copied to make new ones).
- **Outputs land local to `<exp>/`.** Default convention:
  `<exp>/results/<note>/` for cell outputs, `<exp>/logs/<note>_<ts>/`
  for per-run logs. Don't write to the repo root.

## Adding a row to an existing experiment

1. Pick the closest existing config in `<exp>/configs/`.
2. `cp configs/<closest>.json configs/<new_note>.json`.
3. Edit `.note` to match the new filename stem; change only the differing
   fields. Don't ask the user for default values — copy from the parent.
4. Validate: `jq -e . configs/<new_note>.json >/dev/null`.
5. Run: `./run_experiment.sh configs/<new_note>.json`.

## Tabulating results

When asked for "the table", iterate `<exp>/results/*/`, score each, and
emit a markdown table. Format:

```
| Cell / method        | Metric₁ | Metric₂ | Metric₃ |
|----------------------|---------|---------|---------|
| <note A>             | …       | …       | …       |
| <note B>             | …       | …       | …       |
```

Flag missing cells / missing seeds explicitly — never silently average
over fewer samples than the cell asked for.

## Anti-patterns

- A repo-wide `scripts/` dir holding the dispatchers. Each experiment
  owns its own copy under `a_<high>/<detailed>/`.
- Per-experiment runner that doesn't snapshot the config (defeats
  "config IS the record").
- Reusing a `.note` (silent result collision).
- Sweep loops embedded in the runner (mix two layers of concept).
- Hand-writing N config files for a grid sweep. Use a small jq driver:
  ```bash
  for ratio in 0.6 0.7 0.8; do
    for limit in 128 256; do
      tag="r${ratio}_l${limit}"
      jq --arg t "$tag" --argjson r "$ratio" --argjson l "$limit" '
        .note = $t
        | .server.compression_config.gpu_kv_ratio = $r
        | .eval.limit = $l' \
        configs/_template.json > configs/${tag}.json
    done
  done
  GPU_LIST="0 1 2 3" ./batched_run_experiments.sh
  ```
- Editing the templates in this skill folder for a particular
  experiment. Improvements that benefit every experiment go into the
  skill templates; per-experiment quirks go in the local copy.
- A runner that doesn't propagate SIGTERM to its subprocesses (orphaned
  GPUs after the batched dispatcher kills the parent).
