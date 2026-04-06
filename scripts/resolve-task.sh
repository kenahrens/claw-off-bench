#!/usr/bin/env bash
set -euo pipefail

task_ref="${TASK_REF:-}"
task_id="${TASK_ID:-}"
task_instruction="${TASK_INSTRUCTION:-}"

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

if [[ -n "${task_ref}" ]]; then
  if [[ "${task_ref}" =~ ^TASK_([0-9]+)$ ]]; then
    idx="${BASH_REMATCH[1]}"
    if [[ "${idx}" -lt 1 || "${idx}" -gt "${#task_rows[@]}" ]]; then
      echo "error: ${task_ref} is out of range (1-${#task_rows[@]})" >&2
      exit 1
    fi
    row="${task_rows[$((idx - 1))]}"
    task_id="${row%%$'\t'*}"
    task_instruction="${row#*$'\t'}"
  else
    found="false"
    for row in "${task_rows[@]}"; do
      row_id="${row%%$'\t'*}"
      if [[ "${row_id}" == "${task_ref}" ]]; then
        task_id="${row_id}"
        task_instruction="${row#*$'\t'}"
        found="true"
        break
      fi
    done
    if [[ "${found}" != "true" ]]; then
      echo "error: TASK_REF must be TASK_<n> or a task id from tasks/tasks.yaml" >&2
      exit 1
    fi
  fi
fi

if [[ -z "${task_id}" || -z "${task_instruction}" ]]; then
  echo "error: provide TASK_REF or both TASK_ID and TASK_INSTRUCTION" >&2
  exit 1
fi

printf '%s\t%s\n' "${task_id}" "${task_instruction}"
