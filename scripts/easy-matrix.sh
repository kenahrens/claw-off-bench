#!/usr/bin/env bash
set -euo pipefail

agent_filter="${AGENT_FILTER:-}"
repeat_count="${REPEAT_COUNT:-1}"
default_provider="${DEFAULT_PROVIDER:-openrouter}"
default_model="${DEFAULT_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}"

if [[ -z "${LLM_API_KEY:-}" && -n "${OPENROUTER_API_KEY:-}" ]]; then
  export LLM_API_KEY="${OPENROUTER_API_KEY}"
fi

if [[ -z "${LLM_API_KEY:-}" ]]; then
  echo "error: set OPENROUTER_API_KEY (or LLM_API_KEY) before running easy-matrix" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="chat-only-not-used"
fi

export DEFAULT_PROVIDER="${default_provider}" DEFAULT_MODEL="${default_model}"

echo "[easy-matrix] setup resources"
make setup

echo "[easy-matrix] apply secrets"
REQUIRE_GITHUB_TOKEN=false make setup-secrets

echo "[easy-matrix] sync workspace"
make sync-workspace

echo "[easy-matrix] apply egress policy"
make setup-egress

if [[ -z "${agent_filter}" || ",${agent_filter}," == *",zeroclaw," ]]; then
  echo "[easy-matrix] build zeroclaw adapter"
  make build-zeroclaw-adapter
fi

effective_agents="${agent_filter:-all}"
echo "[easy-matrix] run matrix (agents=${effective_agents}, repeats=${repeat_count})"
REQUIRE_GITHUB_TOKEN=false AGENT_FILTER="${agent_filter}" REPEAT_COUNT="${repeat_count}" make run-matrix

echo "[easy-matrix] collect logs"
make collect
