#!/usr/bin/env bash
set -euo pipefail

runs="${CONSISTENCY_RUNS:-2}"
agent_filter="${AGENT_FILTER:-openclaw,nemoclaw,picoclaw}"
default_provider="${DEFAULT_PROVIDER:-openai}"
default_model="${DEFAULT_MODEL:-gpt-4o-mini}"
portability_providers="${PORTABILITY_PROVIDERS:-openai,anthropic}"

if ! [[ "${runs}" =~ ^[0-9]+$ ]] || [[ "${runs}" -lt 2 ]]; then
  echo "error: CONSISTENCY_RUNS must be an integer >= 2" >&2
  exit 1
fi

mkdir -p results/consistency

build_signature() {
  local out_file="$1"
  python3 - "$out_file" <<'PY'
import json
import sys
from pathlib import Path

portability = json.loads(Path("results/portability-sweep.json").read_text(encoding="utf-8"))
track_b = json.loads(Path("results/track-b-summary.json").read_text(encoding="utf-8"))

portability_rows = []
for item in portability.get("results", []):
    portability_rows.append(
        {
            "agent": item.get("agent"),
            "provider": item.get("provider"),
            "status": item.get("status"),
            "failure_category": item.get("failure_category", ""),
        }
    )

track_b_rows = []
for item in track_b.get("summary", {}).get("tasks", []):
    track_b_rows.append(
        {
            "task_id": item.get("task_id"),
            "pass_rate": item.get("pass_rate"),
            "check_pass_rate": item.get("check_pass_rate"),
        }
    )

signature = {
    "portability": sorted(
        portability_rows,
        key=lambda x: (x.get("agent", ""), x.get("provider", "")),
    ),
    "track_b": sorted(track_b_rows, key=lambda x: x.get("task_id", "")),
}

Path(sys.argv[1]).write_text(json.dumps(signature, indent=2) + "\n", encoding="utf-8")
print(f"wrote {sys.argv[1]}")
PY
}

for run_index in $(seq 1 "${runs}"); do
  run_dir="results/consistency/run${run_index}"
  mkdir -p "${run_dir}"

  echo "[consistency] run ${run_index}/${runs}: reset + setup"
  make bench-reset
  AGENT_FILTER="${agent_filter}" make setup-stage

  echo "[consistency] run ${run_index}/${runs}: portability sweep"
  AGENT_FILTER="${agent_filter}" PORTABILITY_PROVIDERS="${portability_providers}" make portability-sweep

  echo "[consistency] run ${run_index}/${runs}: track-b baseline"
  AGENT_FILTER="${agent_filter}" \
    DEFAULT_PROVIDER="${default_provider}" \
    DEFAULT_MODEL="${default_model}" \
    FAIL_FAST=false \
    MAX_TOTAL_RUNS=9 \
    MAX_FAILED_RUNS=9 \
    MAX_WALL_CLOCK_MIN=40 \
    make track-b-baseline || true

  make score
  make score-track-b
  make findings-package

  cp results/portability-sweep.json "${run_dir}/portability-sweep.json"
  cp results/track-b-summary.json "${run_dir}/track-b-summary.json"
  cp results/findings-table.md "${run_dir}/findings-table.md"
  build_signature "${run_dir}/signature.json"
done

base_signature="results/consistency/run1/signature.json"
for run_index in $(seq 2 "${runs}"); do
  compare_signature="results/consistency/run${run_index}/signature.json"
  if ! cmp -s "${base_signature}" "${compare_signature}"; then
    echo "error: consistency check failed between run1 and run${run_index}" >&2
    echo "compare ${base_signature} vs ${compare_signature}" >&2
    exit 1
  fi
done

echo "consistency check passed across ${runs} runs"
