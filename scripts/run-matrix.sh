#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kube.sh
source "${script_dir}/lib/kube.sh"

matrix_file="${AGENT_MATRIX_FILE:-config/agents.csv}"
safety_file="${AGENT_SAFETY_FILE:-config/agents-safety.csv}"
repeat_count="${REPEAT_COUNT:-1}"
agent_filter="${AGENT_FILTER:-}"
matrix_strict="${MATRIX_STRICT:-false}"
preflight_only="${PREFLIGHT_ONLY:-false}"
matrix_default_provider="${DEFAULT_PROVIDER:-openai}"
matrix_default_model="${DEFAULT_MODEL:-gpt-4o-mini}"
task_filter="${TASK_FILTER:-T001,T002}"
tasks_file="${TASKS_FILE:-tasks/tasks.yaml}"
fail_fast="${FAIL_FAST:-true}"
cleanup_on_timeout="${CLEANUP_ON_TIMEOUT:-true}"
auto_clean_runners="${AUTO_CLEAN_RUNNERS:-true}"
track_b_reset_workspace="${TRACK_B_RESET_WORKSPACE:-false}"
max_total_runs="${MAX_TOTAL_RUNS:-0}"
max_failed_runs="${MAX_FAILED_RUNS:-0}"
max_wall_clock_min="${MAX_WALL_CLOCK_MIN:-0}"
max_anthropic_runs="${MAX_ANTHROPIC_RUNS:-0}"

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

if [[ ! -f "${matrix_file}" ]]; then
  echo "error: agent matrix file not found: ${matrix_file}" >&2
  exit 1
fi

if [[ ! -f "${safety_file}" ]]; then
  echo "error: agent safety file not found: ${safety_file}" >&2
  exit 1
fi

if [[ ! -f "${tasks_file}" ]]; then
  echo "error: tasks file not found: ${tasks_file}" >&2
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

if ! [[ "${fail_fast}" =~ ^(true|false)$ ]]; then
  echo "error: FAIL_FAST must be true or false" >&2
  exit 1
fi

if ! [[ "${cleanup_on_timeout}" =~ ^(true|false)$ ]]; then
  echo "error: CLEANUP_ON_TIMEOUT must be true or false" >&2
  exit 1
fi

if ! [[ "${auto_clean_runners}" =~ ^(true|false)$ ]]; then
  echo "error: AUTO_CLEAN_RUNNERS must be true or false" >&2
  exit 1
fi

if ! [[ "${track_b_reset_workspace}" =~ ^(true|false)$ ]]; then
  echo "error: TRACK_B_RESET_WORKSPACE must be true or false" >&2
  exit 1
fi

if ! is_non_negative_integer "${max_total_runs}"; then
  echo "error: MAX_TOTAL_RUNS must be a non-negative integer" >&2
  exit 1
fi

if ! is_non_negative_integer "${max_failed_runs}"; then
  echo "error: MAX_FAILED_RUNS must be a non-negative integer" >&2
  exit 1
fi

if ! is_non_negative_integer "${max_wall_clock_min}"; then
  echo "error: MAX_WALL_CLOCK_MIN must be a non-negative integer" >&2
  exit 1
fi

if ! is_non_negative_integer "${max_anthropic_runs}"; then
  echo "error: MAX_ANTHROPIC_RUNS must be a non-negative integer" >&2
  exit 1
fi

if [[ "${auto_clean_runners}" == "true" ]]; then
  kctl delete jobs -n claw-bench -l app=claw-runner --ignore-not-found >/dev/null || true
  kctl delete pods -n claw-bench -l app=claw-runner --ignore-not-found >/dev/null || true
fi

if command -v minikube >/dev/null 2>&1 && [[ "$(kctl config current-context 2>/dev/null || true)" == "minikube" ]]; then
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
  ' "${tasks_file}"
)

if [[ "${#task_rows[@]}" -eq 0 ]]; then
  echo "error: no tasks found in ${tasks_file}" >&2
  exit 1
fi

if [[ -n "${task_filter}" ]]; then
  filtered_task_rows=()
  for task_row in "${task_rows[@]}"; do
    task_id="${task_row%%$'\t'*}"
    if [[ ",${task_filter}," == *",${task_id},"* ]]; then
      filtered_task_rows+=("${task_row}")
    fi
  done
  task_rows=("${filtered_task_rows[@]}")
fi

if [[ "${#task_rows[@]}" -eq 0 ]]; then
  echo "error: no tasks selected after applying TASK_FILTER=${task_filter}" >&2
  exit 1
fi

echo "matrix defaults: provider=${matrix_default_provider} model=${matrix_default_model} tasks=${task_filter} fail_fast=${fail_fast} budgets(total=${max_total_runs} failed=${max_failed_runs} wall_min=${max_wall_clock_min} anthropic=${max_anthropic_runs})"

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
anthropic_runs=0
SECONDS=0

for row in "${available_rows[@]}"; do
  IFS=',' read -r agent image template bin <<< "${row}"

  safety_row="$(awk -F',' -v agent="${agent}" 'NR > 1 && $1 == agent { print $0; exit }' "${safety_file}")"

  if [[ -z "${safety_row}" ]]; then
    echo "error: missing safety policy for agent ${agent} in ${safety_file}" >&2
    exit 1
  fi

  IFS=',' read -r _policy_agent agent_wait_timeout agent_max_tool_iterations agent_approval_mode agent_cpu_request agent_cpu_limit agent_memory_request agent_memory_limit _policy_notes <<< "${safety_row}"

  if [[ -z "${agent_wait_timeout}" ]]; then
    echo "error: missing wait_timeout safety policy for agent ${agent}" >&2
    exit 1
  fi

  if [[ -z "${agent_approval_mode}" ]]; then
    echo "error: missing approval_mode safety policy for agent ${agent}" >&2
    exit 1
  fi

  if ! [[ "${agent_approval_mode}" =~ ^(default|strict|none)$ ]]; then
    echo "error: invalid approval_mode '${agent_approval_mode}' for agent ${agent}" >&2
    exit 1
  fi

  if [[ -n "${agent_max_tool_iterations}" ]]; then
    if ! [[ "${agent_max_tool_iterations}" =~ ^[0-9]+$ ]] || [[ "${agent_max_tool_iterations}" -lt 1 ]]; then
      echo "error: invalid max_tool_iterations '${agent_max_tool_iterations}' for agent ${agent}" >&2
      exit 1
    fi
  fi

  if [[ -z "${agent_cpu_request}" || -z "${agent_cpu_limit}" || -z "${agent_memory_request}" || -z "${agent_memory_limit}" ]]; then
    echo "error: missing resource safety policy for agent ${agent}" >&2
    exit 1
  fi

  for task_row in "${task_rows[@]}"; do
    task_id="${task_row%%$'\t'*}"
    task_instruction="${task_row#*$'\t'}"

    for run_index in $(seq 1 "${repeat_count}"); do
      if [[ "${max_total_runs}" -gt 0 && "${runs}" -ge "${max_total_runs}" ]]; then
        echo "error: stopping early because MAX_TOTAL_RUNS=${max_total_runs} was reached" >&2
        echo "completed ${runs} runs with ${failures} failures" >&2
        exit 1
      fi

      if [[ "${max_failed_runs}" -gt 0 && "${failures}" -ge "${max_failed_runs}" ]]; then
        echo "error: stopping early because MAX_FAILED_RUNS=${max_failed_runs} was reached" >&2
        echo "completed ${runs} runs with ${failures} failures" >&2
        exit 1
      fi

      if [[ "${max_wall_clock_min}" -gt 0 && "${SECONDS}" -ge $((max_wall_clock_min * 60)) ]]; then
        echo "error: stopping early because MAX_WALL_CLOCK_MIN=${max_wall_clock_min} was reached" >&2
        echo "completed ${runs} runs with ${failures} failures in $((SECONDS / 60))m$((SECONDS % 60))s" >&2
        exit 1
      fi

      if [[ "${matrix_default_provider}" == "anthropic" && "${max_anthropic_runs}" -gt 0 && "${anthropic_runs}" -ge "${max_anthropic_runs}" ]]; then
        echo "error: stopping early because MAX_ANTHROPIC_RUNS=${max_anthropic_runs} was reached" >&2
        echo "completed ${runs} runs with ${failures} failures" >&2
        exit 1
      fi

      runs=$((runs + 1))
      run_task_id="${task_id}r${run_index}"

      if [[ "${matrix_default_provider}" == "anthropic" ]]; then
        anthropic_runs=$((anthropic_runs + 1))
      fi

      echo "[run ${runs}] ${agent} ${run_task_id}"

      if [[ "${track_b_reset_workspace}" == "true" ]]; then
        ./scripts/sync-workspace.sh
      fi

      if ! AGENT_NAME="${agent}" \
        AGENT_IMAGE="${image}" \
        AGENT_TEMPLATE="${template}" \
        AGENT_BIN="${bin}" \
        DEFAULT_PROVIDER="${matrix_default_provider}" \
        DEFAULT_MODEL="${matrix_default_model}" \
        VALIDATE_RESULT=true \
        CLEANUP_ON_TIMEOUT="${cleanup_on_timeout}" \
        WAIT_TIMEOUT="${agent_wait_timeout}" \
        MAX_TOOL_ITERATIONS="${agent_max_tool_iterations}" \
        APPROVAL_MODE="${agent_approval_mode}" \
        RESOURCE_CPU_REQUEST="${agent_cpu_request}" \
        RESOURCE_CPU_LIMIT="${agent_cpu_limit}" \
        RESOURCE_MEMORY_REQUEST="${agent_memory_request}" \
        RESOURCE_MEMORY_LIMIT="${agent_memory_limit}" \
        TASK_ID="${run_task_id}" \
        TASK_INSTRUCTION="${task_instruction}" \
        ./scripts/run-task.sh; then
        failures=$((failures + 1))
        echo "failed: ${agent} ${run_task_id}" >&2

        if [[ "${max_failed_runs}" -gt 0 && "${failures}" -ge "${max_failed_runs}" ]]; then
          echo "error: stopping early because MAX_FAILED_RUNS=${max_failed_runs} was reached" >&2
          echo "completed ${runs} runs with ${failures} failures" >&2
          exit 1
        fi

        if [[ "${fail_fast}" == "true" ]]; then
          echo "error: stopping early because FAIL_FAST=true" >&2
          echo "completed with ${failures} failed runs" >&2
          exit 1
        fi
      fi
    done
  done
done

if [[ "${failures}" -gt 0 ]]; then
  echo "completed with ${failures} failed runs" >&2
  exit 1
fi

echo "completed ${runs} total runs"
