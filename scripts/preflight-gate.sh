#!/usr/bin/env bash
set -euo pipefail

comparison_mode="${COMPARISON_MODE:-available}"
agent_filter="${AGENT_FILTER:-}"
matrix_strict="${MATRIX_STRICT:-false}"

if ! [[ "${comparison_mode}" =~ ^(available|full5)$ ]]; then
  echo "error: COMPARISON_MODE must be available or full5" >&2
  exit 1
fi

if ! [[ "${matrix_strict}" =~ ^(true|false)$ ]]; then
  echo "error: MATRIX_STRICT must be true or false" >&2
  exit 1
fi

if [[ "${comparison_mode}" == "full5" && -n "${agent_filter}" ]]; then
  echo "error: COMPARISON_MODE=full5 requires AGENT_FILTER to be empty" >&2
  exit 1
fi

effective_strict="${matrix_strict}"
if [[ "${comparison_mode}" == "full5" ]]; then
  effective_strict="true"
elif [[ -n "${agent_filter}" ]]; then
  effective_strict="true"
fi

AGENT_FILTER="${agent_filter}" MATRIX_STRICT="${effective_strict}" make matrix-preflight

report_file="results/matrix-preflight.tsv"
if [[ ! -f "${report_file}" ]]; then
  echo "error: preflight report not found: ${report_file}" >&2
  exit 1
fi

if [[ "${comparison_mode}" == "full5" ]]; then
  selected_count="$(awk -F'\t' 'NR > 1 { count++ } END { print count + 0 }' "${report_file}")"
  if [[ "${selected_count}" -ne 5 ]]; then
    echo "error: COMPARISON_MODE=full5 requires 5 configured agents; found ${selected_count}" >&2
    exit 1
  fi
fi

echo "preflight gate passed (mode=${comparison_mode}, strict=${effective_strict})"
