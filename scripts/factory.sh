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
clean_start="${FACTORY_CLEAN_START:-true}"
use_existing_secrets="${FACTORY_USE_EXISTING_SECRETS:-true}"
build_zeroclaw_adapter="${BUILD_ZEROCLAW_ADAPTER:-auto}"
comparison_mode="${COMPARISON_MODE:-available}"

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

if ! [[ "${clean_start}" =~ ^(true|false)$ ]]; then
  echo "error: FACTORY_CLEAN_START must be true or false" >&2
  exit 1
fi

if ! [[ "${use_existing_secrets}" =~ ^(true|false)$ ]]; then
  echo "error: FACTORY_USE_EXISTING_SECRETS must be true or false" >&2
  exit 1
fi

if ! [[ "${build_zeroclaw_adapter}" =~ ^(auto|always|never)$ ]]; then
  echo "error: BUILD_ZEROCLAW_ADAPTER must be auto, always, or never" >&2
  exit 1
fi

if ! [[ "${comparison_mode}" =~ ^(available|full5)$ ]]; then
  echo "error: COMPARISON_MODE must be available or full5" >&2
  exit 1
fi

if [[ "${clean_start}" == "true" ]]; then
  echo "[factory] clean stage"
  make clean-bench
fi

echo "[factory] setup resources"
make setup

if [[ "${use_existing_secrets}" == "true" ]]; then
  echo "[factory] verify cluster secrets"
  REQUIRE_GITHUB_TOKEN="${require_github_token}" ./scripts/check-cluster-secrets.sh
else
  if [[ -z "${LLM_API_KEY:-}" && -n "${OPENROUTER_API_KEY:-}" ]]; then
    export LLM_API_KEY="${OPENROUTER_API_KEY}"
  fi

  if [[ -z "${LLM_API_KEY:-}" ]]; then
    echo "error: set OPENROUTER_API_KEY (or LLM_API_KEY) when FACTORY_USE_EXISTING_SECRETS=false" >&2
    exit 1
  fi

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    export GITHUB_TOKEN="chat-only-not-used"
  fi

  echo "[factory] apply secrets"
  REQUIRE_GITHUB_TOKEN="${require_github_token}" make setup-secrets
fi

echo "[factory] sync workspace"
make sync-workspace

echo "[factory] apply egress policy"
ALLOW_PACKAGE_REGISTRIES="${allow_package_registries}" make setup-egress

if [[ "${build_zeroclaw_adapter}" != "never" && ( -z "${agent_filter}" || ",${agent_filter}," == *",zeroclaw," ) ]]; then
  should_build="true"

  if [[ "${build_zeroclaw_adapter}" == "auto" ]] && docker image inspect zeroclaw-adapter:latest >/dev/null 2>&1; then
    should_build="false"
  fi

  if [[ "${should_build}" == "true" ]]; then
    echo "[factory] build zeroclaw adapter"
    make build-zeroclaw-adapter
  else
    echo "[factory] zeroclaw adapter present locally; skipping build"
  fi
fi

effective_agents="${agent_filter:-all}"
echo "[factory] preflight gate (mode=${comparison_mode}, agents=${effective_agents})"
COMPARISON_MODE="${comparison_mode}" AGENT_FILTER="${agent_filter}" MATRIX_STRICT="${matrix_strict}" ./scripts/preflight-gate.sh

echo "[factory] run matrix (agents=${effective_agents}, repeats=${repeat_count})"
REQUIRE_GITHUB_TOKEN="${require_github_token}" AGENT_FILTER="${agent_filter}" MATRIX_STRICT="${matrix_strict}" REPEAT_COUNT="${repeat_count}" make run-matrix

echo "[factory] collect logs"
make collect

echo "[factory] score artifacts"
make score

echo "[factory] build comparison summary"
make factory-summary

echo "[factory] done (results/score.json, results/matrix-preflight.tsv, results/factory-summary.json)"
