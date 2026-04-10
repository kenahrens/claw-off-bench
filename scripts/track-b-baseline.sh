#!/usr/bin/env bash
set -euo pipefail

task_filter="${TASK_FILTER:-B001,B002,B003}"
repeat_count="${REPEAT_COUNT:-1}"
agent_filter="${AGENT_FILTER:-}"
matrix_strict="${MATRIX_STRICT:-false}"
require_github_token="${REQUIRE_GITHUB_TOKEN:-false}"

if ! [[ "${matrix_strict}" =~ ^(true|false)$ ]]; then
  echo "error: MATRIX_STRICT must be true or false" >&2
  exit 1
fi

if ! [[ "${require_github_token}" =~ ^(true|false)$ ]]; then
  echo "error: REQUIRE_GITHUB_TOKEN must be true or false" >&2
  exit 1
fi

if ! [[ "${repeat_count}" =~ ^[0-9]+$ ]] || [[ "${repeat_count}" -lt 1 ]]; then
  echo "error: REPEAT_COUNT must be a positive integer" >&2
  exit 1
fi

echo "[track-b] setup resources"
make setup

echo "[track-b] verify cluster secrets"
REQUIRE_GITHUB_TOKEN="${require_github_token}" ./scripts/check-cluster-secrets.sh

echo "[track-b] sync workspace"
make sync-workspace

echo "[track-b] apply egress policy"
make setup-egress

if [[ -z "${agent_filter}" || ",${agent_filter}," == *",zeroclaw," ]]; then
  echo "[track-b] ensure zeroclaw adapter image"
  if ! docker image inspect zeroclaw-adapter:latest >/dev/null 2>&1; then
    make build-zeroclaw-adapter
  fi
fi

echo "[track-b] run deterministic matrix"
TASKS_FILE="tasks/track-b-tasks.yaml" \
TASK_FILTER="${task_filter}" \
REPEAT_COUNT="${repeat_count}" \
AGENT_FILTER="${agent_filter}" \
MATRIX_STRICT="${matrix_strict}" \
TRACK_B_EVAL=true \
TRACK_B_RESET_WORKSPACE=true \
VALIDATE_RESULT=false \
make run-matrix

echo "[track-b] collect logs"
make collect

echo "[track-b] score objective gates"
make score-track-b

echo "[track-b] done (results/track-b-summary.json, raw logs under results/raw/)"
