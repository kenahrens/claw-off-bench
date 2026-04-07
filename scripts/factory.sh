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

matrix_strict="${MATRIX_STRICT:-false}"
repeat_count="${REPEAT_COUNT:-1}"
agent_filter="${AGENT_FILTER:-}"
require_github_token="${REQUIRE_GITHUB_TOKEN:-false}"
allow_package_registries="${ALLOW_PACKAGE_REGISTRIES:-false}"

if [[ -z "${LLM_API_KEY:-}" && -n "${OPENROUTER_API_KEY:-}" ]]; then
  export LLM_API_KEY="${OPENROUTER_API_KEY}"
fi

if [[ -z "${LLM_API_KEY:-}" ]]; then
  echo "error: set OPENROUTER_API_KEY (or LLM_API_KEY) before running make factory" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="chat-only-not-used"
fi

if ! [[ "${matrix_strict}" =~ ^(true|false)$ ]]; then
  echo "error: MATRIX_STRICT must be true or false" >&2
  exit 1
fi

if ! [[ "${repeat_count}" =~ ^[0-9]+$ ]] || [[ "${repeat_count}" -lt 1 ]]; then
  echo "error: REPEAT_COUNT must be a positive integer" >&2
  exit 1
fi

if ! [[ "${require_github_token}" =~ ^(true|false)$ ]]; then
  echo "error: REQUIRE_GITHUB_TOKEN must be true or false" >&2
  exit 1
fi

if ! [[ "${allow_package_registries}" =~ ^(true|false)$ ]]; then
  echo "error: ALLOW_PACKAGE_REGISTRIES must be true or false" >&2
  exit 1
fi

echo "[factory] setup resources"
make setup

echo "[factory] apply secrets"
REQUIRE_GITHUB_TOKEN="${require_github_token}" make setup-secrets

echo "[factory] sync workspace"
make sync-workspace

echo "[factory] apply egress policy"
ALLOW_PACKAGE_REGISTRIES="${allow_package_registries}" make setup-egress

if [[ -z "${agent_filter}" || ",${agent_filter}," == *",zeroclaw," ]]; then
  echo "[factory] build zeroclaw adapter"
  make build-zeroclaw-adapter
fi

effective_agents="${agent_filter:-all}"
echo "[factory] preflight matrix (agents=${effective_agents})"
AGENT_FILTER="${agent_filter}" MATRIX_STRICT="${matrix_strict}" make matrix-preflight

echo "[factory] run matrix (agents=${effective_agents}, repeats=${repeat_count})"
REQUIRE_GITHUB_TOKEN="${require_github_token}" AGENT_FILTER="${agent_filter}" MATRIX_STRICT="${matrix_strict}" REPEAT_COUNT="${repeat_count}" make run-matrix

echo "[factory] collect logs"
make collect

echo "[factory] score artifacts"
make score

echo "[factory] done (results/score.json, results/matrix-preflight.tsv)"
