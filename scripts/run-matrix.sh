#!/usr/bin/env bash
set -euo pipefail

matrix_file="${AGENT_MATRIX_FILE:-config/agents.csv}"
repeat_count="${REPEAT_COUNT:-1}"
agent_filter="${AGENT_FILTER:-}"

if [[ ! -f "${matrix_file}" ]]; then
  echo "error: agent matrix file not found: ${matrix_file}" >&2
  exit 1
fi

if ! [[ "${repeat_count}" =~ ^[0-9]+$ ]] || [[ "${repeat_count}" -lt 1 ]]; then
  echo "error: REPEAT_COUNT must be a positive integer" >&2
  exit 1
fi

mapfile -t task_rows < <(
  awk '
    /^[[:space:]]*-[[:space:]]id:/ {
      id = $3
      next
    }
    /^[[:space:]]*instruction:/ {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      print id "\t" line
    }
  ' tasks/tasks.yaml
)

if [[ "${#task_rows[@]}" -eq 0 ]]; then
  echo "error: no tasks found in tasks/tasks.yaml" >&2
  exit 1
fi

failures=0
runs=0

while IFS=',' read -r agent _stars _runtime _footprint _use_case image template bin; do
  [[ -z "${agent}" ]] && continue

  if [[ -n "${agent_filter}" ]]; then
    if [[ ",${agent_filter}," != *",${agent},"* ]]; then
      continue
    fi
  fi

  for task_row in "${task_rows[@]}"; do
    task_id="${task_row%%$'\t'*}"
    task_instruction="${task_row#*$'\t'}"

    for run_index in $(seq 1 "${repeat_count}"); do
      runs=$((runs + 1))
      run_task_id="${task_id}r${run_index}"

      echo "[run ${runs}] ${agent} ${run_task_id}"

      if ! AGENT_NAME="${agent}" \
        AGENT_IMAGE="${image}" \
        AGENT_TEMPLATE="${template}" \
        AGENT_BIN="${bin}" \
        TASK_ID="${run_task_id}" \
        TASK_INSTRUCTION="${task_instruction}" \
        ./scripts/run-task.sh; then
        failures=$((failures + 1))
        echo "failed: ${agent} ${run_task_id}" >&2
      fi
    done
  done
done < <(tail -n +2 "${matrix_file}")

if [[ "${failures}" -gt 0 ]]; then
  echo "completed with ${failures} failed runs" >&2
  exit 1
fi

echo "completed ${runs} total runs"
