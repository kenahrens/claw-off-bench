#!/usr/bin/env bash
set -euo pipefail

profile_file="${EVAL_PROFILE_FILE:-config/eval.env}"

if [[ -f "${profile_file}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ -z "${!key+x}" ]]; then
      export "${key}=${value}"
    fi
  done < "${profile_file}"
fi

comparison_mode="${COMPARISON_MODE:-available}"
agent_filter="${AGENT_FILTER:-}"
matrix_strict="${MATRIX_STRICT:-false}"
default_provider="${DEFAULT_PROVIDER:-openai}"
default_model="${DEFAULT_MODEL:-gpt-4o-mini}"
require_budget_guards="${REQUIRE_BUDGET_GUARDS:-true}"
run_smoke_contracts="${RUN_SMOKE_CONTRACTS:-true}"
smoke_timeout="${PREFLIGHT_SMOKE_TIMEOUT:-180s}"

if [[ "${comparison_mode}" == "full5" ]]; then
  comparison_mode="full"
fi

if ! [[ "${comparison_mode}" =~ ^(available|full)$ ]]; then
  echo "error: COMPARISON_MODE must be available or full" >&2
  exit 1
fi

if ! [[ "${matrix_strict}" =~ ^(true|false)$ ]]; then
  echo "error: MATRIX_STRICT must be true or false" >&2
  exit 1
fi

if ! [[ "${require_budget_guards}" =~ ^(true|false)$ ]]; then
  echo "error: REQUIRE_BUDGET_GUARDS must be true or false" >&2
  exit 1
fi

if ! [[ "${run_smoke_contracts}" =~ ^(true|false)$ ]]; then
  echo "error: RUN_SMOKE_CONTRACTS must be true or false" >&2
  exit 1
fi

if ! [[ "${smoke_timeout}" =~ ^[0-9]+s$ ]]; then
  echo "error: PREFLIGHT_SMOKE_TIMEOUT must be seconds format like 180s" >&2
  exit 1
fi

if ! [[ "${default_provider}" =~ ^(openai|anthropic|ollama)$ ]]; then
  echo "error: DEFAULT_PROVIDER must be openai, anthropic, or ollama" >&2
  exit 1
fi

if [[ "${comparison_mode}" == "full" && -n "${agent_filter}" ]]; then
  echo "error: COMPARISON_MODE=full requires AGENT_FILTER to be empty" >&2
  exit 1
fi

effective_strict="${matrix_strict}"
if [[ "${comparison_mode}" == "full" ]]; then
  effective_strict="true"
elif [[ -n "${agent_filter}" ]]; then
  effective_strict="true"
fi

if [[ "${require_budget_guards}" == "true" ]]; then
  max_total_runs="${MAX_TOTAL_RUNS:-0}"
  max_failed_runs="${MAX_FAILED_RUNS:-0}"
  max_wall_clock_min="${MAX_WALL_CLOCK_MIN:-0}"
  max_anthropic_runs="${MAX_ANTHROPIC_RUNS:-0}"

  for value_name in max_total_runs max_failed_runs max_wall_clock_min max_anthropic_runs; do
    value="${!value_name}"
    if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
      echo "error: budget guard ${value_name} must be a non-negative integer" >&2
      exit 1
    fi
  done

  if [[ "${max_total_runs}" -le 0 ]]; then
    echo "error: MAX_TOTAL_RUNS must be > 0 for guarded runs" >&2
    exit 1
  fi

  if [[ "${max_failed_runs}" -le 0 ]]; then
    echo "error: MAX_FAILED_RUNS must be > 0 for guarded runs" >&2
    exit 1
  fi

  if [[ "${max_wall_clock_min}" -le 0 ]]; then
    echo "error: MAX_WALL_CLOCK_MIN must be > 0 for guarded runs" >&2
    exit 1
  fi

  if [[ "${default_provider}" == "anthropic" && "${max_anthropic_runs}" -le 0 ]]; then
    echo "error: MAX_ANTHROPIC_RUNS must be > 0 when DEFAULT_PROVIDER=anthropic" >&2
    exit 1
  fi
fi

AGENT_FILTER="${agent_filter}" MATRIX_STRICT="${effective_strict}" make matrix-preflight

report_file="results/matrix-preflight.tsv"
if [[ ! -f "${report_file}" ]]; then
  echo "error: preflight report not found: ${report_file}" >&2
  exit 1
fi

if [[ "${comparison_mode}" == "full" ]]; then
  configured_count="$(awk -F',' 'NR > 1 { count++ } END { print count + 0 }' config/agents.csv)"
  selected_count="$(awk -F'\t' 'NR > 1 { count++ } END { print count + 0 }' "${report_file}")"
  if [[ "${selected_count}" -ne "${configured_count}" ]]; then
    echo "error: COMPARISON_MODE=full requires ${configured_count} configured agents; found ${selected_count}" >&2
    exit 1
  fi
fi

if [[ "${run_smoke_contracts}" == "true" ]]; then
  mapfile -t available_agents < <(awk -F'\t' 'NR > 1 && $3 == "available" { print $1 }' "${report_file}")

  if [[ "${#available_agents[@]}" -eq 0 ]]; then
    echo "error: no available agents found for smoke contract checks" >&2
    exit 1
  fi

  echo "preflight smoke contracts: provider=${default_provider} model=${default_model} timeout=${smoke_timeout}"
  for agent in "${available_agents[@]}"; do
    echo "- smoke ${agent}"
    if ! AGENT_NAME="${agent}" \
      SMOKE_PROVIDER="${default_provider}" \
      SMOKE_MODEL="${default_model}" \
      SMOKE_WAIT_TIMEOUT="${smoke_timeout}" \
      ./scripts/run-smoke-one.sh >/tmp/preflight-smoke-${agent}.log 2>&1; then
      reason="$(tr '\n' ' ' < /tmp/preflight-smoke-${agent}.log | sed -E 's/[[:space:]]+/ /g' | cut -c1-220)"
      echo "error: smoke contract failed for ${agent} (${default_provider}/${default_model}): ${reason}" >&2
      exit 1
    fi
  done
fi

echo "preflight gate passed (mode=${comparison_mode}, strict=${effective_strict})"
