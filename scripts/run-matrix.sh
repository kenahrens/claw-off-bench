#!/usr/bin/env bash
set -euo pipefail

matrix_file="${AGENT_MATRIX_FILE:-config/agents.csv}"
repeat_count="${REPEAT_COUNT:-1}"
agent_filter="${AGENT_FILTER:-}"
matrix_strict="${MATRIX_STRICT:-false}"
preflight_only="${PREFLIGHT_ONLY:-false}"

if [[ ! -f "${matrix_file}" ]]; then
  echo "error: agent matrix file not found: ${matrix_file}" >&2
  exit 1
fi

if ! [[ "${repeat_count}" =~ ^[0-9]+$ ]] || [[ "${repeat_count}" -lt 1 ]]; then
  echo "error: REPEAT_COUNT must be a positive integer" >&2
  exit 1
fi

if ! [[ "${matrix_strict}" =~ ^(true|false)$ ]]; then
  echo "error: MATRIX_STRICT must be true or false" >&2
  exit 1
fi

if ! [[ "${preflight_only}" =~ ^(true|false)$ ]]; then
  echo "error: PREFLIGHT_ONLY must be true or false" >&2
  exit 1
fi

if command -v minikube >/dev/null 2>&1 && [[ "$(kubectl config current-context 2>/dev/null || true)" == "minikube" ]]; then
  eval "$(minikube docker-env)"
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

mkdir -p results
preflight_report="results/matrix-preflight.tsv"
printf 'agent\timage\tstatus\treason\n' > "${preflight_report}"

selected_rows=()
while IFS=',' read -r agent _stars _runtime _footprint _use_case image template bin; do
  [[ -z "${agent}" ]] && continue

  if [[ -n "${agent_filter}" && ",${agent_filter}," != *",${agent},"* ]]; then
    continue
  fi

  selected_rows+=("${agent},${image},${template},${bin}")
done < <(tail -n +2 "${matrix_file}")

if [[ "${#selected_rows[@]}" -eq 0 ]]; then
  echo "error: no agents selected after applying AGENT_FILTER" >&2
  exit 1
fi

available_rows=()
unavailable_count=0

for row in "${selected_rows[@]}"; do
  IFS=',' read -r agent image template bin <<< "${row}"

  if [[ -z "${bin}" || -z "${template}" ]]; then
    printf '%s\t%s\tunavailable\tmissing bin/template in matrix\n' "${agent}" "${image}" >> "${preflight_report}"
    unavailable_count=$((unavailable_count + 1))
    continue
  fi

  if docker image inspect "${image}" >/dev/null 2>&1; then
    printf '%s\t%s\tavailable\talready present locally\n' "${agent}" "${image}" >> "${preflight_report}"
    available_rows+=("${row}")
    continue
  fi

  if docker pull "${image}" >/tmp/matrix-pull-${agent}.log 2>&1; then
    printf '%s\t%s\tavailable\tpull succeeded\n' "${agent}" "${image}" >> "${preflight_report}"
    available_rows+=("${row}")
  else
    reason="$(tr '\n' ' ' < /tmp/matrix-pull-${agent}.log | sed -E 's/[[:space:]]+/ /g' | cut -c1-180)"
    printf '%s\t%s\tunavailable\t%s\n' "${agent}" "${image}" "${reason}" >> "${preflight_report}"
    unavailable_count=$((unavailable_count + 1))
  fi
done

echo "wrote preflight report to ${preflight_report}"

if [[ "${matrix_strict}" == "true" && "${unavailable_count}" -gt 0 ]]; then
  echo "error: matrix preflight found ${unavailable_count} unavailable agents and MATRIX_STRICT=true" >&2
  exit 1
fi

if [[ "${preflight_only}" == "true" ]]; then
  echo "preflight completed"
  exit 0
fi

if [[ "${#available_rows[@]}" -eq 0 ]]; then
  echo "error: no available agents to run after preflight" >&2
  exit 1
fi

failures=0
runs=0

for row in "${available_rows[@]}"; do
  IFS=',' read -r agent image template bin <<< "${row}"

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
done

if [[ "${failures}" -gt 0 ]]; then
  echo "completed with ${failures} failed runs" >&2
  exit 1
fi

echo "completed ${runs} total runs"
