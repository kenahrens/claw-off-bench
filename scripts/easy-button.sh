#!/usr/bin/env bash
set -euo pipefail

mode="${EASY_MODE:-job}"
task_ref="${TASK_REF:-TASK_1}"
agent_name="${AGENT_NAME:-zeroclaw}"
agent_image="${AGENT_IMAGE:-zeroclaw-adapter:latest}"
default_provider="${DEFAULT_PROVIDER:-openrouter}"
default_model="${DEFAULT_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}"
wait_timeout="${WAIT_TIMEOUT:-120s}"

if [[ "${mode}" != "job" && "${mode}" != "daemon" ]]; then
  echo "error: EASY_MODE must be 'job' or 'daemon'" >&2
  exit 1
fi

if [[ "${agent_name}" != "zeroclaw" ]]; then
  echo "error: easy-button currently supports AGENT_NAME=zeroclaw only" >&2
  exit 1
fi

if [[ -z "${LLM_API_KEY:-}" && -n "${OPENROUTER_API_KEY:-}" ]]; then
  export LLM_API_KEY="${OPENROUTER_API_KEY}"
fi

if [[ -z "${LLM_API_KEY:-}" ]]; then
  echo "error: set OPENROUTER_API_KEY (or LLM_API_KEY) before running easy-button" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="chat-only-not-used"
fi

export DEFAULT_PROVIDER="${default_provider}" DEFAULT_MODEL="${default_model}"

echo "[easy] setup resources"
make setup

echo "[easy] apply secrets"
REQUIRE_GITHUB_TOKEN=false make setup-secrets

echo "[easy] sync workspace"
make sync-workspace

echo "[easy] apply egress policy"
make setup-egress

echo "[easy] build zeroclaw adapter"
make build-zeroclaw-adapter

if [[ "${mode}" == "job" ]]; then
  echo "[easy] run ${task_ref} in job mode"
  REQUIRE_GITHUB_TOKEN=false WAIT_TIMEOUT="${wait_timeout}" TASK_REF="${task_ref}" AGENT_NAME="${agent_name}" AGENT_IMAGE="${agent_image}" ./scripts/run-task.sh
else
  echo "[easy] run ${task_ref} in daemon mode"
  make remove-daemon
  DAEMON_NAME=zeroclaw-daemon AGENT_IMAGE="${agent_image}" DEFAULT_PROVIDER="${default_provider}" DEFAULT_MODEL="${default_model}" make deploy-daemon
  TASK_REF="${task_ref}" ./scripts/submit-daemon-task.sh
fi
